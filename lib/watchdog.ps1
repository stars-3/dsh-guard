# ============================================================================
#  watchdog.ps1 —— 插件版看门狗（DSH 起不来时自动回滚的那个进程）
#
#  为什么它必须独立于 DSH：插件跑在 DSH 进程里，DSH 起不来时插件根本没机会运行。
#  所以这个脚本由**计划任务**拉起（见 install-watchdog.ps1），DSH 死了它照样活着。
#
#  逻辑本身是从 DSH Desktop 的 DshGuard-Supervisor.ps1 **机械抽取**的
#  （lib/watchdog-core.ps1），这里只做三件事：
#    1. 定义桌面版有、插件版没有的东西（"另一端"的意图标记、维护窗口、AI 诊断…）
#       —— 一律写成"永远不抑制、永远不介入"的垫片，不改抽取出来的代码
#    2. 补上 Cfg 需要的键
#    3. 提供 -Once（跑一轮就退出，自检/调试用）与 -Stop
#
#  用法：
#    watchdog.ps1 -Profile web                      # 常驻（计划任务用）
#    watchdog.ps1 -Profile web -Once -Out r.json    # 只跑一轮（影子环境自检）
#    watchdog.ps1 -Stop                             # 停掉正在跑的守护
# ============================================================================
[CmdletBinding()]
param(
    [string]$Profile      = 'web',
    [string]$GuardHomeDir = '',
    # ⚠️ 默认 0 = "没指定"，交给 guard-bootstrap.ps1 §4 的优先级回退。
    #    计划任务那条路径是显式烘进去的，所以它永远是 explicit。
    [int]   $WebPort      = 0,
    [int]   $IntervalSec  = 0,      # 0 = 用 Cfg 里的默认值
    [string]$WorkDir      = '',     # 自动重启 DSH 时的工作目录（决定会话分组）
    [switch]$Once,                  # 只跑一轮巡检就退出
    [switch]$Stop,                  # 停掉正在跑的守护
    [string]$Out          = ''      # -Once 时把结果写进这个 JSON
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'guard-bootstrap.ps1') -ProfileName $Profile -GuardHome $GuardHomeDir -WebPort $WebPort
. (Join-Path $PSScriptRoot 'guard-core.ps1')
. (Join-Path $PSScriptRoot 'watchdog-core.ps1')

# ---------------------------------------------------------------- 补 Cfg 键
$script:Cfg.HeartbeatStaleSec = 600     # 心跳停滞阈值（Start-SupervisorLoop 会打印它）
$script:Cfg.EnableAi = $false           # 插件版默认不做 AI 诊断（原版依赖作者本机的 ask.py）

# 自动重启 DSH 时用哪个工作目录（DSH 按工作目录给会话分组，起错地方会话列表就是空的）
$script:WorkDir = if ($WorkDir) { $WorkDir }
                  elseif ($env:DSH_GUARD_WORKDIR) { $env:DSH_GUARD_WORKDIR }
                  else { $env:USERPROFILE }

# ---------------------------------------------------------------- 垫片
# 桌面版有"两端"（网页端 3080 / 桌面端 3101），插件版只有网页端。
# ⚠️ 2026-09-14 事故：我原先把下面这些抑制函数**全部垫成"永不抑制"**（返回 false / -1），
#    等于把桌面版专门用来防"人在重启，守护在回滚"对撞的安全带拆了 —— 于是外壳重启时
#    那几秒被当成崩溃、触发回滚、回滚又去抢 3101（EADDRINUSE），把用户的桌面端搞挂。
#    现在按**泛化后**的语义真正实现它们（不依赖任何桌面外壳专有文件）。
$script:NativePort = 0                  # 没有桌面端；Test-TcpPort -Port 0 恒为 false

# 插件版没有"另一端"，所以不存在"用户主动切到另一端"这种情况
function Get-ActiveEnd { return [pscustomobject]@{ End = ''; At = ''; Note = '' } }
function Set-ActiveEnd { param([string]$End, [string]$Note = '') }
function Clear-ActiveEnd { }
function Test-EndSuppressed {
    param([string]$End, $State)
    return [pscustomobject]@{ Suppressed = $false; Reason = '' }
}
# 节流写日志：调用方写成 if (Write-SuppressLog ...) 才记事故，所以这里返回 $true
function Write-SuppressLog {
    param([string]$Key, [string]$Message)
    Write-GuardLog "[$Key] $Message" -Level INFO
    return $true
}

# 「刚刚好像有人把它关了/重启了」→ 返回秒数；返回负数 = 不像主动关闭，该处置就处置。
# 泛化实现：**看我们自己记的"最近一次在跑"时间**（State.lastUpAt）。
#   端口刚还在跑 → 现在不在，最可能是重启过程中的空窗，不是崩溃。
function Get-IntentionalKillAgeSec {
    param([int]$Port, [int]$WithinSec = 180)
    try {
        $st = Get-GuardState
        if ($st -and $st.lastUpAt) {
            $age = [int]((Get-Date) - [datetime]::Parse($st.lastUpAt)).TotalSeconds
            if ($age -ge 0 -and $age -le $WithinSec) { return $age }
        }
    } catch { }
    return -1
}
function Update-EndDownState { param($State) }

# 「维护窗口」：任何人（用户/别的脚本/我们自己的安装与回滚流程）都能声明
# "接下来 N 分钟别动我"。窗口内守护只记录、不重启、不回滚。
#   ⚠️ 泛化实现：不读桌面外壳的 state\shell-maintenance.json，只读守护自己的标记文件。
#   写它：guard.ps1 -Action maint-start -Minutes 30 -Reason '我要重启 DSH'
#        （或独立窗口上的「暂停守护 30 分钟」按钮）
function Get-ShellMaintenance {
    $f = Join-Path $script:StateDir 'maintenance.json'
    if (-not (Test-Path -LiteralPath $f)) { return [pscustomobject]@{ Active = $false; Until = ''; Note = '' } }
    try {
        $m = Read-JsonFile -Path $f
        if ($m -and $m.until) {
            if ([datetime]::Parse($m.until) -gt (Get-Date)) {
                return [pscustomobject]@{ Active = $true; Until = $m.until; Note = [string]$m.note }
            }
        }
    } catch { }
    return [pscustomobject]@{ Active = $false; Until = ''; Note = '' }
}
function Invoke-NativeCycle { param($State) }     # 没有桌面端要巡检
function Invoke-AiDiagnosis {
    param([string]$Context = '', [string]$Question = '')
    return [pscustomobject]@{ Ok = $false; Text = '插件版未启用 AI 诊断' }
}
# 看得见的反馈在插件版由设置页的「守护」面板承担，这里保持静默
function Show-GuardToast { param([string]$Text = '', [int]$Seconds = 8) }

function Get-GuardEnvironment {
    return [ordered]@{
        '版本'       = 'dsh-guard plugin 0.1.0'
        'PowerShell' = $PSVersionTable.PSVersion.ToString()
        'profile'    = $script:ProfileName
        'profileDir' = $script:ProfileDir
        'GuardHome'  = $script:GuardHome
        'WebUrl'     = $script:WebUrl
        '用户'       = $env:USERNAME
        '机器'       = $env:COMPUTERNAME
    }
}

# ---- 覆盖抽取来的 Start-DshWeb ----
# 原版启动的是作者本机的 DshWeb-Launcher.ps1（桌面外壳专有）。插件版要起的是 DSH 自己：
# 直接调 dsh CLI。之所以"覆盖"而不是改抽取文件：保持 lib/*-core.ps1 是"机械抽取、零改动"，
# 便于以后跟上游对照。
function Start-DshWeb {
    param([switch]$WaitForReady, [int]$ReadyTimeoutSec = 120)
    if (Test-TcpPort -Port $script:WebPort) {
        return @{ Ok = $true; Pid = (Get-PortOwnerPid -Port $script:WebPort); Message = "端口 $script:WebPort 已在监听，无需重启" }
    }
    $dsh = Get-Command dsh.cmd -ErrorAction SilentlyContinue
    if (-not $dsh) { $dsh = Get-Command dsh -ErrorAction SilentlyContinue }
    if (-not $dsh) {
        return @{ Ok = $false; Pid = 0; Message = 'PATH 上找不到 dsh 命令，无法自动重启 —— 请手动启动 DSH' }
    }
    try {
        $p = Start-Process -FilePath $dsh.Source `
            -ArgumentList @('web', '--port', "$script:WebPort") `
            -WorkingDirectory $script:WorkDir -WindowStyle Hidden -PassThru
        Write-GuardLog "已用 dsh web --port $script:WebPort 拉起网页端（PID $($p.Id)，工作目录 $script:WorkDir）" -Level OK
    } catch {
        return @{ Ok = $false; Pid = 0; Message = "启动失败：$($_.Exception.Message)" }
    }
    if ($WaitForReady) {
        $deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-TcpPort -Port $script:WebPort) { return @{ Ok = $true; Pid = (Get-PortOwnerPid -Port $script:WebPort); Message = "Web 已就绪（$script:WebUrl）" } }
            if (-not (Test-PidAlive -ProcessId $p.Id)) { return @{ Ok = $false; Pid = $p.Id; Message = '启动进程提前退出' } }
        }
        return @{ Ok = $false; Pid = $p.Id; Message = "等待就绪超时（$ReadyTimeoutSec 秒）" }
    }
    return @{ Ok = $true; Pid = $p.Id; Message = '已启动（未等待就绪）' }
}

# ---------------------------------------------------------------- -Stop
if ($Stop) {
    $lk = Read-JsonFile -Path $script:LockFile
    if ($lk -and $lk.pid -and (Test-PidAlive -ProcessId ([int]$lk.pid))) {
        try { Stop-Process -Id ([int]$lk.pid) -Force -ErrorAction Stop; Write-Host "已停止守护进程 PID $($lk.pid)" }
        catch { Write-Host "停止失败：$($_.Exception.Message)" }
    } else {
        Write-Host '没有正在运行的守护进程'
    }
    Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue
    exit 0
}

# ---------------------------------------------------------------- -Once
if ($Once) {
    Initialize-DshGuardDirs
    $result = [ordered]@{ ok = $true; action = 'once'; at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    try {
        $state = Get-GuardState
        Invoke-MonitorCycle -State $state
        $after = Get-GuardState
        $result.state = [ordered]@{
            lastGoodSnapshot    = $after.lastGoodSnapshot
            lastSeenHash        = $after.lastSeenHash
            pendingSnapshot     = $after.pendingSnapshot
            quarantineUntil     = $after.quarantineUntil
            pluginChangeCount   = $after.pluginChangeCount
            consecutiveRollback = $after.consecutiveRollback
            lastRollbackAt      = $after.lastRollbackAt
        }
        $result.identity = (Get-ProfileIdentity).hash
        $result.snapshots = @(Get-AllSnapshots).Count
    } catch {
        $result.ok = $false
        $result.error = $_.Exception.Message
        $result.stack = $_.ScriptStackTrace
    }
    if ($Out) {
        $dir = Split-Path -Parent $Out
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($Out, ($result | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    } else {
        $result | ConvertTo-Json -Depth 8
    }
    exit $(if ($result.ok) { 0 } else { 1 })
}

# ---------------------------------------------------------------- 常驻
if ($IntervalSec -gt 0) { $script:Cfg.WatchIntervalSec = $IntervalSec }
Start-SupervisorLoop
