# ============================================================================
#  guard-bootstrap.ps1 —— 插件版守护的配置头
#
#  作用：定义 DshGuard.Core.ps1 抽出来的那 25 个函数所依赖的全部 $script: 变量
#        （原本这些变量定义在 DSH Desktop 的 Core 里，且带桌面外壳耦合）。
#
#  与桌面版的关键差别：
#    · GuardRoot 不再是"DSH-Desktop 目录"，而是插件自己的 ~/.dsh-guard
#      （插件包目录可能被 npm/pnpm 覆盖，绝不能把状态写在那里）
#    · 没有 3101/3080 双端、shell2、Launch-Harness、active-end（维护窗口已按泛化语义实现）
#    · profile 名可传参（默认 web）
#
#  所有目录都支持 DSHGUARD_* 环境变量重定向（影子环境自检要用）。
# ============================================================================

param(
    [string]$ProfileName = 'web',
    [string]$GuardHome   = '',
    # ⚠️ 默认 0 = "调用方没指定"。**不要**在这里写死 3080：写死会让默认值冒充"显式指定"，
    #    把下面 §4 的环境变量回退整个盖掉（2026-09-14 真启动实测过这个坑）。
    [int]   $WebPort     = 0,
    # ---- 官方桌面端支持（2026-09-26 新增；**默认值 = 上游行为，不影响 web 那份**）----
    # 'port'    = 老行为：探 DSH 的 Web 端口在不在听
    # 'process' = 官方桌面端：探 `DeepSeek Harness.exe` 进程还在不在
    #             （官方端端口是随机的 —— asar 里是 server.listen(0) —— 按端口盯必然盯错）
    [string]$HealthMode  = '',
    [string]$AppExe      = '',      # 官方端可执行文件（process 模式下用它重启）
    [string]$AppProcess  = '',      # 进程名（不含 .exe）
    [string]$PnpmCmd     = ''       # 回滚时用的 pnpm 命令（官方端要带自带运行时）
)

$ErrorActionPreference = 'Stop'

# ---- 0. 修 PSModulePath（2026-09-26 新增；官方桌面端迁移时发现）----
#
# 现象：**从 PowerShell 7 的会话里 spawn 出来的 5.1 子进程**会继承 PS7 的 PSModulePath
#       （`C:\Program Files\PowerShell\7\Modules`、`…\Documents\PowerShell\Modules` 排在前面），
#       于是 5.1 解析 `Microsoft.PowerShell.Utility` 时**优先命中 PS7 版模块**、加载失败，
#       `Get-FileHash` / `Get-NetTCPConnection` 这类**靠自动加载**的 cmdlet 直接变成
#       "无法将…项识别为 cmdlet" —— 症状与"命令不存在"一模一样，极难归因。
# 复现（实测）：从 node 里 spawn('powershell.exe', ['-File', 任意.ps1]) 时必现
#       （探针证据：GetFileHash=NOT FOUND，且 PSModulePath 首项是 PS7 目录）；
#       同一脚本从 5.1 会话直接调用则正常。
# 处置：5.1 下把 PS7 的模块目录从 PSModulePath 里**剔掉**（保留顺序，只删不换）。
#       放在最前面 —— 本文件之后（以及所有 dot-source 它的脚本）都要用这类 cmdlet。
if ($PSVersionTable.PSVersion.Major -le 5 -and $env:PSModulePath) {
    # ⚠️ 变量名别叫 $keep/$Keep！2026-09-26 实测踩到：guard.ps1 有个 `[int]$Keep` 参数，
    #    PowerShell 变量名**不区分大小写**，而 dot-source 时两者同在调用方作用域 ⇒
    #    把数组赋给 [int] 约束的参数 → "Cannot convert System.Object[] to type System.Int32"，
    #    整个初始化失败（症状与"命令不存在"一样难归因）。同类：账本 E15（$Host）。
    #    护栏：tools\test-var-collision.ps1（静态查"普通局部变量 vs 入口脚本参数名"撞车）。
    $psmpKeepPaths = @($env:PSModulePath -split ';' | Where-Object {
        if (-not $_) { return $false }
        if ($_ -match 'WindowsPowerShell') { return $true }   # 5.1 自己的模块目录，保留
        if ($_ -match 'PowerShell') { return $false }         # PS7 的模块目录，剔掉
        return $true                                          # 其它（如 SQL Server 的），保留
    })
    $env:PSModulePath = ($psmpKeepPaths -join ';')
}

# ---- 1. 根目录 ----
$script:GuardHome = if ($GuardHome) { $GuardHome }
                    elseif ($env:DSHGUARD_HOME) { $env:DSHGUARD_HOME }
                    else { Join-Path $env:USERPROFILE '.dsh-guard' }
$script:GuardRoot = $script:GuardHome          # 抽取出来的函数引用 GuardRoot
$script:DshHome   = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

$script:ProfileName = $ProfileName
$script:ProfileDir  = Join-Path $script:DshHome "profiles\$ProfileName"

$script:LogDir      = Join-Path $script:GuardHome 'logs'
$script:SnapshotDir = Join-Path $script:GuardHome 'snapshots'
$script:StateDir    = Join-Path $script:GuardHome 'state'
$script:AiDir       = Join-Path $script:GuardHome 'ai'
# 抽取出来的 Initialize-DshGuardDirs 会遍历这个变量；插件版不用外壳快照，给它一个占位目录
$script:ShellSnapshotDir = Join-Path $script:GuardHome 'shell-snapshots'

# ---- 2. 环境变量重定向（影子环境/自检用；必须在建目录之前）----
foreach ($pair in @(@('DSHGUARD_HOME', 'GuardHome'), @('DSHGUARD_LOG_DIR', 'LogDir'),
                    @('DSHGUARD_SNAPSHOT_DIR', 'SnapshotDir'), @('DSHGUARD_STATE_DIR', 'StateDir'),
                    @('DSHGUARD_AI_DIR', 'AiDir'))) {
    $v = [Environment]::GetEnvironmentVariable($pair[0])
    if ($v) { Set-Variable -Name $pair[1] -Scope Script -Value $v }
}
$script:GuardRoot = $script:GuardHome

# ---- 3. 状态/日志文件 ----
$script:GuardStateFile  = if ($env:DSHGUARD_GUARD_STATE_FILE) { $env:DSHGUARD_GUARD_STATE_FILE } else { Join-Path $script:StateDir 'guard-state.json' }
$script:IncidentFile    = if ($env:DSHGUARD_INCIDENT_FILE)    { $env:DSHGUARD_INCIDENT_FILE }    else { Join-Path $script:StateDir 'incidents.jsonl' }
$script:GuardLogFile    = if ($env:DSHGUARD_GUARD_LOG)        { $env:DSHGUARD_GUARD_LOG }        else { Join-Path $script:LogDir 'guard.log' }
$script:LockFile        = if ($env:DSHGUARD_LOCK_FILE)        { $env:DSHGUARD_LOCK_FILE }        else { Join-Path $script:StateDir 'watchdog.lock' }

# 看门狗要盯的"服务端日志"和"启动状态"（Get-HealthSnapshot 读它们判断心跳/错误）
# ⚠️ 这两个当初漏定义过：抽取报告里列了，我漏抄 → 影子测试第一轮就报
#    "Cannot bind argument to parameter 'Path' because it is an empty string"（2026-09-14）。
$script:LaunchLogFile   = if ($env:DSHGUARD_LAUNCH_LOG)       { $env:DSHGUARD_LAUNCH_LOG }       else { Join-Path $script:LogDir 'dsh-web.log' }
$script:LaunchStateFile = if ($env:DSHGUARD_STATE_FILE)       { $env:DSHGUARD_STATE_FILE }       else { Join-Path $script:StateDir 'launch-state.json' }

# ---- 4. DSH Web 端口 ----
# 优先级：**显式传参** > 环境变量 DSH_WEB_URL > 3080
#
# ⚠️ 为什么显式参数必须赢过环境变量（2026-09-14 真启动实测踩到）：
#    DSH 会把 DSH_WEB_URL 导出给**自己的整个进程树**，于是在 DSH 里（或从 DSH 会话里）
#    起的第二个实例会继承**上一个实例**的端口。实测：守护起在 3999，status 却报 3101，
#    而且 listening=True —— 探的是另一个实例，纯假阳性。
#    桌面版为同一件事单独写过防呆（DshGuard.Core.ps1「环境里的 DSH_WEB_URL 把网页端指到了
#    …已纠正」）；插件版没有"桌面端/网页端"两个概念，正解是让调用方把**当前实例的真实
#    端口**显式传进来 —— 宿主就是从面板请求的 Host 头拿到它的。
# ⚠️ 先把"调用方到底有没有显式指定"存进一个**另外的名字**，再去动 $script:WebPort。
#
#    原因（2026-09-14 实测踩到；tools\test-host-load.mjs 把它抓了出来）：
#    本文件是被 `.` **点源**进来的，点源时 `$script:` 指的就是**调用方的脚本作用域**，
#    所以 `$script:WebPort` 和参数 `$WebPort` 是**同一个变量** —— 先写
#    `$script:WebPort = 3080` 就把参数值擦掉了，后面 `if ($WebPort -gt 0)` 判断的
#    其实是刚写进去的环境值/3080，几乎恒为真 → 显式端口永远"看起来指定过"，
#    结果仍被环境变量牵着走（实测：实例起在 3999，却报 3101 且 from=explicit）。
$portArg = $WebPort        # 0 = 调用方没有指定
$script:WebPortFrom = 'default'
$script:WebPort     = 3080
if ($env:DSH_WEB_URL -match ':(\d+)') { $script:WebPort = [int]$Matches[1]; $script:WebPortFrom = 'env' }
if ($portArg -gt 0)                   { $script:WebPort = $portArg;         $script:WebPortFrom = 'explicit' }
# 显式指定端口时 URL 自己拼 —— 不能再用环境里那个"可能属于别的实例"的 URL
$script:WebUrl = if ($script:WebPortFrom -eq 'env' -and $env:DSH_WEB_URL) { $env:DSH_WEB_URL }
                 else { "http://127.0.0.1:$($script:WebPort)" }

# ---- 4.5 运行模式：官方桌面端（2026-09-26 新增）----
#
# 为什么需要它：官方桌面端（D:\dsh\DeepSeek Harness.exe）与自制外壳的差别有二 ——
#   ① 它的界面端口**每次启动都随机**（asar 里是 `server.listen(0, "127.0.0.1")`，
#      实测过 19387）⇒ 按端口盯"在不在听"必然盯错；
#   ② 它没有 `dsh web --port` 这条 CLI ⇒ 原来看门狗的自动拉起方式用不了。
# 所以官方端用 `HealthMode='process'`：**"活着"的定义 = `DeepSeek Harness.exe` 进程在**，
# 下游的宽限期/阈值/隔离观察/回滚逻辑一行都不用改（它们只读 $Health.PortUp）。
#
# 优先级：**显式传参 > DSHGUARD_* 环境变量 > <GuardHome>\config.json > 内建默认**
# （config.json 由插件的 lib/index.js 写入，这样计划任务、独立面板、命令行三条路径
#   不必各自带一遍参数也能拿到同一套设置。）
# 注意文件名**按 profile 分开**：GuardHome（~/.dsh-guard）是整机共用的，
# 若共用一份 config.json，desktop 写了 process 模式之后 web 那份也会跟着变 —— 那会
# 让"你自己手动跑的 web 看门狗"去盯官方端进程。（显式传参 > 环境变量 > 本文件 > 默认）
$script:GuardConfigFile = Join-Path $script:GuardHome ("config-$ProfileName.json")
$script:GuardConfig = $null
if (Test-Path -LiteralPath $script:GuardConfigFile) {
    try { $script:GuardConfig = Get-Content -LiteralPath $script:GuardConfigFile -Raw | ConvertFrom-Json } catch { $script:GuardConfig = $null }
}
function Get-GuardCfgValue {
    param([string]$Key)
    if ($script:GuardConfig -and ($script:GuardConfig.PSObject.Properties.Name -contains $Key)) {
        return [string]$script:GuardConfig.$Key
    }
    return ''
}

$script:HealthMode = if ($HealthMode) { $HealthMode }
                     elseif ($env:DSHGUARD_HEALTH_MODE) { $env:DSHGUARD_HEALTH_MODE }
                     else { Get-GuardCfgValue 'healthMode' }
if (-not $script:HealthMode) { $script:HealthMode = 'port' }

$script:AppExe = if ($AppExe) { $AppExe }
                 elseif ($env:DSHGUARD_APP_EXE) { $env:DSHGUARD_APP_EXE }
                 else { Get-GuardCfgValue 'appExe' }
if (-not $script:AppExe) { $script:AppExe = 'D:\dsh\DeepSeek Harness.exe' }

$script:AppProcess = if ($AppProcess) { $AppProcess }
                     elseif ($env:DSHGUARD_APP_PROCESS) { $env:DSHGUARD_APP_PROCESS }
                     else { Get-GuardCfgValue 'appProcess' }
if (-not $script:AppProcess) { $script:AppProcess = 'DeepSeek Harness' }

# 回滚最后要跑一次 `pnpm install`：官方端进程的 PATH 里没有 pnpm，必须用官方端自带的运行时。
$script:PnpmCmd = if ($PnpmCmd) { $PnpmCmd }
                  elseif ($env:DSHGUARD_PNPM) { $env:DSHGUARD_PNPM }
                  else { Get-GuardCfgValue 'pnpmCmd' }
if (-not $script:PnpmCmd) {
    $rtNode = 'D:\dsh\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
    $rtPnpm = 'D:\dsh\resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.cjs'
    if ($script:HealthMode -eq 'process' -and (Test-Path -LiteralPath $rtNode) -and (Test-Path -LiteralPath $rtPnpm)) {
        $script:PnpmCmd = '"{0}" "{1}"' -f $rtNode, $rtPnpm
    }
    else { $script:PnpmCmd = 'pnpm' }
}

# 日志文案用的"判定对象称呼"（2026-09-26）：进程模式与端口模式各一套说法，
# 免得官方端模式下日志还在说"Web 未在运行 / 端口 X 正常"，读日志的人会以为判据没换。
$script:SubjectLabel = if ($script:HealthMode -eq 'process') { "官方端进程 $script:AppProcess" } else { "Web 端口 $script:WebPort" }
$script:SubjectIdle  = if ($script:HealthMode -eq 'process') { '官方端进程不在' } else { 'Web 未在运行' }

# 进程模式的判活辅助（port 模式下不使用，但定义着无害）
function Test-AppRunning {
    param([string]$Name = $script:AppProcess)
    return [bool](Get-Process -Name $Name -ErrorAction SilentlyContinue)
}
function Get-AppPid {
    param([string]$Name = $script:AppProcess)
    $p = @(Get-Process -Name $Name -ErrorAction SilentlyContinue | Sort-Object StartTime)
    if ($p.Count -gt 0) { return [int]$p[0].Id }
    return 0
}

# ---- 5. 端口占用查询缓存（Get-PortOwnerPid 用）----
$script:PortOwnerCache = @{}

# ---- 6. 日志错误特征（判断"崩溃/报错密集"）----
#  说明：与桌面版同源；插件版先内置这一份，后续可做成配置项。
$script:ErrorPatterns = @(
    'Failed to load plugins',
    'Error: Cannot find module',
    'Cannot find package',
    'ERR_MODULE_NOT_FOUND',
    'ERR_PNPM_',
    'UnhandledPromiseRejection',
    'Uncaught Exception',
    'FATAL ERROR'
    # ⚠️ 故意**不含** `EADDRINUSE`（2026-09-14）：它意味着"已经有实例占着端口"，
    #    也就是"另一个 DSH 活着"，而不是"这个坏了"。把它当致命错误会让看门狗在
    #    端口被占时误判成崩溃 → 回滚（这是那次事故的放大器之一）。
)
$script:ErrorWhitelist = @(
    'ExperimentalWarning',
    'DeprecationWarning',
    'punycode'
)

# ---- 7. 巡检参数（可用 DSHGUARD_* 环境变量覆盖）----
$script:Cfg = [ordered]@{
    WatchIntervalSec    = 5      # 巡检间隔（秒）
    ProbeIntervalSec    = 20     # HTTP 健康探测间隔
    ErrorBurstWindowSec = 60     # 错误密集判定窗口
    ErrorBurstCount     = 3      # 窗口内 N 条错误即视为不健康
    QuarantineSec       = 90     # 插件变更后的隔离观察期
    # ⚠️ 2026-09-14 夹具抓到的 bug：核心代码（watchdog-core.ps1 判"最近装过插件"）一直在读
    #    这个键，但**全项目没有定义过它** → 取到 $null → 比较恒假 → "近期动过插件"永远为假
    #    → 自动回滚实际上一直是哑的（真机那次能回滚纯属隔离期 $inQuarantine 恰好为真）。
    #    凡是核心引用的 Cfg 键，这里必须都有；tools\test-config.ps1 现在会静态核对这一点。
    PluginChangeWindowSec = 900  # "最近动过插件"的时间窗（秒）：回滚只允许落在这个窗口内
    RestartGraceSec     = 90     # 端口刚不在时的宽限期：这段时间内只观察，不重启不回滚
    MaxRollbackAttempts = 3      # 连续回滚上限，防死循环
    # ⚠️ 下面两个默认都是 $false（2026-09-14 事故后改的）：
    #   看门狗只能用 `dsh web --port <port>` 起一个**没有窗口**的实例；而桌面外壳随后启动时，
    #   启动器会走"快速路径"看到端口已被占用 → 只把"已有窗口"拉到前台，可那个实例没有窗口
    #   → 用户看到的现象就是"点图标打不开"。所以**默认不替用户启动 DSH**，只记录 + 提示。
    AutoStartDsh        = $false # 端口持续不在且有致命证据时，是否擅自 dsh web 拉起
    AutoRestart         = $false # 回滚后是否擅自拉起（同上，默认关）
    KeepSnapshots       = 8      # 快照保留个数（超出的自动清理；lastGood 那个永不删）
}
foreach ($k in @($script:Cfg.Keys)) {
    # ⚠️ 必须用 **-creplace**（区分大小写），不能用 -replace。
    #
    #    2026-09-14 实测踩到：PowerShell 的 `-replace` **默认大小写不敏感**，于是
    #    `[a-z0-9]` 连大写字母也匹配、`[A-Z]` 连小写也匹配 → 整个正则几乎匹配每两个字符 →
    #    生成的名字是 `DSHGUARD_W_AT_CH_IN_TE_RV_AL_SE_C` 这种垃圾：
    #        -replace  : W_at_ch_In_te_rv_al_Se_c     ← 错
    #        -creplace : Watch_Interval_Sec           ← 对
    #    症状极其隐蔽：**所有 DSHGUARD_* 配置覆盖全部静默失效**（实测设
    #    DSHGUARD_QUARANTINE_SEC=42，Cfg.QuarantineSec 仍然是 90）。
    #    桌面版 Core 里那句「不要用正则拆分驼峰……会被拆成 DSHGUARD_E_NA_BL_EA_I」
    #    说的就是这件事，它最后用了显式映射表；这里保留推导但改用 -creplace。
    #    （改完请跑 tools\test-config.ps1 复核 —— 那里把这两件事都钉住了。）
    $envName = 'DSHGUARD_' + ($k -creplace '([a-z0-9])([A-Z])', '$1_$2').ToUpper()
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) {
        $cur = $script:Cfg[$k]
        $script:Cfg[$k] = if ($cur -is [bool]) { $v -in @('1', 'true', 'yes') }
                          elseif ($cur -is [int]) { [int]$v }
                          else { $v }
    }
}

# ---- 8. 快照包含哪些文件（与桌面版一致；node_modules 由 New-ProfileSnapshot 另做镜像）----
$script:SnapshotFiles = @(
    @{ Src = 'package.json';        Rel = 'package.json' },
    @{ Src = 'cordis.yml';          Rel = 'cordis.yml' },
    @{ Src = 'cordis.patch.yml';    Rel = 'cordis.patch.yml' },
    @{ Src = 'pnpm-lock.yaml';      Rel = 'pnpm-lock.yaml' },
    @{ Src = 'pnpm-workspace.yaml'; Rel = 'pnpm-workspace.yaml' }
)
