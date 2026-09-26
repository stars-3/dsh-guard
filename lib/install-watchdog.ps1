# ============================================================================
#  install-watchdog.ps1 —— 把看门狗装成 Windows 计划任务
#
#  为什么必须用计划任务：插件跑在 DSH 进程里，DSH 起不来时插件根本没机会运行。
#  计划任务由 Windows 拉起，DSH 死了它照样活 —— 这才是"能救命"的那一半。
#
#  它做三件事：
#    1. 把 lib\*.ps1 复制到 <GuardHome>\bin\ —— 稳定路径，不受 npm 包更新影响
#    2. 注册计划任务（登录时启动、隐藏、无时长上限、失败自动重试）
#    3. 立刻启动一次并自检
#
#  注册计划任务可能需要管理员：脚本会先直接试，失败就**自请求提权**重跑一次
#  （带 -Elevated 标记，避免无限循环）。
#
#  用法：
#    install-watchdog.ps1 -Profile web                 # 安装（计划任务，会弹一次 UAC）
#    install-watchdog.ps1 -Profile web -UseStartup     # 装到【启动文件夹】（不需要管理员，不弹 UAC）
#    install-watchdog.ps1 -Profile web -DryRun         # 只打印将要做什么
#    install-watchdog.ps1 -Profile web -UseStartup -NoStart   # 只安装，不立刻启动（排查用）
#    uninstall-watchdog.ps1                            # 卸载
# ============================================================================
[CmdletBinding()]
param(
    [string]$Profile      = 'web',
    [string]$GuardHomeDir = '',
    # ⚠️ 默认 0 = "没指定"，交给 §4 的优先级回退（见 guard-bootstrap.ps1）。
    #    写死 3080 会让默认值冒充"显式指定"，把环境变量回退整个盖掉。
    [int]   $WebPort      = 0,
    # ---- 官方桌面端支持（2026-09-26 新增；留空 = 上游行为）----
    [string]$HealthMode   = '',
    [string]$AppExe       = '',
    [string]$AppProcess   = '',
    [string]$WorkDir      = '',
    [string]$TaskName     = 'DSH Guard 看门狗',
    # 用【启动文件夹】而不是计划任务：**不需要管理员权限**、不弹 UAC。
    # 启动文件夹方式对所有用户都可用（不需要管理员），是计划任务被拒时的兜底。
    # 代价：它靠资源管理器在登录时启动，比计划任务稍弱；但对"登录后 DSH 崩了能回滚"够用。
    [switch]$UseStartup,
    [string]$StartupDir   = '',        # 默认 = 当前用户的启动文件夹；测试时可指到别处
    [switch]$NoStart,                  # 只安装，不立刻启动看门狗（测试/排查用）
    [switch]$DryRun,
    [switch]$Elevated          # 内部用：表示已经提权过，不要再自请求
)

$ErrorActionPreference = 'Continue'
$libDir = $PSScriptRoot                      # 插件包里的 lib\

. (Join-Path $libDir 'guard-bootstrap.ps1') -ProfileName $Profile -GuardHome $GuardHomeDir -WebPort $WebPort -HealthMode $HealthMode -AppExe $AppExe -AppProcess $AppProcess
. (Join-Path $libDir 'guard-core.ps1')

# 端口兜底：双击 .cmd / 从资源管理器启动时，环境里没有 DSH_WEB_URL，bootstrap 会退到默认 3080；
# 而用户的 DSH 可能配在别的端口。安装是一次性动作，这里花一次 netstat 探测，
# 免得看门狗盯着一个没人监听的端口 —— 那会表现成"以为 DSH 死了，反复重启/回滚"。
if ($script:WebPortFrom -eq 'default') {
    try {
        $seen = @{}; $cand = @()
        foreach ($l in (& netstat -ano 2>$null | Select-String 'LISTENING')) {
            $m = [regex]::Match($l.Line, ':(\d+)\s+\S+\s+LISTENING\s+(\d+)')
            if (-not $m.Success) { continue }
            $p = [int]$m.Groups[1].Value; $owner = [int]$m.Groups[2].Value
            if ($p -lt 1024 -or $seen.ContainsKey($p)) { continue }
            $seen[$p] = $true
            $proc = Get-Process -Id $owner -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -eq 'node') {
                $cand += [pscustomobject]@{ Port = $p; Started = $proc.StartTime }
            }
        }
        if ($cand.Count -ge 1) {
            $pick = @($cand | Sort-Object Started -Descending)[0]
            $script:WebPort = $pick.Port
            $script:WebPortFrom = 'probe'
            Write-Host ("  （没显式指定端口，自动探测到 DSH 实例在 {0}）" -f $pick.Port) -ForegroundColor DarkGray
        }
    } catch { }
}

$binDir = Join-Path $script:GuardHome 'bin'
$workDir2 = if ($WorkDir) { $WorkDir } elseif ($env:DSH_GUARD_WORKDIR) { $env:DSH_GUARD_WORKDIR } else { $env:USERPROFILE }

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

# 用启动文件夹装：不需要管理员，所以**永远不会弹 UAC**。
# 放一个 .lnk 指向 powershell.exe 跑 bin\watchdog.ps1（隐藏窗口），登录时由资源管理器拉起。
function Install-StartupShortcut {
    # ⚠️ 参数名别叫 $Args —— 那是 PowerShell 的**自动变量**（$args），会被它顶掉：
    #    实测 `$lnk.Arguments = $Args` 写出来是**空字符串** → 启动项指向 powershell.exe 却没参数，
    #    登录时静默什么都不执行。同族第 4 次（$Host / $Home / $Path / $Args）。
    param([string]$WatchdogPath, [string]$ArgLine)

    $dir = if ($StartupDir) { $StartupDir } else { [Environment]::GetFolderPath('Startup') }
    if (-not $dir) { throw '拿不到启动文件夹路径' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $lnkPath = Join-Path $dir 'DSH Guard 看门狗.lnk'
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\powershell.exe'
    $lnk.Arguments = $ArgLine
    $lnk.WorkingDirectory = $workDir2
    $lnk.Description = 'DSH Guard 看门狗 —— 登录时启动，DSH 起不来时自动回滚'
    $ico = Join-Path $binDir 'guard.ico'
    if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = $ico + ',0' }
    $lnk.Save()
    return $lnkPath
}

# 端口是从哪来的要写在脸上：DSH 会把 DSH_WEB_URL 导出给整个进程树，猜错的表现是
# "看门狗盯着一个没人监听的端口，于是以为 DSH 死了，反复重启/回滚"——比报错更难查。
$portFromText = switch ($script:WebPortFrom) {
    'explicit' { '面板/命令行显式指定' }
    'env'      { '环境变量 DSH_WEB_URL' }
    'probe'    { '自动探测（正在监听的 DSH 实例）' }
    default    { '默认值 3080（建议用 -WebPort 明确指定）' }
}

Say ''
Say '=== DSH Guard 看门狗安装 ===' 'Cyan'
Say ("  profile      : {0}" -f $Profile)
Say ("  守护数据目录 : {0}" -f $script:GuardHome)
Say ("  脚本目标目录 : {0}" -f $binDir)
Say ("  DSH 端口     : {0}  ← {1}" -f $script:WebPort, $portFromText)
Say ("  重启工作目录 : {0}" -f $workDir2)
Say ("  计划任务名   : {0}" -f $TaskName)

if ($DryRun) {
    Say ''
    Say '（-DryRun：以下动作都不会真的执行）' 'Yellow'
    Say ("  1. 复制 lib\*.ps1 -> {0}" -f $binDir)
    Say ("  2. 注册计划任务『{0}』（登录时启动、隐藏、无时长上限、失败重试 3 次）" -f $TaskName)
    Say ("  3. 启动一次并写自检结果")
    exit 0
}

# ---------------------------------------------------------------- 1. 复制脚本
Say ''
Say '1) 复制脚本到稳定目录 ...' 'Cyan'
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Force -Path $binDir | Out-Null }
$copied = 0
foreach ($f in (Get-ChildItem $libDir -File -Filter '*.ps1')) {
    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $binDir $f.Name) -Force
    $copied++
}
# 独立窗口（ui\Guard-UI.ps1）也复制进 bin：
#   ① 它和 guard.ps1 同目录就能自己找到（Guard-UI.ps1 的第一个候选路径就是同目录）
#   ② 这样即使用户把插件目录删了，<守护数据目录>\bin 里仍然有一个能回滚的救命窗口
$uiDir = Join-Path (Split-Path $libDir -Parent) 'ui'
$uiCopied = 0
if (Test-Path -LiteralPath $uiDir) {
    foreach ($f in (Get-ChildItem $uiDir -File | Where-Object { $_.Extension -in @('.ps1', '.ico', '.vbs') })) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $binDir $f.Name) -Force
        $uiCopied++
    }
}
Say ("   已复制 {0} 个 .ps1（含独立窗口 {1} 个）" -f $copied, $uiCopied) 'Green'
Say ("   独立窗口: {0}" -f (Join-Path $binDir 'Guard-UI.ps1')) 'DarkGray'
$watchdog = Join-Path $binDir 'watchdog.ps1'
if (-not (Test-Path $watchdog)) { Say "   ✗ 复制后仍找不到 watchdog.ps1，中止" 'Red'; exit 2 }

# ---------------------------------------------------------------- 2. 装自启
Say ''
# 烘进自启项的端口必须是**解析后的**（$script:WebPort），不是原始参数：
# 它是在登录时启动的，那时环境里没有 DSH_WEB_URL，只能靠这里烘死的值。
$argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdog`" -Profile $Profile -GuardHomeDir `"$($script:GuardHome)`" -WebPort $($script:WebPort) -WorkDir `"$workDir2`""
# 官方桌面端（2026-09-26）：把运行模式一并烘进自启项 —— 登录时环境里没有 DSH_WEB_URL/DSHGUARD_*，
# 只能靠这里烘死的值。（PnpmCmd 故意不烘：它可能自带引号（`"node.exe" "pnpm.cjs"`），
# 嵌进 argLine 会把引号搞乱；改由 <GuardHome>\config.json 提供。）
if ($script:HealthMode -and $script:HealthMode -ne 'port') { $argLine += " -HealthMode $($script:HealthMode)" }
if ($script:AppExe)     { $argLine += " -AppExe `"$($script:AppExe)`"" }
if ($script:AppProcess) { $argLine += " -AppProcess `"$($script:AppProcess)`"" }
$installedVia = ''

if ($UseStartup) {
    Say '2) 装到启动文件夹（不需要管理员权限）...' 'Cyan'
    try {
        $lnk = Install-StartupShortcut -WatchdogPath $watchdog -ArgLine $argLine
        Say ("   ✓ 已创建：{0}" -f $lnk) 'Green'
        Say '   登录时由资源管理器自动拉起（不需要管理员，也不弹 UAC）' 'DarkGray'
        $installedVia = 'startup'
    } catch {
        Say ("   ✗ 创建启动项失败：{0}" -f $_.Exception.Message) 'Red'
        exit 4
    }
} else {
    Say '2) 注册计划任务 ...' 'Cyan'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        Say '   ✓ 计划任务已注册' 'Green'
        $installedVia = 'task'
    } catch {
        Say ("   ✗ 注册失败：{0}" -f $_.Exception.Message) 'Red'
        if (-not $Elevated) {
            Say ''
            Say '   看起来需要管理员权限 —— 正在自请求提权（会弹一次 UAC）...' 'Yellow'
            $re = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                    '-Profile', $Profile, '-WebPort', "$($script:WebPort)", '-TaskName', "`"$TaskName`"", '-Elevated')
            if ($GuardHomeDir) { $re += @('-GuardHomeDir', "`"$GuardHomeDir`"") }
            if ($WorkDir) { $re += @('-WorkDir', "`"$WorkDir`"") }
            # 官方桌面端模式要跟着提权进程一起传下去，否则提权后烘进自启项的是默认 port 模式
            if ($HealthMode) { $re += @('-HealthMode', $HealthMode) }
            if ($AppExe) { $re += @('-AppExe', "`"$AppExe`"") }
            if ($AppProcess) { $re += @('-AppProcess', "`"$AppProcess`"") }
            try {
                $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $re -Verb RunAs -PassThru
                $p.WaitForExit()
                Say ("   提权进程退出码：{0}" -f $p.ExitCode) 'Yellow'
                Say '   请重新运行一次以确认结果（或看设置页的守护面板）' 'Yellow'
            } catch {
                Say ("   提权被取消或失败：{0}" -f $_.Exception.Message) 'Red'
            }
        }
        Say ''
        Say '   👉 不想提权也行：加 -UseStartup 改装到【启动文件夹】，效果一样且不需要管理员。' 'Yellow'
        Say '      （看门狗界面上的按钮会自动问你要不要这么做）' 'DarkGray'
        exit 3
    }
}

if ($NoStart) {
    Say ''
    Say '（-NoStart：不立刻启动看门狗）' 'Yellow'
    Say ('安装方式: ' + $installedVia) 'Green'
    exit 0
}

# ---------------------------------------------------------------- 3. 立刻启动一次 + 自检
Say ''
Say '3) 立刻启动看门狗并自检 ...' 'Cyan'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $binDir 'watchdog.ps1') -Stop 2>&1 | ForEach-Object { '   ' + $_ }
$onceOut = Join-Path $script:GuardHome 'install-selfcheck.json'
& powershell -NoProfile -ExecutionPolicy Bypass -File $watchdog -Profile $Profile -GuardHomeDir $script:GuardHome -WebPort $($script:WebPort) -WorkDir $workDir2 -Once -Out $onceOut 2>&1 | Out-Null
if (Test-Path $onceOut) {
    $j = Get-Content $onceOut -Raw | ConvertFrom-Json
    if ($j.ok) {
        Say ("   ✓ 自检通过：指纹 {0}，已有快照 {1} 个" -f $j.identity, $j.snapshots) 'Green'
    } else {
        Say ("   ✗ 自检失败：{0}" -f $j.error) 'Red'
        Say ("     {0}" -f $j.stack) 'DarkGray'
    }
} else {
    Say '   ✗ 自检没有产出结果（看 guard.log）' 'Red'
}

# 启动常驻进程（脱离本进程；下次登录由计划任务 / 启动文件夹接管）
try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 2
    $lk = Read-JsonFile -Path $script:LockFile
    if ($lk -and $lk.pid -and (Test-PidAlive -ProcessId ([int]$lk.pid))) {
        Say ("   ✓ 看门狗已在运行（PID {0}）" -f $lk.pid) 'Green'
    } else {
        Say '   ⚠ 看门狗进程没起来（看 guard.log；也可能被自启项在登录后接管）' 'Yellow'
    }
} catch {
    Say ("   ⚠ 启动常驻进程失败：{0}" -f $_.Exception.Message) 'Yellow'
}

Say ''
Say ("安装完成（方式：{0}）。" -f $(if ($installedVia -eq 'startup') { '启动文件夹（不需要管理员）' } else { '计划任务' })) 'Green'
Say '设置页的「守护」面板会显示"看门狗运行中"。' 'Green'
Say ("卸载： powershell -File `"{0}`"" -f (Join-Path $PSScriptRoot 'uninstall-watchdog.ps1')) 'DarkGray'
