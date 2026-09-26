# ============================================================================
#  guard.ps1 —— 插件版守护的命令行入口
#
#  宿主插件（lib/index.js）通过 spawn 调用它，结果**写进 -Out 指定的 JSON 文件**
#  （不靠 stdout 解析，避免日志噪音干扰）。
#
#  用法：
#    guard.ps1 -Action status   -Profile web -Out C:\...\r.json
#    guard.ps1 -Action list     -Profile web -Out ...
#    guard.ps1 -Action snapshot -Profile web -Reason manual -Out ...
#    guard.ps1 -Action rollback -Profile web [-Id <快照名或目录>] -Out ...
#    guard.ps1 -Action incidents -Profile web [-Limit 20] -Out ...
#
#  退出码：0 = 成功（JSON 里 ok=true）；1 = 失败（JSON 里 ok=false + error）
# ============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'list', 'snapshot', 'rollback', 'incidents', 'prune', 'delete', 'maint-start', 'maint-stop')]
    [string]$Action,

    [string]$Profile = 'web',
    [string]$Id      = '',
    [string]$Reason  = 'manual',
    # ⚠️ 不能叫 -Home：$HOME 是 PowerShell 只读自动变量，参数绑定会直接抛
    #    "Cannot overwrite variable Home because it is read-only or constant"（2026-09-14 实测踩到）。
    #    同一个坑在这个项目里出现过两次 —— build-shell.ps1 的 $Host 也是这个原因改名的。
    [string]$GuardHomeDir = '',
    # ⚠️ 默认 0 = "没指定" —— 让 guard-bootstrap.ps1 §4 的优先级去回退（显式 > DSH_WEB_URL > 3080）。
    #    这里写死 3080 会让默认值冒充"显式指定"，把环境变量回退整个盖掉。
    [int]   $WebPort = 0,
    [int]   $Limit   = 20,
    # prune 用：保留最近几个（0 = 用 Cfg.KeepSnapshots）
    [int]   $Keep    = 0,
    # maint-start 用：维护窗口多少分钟（0 = 30）
    [int]   $Minutes = 0,
    [string]$Note    = '',

    [Parameter(Mandatory = $true)]
    [string]$Out
)

$ErrorActionPreference = 'Stop'

function Write-Result($obj) {
    $json = $obj | ConvertTo-Json -Depth 8
    $dir = Split-Path -Parent $Out
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    . (Join-Path $PSScriptRoot 'guard-bootstrap.ps1') -ProfileName $Profile -GuardHome $GuardHomeDir -WebPort $WebPort
    . (Join-Path $PSScriptRoot 'guard-core.ps1')
    Initialize-DshGuardDirs
}
catch {
    # ⚠️ 2026-09-26：加上 stack —— 初始化失败原来只报一句 message，定位全靠猜
    #    （当天真实踩到："初始化失败: Cannot convert System.Object[] to System.Int32"，
    #     光看这句话完全不知道是 bootstrap/core/建目录 哪一步、哪一行）。
    Write-Result ([ordered]@{ ok = $false; action = $Action; error = "初始化失败: $($_.Exception.Message)"; stack = "$($_.ScriptStackTrace)"; at = "$($_.InvocationInfo.PositionMessage)" })
    exit 1
}

# 把内部快照对象压成面板要的字段（不把 package.json/patch 正文塞进 JSON）
#
# ⚠️ 必须写成 `return ,@(...)`：PowerShell 的函数返回会把**单元素数组拆开**，
#    于是 1 个快照时 ConvertTo-Json 输出的是对象而不是数组，面板的 Array.isArray
#    判断失败 → 界面上一个快照都不显示（2026-09-14 实测踩到）。
#    逗号运算符阻止这次拆包。
function Convert-Snapshots($snaps) {
    return ,@($snaps | ForEach-Object {
        $m = $_.Meta
        [ordered]@{
            name      = $_.Name
            dir       = $_.Dir
            label     = $m.label
            reason    = $m.reason
            createdAt = $m.createdAt
            sizeMB    = $m.sizeMB
            health    = $m.health
            hash      = $m.identity.hash
            depCount  = $m.identity.depCount
            nodeModules = [bool]$m.nodeModules
        }
    })
}

# 解析回滚目标：显式 Id > 守护状态里的 lastGoodSnapshot > 最近一个快照
function Resolve-RollbackTarget {
    param([string]$WantId)
    $snaps = @(Get-AllSnapshots)
    if (-not $snaps.Count) { return @{ Dir = ''; From = ''; How = 'none' } }

    if ($WantId) {
        $hit = $snaps | Where-Object { $_.Name -eq $WantId -or $_.Dir -eq $WantId } | Select-Object -First 1
        if ($hit) { return @{ Dir = $hit.Dir; From = $hit.Name; How = 'explicit' } }
        return @{ Dir = ''; From = $WantId; How = 'not-found' }
    }

    $st = Get-GuardState
    if ($st -and $st.lastGoodSnapshot -and (Test-Path $st.lastGoodSnapshot)) {
        return @{ Dir = $st.lastGoodSnapshot; From = (Split-Path $st.lastGoodSnapshot -Leaf); How = 'lastGood' }
    }

    $latest = $snaps | Select-Object -First 1
    return @{ Dir = $latest.Dir; From = $latest.Name; How = 'latest' }
}

$exitCode = 0
try {
    switch ($Action) {

        'status' {
            $snaps = @(Get-AllSnapshots)

            # 看门狗跑的是 <守护数据目录>\bin 里的**副本**，而那份只在"安装看门狗"时同步。
            # 于是很容易出现："我改了/更新了插件，但看门狗还在跑旧代码" —— 症状是某个新功能
            # （比如快照自动清理）死活不生效。这里把差异检测出来，界面就能提示用户重装。
            # ⚠️ 2026-09-14 用户报"快照没有自动清理"，根因就是这个。
            $scriptsStale = $false
            $staleFiles = @()
            # 哪一边旧：'bin' = 看门狗跑的是旧脚本；'plugin' = 插件目录那份是旧的。
            # ⚠️ 必须分方向，否则提示会指错动作：2026-09-14 就出现过"bin 是最新的、插件那份是旧的"，
            #    而提示却让用户去重装看门狗 —— 白跑一趟，警告还不会消失。
            $staleSide = ''
            $binDir = Join-Path $script:GuardHome 'bin'
            if ((Test-Path -LiteralPath $binDir) -and ($PSScriptRoot -ne $binDir)) {
                foreach ($n in @('guard-core.ps1', 'watchdog-core.ps1', 'watchdog.ps1', 'guard.ps1')) {
                    $srcF = Join-Path $PSScriptRoot $n
                    $binF = Join-Path $binDir $n
                    if ((Test-Path -LiteralPath $srcF) -and (Test-Path -LiteralPath $binF)) {
                        if ((Get-FileHash -LiteralPath $srcF).Hash -ne (Get-FileHash -LiteralPath $binF).Hash) {
                            $scriptsStale = $true
                            $staleFiles += $n
                            if (-not $staleSide) {
                                try {
                                    $srcT = (Get-Item -LiteralPath $srcF).LastWriteTime
                                    $binT = (Get-Item -LiteralPath $binF).LastWriteTime
                                    $staleSide = if ($srcT -gt $binT) { 'bin' } else { 'plugin' }
                                } catch { $staleSide = 'unknown' }
                            }
                        }
                    }
                }
            }
            $running = $false; $watchPid = 0
            if (Test-Path $script:LockFile) {
                try {
                    $lk = Read-JsonFile -Path $script:LockFile
                    if ($lk -and $lk.pid) { $watchPid = [int]$lk.pid; $running = Test-PidAlive -ProcessId $watchPid }
                } catch { }
            }
            $lastIncident = $null
            if (Test-Path $script:IncidentFile) {
                $tail = @(Get-Content $script:IncidentFile -Tail 1 -ErrorAction SilentlyContinue)
                if ($tail.Count -and $tail[0]) { try { $lastIncident = $tail[0] | ConvertFrom-Json } catch { } }
            }
            $idn = Get-ProfileIdentity
            Write-Result ([ordered]@{
                    ok            = $true
                    action        = 'status'
                    at            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    profile       = $script:ProfileName
                    profileDir    = $script:ProfileDir
                    profileExists = (Test-Path $script:ProfileDir)
                    guardHome     = $script:GuardHome
                    web           = [ordered]@{
                        port      = $script:WebPort
                        # 端口是从哪来的：explicit（面板/命令行传的）/ env（DSH_WEB_URL）/ default
                        # 面板要显示它 —— 猜错端口的表现是"看门狗以为 DSH 死了、反复重启"，
                        # 光看一个数字分辨不出来（2026-09-14 真启动实测踩到）。
                        portFrom  = $script:WebPortFrom
                        url       = $script:WebUrl
                        listening = (Test-TcpPort -Port $script:WebPort)
                    }
                    watchdog      = [ordered]@{
                        running  = $running
                        pid      = $watchPid
                        lockFile = $script:LockFile
                        # true = <守护数据目录>\bin 里的脚本与插件里的 lib 不一致（看门狗在跑旧代码）
                        scriptsStale = $scriptsStale
                        staleFiles   = @($staleFiles)
                        scriptStaleSide = $staleSide
                    }
                    # 维护窗口（guard.ps1 -Action maint-start 写的标记文件）
                    maintenanceActive = (Test-Path -LiteralPath (Join-Path $script:StateDir 'maintenance.json'))
                    profileIdentity = [ordered]@{
                        hash      = $idn.hash
                        depCount  = $idn.depCount
                        bundles   = @($idn.bundles)
                    }
                    snapshotCount = $snaps.Count
                    snapshots     = Convert-Snapshots $snaps
                    lastIncident  = $lastIncident
                })
        }

        'list' {
            Write-Result ([ordered]@{
                    ok        = $true
                    action    = 'list'
                    profile   = $script:ProfileName
                    snapshots = Convert-Snapshots @(Get-AllSnapshots)
                })
        }

        'snapshot' {
            $label = if ($Reason) { $Reason } else { 'manual' }
            $dir = New-ProfileSnapshot -Label $label -Reason 'manual'
            if (-not $dir) { throw '创建快照失败（看 guard.log）' }
            $meta = Get-SnapshotMeta -Dir $dir
            Write-Result ([ordered]@{
                    ok      = $true
                    action  = 'snapshot'
                    dir     = $dir
                    name    = (Split-Path $dir -Leaf)
                    label   = $meta.label
                    sizeMB  = $meta.sizeMB
                    hash    = $meta.identity.hash
                    depCount = $meta.identity.depCount
                    message = "已创建快照 $(Split-Path $dir -Leaf)（$($meta.sizeMB) MB）"
                })
        }

        'rollback' {
            $t = Resolve-RollbackTarget -WantId $Id
            if ($t.How -eq 'none') { throw '没有任何快照可回滚 —— 先打一个快照' }
            if ($t.How -eq 'not-found') { throw "找不到快照：$($t.From)" }

            $r = Restore-ProfileSnapshot -SnapshotDir $t.Dir -Force
            Write-Result ([ordered]@{
                    ok             = [bool]$r.Ok
                    action         = 'rollback'
                    how            = $t.How
                    restoredFrom   = $t.From
                    restoredDir    = $t.Dir
                    steps          = @($r.Steps)
                    message        = $r.Message
                    removedPackages = @($r.RemovedPackages)
                    restartNeeded  = [bool]$r.Ok
                })
            if (-not $r.Ok) { $exitCode = 1 }
        }

        # ---- 维护窗口：声明"接下来 N 分钟别动我" ----
        # 窗口内看门狗只记录、不重启、不回滚（Get-ShellMaintenance 读这个文件）。
        # 用途：你要重启 DSH / 改配置 / 换插件，不想让守护在这期间抢着处置。
        'maint-start' {
            $mins = if ($Minutes -gt 0) { $Minutes } else { 30 }
            $until = (Get-Date).AddMinutes($mins)
            $mf = Join-Path $script:StateDir 'maintenance.json'
            Write-JsonFile -Path $mf -Object ([ordered]@{
                    until = $until.ToString('yyyy-MM-dd HH:mm:ss')
                    note  = $Note
                    by    = 'guard.ps1'
                    at    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                })
            Write-GuardLog ("已开维护窗口：至 {0}（{1}）—— 期间守护只记录，不重启、不回滚" -f $until.ToString('HH:mm:ss'), $Note) -Level INFO
            Write-Result ([ordered]@{
                    ok      = $true
                    action  = 'maint-start'
                    until   = $until.ToString('yyyy-MM-dd HH:mm:ss')
                    note    = $Note
                    message = "已开维护窗口 $mins 分钟（至 $($until.ToString('HH:mm:ss'))）"
                })
        }

        'maint-stop' {
            $mf = Join-Path $script:StateDir 'maintenance.json'
            if (Test-Path -LiteralPath $mf) { Remove-Item -LiteralPath $mf -Force -ErrorAction SilentlyContinue }
            Write-GuardLog '维护窗口已关闭，守护恢复看护' -Level INFO
            Write-Result ([ordered]@{ ok = $true; action = 'maint-stop'; message = '维护窗口已关闭' })
        }

        'prune' {
            $keepN = if ($Keep -gt 0) { $Keep } else { $script:Cfg.KeepSnapshots }
            $before = @(Get-AllSnapshots).Count
            Remove-OldSnapshots -Keep $keepN
            $after = @(Get-AllSnapshots).Count
            Write-Result ([ordered]@{
                    ok      = $true
                    action  = 'prune'
                    keep    = $keepN
                    before  = $before
                    after   = $after
                    message = "清理完成：$before -> $after 个快照（保留最近 $keepN 个；标记为 lastGood 的永不删）"
                })
        }

        'delete' {
            if (-not $Id) { throw 'delete 需要 -Id（快照名或目录）' }
            $snaps = @(Get-AllSnapshots)
            $hit = $snaps | Where-Object { $_.Name -eq $Id -or $_.Dir -eq $Id } | Select-Object -First 1
            if (-not $hit) { throw "找不到快照：$Id" }
            $st = Get-GuardState
            if ($st -and $st.lastGoodSnapshot -and $hit.Dir -eq $st.lastGoodSnapshot) {
                throw "这个快照是当前标记的 lastGood（回滚基准），拒绝删除：$($hit.Name)"
            }
            Remove-Item -Recurse -Force -LiteralPath $hit.Dir -ErrorAction Stop
            Write-GuardLog "已删除快照 $($hit.Name)" -Level INFO
            Write-Result ([ordered]@{
                    ok      = $true
                    action  = 'delete'
                    deleted = $hit.Name
                    left    = @(Get-AllSnapshots).Count
                    message = "已删除快照 $($hit.Name)"
                })
        }

        'incidents' {
            $items = @()
            if (Test-Path $script:IncidentFile) {
                $lines = @(Get-Content $script:IncidentFile -Tail $Limit -ErrorAction SilentlyContinue)
                foreach ($ln in $lines) { if ($ln) { try { $items += ($ln | ConvertFrom-Json) } catch { } } }
            }
            Write-Result ([ordered]@{
                    ok        = $true
                    action    = 'incidents'
                    count     = $items.Count
                    incidents = $items
                })
        }
    }
}
catch {
    Write-Result ([ordered]@{
            ok     = $false
            action = $Action
            error  = $_.Exception.Message
            at     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        })
    $exitCode = 1
}

exit $exitCode
