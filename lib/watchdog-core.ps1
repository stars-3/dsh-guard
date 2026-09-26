# ============================================================================
#  watchdog-core.ps1 —— 从 DSH Desktop 的 DshGuard-Supervisor.ps1 抽取的通用看门狗函数
#  （由 tools\extract-supervisor.ps1 机械抽取生成，函数体未改动）
# ============================================================================

# ---- Test-SupervisorRunning  (源 DshGuard-Supervisor.ps1 第 63-70 行) ----
function Test-SupervisorRunning {
    if (-not (Test-Path $script:LockFile)) { return $false }
    try {
        $info = Read-JsonFile -Path $script:LockFile
        if (-not $info) { return $false }
        return (Test-PidAlive -ProcessId $info.pid)
    } catch { return $false }
}

# ---- Enter-SupervisorLock  (源 DshGuard-Supervisor.ps1 第 72-78 行) ----
function Enter-SupervisorLock {
    Write-JsonFile -Path $script:LockFile -Object ([ordered]@{
            pid       = $PID
            startedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            action    = $Action
        })
}

# ---- Exit-SupervisorLock  (源 DshGuard-Supervisor.ps1 第 80-87 行) ----
function Exit-SupervisorLock {
    try {
        # 只在"锁还是自己的"时候才删：锁被别人接管时删掉会把新实例的单实例保护弄坏
        $lk = Read-JsonFile -Path $script:LockFile
        if ($lk -and $lk.pid -and [int]$lk.pid -ne $PID) { return }
        Remove-Item -Force $script:LockFile -ErrorAction SilentlyContinue
    } catch { }
}

# ---- Get-HealthSnapshot  (源 DshGuard-Supervisor.ps1 第 92-129 行) ----
function Get-HealthSnapshot {
    <#
      .OUTPUTS @{ PortUp; HttpOk; HttpMsg; LauncherPid; LauncherAlive; NodePid;
                  HeartbeatAge; Phase; Exited; ExitCode; Note }
    #>
    # ---- 判活：两种模式（2026-09-26 新增，默认行为与上游一致）----
    #   port    : 老行为 —— DSH 的 Web 端口在不在听
    #   process : 官方桌面端 —— `DeepSeek Harness.exe` 进程还在不在
    #             ⚠️ 关键设计：把 process 的结论写进**同一个 PortUp 字段**，
    #             于是下游（宽限期、连续轮次阈值、隔离观察、回滚判定）一行都不用改。
    $procUp = $null
    if ($script:HealthMode -eq 'process') {
        $procUp   = Test-AppRunning
        $portUp   = $procUp
        $ownerPid = if ($procUp) { Get-AppPid } else { 0 }
    }
    else {
        $portUp   = Test-TcpPort -Port $script:WebPort
        $ownerPid = if ($portUp) { Get-PortOwnerPid -Port $script:WebPort } else { 0 }
    }
    $st = Read-JsonFile -Path $script:LaunchStateFile

    $launcherPid = 0; $nodePid = 0; $phase = 'unknown'; $exited = $false; $exitCode = $null
    $hbAge = [int]::MaxValue
    if ($st) {
        if ($st.PSObject.Properties.Name -contains 'launcherPid') { $launcherPid = [int]$st.launcherPid }
        if ($st.PSObject.Properties.Name -contains 'nodePid') { $nodePid = [int]$st.nodePid }
        if ($st.PSObject.Properties.Name -contains 'phase') { $phase = [string]$st.phase }
        if ($st.PSObject.Properties.Name -contains 'exited') { $exited = [bool]$st.exited }
        if ($st.PSObject.Properties.Name -contains 'exitCode') { $exitCode = $st.exitCode }
        if ($st.PSObject.Properties.Name -contains 'heartbeat') {
            try { $hbAge = [int]((Get-Date) - [datetime]::Parse($st.heartbeat)).TotalSeconds } catch { }
        }
    }
    $launcherAlive = (Test-PidAlive -ProcessId $launcherPid)

    return [ordered]@{
        PortUp         = $portUp
        PortOwnerPid   = $ownerPid
        HealthMode     = $script:HealthMode
        ProcessUp      = $procUp
        HttpOk         = $null
        HttpMsg        = ''
        LauncherPid    = $launcherPid
        LauncherAlive  = $launcherAlive
        NodePid        = $(if ($ownerPid -gt 0) { $ownerPid } else { $nodePid })
        HeartbeatAge   = $hbAge
        Phase          = $phase
        Exited         = $exited
        ExitCode       = $exitCode
        Note           = ''
    }
}

# ---- Test-HealthBad  (源 DshGuard-Supervisor.ps1 第 131-143 行) ----
function Test-HealthBad {
    <#  综合判断"当前运行是否不健康"  #>
    param($Health, [int]$ErrorCount = 0)
    $reasons = @()
    if (-not $Health.PortUp) {
        if ($script:HealthMode -eq 'process') { $reasons += "官方端进程 $script:AppProcess 不在" }
        else { $reasons += "Web 端口 $script:WebPort 未监听" }
    }
    if ($Health.PortUp -and $Health.HttpOk -eq $false) { $reasons += "HTTP 探测失败：$($Health.HttpMsg)" }
    # process 模式没有"启动器心跳"这个东西（官方端不写 launch-state.json），
    # 拿旧文件里的时间戳去判"心跳停滞"只会产出假理由 ⇒ 该模式下跳过。
    if ($script:HealthMode -ne 'process' -and -not $Health.PortUp -and
        $Health.HeartbeatAge -ne [int]::MaxValue -and
        $Health.HeartbeatAge -gt $script:Cfg.HeartbeatStaleSec -and -not $Health.Exited) {
        $reasons += "启动器心跳停滞 $($Health.HeartbeatAge) 秒（阈值 $($script:Cfg.HeartbeatStaleSec)s）"
    }
    if ($ErrorCount -ge $script:Cfg.ErrorBurstCount) { $reasons += "短时间内出现 $ErrorCount 条错误日志" }
    return $reasons
}

# ---- Get-PluginDelta  (源 DshGuard-Supervisor.ps1 第 148-160 行) ----
function Get-PluginDelta {
    <#  比较"上一个可用版本"与"当前 profile"的依赖差异  #>
    param($GoodIdentity, $CurrentIdentity)
    $added = @(); $removed = @(); $changedCfg = $false
    try {
        $g = @($GoodIdentity.dependencies)
        $c = @($CurrentIdentity.dependencies)
        $added = @($c | Where-Object { $_ -notin $g })
        $removed = @($g | Where-Object { $_ -notin $c })
        $changedCfg = ($GoodIdentity.patchYml -ne $CurrentIdentity.patchYml)
    } catch { }
    return @{ Added = $added; Removed = $removed; ConfigChanged = $changedCfg }
}

# ---- Start-Quarantine  (源 DshGuard-Supervisor.ps1 第 162-183 行) ----
function Start-Quarantine {
    <#  检测到插件变更：打快照 + 进入观察期  #>
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Reason)
    $snap = New-ProfileSnapshot -Label 'post-plugin-change' -Reason 'on-plugin-change'
    if (-not $snap) { return $false }

    $id = Get-ProfileIdentity
    $state.lastPluginChange = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $state.pluginChangeCount = [int]$state.pluginChangeCount + 1
    $state.quarantineUntil = (Get-Date).AddSeconds($script:Cfg.QuarantineSec).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $state.pendingSnapshot = $snap
    $state.pendingHash = $id.hash
    Save-GuardState -State $state

    Write-GuardLog "检测到 profile 变更（$Reason）：依赖 $($id.depCount) 项，指纹 $($id.hash)" -Level WARN
    Write-GuardLog "已快照并进入 $($script:Cfg.QuarantineSec) 秒隔离观察期 -> $snap" -Level WARN
    Write-Incident -Kind 'plugin-change' -Data @{
        reason = $Reason; snapshot = $snap; hash = $id.hash
        dependencies = @($id.dependencies); count = $id.depCount
    }
    return $true
}

# ---- Complete-Quarantine  (源 DshGuard-Supervisor.ps1 第 185-208 行) ----
function Complete-Quarantine {
    <#  观察期结束且一直健康 → 晋升为"可用版本"  #>
    param([Parameter(Mandatory = $true)]$State)
    $snap = $State.pendingSnapshot
    if ($snap -and (Test-Path $snap)) {
        Set-SnapshotHealth -Dir $snap -Health 'good' -Note '隔离观察期内未出现崩溃或报错'
        $state.lastGoodSnapshot = $snap
        $hist = @($state.goodHistory)
        $hist += [pscustomobject]@{
            snapshot = $snap
            hash     = $State.pendingHash
            at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        }
        if ($hist.Count -gt 20) { $hist = $hist[($hist.Count - 20)..($hist.Count - 1)] }
        $state.goodHistory = $hist
        Write-GuardLog "观察期结束，运行健康：$snap 已晋升为『可用版本』(hash=$($State.pendingHash))" -Level OK
        Write-Incident -Kind 'promote-good' -Data @{ snapshot = $snap; hash = $State.pendingHash }
    }
    $state.pendingSnapshot = $null
    $state.pendingHash = $null
    $state.quarantineUntil = $null
    $state.consecutiveRollback = 0
    Save-GuardState -State $state
}

# ---- Invoke-Rollback  (源 DshGuard-Supervisor.ps1 第 210-292 行) ----
function Invoke-Rollback {
    <#
      .SYNOPSIS 回滚到最近可用版本并（可选）重启，返回是否恢复成功
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Why,
        [string]$ContextForAi = ''
    )
    $target = $State.lastGoodSnapshot
    if (-not $target -or -not (Test-Path $target)) {
        # 没有历史可用版本 → 退而求其次：用"变更前"的那个快照
        $cands = @(Get-AllSnapshots | Where-Object { $_.Meta.reason -in @('baseline', 'on-plugin-change', 'manual') })
        $target = $null
        foreach ($c in $cands) {
            if ($c.Dir -ne $State.pendingSnapshot -and $c.Meta.health -ne 'bad') { $target = $c.Dir; break }
        }
        if (-not $target) {
            Write-GuardLog "回滚中止：找不到任何可用的历史版本（快照目录：$script:SnapshotDir）" -Level ERROR
            Write-Incident -Kind 'rollback-failed' -Data @{ why = $Why; error = 'no-usable-snapshot' }
            return $false
        }
        Write-GuardLog "没有 lastGood，退化为使用快照：$target" -Level WARN
    }

    Write-GuardLog "触发回滚（$Why）→ 目标：$target" -Level ROLLBACK
    $aiText = ''
    if ($script:Cfg.EnableAi) {
        $ai = Invoke-AiDiagnosis -Context $ContextForAi -Question 'DSH 刚装了一个新插件后崩溃/报错，请判断根因与处置建议。'
        if ($ai.Ok) { $aiText = $ai.Text } else { Write-GuardLog "AI 诊断不可用：$($ai.Text)" -Level WARN }
    }

    # 标记坏快照
    if ($State.pendingSnapshot -and (Test-Path $State.pendingSnapshot)) {
        Set-SnapshotHealth -Dir $State.pendingSnapshot -Health 'bad' -Note $Why
        $bad = @($State.badSnapshots)
        $bad += [pscustomobject]@{ snapshot = $State.pendingSnapshot; hash = $State.pendingHash; why = $Why; at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') }
        $State.badSnapshots = $bad
    }

    $stopped = Stop-DshWeb -Force
    Write-GuardLog "停止当前 Web：$($stopped.Message)" -Level WARN

    $r = Restore-ProfileSnapshot -SnapshotDir $target
    Write-Incident -Kind 'rollback' -Data @{
        why       = $Why
        target    = $target
        ok        = $r.Ok
        steps     = $r.Steps
        removed   = $r.RemovedPackages
        ai        = $aiText
    }
    foreach ($s in $r.Steps) { Write-GuardLog "  · $s" -Level ROLLBACK }

    $State.lastRollbackAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $State.consecutiveRollback = [int]$State.consecutiveRollback + 1
    $State.pendingSnapshot = $null
    $State.pendingHash = $null
    $State.quarantineUntil = $null
    Save-GuardState -State $State

    if (-not $script:Cfg.AutoRestart) {
        Write-GuardLog 'AutoRestart 已关闭：请手动双击桌面『DSH Web』启动' -Level WARN
        return $r.Ok
    }

    Start-Sleep -Seconds 3
    $start = Start-DshWeb -WaitForReady -ReadyTimeoutSec 120
    if ($start.Ok) {
        Write-GuardLog "回滚后重启成功：$script:WebUrl（$($start.Message)）" -Level OK
        Write-Incident -Kind 'rollback-restart' -Data @{ ok = $true; url = $script:WebUrl; pid = $start.Pid }
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            [System.Windows.Forms.MessageBox]::Show(
                "检测到新插件导致 DSH 崩溃/报错，已自动回滚到上一个可用版本并重启。`n`n地址：$script:WebUrl`n原因：$Why`n还原快照：$target`n`n详细日志：$script:GuardLogFile", 'DSH 守护 - 已自动回滚',
                'OK', 'Information') | Out-Null
        } catch { }
        return $true
    }
    Write-GuardLog "回滚后重启失败：$($start.Message)" -Level CRASH
    Write-Incident -Kind 'rollback-restart' -Data @{ ok = $false; msg = $start.Message }
    return $false
}

# ---- Invoke-WebCycle  (源 DshGuard-Supervisor.ps1 第 297-556 行) ----
function Invoke-WebCycle {
    param([Parameter(Mandatory = $true)]$State)

    $health = Get-HealthSnapshot
    if ($health.PortUp) {
        # ⚠️ 2026-09-26：进程模式**必须跳过** HTTP 探测 —— 它按 $script:WebUrl（烘死的端口）探，
        #    而官方端每次启动端口都变 ⇒ 重启后必然探失败，于是给一个**明明在跑**的官方端
        #    加上"HTTP 探测失败"这条不健康理由（后续可能触发误重启/误回滚）。
        #    进程模式下"进程在"就是全部判据，端口/HTTP 都不参与。
        if ($script:HealthMode -eq 'process') {
            $health.HttpOk  = $null
            $health.HttpMsg = ''
        }
        else {
            $h = Test-WebHttp -Url $script:WebUrl -TimeoutSec 12
            $health.HttpOk = $h.Ok
            $health.HttpMsg = $h.Msg
            if (-not $h.Ok) { Write-GuardLog "HTTP 探测异常：$($h.Msg)" -Level WARN }
        }
    }
    # 刷新两端"连续不可用"计时（抑制判据用它，抗瞬时抖动；2026-09-13 加）
    Update-EndDownState -State $State

    # ---- 0. 启动器换代（重启过）→ 重置日志读取位置 ----
    $State.launcherChanged = $false
    if ($health.LauncherPid -gt 0 -and [int]$State.lastLauncherPid -ne $health.LauncherPid) {
        # ⚠️ 重置位置要跳到**当前文件末尾**，绝不能写 0。
        # 写 0 = 下一轮从文件开头重读，会把整份历史日志里的旧错误当成"新增"：
        # 2026-09-12 实测 —— 一次换代后报"实时日志新增 10 条错误行"，示例行的时间戳
        # 还是凌晨 01:26 的，且 10 条的记账时间戳全部落在同一秒（19:02:39.190）。
        # 这会凑出"错误密集"，与"网页端未监听"叠加 → 误判故障 → 触发插件回滚。
        $endOffset = 0
        try {
            if (Test-Path -LiteralPath $script:LaunchLogFile) {
                $endOffset = [long](Get-Item -LiteralPath $script:LaunchLogFile -ErrorAction Stop).Length
            }
        } catch { $endOffset = 0 }
        Write-GuardLog "检测到启动器换代：PID $($State.lastLauncherPid) -> $($health.LauncherPid)，日志读取位置跳到末尾（offset=$endOffset）" -Level INFO
        $State.lastLauncherPid = $health.LauncherPid
        $State.logOffset = $endOffset
        $State.errorTimes = @()
        $State.launcherChanged = $true
        Save-GuardState -State $State
    }

    # ---- 1. 增量扫日志抓错误 ----
    $from = 0
    if ($State.PSObject.Properties.Name -contains 'logOffset' -and $State.logOffset) { $from = [long]$State.logOffset }
    $scan = Get-NewLogErrors -Path $script:LaunchLogFile -FromOffset $from
    if ($scan.NewBytes -gt 0 -or $scan.LastOffset -ne $from) {
        $State.logOffset = $scan.LastOffset
    }
    $newErrors = @($scan.Errors)
    if ($newErrors.Count -gt 0) {
        Write-GuardLog "实时日志新增 $($newErrors.Count) 条错误行；示例：$($newErrors[0])" -Level ERROR
        $times = @($State.errorTimes)
        foreach ($e in $newErrors) { $times += (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') }
        if ($times.Count -gt 200) { $times = $times[($times.Count - 200)..($times.Count - 1)] }
        $State.errorTimes = $times
        foreach ($e in ($newErrors | Select-Object -First 15)) {
            Write-Incident -Kind 'log-error' -Data @{ line = $e }
        }
    }
    # 统计窗口内错误数
    $cut = (Get-Date).AddSeconds(-1 * $script:Cfg.ErrorBurstWindowSec)
    $recent = 0
    foreach ($t in @($State.errorTimes)) {
        try { if ([datetime]::Parse($t) -ge $cut) { $recent++ } } catch { }
    }

    # ---- 2. 判断当前 profile 是否发生过插件变更 ----
    $id = Get-ProfileIdentity
    $sig = Get-ProfileFileSignature
    $lastHash = $State.lastSeenHash
    $inQuarantine = $false
    if ($State.quarantineUntil) {
        try { $inQuarantine = ((Get-Date) -lt [datetime]::Parse($State.quarantineUntil)) } catch { $inQuarantine = $false }
    }

    if (-not $lastHash) {
        # 守护首次运行：以当前状态建立基线
        if (-not $State.lastGoodSnapshot -or -not (Test-Path $State.lastGoodSnapshot)) {
            $base = New-ProfileSnapshot -Label 'baseline' -Reason 'baseline'
            if ($base) {
                Set-SnapshotHealth -Dir $base -Health 'good' -Note '守护建立基线时运行中'
                $State.lastGoodSnapshot = $base
                Write-GuardLog "首次运行：已建立基线可用版本 $base（hash=$($id.hash)）" -Level OK
                Write-Incident -Kind 'baseline' -Data @{ snapshot = $base; hash = $id.hash; dependencies = @($id.dependencies) }
            }
        }
        $State.lastSeenHash = $id.hash
        $State.profileSignature = $sig
        Save-GuardState -State $State
    } elseif ($id.hash -eq $lastHash -and (-not $State.profileSignature -or $State.launcherChanged)) {
        # 依赖清单没变，且（没有基线签名 / 只是一次重启）→ 这不是"装了插件"
        # 关键：没有基线签名时"建立基线"而不是"报变更"，否则守护每次启动都会误报一次
        Write-GuardLog "profile 未变更（建立/刷新文件签名基线），不进入隔离观察" -Level INFO
        $State.profileSignature = $sig
        Save-GuardState -State $State
    } elseif ($id.hash -ne $lastHash -or $sig -ne $State.profileSignature) {
        # 依赖清单变了，或者 profile 文件刚被改写（pnpm add 会先写 lock/package.json）
        $State.lastSeenHash = $id.hash
        $State.profileSignature = $sig
        if ($inQuarantine) {
            Write-GuardLog '观察期内 profile 又发生变化，延长观察期' -Level WARN
            $State.quarantineUntil = (Get-Date).AddSeconds($script:Cfg.QuarantineSec).ToString('yyyy-MM-dd HH:mm:ss.fff')
            Save-GuardState -State $State
        } else {
            $goodMeta = if ($State.lastGoodSnapshot -and (Test-Path $State.lastGoodSnapshot)) { Get-SnapshotMeta -Dir $State.lastGoodSnapshot } else { $null }
            $delta = if ($goodMeta) { Get-PluginDelta -GoodIdentity $goodMeta.identity -CurrentIdentity $id } else { @{ Added = @(); Removed = @(); ConfigChanged = $false } }
            $desc = @()
            if ($delta.Added.Count) { $desc += "新增：$($delta.Added -join ', ')" }
            if ($delta.Removed.Count) { $desc += "移除：$($delta.Removed -join ', ')" }
            if ($delta.ConfigChanged) { $desc += '配置(cordis.patch.yml)有改动' }
            if ($desc.Count -eq 0) { $desc += 'profile 文件被改写（依赖清单未变）' }
            if (-not (Start-Quarantine -State $State -Reason ($desc -join '；'))) {
                Write-GuardLog '插件变更后打快照失败（继续监控，但回滚点可能不准）' -Level ERROR
            }
        }
    } else {
        Save-GuardState -State $State
    }

    # ---- 3. 崩溃/不健康判定（**插件版在 2026-09-14 事故后重写**）----
    #
    # ⚠️ 事故复盘（这段原来长什么样、为什么会把用户的 DSH 搞挂）：
    #    原来这里把「端口不在 + 启动器 PID 已死 / 已记录退出」判成**明确崩溃**：
    #        if (-not $health.PortUp) {
    #            if ($health.LauncherPid -gt 0 -and -not $health.LauncherAlive) { $crashed = $true }
    #    而"外壳重启"恰好就是**先杀掉旧服务、再起新服务**，中间几秒端口不在、旧启动器 PID 已死
    #    —— 于是正常重启被当成崩溃；又因为正落在"插件变更后"窗口里，触发了自动回滚；
    #    回滚流程随后去拉 3101，与外壳刚起的服务**撞端口**（EADDRINUSE），
    #    结果 3101 再也起不来、桌面端打不开。
    #
    #    插件版**没有**桌面版那套"这次是用户主动重启"的意图信号（那依赖外壳专有文件，
    #    而且我们来就是要泛化掉它），所以判据必须**保守**：
    #      · 端口短暂不在**从来不等于**崩溃；
    #      · 超过宽限期仍在不在，也还要看**日志里有没有致命错误证据**（插件加载失败之类）；
    #      · 日志干净 → 就当"用户自己关了 DSH"，只记录、不处置。
    #    宁可漏救，不可误回滚 —— 误回滚会动用户的 profile，代价高得多。
    $badReasons = @(Test-HealthBad -Health $health -ErrorCount $recent)
    $fatalEvidence = ($recent -ge 1)     # $recent = 日志里命中 ErrorPatterns 的条数（见 Get-HealthSnapshot）
    $crashed = $false

    if ($health.PortUp) {
        $State.lastUpAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $State.downSince = $null
    } else {
        # 计时基准：优先"最后一次见到它在跑"；从没见过它跑（例如守护先起来、DSH 还没起过）
        # 就用"第一次发现它不在"——否则 downSec 恒为 0，会永远卡在宽限期里干等，
        # 连"日志有致命错误 → 判定起不来"那条路都走不到。
        if (-not $State.downSince) { $State.downSince = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') }
        $refStr = if ($State.lastUpAt) { $State.lastUpAt } else { $State.downSince }
        $downSec = 0
        try { $downSec = [int]((Get-Date) - [datetime]::Parse($refStr)).TotalSeconds } catch { $downSec = 0 }
        $grace = [int]$script:Cfg.RestartGraceSec
        if ($downSec -lt $grace) {
            # 刚还在跑 → 大概率有人（用户 / 外壳启动器 / 我们自己）正在重启它。等一等，别抢。
            Write-GuardLog "$script:SubjectIdle，但距最近一次在跑只有 $downSec 秒（宽限 $grace 秒）→ 只观察，不重启、不回滚" -Level INFO -NoConsole
            Save-GuardState -State $State
            return
        }
        if (-not $fatalEvidence) {
            # 超过宽限但日志干净：没有任何"它坏了"的证据，很可能就是用户自己关的。
            Write-GuardLog "$script:SubjectIdle（已 $downSec 秒），但日志里没有致命错误证据 → 判定为用户未启动/已关闭，不处置" -Level INFO -NoConsole
            Save-GuardState -State $State
            return
        }
        $badReasons += "$script:SubjectIdle（已 $downSec 秒）且日志有致命错误证据（近期错误 $recent 条）"
    }

    # ---- 4. 处置 ----
    $why = ($badReasons -join '；')

    # 主动切换 ≠ 崩溃（2026-09-13 实测补上）。
    # Stop-OtherInstances.ps1 启动另一端时会强杀本端：退出码 -1、进程"不见了"，
    # 从退出码/存活状态上**无法**与真崩溃区分；只有 instance-cleanup.log 的 kill
    # 记录能证明那是设计行为（会话写句柄独占，"开一端就关另一端"）。
    # 不区分会怎样（2026-09-14 真机实测）：外壳重启那几秒被判成崩溃 → 自动回滚 →
    # 回滚流程又去拉同一个端口 → 撞端口（EADDRINUSE）→ 服务再也起不来、界面打不开。
    if ($badReasons.Count -gt 0) {
        $ikAge = Get-IntentionalKillAgeSec -Port $script:WebPort -WithinSec 180
        if ($ikAge -ge 0) {
            if (Write-SuppressLog -Key 'web-intentional-switch' -Message "网页端不在跑，但 $ikAge 秒前被另一端主动关掉（Stop-OtherInstances 设计行为，非崩溃）→ 不重启、不回滚") {
                Write-Incident -Kind 'web-intentional-switch' -Data @{ why = $why; ageSec = $ikAge }
            }
            Save-GuardState -State $State
            return
        }
    }

    # 维护窗口内只记录不处置（对**两端**都算）。
    # 为什么必须有这一条：重启 DSH（或改配置/换插件）时端口会短暂不在，
    # 此刻"刚刚还在跑"这条抑制未必成立（可能已经超过 180 秒窗口），
    # 于是守护会抢着重启、甚至在"刚装过插件"的窗口里回滚 profile，
    # 和用户的操作对撞。所以"我要动它"时请先声明：
    #   guard.ps1 -Action maint-start -Minutes 30 -Note '我在改配置'（独立窗口也有按钮）
    # 窗口到期自动失效，不会永久关掉守护。
    if ($badReasons.Count -gt 0) {
        $mt = Get-ShellMaintenance
        if ($mt.Active) {
            if (Write-SuppressLog -Key 'web-maintenance' -Message "服务异常（$why），但处于维护窗口内（至 $($mt.Until)：$($mt.Note)）→ 只记录不处置") {
                Write-Incident -Kind 'web-maintenance-suppressed' -Data @{ why = $why; until = $mt.Until; note = $mt.Note }
            }
            return
        }
    }

    # （原版这里有一条"用户主动切到了另一端 → 别去复活本端"的抑制；插件版只有一端，
    #   Test-EndSuppressed 恒为 false，整块删掉了；要"别动我"请用维护窗口。）
    if ($badReasons.Count -gt 0) {
        $supW = Test-EndSuppressed -End 'web' -State $State
        if ($supW.Suppressed) {
            # 节流：用户待在另一端是"持续状态"，每 30 分钟最多记一条，别把日志刷爆
            if (Write-SuppressLog -Key 'web-suppressed' -Message "网页端异常（$why），但$($supW.Reason) → 按用户意图保持关闭，不重启也不回滚") {
                Write-Incident -Kind 'web-suppressed' -Data @{ why = $why; activeEnd = (Get-ActiveEnd).End }
            }
            return
        }
    }

    if ($badReasons.Count -gt 0) {
        # ---- 4a. 动手之前**再探一次端口** ----
        # 这是 2026-09-14 事故最直接的教训：从"判定"到"动手"之间可能已经过了几秒，
        # 而外壳/用户可能刚好把服务拉起来了 —— 那时再回滚就是**跟人抢**；
        # 更糟的是回滚流程自己也会去拉 3101，两边撞端口（EADDRINUSE）→ 服务再也起不来。
        # 所以：端口只要活了，立刻放弃本次处置。
        if (Test-TcpPort -Port $script:WebPort) {
            Write-GuardLog '动手前复查：端口又活了（有人在重启/已启动）→ 放弃本次处置' -Level INFO -NoConsole
            $State.lastUpAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            Save-GuardState -State $State
            return
        }

        # 有明确故障：只有"起不来 **且** 近期动过插件"才回滚（其余一律不擅自动 profile）
        $recentPlugin = $false
        if ($State.lastPluginChange) {
            try { $recentPlugin = (((Get-Date) - [datetime]::Parse($State.lastPluginChange)).TotalSeconds -lt $script:Cfg.PluginChangeWindowSec) } catch { }
        }
        $isPending = [bool]$State.pendingSnapshot

        if (($recentPlugin -or $isPending -or $inQuarantine) -and $State.consecutiveRollback -lt $script:Cfg.MaxRollbackAttempts) {
            Write-GuardLog "确认起不来：$why → 判定与最近插件变更相关，启动自动回滚" -Level CRASH
            $tail = @(Get-LogTail -Path $script:LaunchLogFile -Lines 60)
            $ctx = @"
【故障原因】$why
【当前 profile 依赖】$(@($id.dependencies) -join ', ')
【上一个可用版本】$($State.lastGoodSnapshot)
【最近插件变更时间】$($State.lastPluginChange)
【最近日志尾部】
$($tail -join "`n")
"@
            $ok = Invoke-Rollback -State $State -Why $why -ContextForAi $ctx
            if ($ok) {
                Write-GuardLog '自动回滚完成 —— 请重新启动 DSH（看门狗默认不再替你拉起，见下）' -Level OK
            } else {
                Write-GuardLog '自动回滚后仍未恢复，将继续监控并重试' -Level ERROR
                Start-Sleep -Seconds 15
            }
            return
        }

        # ---- 4b. 不回滚时怎么办 ----
        # ⚠️ 默认**不擅自启动 DSH**（`Cfg.AutoStartDsh = $false`）：
        #    我们只能用 `dsh web --port <port>` 起一个**没有窗口**的实例；而桌面外壳之后启动时，
        #    启动器会走"快速路径"看到端口已被占用 → 只把"已有窗口"拉到前台，可那个实例根本没窗口
        #    → 用户看到的现象就是"点图标打不开"。所以这里只记录 + 提示，由用户自己启动。
        #    （想要旧行为——自动拉起——设 DSHGUARD_AUTO_RESTART=1；命令行用户无所谓，
        #      但桌面外壳用户会被上面那条坑到。）
        Write-GuardLog "故障（与插件变更无关或无需回滚）：$why" -Level WARN
        Write-Incident -Kind 'unhealthy' -Data @{ why = $why; quarantine = $inQuarantine; recentErrors = $recent }
        if ($State.consecutiveRollback -ge $script:Cfg.MaxRollbackAttempts) {
            Write-GuardLog "已连续回滚 $($State.consecutiveRollback) 次，暂停自动回滚以避免死循环，请人工介入" -Level ERROR
        }
        if ($script:Cfg.AutoStartDsh -and -not $health.PortUp) {
            Write-GuardLog '（已开启自动拉起）尝试用 dsh web 启动服务…' -Level WARN
            $start = Start-DshWeb -WaitForReady -ReadyTimeoutSec 120
            if ($start.Ok) {
                Write-GuardLog "重启成功：$($start.Message)" -Level OK
                Write-Incident -Kind 'restart' -Data @{ ok = $true; pid = $start.Pid }
                $State.logOffset = 0
                $State.errorTimes = @()
                Save-GuardState -State $State
            } else {
                Write-GuardLog "重启失败：$($start.Message)" -Level ERROR
                Write-Incident -Kind 'restart' -Data @{ ok = $false; msg = $start.Message }
                Start-Sleep -Seconds 20
            }
        } else {
            Write-GuardLog '看门狗默认不替你启动 DSH（免得起出"没有窗口"的实例，反而让人以为打不开）。请自行启动；确实要它自动拉起，设 DSHGUARD_AUTO_START_DSH=1' -Level INFO -NoConsole
        }
        return
    }

    # ---- 5. 观察期正常结束 → 晋升可用版本 ----
    if ($inQuarantine) {
        $remain = 0
        try { $remain = [int](([datetime]::Parse($State.quarantineUntil)) - (Get-Date)).TotalSeconds } catch { }
        if ($remain -le 0) {
            if ($health.PortUp) { Complete-Quarantine -State $State }
            else { Write-GuardLog "观察期结束时 $script:SubjectIdle，暂不晋升" -Level WARN }
        } else {
            Write-GuardLog "隔离观察中：还有约 $remain 秒（若无崩溃将晋升为可用版本）端口=$($health.PortUp) 心跳=$($health.HeartbeatAge)s 近期错误=$recent" -Level INFO -NoConsole
        }
    } else {
        # 稳态巡检日志
        # 端口活着 → 清掉可能残留的"另一端"标记（插件版是空操作，留着便于将来多端复用）
        if ($health.PortUp -and (Get-ActiveEnd).End -eq 'native') { Clear-ActiveEnd }
        # ⚠️ 2026-09-26：文案要跟着模式走 —— 进程模式下原来照样打印"端口 19387 正常"，
        #    看日志的人会以为还在按端口判活（实际判的是 DeepSeek Harness.exe 进程）。
        $nodeInfo = if ($health.PortUp) { "$script:SubjectLabel 在(PID $($health.PortOwnerPid))" } else { $script:SubjectIdle }
        Write-GuardLog "巡检：$nodeInfo ，模式 $($script:HealthMode) ，HttpOk=$($health.HttpOk) ，心跳 $($health.HeartbeatAge)s ，近期错误 $recent 条" -Level INFO -NoConsole
    }

    Save-GuardState -State $State
}

# ---- Invoke-MonitorCycle  (源 DshGuard-Supervisor.ps1 第 566-575 行) ----
function Invoke-MonitorCycle {
    param([Parameter(Mandatory = $true)]$State)
    Invoke-WebCycle -State $State
    try {
        Invoke-NativeCycle -State $State
    } catch {
        Write-GuardLog "附加巡检异常（不影响主监控）：$($_.Exception.Message)" -Level ERROR
        Write-GuardLog "堆栈：$($_.ScriptStackTrace)" -Level ERROR -NoConsole
    }
}

# ---- Start-SupervisorLoop  (源 DshGuard-Supervisor.ps1 第 580-643 行) ----
function Start-SupervisorLoop {
    if (Test-SupervisorRunning) {
        $other = Read-JsonFile -Path $script:LockFile
        Write-GuardLog "已有守护进程在运行（PID $($other.pid)），本进程退出，避免重复监控" -Level WARN
        exit 0
    }
    Enter-SupervisorLock
    try {
        Write-GuardLog "==================== DSH 守护（看门狗）启动 ====================" -Level OK
        $env2 = Get-GuardEnvironment
        foreach ($k in $env2.Keys) { Write-GuardLog "守护环境 $k = $($env2[$k])" -Level INFO -NoConsole }
        Write-GuardLog "监控目标：$script:WebUrl ；日志：$script:LaunchLogFile" -Level OK
        Write-GuardLog "参数：观察期 $($script:Cfg.QuarantineSec)s / 心跳阈值 $($script:Cfg.HeartbeatStaleSec)s / 轮询 $($script:Cfg.WatchIntervalSec)s / 自动重启=$($script:Cfg.AutoRestart) / AI诊断=$($script:Cfg.EnableAi)" -Level OK
        Write-Incident -Kind 'supervisor-start' -Data @{ pid = $PID; webUrl = $script:WebUrl; profile = $script:ProfileDir }

        # 看得见的反馈：守护是隐藏进程，双击快捷方式屏幕上什么都没有，容易被当成"没起作用"。
        # （Win11 可能把气泡收进"通知中心"；弹不出来不影响守护本身。）
        try {
            # 泛化：插件版只有"一个 DSH"（没有应用端/网页端之分），端口取自配置
            $wUp = Test-TcpPort -Port $script:WebPort
            $toast = '已启动（PID ' + $PID + '）' + [Environment]::NewLine +
                "监视端口 $script:WebPort：" + $(if ($wUp) { '在跑' } else { '未运行' }) +
                [Environment]::NewLine + '双击插件目录里的 Open-Guard-UI.cmd 可随时看状态'
            Show-GuardToast -Text $toast -Seconds 8
        } catch { }

        $fails = 0
        while ($true) {
            try {
                # ---- 单实例自检（每轮）：锁被新实例接管就主动退出 ----
                # 起因：锁文件被后来的实例覆盖后，老进程只会一直跑下去（今天真出现过：
                # 01:23 启动的守护在侧边同时监控了 10 小时，日志每轮写两遍）。
                if (-not (Test-Path $script:LockFile)) {
                    Write-GuardLog '锁文件已消失（被 stop 或新实例接管），本进程退出避免重复监控' -Level WARN
                    break
                }
                $lk = Read-JsonFile -Path $script:LockFile
                if ($lk -and $lk.pid -and [int]$lk.pid -ne $PID -and (Test-PidAlive -ProcessId ([int]$lk.pid))) {
                    Write-GuardLog "锁已属于 PID $($lk.pid)（本进程 $PID 已被取代），退出避免重复监控" -Level WARN
                    Write-Incident -Kind 'supervisor-superseded' -Data @{ self = $PID; owner = [int]$lk.pid }
                    break
                }
                $state = Get-GuardState
                Invoke-MonitorCycle -State $state
                $fails = 0
            } catch {
                $fails++
                Write-GuardLog "监控循环异常（第 $fails 次）：$($_.Exception.Message)" -Level ERROR
                Write-GuardLog "堆栈：$($_.ScriptStackTrace)" -Level ERROR -NoConsole
                if ($fails -ge 10) {
                    Write-GuardLog '连续 10 次监控循环异常，守护退出（请查看上面堆栈）' -Level CRASH
                    Write-Incident -Kind 'supervisor-crash' -Data @{ error = $_.Exception.Message; stack = $_.ScriptStackTrace }
                    break
                }
                Start-Sleep -Seconds 5
            }
            Start-Sleep -Seconds $script:Cfg.WatchIntervalSec
        }
    } finally {
        Exit-SupervisorLock
        Write-GuardLog '==================== DSH 守护（看门狗）退出 ====================' -Level WARN
        Write-Incident -Kind 'supervisor-stop' -Data @{ pid = $PID }
    }
}

