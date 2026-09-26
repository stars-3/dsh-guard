<#
  Install-Plugin.ps1 —— 把 DSH Guard 装进 DSH profile（默认 web）

  机制与 DSH-Desktop\Install-GroupToolsPlugin.ps1 完全一致（本机已验证过的本地装法）：
    ① 拷插件源码 → <ProfileDir>\node_modules\dsh-guard
    ② 把 "dsh-guard" 登记进 profile 的 dsh.profile.bundles
    ③ 官方端：**新增 bundle** 热加载；**改插件内部代码**要重启官方端；客户端面板刷新页面（Ctrl+R）

  为什么不用 `dsh plugin --profile web add`：那条会转给 pnpm，对**本地未发布**的包
  会触发一次全量重解析（要联网、要动 lockfile）；手动拷+登记不动 lockfile，
  卸载也干净（-Revert 两步都能撤回）。

  ⚠️ 装之前会先打一个 profile 快照（用本插件自己的守护核心），
     万一装完起不来，可以回滚。不想打快照用 -NoSnapshot。

  用法：
    Install-Plugin.ps1                     装（默认 profile web）
    Install-Plugin.ps1 -Verify             只体检：装没装 / bundles 有没有 / 语法对不对
    Install-Plugin.ps1 -Revert             卸载：删目录 + 从 bundles 摘掉
    Install-Plugin.ps1 -ProfileDir <路径>   指定别的 profile 目录（影子环境/别的 profile）
    Install-Plugin.ps1 -NoSnapshot         装之前不打快照（快照失败时才用）
#>
[CmdletBinding()]
param(
    [switch]$Revert,
    [switch]$Verify,
    [string]$Profile    = 'web',
    [string]$ProfileDir = '',
    [switch]$NoSnapshot
)

$ErrorActionPreference = 'Stop'

$pkgName = 'dsh-guard'
$src     = $PSScriptRoot
# 只装这些 —— 和 package.json 的 files 字段一致。tools\ / _shadow\ 是开发用的，不进 profile。
$payload = @('lib', 'client', 'ui', 'cordis.patch.yml', 'package.json', 'README.md', 'LICENSE')

if (-not $ProfileDir) { $ProfileDir = Join-Path $env:USERPROFILE ".dsh\profiles\$Profile" }
$dest       = Join-Path $ProfileDir "node_modules\$pkgName"
$profilePkg = Join-Path $ProfileDir 'package.json'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

# 语法自检用：拷到临时文件再用 node --check 解析（不执行）
#   ⚠️ index.js 是 ESM（type: module），临时文件必须用 .mjs；用 .js 会被当 CJS 解析，
#      `import` 直接报语法错 —— 那是假失败。
function Test-Js($path, $ext) {
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    $tmp = Join-Path $env:TEMP ('dsg-' + [guid]::NewGuid().ToString('N') + $ext)
    Copy-Item -LiteralPath $path -Destination $tmp -Force
    $out = & node --check $tmp 2>&1 | Out-String
    $rc  = $LASTEXITCODE
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if ($rc -eq 0) { return 'ok' }
    return "bad: $($out.Trim())"
}

# .ps1 必须带 UTF-8 BOM，否则 5.1 按 ANSI 读中文 → 一堆假语法错（本项目反复踩过）
#   ⚠️ 用 [IO.File]::ReadAllBytes 而不是 Get-Content -Encoding Byte / -AsByteStream：
#      前者是 5.1 专有、后者是 PS7 专有，写成哪个都会在另一边报"参数找不到"。
#      这个脚本是 5.1 跑的（.cmd / 双击），但留成两边都能跑更稳。
function Test-Bom($path) {
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    $b = [System.IO.File]::ReadAllBytes($path)
    if ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) { return 'ok' }
    return 'no-bom'
}

# 返回**语法错误个数**（不是错误列表）。
#   ⚠️ 为什么不返回列表：PowerShell 的数组拆包/打包太容易出幽灵元素，这里踩过两次 ——
#      ① 直接返回 $errs（$null）→ 调用方 @($null).Count = 1；
#      ② 想"保住数组"写成 `return , @($errs | Where-Object { $_ })` →
#         **空结果也被逗号包成一个元素**，.Count 照样是 1（"7 个文件全好"被报成
#         "语法错 7 处"）。返回标量计数就没有这个歧义。
function Get-ParseErrorCount($path) {
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
    return @($errs | Where-Object { $_ }).Count
}

Say ''
Say '== DSH Guard 插件' Cyan
Say "   源码 : $src"
Say "   目标 : $dest"

if (-not (Test-Path -LiteralPath $profilePkg)) {
    Say ''
    Say "找不到 profile 的 package.json：$profilePkg" Red
    Say '（profile 名不对？用 -ProfileDir 指定具体目录）' Yellow
    exit 3
}

function Get-Bundles($path) {
    $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $b = @()
    if ($json.dsh -and $json.dsh.profile -and $json.dsh.profile.bundles) { $b = @($json.dsh.profile.bundles) }
    return [pscustomobject]@{ Json = $json; Bundles = $b }
}

$parsed     = Get-Bundles $profilePkg
$cfg        = $parsed.Json
$bundles    = @($parsed.Bundles)
$registered = $bundles -contains $pkgName
$installed  = Test-Path -LiteralPath $dest

# 客户端 inject 契约（静态检查，不执行 JS）。
#
# ⚠️ 为什么必须查这条（2026-09-14 真机事故）：
#    client.js 里的 `inject` 是 **Cordis 服务名**列表，写成包名（'@deepseek-ai/...'）会让
#    客户端插件去等一个永远不存在的服务 → 加载失败 → **界面白屏**。
#    出事后只能靠卸载恢复。这条检查把它挡在安装之前。
#    权威参照：官方 dsh-client-ui-settings-plugin-inventory 的 lib/client.js 写的是
#    ["slots","locale","remote","remote.pluginInventory"]；本机已安装版本里有 44 个
#    客户端 bundle 都写 `inject = ["slots"]`，服务名都是小写标识符。
function Test-ClientInjectContract($clientJsPath) {
    if (-not (Test-Path -LiteralPath $clientJsPath)) { return @{ Ok = $false; Why = '找不到 client.js' } }
    $text = Get-Content -LiteralPath $clientJsPath -Raw -Encoding UTF8
    $m = [regex]::Match($text, "var\s+inject\s*=\s*\[([^\]]*)\]")
    if (-not $m.Success) { return @{ Ok = $false; Why = 'client.js 里找不到 inject 声明' } }
    $names = @([regex]::Matches($m.Groups[1].Value, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value })
    $bad = @($names | Where-Object { $_ -match '[@/]' })
    if ($bad.Count) { return @{ Ok = $false; Why = "inject 里混进了包名（这里只能写服务名）: $($bad -join ', ')"; Names = $names } }
    if ($names -notcontains 'slots') { return @{ Ok = $false; Why = 'inject 里没有 slots（面板用 ctx.slots 挂设置页 Tab）'; Names = $names } }
    return @{ Ok = $true; Names = $names }
}

# ---------------------------------------------------------------- -Verify
if ($Verify) {
    Say ''
    Say ("   目录已安装  : {0}" -f $installed)  $(if ($installed) { 'Green' } else { 'Yellow' })
    Say ("   bundles 登记: {0}" -f $registered) $(if ($registered) { 'Green' } else { 'Yellow' })
    Say ("   当前 bundles: {0}" -f ($bundles -join ', '))

    if ($installed) {
        $cli = Test-Js (Join-Path $dest 'client\client.js') '.js'
        $hos = Test-Js (Join-Path $dest 'lib\index.js')     '.mjs'
        Say ("   client.js 解析: {0}" -f $cli) $(if ($cli -eq 'ok') { 'Green' } else { 'Red' })
        Say ("   index.js  解析: {0}" -f $hos) $(if ($hos -eq 'ok') { 'Green' } else { 'Red' })
        $ic = Test-ClientInjectContract (Join-Path $dest 'client\client.js')
        Say ("   client inject : {0}" -f $(if ($ic.Ok) { ($ic.Names -join ', ') } else { $ic.Why })) $(if ($ic.Ok) { 'Green' } else { 'Red' })
    }

    # ⚠️ BOM 检查必须**同时覆盖项目根目录的 .ps1**（含本脚本自己）。
    #    2026-09-14 实测踩到：edit 工具改一次就丢 BOM，而当时的检查只扫 lib\*.ps1，
    #    于是"检查通过"、双击安装器却报一堆假语法错（5.1 按 GBK 读中文串）。
    #    检查范围写窄了 = 假通过，比不检查更坏。
    $ps1All = @()
    if ($installed) { $ps1All += @(Get-ChildItem -LiteralPath (Join-Path $dest 'lib') -Filter '*.ps1' -File -ErrorAction SilentlyContinue) }
    $ps1All += @(Get-ChildItem -LiteralPath $src -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $ps1All += @(Get-ChildItem -LiteralPath (Join-Path $src 'lib') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $bad = @($ps1All | Where-Object { (Test-Bom $_.FullName) -ne 'ok' })
    $perr = 0
    foreach ($f in $ps1All) { $perr += Get-ParseErrorCount $f.FullName }
    Say ("   .ps1 共 {0} 个（含安装器自己）：BOM 缺失 {1} 个，语法错 {2} 处" -f $ps1All.Count, $bad.Count, $perr) `
        $(if ($bad.Count -eq 0 -and $perr -eq 0) { 'Green' } else { 'Red' })
    if ($bad.Count) { $bad | ForEach-Object { Say ('      ✗ 缺 BOM：' + $_.FullName) Red } }

    Say ''
    if ($installed -and $registered) { Say '   => 已装好。（新增 bundle 热加载；客户端面板刷新页面 Ctrl+R）' Green }
    else { Say '   => 没装 / 不完整。跑一次不带参数的即可安装。' Yellow }
    exit 0
}

# ---------------------------------------------------------------- -Revert
if ($Revert) {
    Say ''
    if ($installed) { Remove-Item -LiteralPath $dest -Recurse -Force; Say "   已删除 $dest" Green }
    else { Say '   目录本来就不在' DarkGray }

    if ($registered) {
        $cfg.dsh.profile.bundles = @($bundles | Where-Object { $_ -ne $pkgName })
        # ⚠️ 必须用 .NET 写【无 BOM】的 UTF-8。
        #    DSH 用 readFileSync(...,'utf8') + JSON.parse 读 profile manifest，
        #    JSON.parse 不认开头的 \uFEFF → SyntaxError → 服务起不来、界面全打不开。
        #    （2026-09-12 真踩过：就是这一行把 profile 写坏、把桌面端搞崩了。）
        $json = $cfg | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($profilePkg, $json, (New-Object System.Text.UTF8Encoding($false)))
        Say ("   已从 bundles 摘掉（剩 {0} 项）" -f @($cfg.dsh.profile.bundles).Count) Green
    }
    else { Say '   bundles 里本来也没有' DarkGray }

    Say ''
    Say '卸载完成（新增/移除 bundle 热加载；客户端面板刷新页面 Ctrl+R）。' Yellow
    Say "（守护自己攒的快照没删：$env:USERPROFILE\.dsh-guard —— 要清就手动删那个目录）" DarkGray
    exit 0
}

# ---------------------------------------------------------------- 安装
Say ''
if (-not (Test-Path -LiteralPath (Join-Path $src 'lib\index.js'))) {
    Say "找不到插件源码：$src\lib\index.js" Red
    exit 3
}

# ① 装之前先打快照 —— 用本插件自己的守护核心
if (-not $NoSnapshot) {
    $profilesRoot = Split-Path $ProfileDir -Parent
    $dshHome      = Split-Path $profilesRoot -Parent
    $leaf         = Split-Path $ProfileDir -Leaf
    if ((Split-Path $profilesRoot -Leaf) -ne 'profiles') {
        Say "⚠️ $ProfileDir 不像 <DSH_HOME>\profiles\<名字>，跳过快照这一步" Yellow
    }
    else {
        Say '① 先打一个 profile 快照（装坏了能靠它回滚）…' Cyan
        Say '   （要镜像 node_modules，可能要几十秒到几分钟，别关窗口）' DarkGray
        # 让守护盯的就是同一个 profile：它按 $DSH_HOME\profiles\<名字> 解析
        $env:DSH_HOME = $dshHome
        $out = Join-Path $env:TEMP ('dsg-snap-' + [guid]::NewGuid().ToString('N') + '.json')
        & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $src 'lib\guard.ps1') `
            -Action snapshot -Profile $leaf -Reason 'pre-plugin-install' -Out $out 2>&1 |
            Out-String | ForEach-Object { if ($_.Trim()) { Say "   $($_.Trim())" DarkGray } }

        $snapOk = $false
        if (Test-Path -LiteralPath $out) {
            try {
                $r = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($r.ok) { Say "   快照已建：$($r.name)（$($r.sizeMB) MB）" Green; $snapOk = $true }
                else { Say "   快照失败：$($r.error)" Red }
            }
            catch { Say "   快照结果读不出来：$($_.Exception.Message)" Red }
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        }
        else { Say '   快照没有产出结果文件' Red }

        if (-not $snapOk) {
            Say ''
            Say '没有快照 = 装坏了没有安全带，已中止。' Red
            Say '（确实不想要快照：加 -NoSnapshot 重跑）' Yellow
            exit 4
        }
    }
}

# ② 拷文件
Say ''
Say '② 拷贝插件文件…' Cyan
if ($installed) { Remove-Item -LiteralPath $dest -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($item in $payload) {
    $from = Join-Path $src $item
    if (-not (Test-Path -LiteralPath $from)) {
        if ($item -in @('README.md', 'LICENSE')) { continue }   # 这两个还没写也不该拦住安装
        Say "   缺少 $item" Red; Remove-Item -LiteralPath $dest -Recurse -Force; exit 5
    }
    Copy-Item -LiteralPath $from -Destination $dest -Recurse -Force
}
Say ("   已复制 {0} 个文件" -f @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count) Green

# ③ 登记 bundles
Say ''
Say '③ 登记进 profile 的 bundles…' Cyan
if ($registered) { Say '   已经有，跳过' DarkGray }
else {
    $cfg.dsh.profile.bundles = @($bundles + $pkgName)
    if (-not $cfg.dsh) { throw 'profile 的 package.json 里没有 dsh 字段，先确认这是不是 DSH profile' }
    $json = $cfg | ConvertTo-Json -Depth 10
    # 见上：无 BOM，否则 DSH 起不来
    [System.IO.File]::WriteAllText($profilePkg, $json, (New-Object System.Text.UTF8Encoding($false)))
    Say ("   已登记（现在 {0} 项）" -f @($cfg.dsh.profile.bundles).Count) Green
}

# ④ 落地自检 —— 装完立刻验，坏了就地回滚
Say ''
Say '④ 落地自检…' Cyan
$fail = $false
$cli = Test-Js (Join-Path $dest 'client\client.js') '.js'
$hos = Test-Js (Join-Path $dest 'lib\index.js')     '.mjs'
if ($cli -ne 'ok') { Say "   client.js 解析失败：$cli" Red; $fail = $true } else { Say '   client.js 解析通过' Green }
if ($hos -ne 'ok') { Say "   index.js  解析失败：$hos" Red; $fail = $true } else { Say '   index.js  解析通过' Green }

# 客户端 inject 契约 —— 装之前就把"白屏级"错误拦住（2026-09-14 真机事故）
$ic = Test-ClientInjectContract (Join-Path $dest 'client\client.js')
if (-not $ic.Ok) { Say ("   ❌ client inject 契约不合法：{0}" -f $ic.Why) Red; $fail = $true }
else { Say ("   client inject 契约正确：{0}" -f ($ic.Names -join ', ')) Green }

$badPs1 = @()
$badPs1 += @(Get-ChildItem -LiteralPath (Join-Path $dest 'lib') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
             Where-Object { (Test-Bom $_.FullName) -ne 'ok' })
# 项目根目录的 .ps1（含本安装器自己）也要查 —— 它丢了 BOM 就双击不起来（2026-09-14 实测）
$badPs1 += @(Get-ChildItem -LiteralPath $src -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
             Where-Object { (Test-Bom $_.FullName) -ne 'ok' })
if ($badPs1.Count) { Say ("   这些 .ps1 缺 BOM（5.1 会读成乱码）：{0}" -f (($badPs1 | ForEach-Object Name) -join ', ')) Red; $fail = $true }
else { Say '   .ps1（装在 profile 的 + 项目根目录的）都带 BOM' Green }

# profile manifest 必须是合法 JSON 且**没有 BOM**（这条坏了整个 DSH 起不来）
if ((Test-Bom $profilePkg) -eq 'ok') {
    Say '   ❌ profile 的 package.json 被写进了 BOM —— 必须修掉' Red; $fail = $true
}
else {
    try { $null = Get-Content -LiteralPath $profilePkg -Raw -Encoding UTF8 | ConvertFrom-Json; Say '   profile manifest 合法且无 BOM' Green }
    catch { Say "   ❌ profile manifest 不是合法 JSON：$($_.Exception.Message)" Red; $fail = $true }
}

if ($fail) {
    Say ''
    Say '自检没过 —— 正在撤销这次安装…' Red
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    if ($registered) { Say '   （bundles 里那条本来就在，没动）' DarkGray }
    else {
        $cfg.dsh.profile.bundles = @($bundles)
        $json = $cfg | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($profilePkg, $json, (New-Object System.Text.UTF8Encoding($false)))
        Say '   已把 bundles 还原' Green
    }
    Say ''
    Say '已还原，DSH 应该还能正常启动。' Yellow
    exit 5
}

# ---------------------------------------------------------------- ⑤ 同步看门狗副本
# 为什么要有这一步：`<守护数据目录>\bin\` 是看门狗**独立运行**时用的脚本副本
# （DSH 挂了它也得能跑，所以不能只依赖插件目录）。于是同一份脚本存在两处，
# 插件升级后若只重装插件、不同步 bin，就会出现「看门狗在跑旧脚本」的告警 ——
# 而那条告警说的是"插件目录那份旧"，会把人指去重装看门狗（2026-09-14 真发生过，
# 白跑一趟且告警不消失）。装插件时顺手同步，两边就不会漂移。
$guardHomeDir = if ($env:DSHGUARD_HOME) { $env:DSHGUARD_HOME } else { Join-Path $env:USERPROFILE '.dsh-guard' }
$binDir = Join-Path $guardHomeDir 'bin'
if (Test-Path -LiteralPath $binDir) {
    Say ''
    Say '⑤ 同步看门狗脚本副本…' Cyan
    $synced = 0
    foreach ($pf in (Get-ChildItem (Join-Path $src 'lib') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $pf.FullName -Destination (Join-Path $binDir $pf.Name) -Force
        $synced++
    }
    Say ("   已同步 {0} 个脚本 -> {1}" -f $synced, $binDir) Green

    # 正在跑的看门狗用的是**内存里**的旧函数，重启才生效
    $wdScript = Join-Path $binDir 'watchdog.ps1'
    $lockFile = Join-Path $guardHomeDir 'state\watchdog.lock'
    $wdPid = 0; $wdPort = 0
    if (Test-Path -LiteralPath $lockFile) {
        try {
            $lk = Get-Content $lockFile -Raw | ConvertFrom-Json
            $wdPid = [int]$lk.pid
            if ($lk.PSObject.Properties.Name -contains 'port') { $wdPort = [int]$lk.port }
        } catch { }
    }
    if (-not $wdPort -and $env:DSH_WEB_URL) { try { $wdPort = ([uri]$env:DSH_WEB_URL).Port } catch { } }
    if ($wdPid -gt 0 -and (Test-Path -LiteralPath $wdScript) -and (Get-Process -Id $wdPid -ErrorAction SilentlyContinue)) {
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wdScript -Stop *> $null
            Start-Sleep -Milliseconds 800
            $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', "`"$wdScript`"", '-Profile', $Profile, '-GuardHomeDir', "`"$guardHomeDir`"")
            if ($wdPort -gt 0) { $al += @('-WebPort', "$wdPort") }
            Start-Process -FilePath 'powershell.exe' -ArgumentList $al -WindowStyle Hidden | Out-Null
            Say '   看门狗已重启（让新脚本生效）' Green
        } catch { Say ("   ⚠️ 看门狗重启失败（不影响插件本身）：{0}" -f $_.Exception.Message) Yellow }
    }
}

Say ''
Say '装好了。' Green
Say ''
Say '下一步：' Cyan
Say '  1) 官方端：新增 bundle 热加载（改插件代码则要重启）；npm/web 那份若没生效就重启一次 DSH'
Say '  2) 打开 设置 → 插件 → 守护，就是面板（状态 / 快照 / 一键回滚）'
Say '  3) 想要"DSH 挂了也能救你"：双击 Install-Watchdog-NoAdmin.cmd（不需要管理员）'
Say '     或 Install-Watchdog.cmd（注册计划任务，弹一次 UAC）'
Say '     （看门狗独立于 DSH 进程；不装的话 DSH 一崩就没人救它。安装入口在独立窗口里也有）'
Say ''
Say "卸载：双击 Uninstall-Plugin.cmd（或 Install-Plugin.ps1 -Revert）" DarkGray
exit 0
