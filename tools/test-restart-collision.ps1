<#
  test-restart-collision.ps1 —— 回归夹具：复现 2026-09-14 那次「看门狗把重启当崩溃、回滚又把端口搞死」的事故

  ── 事故场景（真机日志实证的那次）────────────────────────────────────────────
    用户双击桌面图标 → 外壳启动器**先杀掉 3101 旧服务、再起新的**（端口有几秒不在）
    → 旧判据把这 5 秒判成「明确崩溃」（因为它看到"启动器记录在案但进程没了"）
    → 又正好落在「插件变更后」的窗口里 → 触发自动回滚、把刚装的插件移除
    → 回滚流程随后又去拉 3101，与外壳刚起的服务**撞端口**（EADDRINUSE）
    → 3101 再也起不来、桌面端打不开。

  ── 本夹具断言（全部在影子环境里跑，绝不碰真 profile）───────────────────────
    A 刚还在跑（宽限期内）                      → 不重启、不回滚
    B 不在很久、日志干净                        → 不重启、不回滚（用户自己关的）
    C 不在很久 + 日志有致命错误 + 近期动过插件  → **应当回滚**（救命的那个能力不能被改没）
    D 端口活着（但日志有错误）                  → 不回滚

  ── 证据用两处独立来源 ──────────────────────────────────────────────────────
    ① guard.log 里有没有 [ROLLBACK] 行
    ② profile 里那个"假插件"是否还在（回滚会把它移除）
    两个都同意才算通过 —— 单看日志容易被"日志没写全"骗过去。

  用法：powershell -File tools\test-restart-collision.ps1 [-Port 4399]
  退出码：0 = 全部通过；1 = 有用例失败
#>
param(
    [int]$Port = 4399,
    [string]$WorkRoot = ''
)

$ErrorActionPreference = 'Stop'
$proj = Split-Path $PSScriptRoot -Parent
if (-not $WorkRoot) { $WorkRoot = Join-Path $proj '_shadow\collide' }
$fakePkg = 'dsh-guard-test-plugin'          # 假插件名：回滚会把它从 bundles 里移除

$script:listener = $null
function Start-FakeDsh {
    param([int]$P)
    Stop-FakeDsh
    $script:listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $P)
    $script:listener.Start()
}
function Stop-FakeDsh {
    if ($script:listener) { try { $script:listener.Stop() } catch { }; $script:listener = $null }
}

# ---- 造一份最小可用的影子 profile（含假插件则说明"刚装过东西"）----------------
function New-CaseProfile {
    param([string]$ProfileDir, [switch]$WithFakePlugin)
    Remove-Item $ProfileDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
    $bundles = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', 'dsh-plugin')
    if ($WithFakePlugin) { $bundles += $fakePkg }
    $pkg = [ordered]@{
        name    = 'web'
        version = '0.0.0'
        dsh     = [ordered]@{ profile = [ordered]@{ bundles = $bundles } }
    }
    # ⚠️ 给 node/自身读的 JSON：必须**不带 BOM**（带 BOM 会让 JSON.parse 炸）
    [System.IO.File]::WriteAllText((Join-Path $ProfileDir 'package.json'),
        ($pkg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $ProfileDir 'cordis.patch.yml'),
        "# fixture`n", (New-Object System.Text.UTF8Encoding($false)))
    if ($WithFakePlugin) {
        $nm = Join-Path $ProfileDir "node_modules\$fakePkg"
        New-Item -ItemType Directory -Force -Path $nm | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $nm 'package.json'),
            '{"name":"' + $fakePkg + '","version":"0.0.1"}', (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Set-CaseState {
    <#  手写守护状态：夹具要精确控制"最后见到它在跑"和"最近插件变更"两个时间点  #>
    param(
        [string]$GuardHome,
        [int]$LastUpAgoSec = -1,        # -1 = 从没见它在跑
        [int]$PluginChangeAgoSec = -1,  # -1 = 没有插件变更记录
        [string]$LastGoodSnapshot = ''
    )
    $stateDir = Join-Path $GuardHome 'state'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $st = [ordered]@{
        lastGoodSnapshot   = $LastGoodSnapshot
        goodHistory        = @()
        badSnapshots       = @()
        lastPluginChange   = $(if ($PluginChangeAgoSec -ge 0) { (Get-Date).AddSeconds(-$PluginChangeAgoSec).ToString('yyyy-MM-dd HH:mm:ss.fff') } else { $null })
        pluginChangeCount  = $(if ($PluginChangeAgoSec -ge 0) { 1 } else { 0 })
        quarantineUntil    = $null
        pendingSnapshot    = $null
        pendingHash        = $null
        lastSeenHash       = $null
        profileSignature   = $null
        lastLauncherPid    = 0
        launcherChanged    = $false
        logOffset          = 0
        errorTimes         = @()
        consecutiveRollback = 0
        lastRollbackAt     = $null
        lastUpAt           = $(if ($LastUpAgoSec -ge 0) { (Get-Date).AddSeconds(-$LastUpAgoSec).ToString('yyyy-MM-dd HH:mm:ss.fff') } else { $null })
        downSince          = $null
        updatedAt          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    }
    [System.IO.File]::WriteAllText((Join-Path $stateDir 'guard-state.json'),
        ($st | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Cycle {
    param([string]$Root, [string]$GuardHome)
    $env:DSH_HOME = Join-Path $Root '.dsh'
    $env:DSHGUARD_HOME = $GuardHome
    $env:DSH_WEB_URL = "http://127.0.0.1:$Port"
    $env:DSHGUARD_AUTO_RESTART = '0'
    $env:DSHGUARD_AUTO_START_DSH = '0'
    $out = Join-Path $Root 'once.json'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'lib\watchdog.ps1') `
        -Profile web -WebPort $Port -Once -Out $out *> $null
    return $LASTEXITCODE
}

function Read-GuardLog {
    param([string]$GuardHome)
    $f = Join-Path $GuardHome 'logs\guard.log'
    # ⚠️ 必须显式 -Encoding UTF8：guard.log 是无 BOM 的 UTF-8，5.1 的 Get-Content 默认按 ANSI/GBK 读，
    #    中文会被读成乱码 → 断言里那些中文关键词（"宽限"/"没有致命错误证据"）**永远匹配不上**。
    #    这是夹具第一版自己的 bug，靠"用例 A 明明该过却报没有宽限字样"才看出来。
    if (Test-Path $f) { return @(Get-Content $f -Encoding UTF8) }
    return @()
}

$results = @()
function Assert-Case {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $script:results += [pscustomobject]@{ Case = $Name; Pass = $Pass; Detail = $Detail }
    $tag = if ($Pass) { '[PASS]' } else { '[FAIL]' }
    Write-Host ("  {0} {1} —— {2}" -f $tag, $Name, $Detail)
}

Write-Host ''
Write-Host '=== 重启对撞回归夹具（影子环境，端口 ' -NoNewline
Write-Host "$Port" -NoNewline
Write-Host '）==='
Write-Host "  工作根目录：$WorkRoot"
Write-Host ''

# ══════════════════════════════════════════════ A：刚还在跑（宽限期内）—— 不应回滚
$root = Join-Path $WorkRoot 'A-grace'
$guardHome = Join-Path $root 'guardhome'
$prof = Join-Path $root '.dsh\profiles\web'
New-CaseProfile -ProfileDir $prof -WithFakePlugin
Set-CaseState -GuardHome $guardHome -LastUpAgoSec 3 -PluginChangeAgoSec 30
Stop-FakeDsh                                   # 端口不在：模拟"外壳刚把旧服务杀掉"
$null = Invoke-Cycle -Root $root -GuardHome $guardHome
$log = Read-GuardLog -GuardHome $guardHome
$rolled = [bool](@($log | Select-String '\[ROLLBACK\]').Count)
$fakeStill = Test-Path (Join-Path $prof "node_modules\$fakePkg")
$graceMsg = [bool](@($log | Select-String '宽限').Count)
Assert-Case 'A 刚还在跑（宽限内）不回滚' ((-not $rolled) -and $fakeStill) `
    ("guard.log 有 ROLLBACK=$rolled（期望 False）；假插件还在=$fakeStill（期望 True）；日志提到宽限=$graceMsg")

# ══════════════════════════════════════════════ B：不在很久但日志干净 —— 不应回滚
$root = Join-Path $WorkRoot 'B-clean'
$guardHome = Join-Path $root 'guardhome'
$prof = Join-Path $root '.dsh\profiles\web'
New-CaseProfile -ProfileDir $prof -WithFakePlugin
Set-CaseState -GuardHome $guardHome -LastUpAgoSec 600 -PluginChangeAgoSec 30
Stop-FakeDsh
$null = Invoke-Cycle -Root $root -GuardHome $guardHome
$log = Read-GuardLog -GuardHome $guardHome
$rolled = [bool](@($log | Select-String '\[ROLLBACK\]').Count)
$fakeStill = Test-Path (Join-Path $prof "node_modules\$fakePkg")
$cleanMsg = [bool](@($log | Select-String '没有致命错误证据').Count)
Assert-Case 'B 不在很久但日志干净 → 不回滚' ((-not $rolled) -and $fakeStill -and $cleanMsg) `
    ("ROLLBACK=$rolled（期望 False）；假插件还在=$fakeStill（期望 True）；日志提到「没有致命错误证据」=$cleanMsg")

# ══════════════════════════════════════════════ C：不在很久 + 致命错误 + 近期动过插件 —— 应当回滚
$root = Join-Path $WorkRoot 'C-fatal'
$guardHome = Join-Path $root 'guardhome'
$prof = Join-Path $root '.dsh\profiles\web'
New-CaseProfile -ProfileDir $prof                 # 先不含假插件 → 它就是"上一个好版本"
$env:DSH_HOME = Join-Path $root '.dsh'
$env:DSHGUARD_HOME = $guardHome
$env:DSH_WEB_URL = "http://127.0.0.1:$Port"
$out = Join-Path $root 'snap.json'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'lib\guard.ps1') `
    -Action snapshot -Profile web -Reason fixture-baseline -WebPort $Port -Out $out *> $null
$baseSnap = ''
if (Test-Path $out) {
    $snapRes = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json
    $baseSnap = [string]$snapRes.dir
    if (-not $baseSnap -and $snapRes.name) { $baseSnap = Join-Path $guardHome ("snapshots\" + $snapRes.name) }
}
New-CaseProfile -ProfileDir $prof -WithFakePlugin   # 现在"刚装了个插件"
Set-CaseState -GuardHome $guardHome -LastUpAgoSec 600 -PluginChangeAgoSec 30 -LastGoodSnapshot $baseSnap
# 日志里造一条**真会被 ErrorPatterns 命中**的致命错误
$logDir = Join-Path $guardHome 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $logDir 'dsh-web.log'),
    "2026-09-14 00:00:00 Failed to load plugins: dsh-guard-test-plugin`n", (New-Object System.Text.UTF8Encoding($false)))
Stop-FakeDsh
$null = Invoke-Cycle -Root $root -GuardHome $guardHome
$log = Read-GuardLog -GuardHome $guardHome
$rolled = [bool](@($log | Select-String '\[ROLLBACK\]').Count)
$fakeGone = -not (Test-Path (Join-Path $prof "node_modules\$fakePkg"))
Assert-Case 'C 起不来 + 近期动过插件 → 应该回滚（救命能力仍在）' ($rolled -and $fakeGone) `
    ("ROLLBACK=$rolled（期望 True）；假插件已被移除=$fakeGone（期望 True）；基线快照=$baseSnap")

# ══════════════════════════════════════════════ D：端口活着 —— 不应回滚
$root = Join-Path $WorkRoot 'D-up'
$guardHome = Join-Path $root 'guardhome'
$prof = Join-Path $root '.dsh\profiles\web'
New-CaseProfile -ProfileDir $prof -WithFakePlugin
Set-CaseState -GuardHome $guardHome -LastUpAgoSec 600 -PluginChangeAgoSec 30
$logDir = Join-Path $guardHome 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $logDir 'dsh-web.log'),
    "2026-09-14 00:00:00 Failed to load plugins: whatever`n", (New-Object System.Text.UTF8Encoding($false)))
Start-FakeDsh -P $Port                          # 端口活着 = 服务在跑
Start-Sleep -Milliseconds 300
$null = Invoke-Cycle -Root $root -GuardHome $guardHome
Stop-FakeDsh
$log = Read-GuardLog -GuardHome $guardHome
$rolled = [bool](@($log | Select-String '\[ROLLBACK\]').Count)
$fakeStill = Test-Path (Join-Path $prof "node_modules\$fakePkg")
Assert-Case 'D 端口活着 → 不回滚' ((-not $rolled) -and $fakeStill) `
    ("ROLLBACK=$rolled（期望 False）；假插件还在=$fakeStill（期望 True）")

# ══════════════════════════════════════════════ E：升级路径 —— 状态文件缺少新字段
#  2026-09-14 真机事故（安装器落地自检当场报红）：
#    新版给状态加了 lastUpAt / downSince，而磁盘上还是**旧版写的**状态文件；
#    而给 PSCustomObject 赋一个不存在的属性会**直接抛异常** →
#    升级后第一轮巡检就崩：「设置"lastUpAt"时发生异常:"在此对象上找不到属性"lastUpAt"」。
#  这条用例守两件事：**全新的状态文件** 与 **老状态文件**，都必须能安全跑完一轮。
foreach ($variant in @('no-state-file', 'legacy-state-file')) {
    $root = Join-Path $WorkRoot ("E-" + $variant)
    $guardHome = Join-Path $root 'guardhome'
    $prof = Join-Path $root '.dsh\profiles\web'
    New-CaseProfile -ProfileDir $prof
    if ($variant -eq 'legacy-state-file') {
        Set-CaseState -GuardHome $guardHome -LastUpAgoSec -1
        $sf = Join-Path $guardHome 'state\guard-state.json'
        $st = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        $st.PSObject.Properties.Remove('lastUpAt') | Out-Null
        $st.PSObject.Properties.Remove('downSince') | Out-Null
        [System.IO.File]::WriteAllText($sf, ($st | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    }
    Stop-FakeDsh
    $null = Invoke-Cycle -Root $root -GuardHome $guardHome
    $out = Join-Path $root 'once.json'
    $ok = $false
    if (Test-Path $out) { try { $ok = [bool]((Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json).ok) } catch { $ok = $false } }
    $log = Read-GuardLog -GuardHome $guardHome
    $crash = [bool](@($log | Select-String '在此对象上找不到属性|Exception|异常').Count)
    Assert-Case ("E 升级路径（$variant）不崩") ($ok -and -not $crash) `
        ("-Once 结果 ok=$ok（期望 True）；日志含异常=$crash（期望 False）")
}

# ══════════════════════════════════════════════ 汇总
$fail = @($results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("=== 结果：{0}/{1} 通过 ===" -f ($results.Count - $fail.Count), $results.Count)
if ($fail.Count) {
    Write-Host '  失败用例：'
    $fail | ForEach-Object { Write-Host ("    · " + $_.Case) }
    exit 1
}
Write-Host '  结论：OK —— 重启不再被误判成崩溃；该救命时（起不来 + 近期装过插件）仍然会回滚'
exit 0
