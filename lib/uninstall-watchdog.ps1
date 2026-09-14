# ============================================================================
#  uninstall-watchdog.ps1 —— 卸载看门狗（停进程 + 注销计划任务）
#
#  默认**保留**快照（那是你的回滚点，删了就没了）与 bin 目录（便于重装）。
#  要连脚本目录一起清掉用 -RemoveBin。
#
#  用法：
#    uninstall-watchdog.ps1                 # 停守护 + 注销计划任务 + 删启动项
#    uninstall-watchdog.ps1 -DryRun         # 只打印将要做什么
#    uninstall-watchdog.ps1 -RemoveBin      # 顺带删掉 bin 目录（快照仍保留）
# ============================================================================
[CmdletBinding()]
param(
    [string]$Profile      = 'web',
    [string]$GuardHomeDir = '',
    # ⚠️ $WebPort / $WorkDir 这个脚本**用不到**，但必须留着：
    #    宿主插件（lib/index.js 的 runDetached）和独立窗口都拿**同一套参数**去调 install/uninstall，
    #    少一个参数，PowerShell 会在**参数绑定阶段**就报 "A parameter cannot be found…" 并退出 1 ——
    #    脚本一行都不会执行，而调用方只看到"已启动"，于是表现为"点了没反应"。
    #    2026-09-14 实测踩到：面板/独立窗口的「停止并卸载看门狗」从来就没成功过。
    #    👉 改这两个脚本的参数时，**两边必须保持同一套**。
    [int]   $WebPort      = 0,
    [string]$WorkDir      = '',
    [string]$TaskName     = 'DSH Guard 看门狗',
    [string]$StartupDir   = '',        # 默认 = 当前用户启动文件夹
    [switch]$RemoveBin,
    [switch]$Elevated,          # 内部用：已经提权过，不要再自请求
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'guard-bootstrap.ps1') -ProfileName $Profile -GuardHome $GuardHomeDir -WebPort $WebPort
. (Join-Path $PSScriptRoot 'guard-core.ps1')

$binDir = Join-Path $script:GuardHome 'bin'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ''
Say '=== DSH Guard 看门狗卸载 ===' 'Cyan'
Say ("  守护数据目录 : {0}" -f $script:GuardHome)
Say ("  计划任务名   : {0}" -f $TaskName)
Say ("  快照         : 保留（{0}）" -f $script:SnapshotDir)

if ($DryRun) {
    Say ''
    Say '（-DryRun：以下动作都不会真的执行）' 'Yellow'
    Say '  1. 停掉正在运行的看门狗进程'
    Say '  2. 注销计划任务'
    if ($RemoveBin) { Say ("  3. 删除 {0}" -f $binDir) } else { Say '  3. 保留 bin 目录' }
    exit 0
}

# 1) 停进程
Say ''
Say '1) 停止看门狗 ...' 'Cyan'
$wd = Join-Path $binDir 'watchdog.ps1'
if (Test-Path $wd) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $wd -Stop 2>&1 | ForEach-Object { '   ' + $_ }
} else {
    $lk = Read-JsonFile -Path $script:LockFile
    if ($lk -and $lk.pid -and (Test-PidAlive -ProcessId ([int]$lk.pid))) {
        try { Stop-Process -Id ([int]$lk.pid) -Force -ErrorAction Stop; Say ("   已停止 PID {0}" -f $lk.pid) 'Green' }
        catch { Say ("   停止失败：{0}" -f $_.Exception.Message) 'Red' }
    } else { Say '   没有正在运行的看门狗' 'DarkGray' }
    Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue
}

# 2) 注销计划任务 + 删启动项
#    两种自启方式都要清：装的时候可能用的是计划任务，也可能是启动文件夹（不需要管理员那种）。
Say ''
Say '2) 注销自启项 ...' 'Cyan'
try {
    # 直接 Unregister：不用先 Get-ScheduledTask（那个在受限环境里会看不到任务，导致误判"没装"）
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Say '   ✓ 计划任务已注销' 'Green'
} catch {
    Say ("   · 计划任务：没找到或注销失败（{0}）" -f $_.Exception.Message) 'DarkGray'
    # 计划任务在系统任务库里，注销**必须要管理员**。别只留一句"可能需要权限"就完事 ——
    # 残留的任务会在**下次登录**把看门狗又拉起来（2026-09-14：用户就是这么被它二次回滚的）。
    if (-not $Elevated) {
        Say ''
        Say '   正在自请求提权来注销这个计划任务（会弹一次 UAC）...' 'Yellow'
        $re = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                '-Profile', $Profile, '-Elevated')
        if ($GuardHomeDir) { $re += @('-GuardHomeDir', "`"$GuardHomeDir`"") }
        if ($TaskName) { $re += @('-TaskName', "`"$TaskName`"") }
        if ($StartupDir) { $re += @('-StartupDir', "`"$StartupDir`"") }
        try {
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $re -Verb RunAs -PassThru
            $p.WaitForExit()
            Say ("   提权进程退出码：{0}" -f $p.ExitCode) 'Yellow'
        } catch {
            Say ("   提权被取消或失败：{0}" -f $_.Exception.Message) 'Red'
            Say '   想手动清：以管理员身份开 PowerShell，执行：' 'DarkGray'
            Say ("     Unregister-ScheduledTask -TaskName `"$TaskName`" -Confirm:`$false") 'DarkGray'
        }
    }
}

$startupFolder = if ($StartupDir) { $StartupDir } else { [Environment]::GetFolderPath('Startup') }
$startupLnk = if ($startupFolder) { Join-Path $startupFolder 'DSH Guard 看门狗.lnk' } else { '' }
if ($startupLnk -and (Test-Path -LiteralPath $startupLnk)) {
    try { Remove-Item -LiteralPath $startupLnk -Force -ErrorAction Stop; Say ("   ✓ 已删除启动项：{0}" -f $startupLnk) 'Green' }
    catch { Say ("   ⚠ 删除启动项失败：{0}" -f $_.Exception.Message) 'Yellow' }
} else {
    Say '   · 启动文件夹里没有它' 'DarkGray'
}

# 3) 可选的 bin 清理
if ($RemoveBin) {
    Say ''
    Say '3) 删除脚本目录 ...' 'Cyan'
    if (Test-Path $binDir) {
        try { Remove-Item -Recurse -Force $binDir -ErrorAction Stop; Say ("   ✓ 已删除 {0}" -f $binDir) 'Green' }
        catch { Say ("   ⚠ 删除失败：{0}" -f $_.Exception.Message) 'Yellow' }
    } else { Say '   （不存在）' 'DarkGray' }
}

Say ''
Say '卸载完成。快照仍保留在：' 'Green'
Say ("  {0}" -f $script:SnapshotDir) 'DarkGray'
