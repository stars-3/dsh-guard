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
    [int]   $WebPort     = 0
)

$ErrorActionPreference = 'Stop'

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
