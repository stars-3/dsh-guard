# ============================================================================
#  guard-core.ps1 —— 从 DSH Desktop 的 DshGuard.Core.ps1 抽取的通用部分
#  （由 tools\extract-core.ps1 机械抽取生成，函数体未改动）
#  依赖的 $script: 变量见文件末尾的说明，不包含任何桌面外壳专用变量。
# ============================================================================

# ---- Initialize-DshGuardDirs  (源 DshGuard.Core.ps1 第 188-192 行) ----
function Initialize-DshGuardDirs {
    foreach ($d in @($script:LogDir, $script:SnapshotDir, $script:StateDir, $script:AiDir, $script:ShellSnapshotDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
}

# ---- Repair-Utf16Log  (源 DshGuard.Core.ps1 第 194-218 行) ----
function Repair-Utf16Log {
    <#
      .SYNOPSIS 修复历史上被 PowerShell 以 UTF-16 写坏的日志（"n o d e" 带 NUL）
      .NOTES    只在检测到 NUL 字节时重写，正常 UTF-8 日志原样不动
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fi = Get-Item $Path -ErrorAction Stop
        if ($fi.Length -lt 2 -or $fi.Length -gt 64MB) { return $false }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $nul = 0
        foreach ($b in $bytes) { if ($b -eq 0) { $nul++ } }
        if ($nul -lt 4) { return $false }

        $ms = New-Object System.IO.MemoryStream(, $bytes)
        $sr = New-Object System.IO.StreamReader($ms, [System.Text.Encoding]::Unicode, $true)
        $text = $sr.ReadToEnd()
        $sr.Close(); $ms.Close()
        if ($text -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
        Write-GuardLog "检测到 UTF-16 乱码日志，已自动修复为 UTF-8：$Path（原 $($fi.Length) 字节）" -Level WARN
        return $true
    } catch { return $false }
}

# ---- Write-GuardLog  (源 DshGuard.Core.ps1 第 223-270 行) ----
function Write-GuardLog {
    <#
      .SYNOPSIS 写一条带时间戳的日志到指定文件，同时回显到控制台
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'CRASH', 'ROLLBACK', 'AI')][string]$Level = 'INFO',
        [string]$LogFile = $script:GuardLogFile,
        [switch]$NoConsole,
        [switch]$Raw
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    if ($Raw) { $line = "[$ts] $Message" } else { $line = "[$ts] [$Level] $Message" }

    # 单文件超过 8MB 自动轮转
    try {
        if (Test-Path $LogFile) {
            $fi = Get-Item $LogFile -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -gt 8MB) {
                $rot = [IO.Path]::ChangeExtension($LogFile, $null).TrimEnd('.') + '.' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log'
                Move-Item -Force $LogFile $rot -ErrorAction SilentlyContinue
            }
        }
    } catch { }

    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # 用 StreamWriter 追加，UTF-8 无 BOM，避免 Add-Content 的编码差异
        $enc = New-Object System.Text.UTF8Encoding($false)
        $sw  = New-Object System.IO.StreamWriter($LogFile, $true, $enc)
        $sw.WriteLine($line)
        $sw.Flush(); $sw.Close(); $sw.Dispose()
    } catch { }

    if (-not $NoConsole) {
        $color = switch ($Level) {
            'ERROR'    { 'Red' }
            'CRASH'    { 'Magenta' }
            'ROLLBACK' { 'Yellow' }
            'WARN'     { 'DarkYellow' }
            'OK'       { 'Green' }
            'AI'       { 'Cyan' }
            default    { 'Gray' }
        }
        try { Write-Host $line -ForegroundColor $color } catch { Write-Host $line }
    }
}

# ---- Write-Incident  (源 DshGuard.Core.ps1 第 272-290 行) ----
function Write-Incident {
    <#  结构化事故记录（JSONL），供事后追溯与 AI 复盘  #>
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [hashtable]$Data = @{}
    )
    Initialize-DshGuardDirs
    $rec = [ordered]@{
        time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        kind = $Kind
    }
    foreach ($k in $Data.Keys) { $rec[$k] = $Data[$k] }
    $json = ($rec | ConvertTo-Json -Depth 6 -Compress)
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        $sw  = New-Object System.IO.StreamWriter($script:IncidentFile, $true, $enc)
        $sw.WriteLine($json); $sw.Flush(); $sw.Close(); $sw.Dispose()
    } catch { }
}

# ---- Write-JsonFile  (源 DshGuard.Core.ps1 第 292-300 行) ----
function Write-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Object)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    $json = $Object | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force $tmp $Path
}

# ---- Read-JsonFile  (源 DshGuard.Core.ps1 第 302-310 行) ----
function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
        return ($txt | ConvertFrom-Json)
    } catch { return $null }
}

# ---- Get-ProfileFileSignature  (源 DshGuard.Core.ps1 第 315-328 行) ----
function Get-ProfileFileSignature {
    <#  profile 关键文件的"最后写入时间+大小"指纹：用于秒级发现"刚装完插件"  #>
    $parts = @()
    # 注意：不要把 cordis.yml 算进来 —— DSH 每次启动都会重写这个（固定内容 "[]" 的
    # 加载器锚点文件），把它算进签名会让"每次启动"都被误判成"profile 被改写"。
    foreach ($f in @('package.json', 'cordis.patch.yml', 'pnpm-lock.yaml', 'pnpm-workspace.yaml')) {
        $p = Join-Path $script:ProfileDir $f
        if (Test-Path $p) {
            $fi = Get-Item $p -ErrorAction SilentlyContinue
            if ($fi) { $parts += "$f=$($fi.LastWriteTimeUtc.Ticks):$($fi.Length)" }
        }
    }
    return ($parts -join '|')
}

# ---- Test-TcpPort  (源 DshGuard.Core.ps1 第 330-347 行) ----
function Test-TcpPort {
    param([int]$Port = $script:WebPort, [string]$TargetHost = '127.0.0.1', [int]$TimeoutMs = 2000)
    # 快速否定：本机没人 LISTENING 时，TCP connect 不会"立刻被拒"，而是一路挂到超时
    # （实测：连一个已关闭的端口要 ~2s 才失败；有进程在跑的端口只要 ~10ms）。
    # 所以先花 ~0.15 秒问一次 netstat（带 2 秒缓存），没人听就直接 false ——
    # 这一步把每轮巡检从 7.2 秒拉回约 5.2 秒。非本机地址不走这条捷径。
    if ($TargetHost -in @('127.0.0.1', 'localhost', '::1')) {
        if ((Get-PortOwnerPid -Port $Port) -le 0) { return $false }
    }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false }
    finally { try { $client.Close() } catch { } }
}

# ---- Test-WebHttp  (源 DshGuard.Core.ps1 第 349-365 行) ----
function Test-WebHttp {
    <#  返回 @{ Ok=bool; Status=int; Msg=string }；401/403 也算"服务活着"  #>
    param([string]$Url = $script:WebUrl, [int]$TimeoutSec = 12)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return @{ Ok = $true; Status = [int]$r.StatusCode; Msg = 'HTTP ' + $r.StatusCode }
    } catch {
        $resp = $null
        try { $resp = $_.Exception.Response } catch { }
        if ($resp -and $resp.StatusCode) {
            $code = [int]$resp.StatusCode
            if ($code -in 401, 403, 404) { return @{ Ok = $true; Status = $code; Msg = "HTTP $code（服务在跑，需要鉴权）" } }
            return @{ Ok = $false; Status = $code; Msg = "HTTP $code" }
        }
        return @{ Ok = $false; Status = 0; Msg = $_.Exception.Message }
    }
}

# ---- Get-PortOwnerPid  (源 DshGuard.Core.ps1 第 392-412 行) ----
function Get-PortOwnerPid {
    <#  用 netstat 找监听指定端口的 PID（沙箱下 CIM 不可用，netstat 可靠）
        注意：每次 netstat 要起一个进程（~0.3-0.5s），而一轮巡检里同一个端口会被问好几次
        （实测把巡检间隔从 5s 拖到 7.2s）。这里做 2 秒缓存：一轮之内只真跑一次，
        顺带让同一轮的判断更一致。 #>
    param([int]$Port = $script:WebPort, [int]$CacheMs = 2000)
    $now = [datetime]::UtcNow
    if ($script:PortOwnerCache.ContainsKey($Port)) {
        $e = $script:PortOwnerCache[$Port]
        if ((($now - $e.At).TotalMilliseconds) -lt $CacheMs) { return [int]$e.Pid }
    }
    $out = & netstat -ano 2>$null | Select-String (':' + $Port + '\s') | Select-String 'LISTENING'
    $result = 0
    foreach ($line in $out) {
        $parts = ($line.ToString().Trim() -split '\s+')
        $ownerPid = $parts[-1]
        if ($ownerPid -match '^\d+$') { $result = [int]$ownerPid; break }
    }
    $script:PortOwnerCache[$Port] = @{ Pid = $result; At = $now }
    return $result
}

# ---- Test-PidAlive  (源 DshGuard.Core.ps1 第 414-418 行) ----
function Test-PidAlive {
    param([int]$ProcessId)
    if (-not $ProcessId -or $ProcessId -le 0) { return $false }
    try { return [bool](Get-Process -Id $ProcessId -ErrorAction Stop) } catch { return $false }
}

# ---- Test-ErrorLine  (源 DshGuard.Core.ps1 第 471-477 行) ----
function Test-ErrorLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    foreach ($w in $script:ErrorWhitelist) { if ($Line -like "*$w*") { return $false } }
    foreach ($p in $script:ErrorPatterns) { if ($Line -match $p) { return $true } }
    return $false
}

# ---- Get-LogTail  (源 DshGuard.Core.ps1 第 479-484 行) ----
function Get-LogTail {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Lines = 200)
    if (-not (Test-Path $Path)) { return @() }
    try { return @(Get-Content -Path $Path -Tail $Lines -Encoding UTF8 -ErrorAction Stop) }
    catch { return @() }
}

# ---- Get-NewLogErrors  (源 DshGuard.Core.ps1 第 486-522 行) ----
function Get-NewLogErrors {
    <#
      .SYNOPSIS 读取日志文件中"上次检查位置之后"新增的错误行
      .OUTPUTS   @{ Errors=@(行); LastOffset=int; NewBytes=int }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$FromOffset = 0,
        [int]$MaxLines = 4000
    )
    $result = @{ Errors = @(); LastOffset = $FromOffset; NewBytes = 0 }
    if (-not (Test-Path $Path)) { return $result }
    try {
        $fi = Get-Item $Path -ErrorAction Stop
        $len = $fi.Length
        if ($len -lt $FromOffset) { $FromOffset = 0 }   # 文件被轮转/截断
        $result.NewBytes = [int]($len - $FromOffset)
        if ($len -le $FromOffset) { $result.LastOffset = $len; return $result }

        # 用共享读方式读增量（node 正在写这个文件）
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $fs.Seek($FromOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $buf = New-Object byte[] ($len - $FromOffset)
            $read = $fs.Read($buf, 0, $buf.Length)
            $result.LastOffset = $FromOffset + $read
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Close(); $fs.Dispose() }

        $lines = $text -split "`r?`n"
        if ($lines.Count -gt $MaxLines) { $lines = $lines[($lines.Count - $MaxLines)..($lines.Count - 1)] }
        $errs = @()
        foreach ($l in $lines) { if (Test-ErrorLine -Line $l) { $errs += $l.Trim() } }
        $result.Errors = $errs
    } catch { }
    return $result
}

# ---- Get-ProfileIdentity  (源 DshGuard.Core.ps1 第 535-565 行) ----
function Get-ProfileIdentity {
    <#  计算 profile 的"身份指纹"：装了什么插件、配置如何  #>
    $pkg = Join-Path $script:ProfileDir 'package.json'
    $patch = Join-Path $script:ProfileDir 'cordis.patch.yml'
    $deps = @()
    $bundles = @()
    $pkgText = ''
    if (Test-Path $pkg) {
        $pkgText = [System.IO.File]::ReadAllText($pkg)
        try {
            $o = $pkgText | ConvertFrom-Json
            if ($o.dependencies) { $deps = @($o.dependencies.PSObject.Properties | ForEach-Object { "$($_.Name)@$($_.Value)" } | Sort-Object) }
            if ($o.dsh -and $o.dsh.profile -and $o.dsh.profile.bundles) { $bundles = @($o.dsh.profile.bundles) }
        } catch { }
    }
    $patchText = if (Test-Path $patch) { [System.IO.File]::ReadAllText($patch) } else { '' }

    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pkgText + "`n---`n" + $patchText)
    $hash = ([BitConverter]::ToString($md5.ComputeHash($bytes))).Replace('-', '').Substring(0, 12)

    return [ordered]@{
        hash          = $hash
        capturedAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        dependencies  = $deps
        bundles       = $bundles
        depCount      = $deps.Count
        packageJson   = $pkgText
        patchYml      = $patchText
    }
}

# ---- New-ProfileSnapshot  (源 DshGuard.Core.ps1 第 567-622 行) ----
function New-ProfileSnapshot {
    <#
      .SYNOPSIS 给当前 web profile 打一个完整快照
      .OUTPUTS  快照目录路径（失败返回 $null）
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [ValidateSet('baseline', 'on-plugin-change', 'manual', 'pre-rollback', 'quarantine')][string]$Reason = 'manual'
    )
    Initialize-DshGuardDirs
    if (-not (Test-Path $script:ProfileDir)) {
        Write-GuardLog "快照失败：profile 目录不存在 $script:ProfileDir" -Level ERROR
        return $null
    }
    # ---- 去重：状态没变就不重复占盘 ----
    #  看门狗每次启动都会打一个 baseline；不去重的话，重启几次就多出几百 MB。
    #  判据是「标签相同 + 指纹相同」：指纹变了（装了插件/改了配置）就照常新建，
    #  所以"出事前那个好版本"永远不会被跳过。
    #  ⚠️ 2026-09-14 用户的快照就是这么涨到 9 个 / 59MB 的。
    try {
        $nowId = Get-ProfileIdentity
        $latestList = @(Get-AllSnapshots)
        if ($latestList.Count -ge 1) {
            $lm = Get-SnapshotMeta -Dir $latestList[0].Dir
            if ($lm -and $lm.label -eq $Label -and $lm.identity -and $lm.identity.hash -eq $nowId.hash) {
                Write-GuardLog ("跳过快照 [{0}]：与最近一个快照指纹相同（{1}），不重复占用磁盘" -f $Label, $nowId.hash) -Level INFO
                return $latestList[0].Dir
            }
        }
    } catch { }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $safe = ($Label -replace '[\\/:*?"<>|\s]', '_')
    $dir = Join-Path $script:SnapshotDir "$stamp`_$safe"
    $n = 1
    while (Test-Path $dir) { $dir = Join-Path $script:SnapshotDir "$stamp`_$safe`_$n"; $n++ }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $copied = @()
    foreach ($f in $script:SnapshotFiles) {
        $src = Join-Path $script:ProfileDir $f.Src
        if (Test-Path $src) {
            Copy-Item -Force -LiteralPath $src -Destination (Join-Path $dir $f.Rel)
            $copied += $f.Rel
        }
    }
    # node_modules 完整镜像（本 profile 约 6~10MB，可接受；不跟随符号链接以保留 pnpm 结构）
    $nmSrc = Join-Path $script:ProfileDir 'node_modules'
    $nmOk = $false
    if (Test-Path $nmSrc) {
        $nmDst = Join-Path $dir 'node_modules'
        $null = & robocopy $nmSrc $nmDst /MIR /SL /NFL /NDL /NJH /NJS /NP /R:1 /W:1 2>$null
        $rc = $LASTEXITCODE
        if ($rc -lt 8) { $nmOk = $true }
        else { Write-GuardLog "node_modules 镜像 robocopy 返回码 $rc（非致命，仍可用 pnpm 恢复）" -Level WARN }
    }

    $id = Get-ProfileIdentity
    $meta = [ordered]@{
        label        = $Label
        reason       = $Reason
        createdAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        profileDir   = $script:ProfileDir
        files        = $copied
        nodeModules  = $nmOk
        identity     = $id
        sizeMB       = [math]::Round(((Get-ChildItem $dir -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 2)
        health       = 'unknown'
    }
    Write-JsonFile -Path (Join-Path $dir 'meta.json') -Object $meta
    Write-GuardLog "已创建快照 [$Label] hash=$($id.hash) 依赖=$($id.depCount) 项 大小=$($meta.sizeMB)MB -> $dir" -Level OK

    # ---- 保留策略：打完就清理 ----
    #  Remove-OldSnapshots 一直存在，但**从来没有任何地方调用它** —— 所以快照只增不减。
    #  （标记为 lastGood 的那个永不被删，见函数内部。）
    try { Remove-OldSnapshots -Keep $script:Cfg.KeepSnapshots } catch { }

    return $dir
}

# ---- Get-SnapshotMeta  (源 DshGuard.Core.ps1 第 624-627 行) ----
function Get-SnapshotMeta {
    param([Parameter(Mandatory = $true)][string]$Dir)
    return Read-JsonFile -Path (Join-Path $Dir 'meta.json')
}

# ---- Get-AllSnapshots  (源 DshGuard.Core.ps1 第 629-638 行) ----
function Get-AllSnapshots {
    <#  按时间倒序返回所有快照（含 meta）  #>
    Initialize-DshGuardDirs
    $out = @()
    foreach ($d in (Get-ChildItem $script:SnapshotDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $meta = Get-SnapshotMeta -Dir $d.FullName
        if ($meta) { $out += [pscustomobject]@{ Dir = $d.FullName; Name = $d.Name; Meta = $meta } }
    }
    return $out
}

# ---- Get-GuardState  (源 DshGuard.Core.ps1 第 640-692 行) ----
function Get-GuardState {
    $st = Read-JsonFile -Path $script:GuardStateFile
    if (-not $st) {
        $st = [pscustomobject][ordered]@{
            lastGoodSnapshot    = $null
            goodHistory         = @()
            badSnapshots        = @()
            lastPluginChange    = $null
            pluginChangeCount   = 0
            quarantineUntil     = $null
            pendingSnapshot     = $null
            pendingHash         = $null
            lastSeenHash        = $null
            profileSignature    = $null
            lastLauncherPid     = 0
            launcherChanged     = $false
            logOffset           = 0
            errorTimes          = @()
            consecutiveRollback = 0
            lastRollbackAt      = $null
            # 运行期字段（新版加的；老状态文件里没有 → 见下面 $defaults 的补齐逻辑）
            lastUpAt            = $null
            downSince           = $null
            # 运行期状态（不属于 profile）：与上面这些 profile 字段互不干扰
            native              = [pscustomobject][ordered]@{
                lastGoodSnapshot    = $null
                lastSeenPayloadHash = $null
                pendingSnapshot     = $null
                pendingHash         = $null
                quarantineUntil     = $null
                failStreak          = 0
                attempts            = 0
                lastAttemptAt       = $null
                consecutiveRollback = 0
                lastChangeAt        = $null
                lastRollbackAt      = $null
                lastHealthyAt       = $null
            }
            updatedAt           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        }
    } else {
        # 补齐可能缺失的字段（老状态文件 / 手改过）
        # ⚠️ 这一步是**必须的**，不是保险：$st 是从 JSON 反序列化出来的 PSCustomObject，
        #    给它赋一个**不存在的属性会直接抛异常**（哈希表不会，PSCustomObject 会）：
        #      "设置"lastUpAt"时发生异常:"在此对象上找不到属性"lastUpAt""
        #    2026-09-14 真机踩到：新版给状态加了 lastUpAt / downSince，而磁盘上还是旧版写的
        #    状态文件 → 升级后**第一轮巡检就崩**（安装器的落地自检当场报红）。
        #    👉 以后给状态加字段，**必须同时**加进下面 $defaults 和上面的默认对象。
        $defaults = [ordered]@{
            lastGoodSnapshot = $null; goodHistory = @(); badSnapshots = @(); lastPluginChange = $null
            pluginChangeCount = 0; quarantineUntil = $null; pendingSnapshot = $null; pendingHash = $null
            lastSeenHash = $null; profileSignature = $null; lastLauncherPid = 0; launcherChanged = $false; logOffset = 0
            errorTimes = @(); consecutiveRollback = 0; lastRollbackAt = $null; native = $null
            lastUpAt = $null; downSince = $null
        }
        foreach ($k in $defaults.Keys) {
            if (-not ($st.PSObject.Properties.Name -contains $k)) {
                $st | Add-Member -Force -NotePropertyName $k -NotePropertyValue $defaults[$k]
            }
        }
    }
    return $st
}

# ---- Save-GuardState  (源 DshGuard.Core.ps1 第 694-698 行) ----
function Save-GuardState {
    param([Parameter(Mandatory = $true)]$State)
    $State | Add-Member -Force -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))
    Write-JsonFile -Path $script:GuardStateFile -Object $State
}

# ---- Set-SnapshotHealth  (源 DshGuard.Core.ps1 第 700-715 行) ----
function Set-SnapshotHealth {
    param([Parameter(Mandatory = $true)][string]$Dir, [Parameter(Mandatory = $true)][string]$Health, [string]$Note = '')
    $metaPath = Join-Path $Dir 'meta.json'
    $meta = Read-JsonFile -Path $metaPath
    if (-not $meta) { return }
    # 注意：对"已存在的属性"不能用 Add-Member -Force（会把值变成 Hashtable 包装），要直接赋值
    foreach ($kv in @(@('health', $Health),
                      @('healthAt', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')),
                      @('healthNote', $Note))) {
        $n = $kv[0]; $v = $kv[1]
        if ($null -eq $v) { continue }
        if ($meta.PSObject.Properties.Name -contains $n) { $meta.$n = $v }
        else { $meta | Add-Member -NotePropertyName $n -NotePropertyValue $v }
    }
    Write-JsonFile -Path $metaPath -Object $meta
}

# ---- Remove-OldSnapshots  (源 DshGuard.Core.ps1 第 717-734 行) ----
function Remove-OldSnapshots {
    <#  只保留最近 N 个快照；被标记为 lastGood 的永不删除  #>
    param([int]$Keep = $script:Cfg.KeepSnapshots)
    $all = Get-AllSnapshots
    if ($all.Count -le $Keep) { return }
    $state = Get-GuardState
    $keepGood = $state.lastGoodSnapshot
    $i = 0
    foreach ($s in $all) {
        $i++
        if ($i -le $Keep) { continue }
        if ($keepGood -and ($s.Dir -eq $keepGood)) { continue }
        try {
            Remove-Item -Recurse -Force -LiteralPath $s.Dir -ErrorAction Stop
            Write-GuardLog "清理旧快照 $($s.Name)" -Level INFO
        } catch { }
    }
}

# ---- Restore-ProfileSnapshot  (源 DshGuard.Core.ps1 第 739-874 行) ----
function Restore-ProfileSnapshot {
    <#
      .SYNOPSIS 将 web profile 回滚到指定快照
      .OUTPUTS  @{ Ok=bool; Steps=@(); Message=string }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotDir,
        [switch]$Force
    )
    $steps = @()
    if (-not (Test-Path $SnapshotDir)) {
        return @{ Ok = $false; Steps = $steps; Message = "快照目录不存在：$SnapshotDir" }
    }
    $meta = Get-SnapshotMeta -Dir $SnapshotDir
    if (-not $meta) { return @{ Ok = $false; Steps = $steps; Message = '快照缺少 meta.json，拒绝回滚' } }

    Write-GuardLog "开始回滚 -> $SnapshotDir（hash=$($meta.identity.hash)）" -Level ROLLBACK

    # 0) 回滚前先给"当前的坏状态"留档，便于事后复盘
    try {
        $preDir = New-ProfileSnapshot -Label 'pre-rollback-broken' -Reason 'pre-rollback'
        if ($preDir) { $steps += "已留档当前（坏）状态：$preDir" }
    } catch { }

    # 1) 备份当前 cordis.yml（DSH 每次启动会重组，但留着更安全）
    $curCordis = Join-Path $script:ProfileDir 'cordis.yml'
    if (Test-Path $curCordis) {
        Copy-Item -Force $curCordis (Join-Path $SnapshotDir 'cordis.yml.before-rollback') -ErrorAction SilentlyContinue
    }

    # 2) 还原配置文件
    $restored = 0
    foreach ($f in $script:SnapshotFiles) {
        $src = Join-Path $SnapshotDir $f.Rel
        $dst = Join-Path $script:ProfileDir $f.Src
        if (Test-Path $src) {
            try {
                Copy-Item -Force -LiteralPath $src -Destination $dst -ErrorAction Stop
                $restored++
                $steps += "还原 $($f.Src)"
            } catch {
                $steps += "还原 $($f.Src) 失败：$($_.Exception.Message)"
                Write-GuardLog "还原 $($f.Src) 失败：$($_.Exception.Message)" -Level ERROR
            }
        } elseif ($f.Src -eq 'cordis.patch.yml') {
            # 快照里没有该文件 => 当时是空的/不存在，写回默认空数组
            try { [System.IO.File]::WriteAllText($dst, "[]`n", (New-Object System.Text.UTF8Encoding($false))); $restored++; $steps += "还原 $($f.Src)（写回空配置）" } catch { }
        }
    }

    # 3) 比对依赖差异：找出"快照里没有、现在多出来"的插件包
    $nowId  = Get-ProfileIdentity
    $goodId = $meta.identity
    $goodDeps = @($goodId.dependencies)
    $nowDeps  = @($nowId.dependencies)

    # 当前目录下真实存在的顶层包
    $nm = Join-Path $script:ProfileDir 'node_modules'
    $present = @()
    if (Test-Path $nm) {
        foreach ($item in (Get-ChildItem $nm -Force -ErrorAction SilentlyContinue)) {
            if ($item.Name -in @('.bin', '.pnpm', '.modules.yaml', '.package-map.json', '.pnpm-workspace-state-v1.json')) { continue }
            if ($item.Name.StartsWith('@')) {
                foreach ($sub in (Get-ChildItem $item.FullName -Force -ErrorAction SilentlyContinue)) {
                    $present += "$($item.Name)/$($sub.Name)"
                }
            } else { $present += $item.Name }
        }
    }
    # 快照当时的顶层包（从镜像里读）
    $presentBefore = @()
    $nmSnap = Join-Path $SnapshotDir 'node_modules'
    if (Test-Path $nmSnap) {
        foreach ($item in (Get-ChildItem $nmSnap -Force -ErrorAction SilentlyContinue)) {
            if ($item.Name -in @('.bin', '.pnpm', '.modules.yaml', '.package-map.json', '.pnpm-workspace-state-v1.json')) { continue }
            if ($item.Name.StartsWith('@')) {
                foreach ($sub in (Get-ChildItem $item.FullName -Force -ErrorAction SilentlyContinue)) {
                    $presentBefore += "$($item.Name)/$($sub.Name)"
                }
            } else { $presentBefore += $item.Name }
        }
    }

    $newPkgs = @($present | Where-Object { $_ -notin $presentBefore })
    $removedPackages = @()
    foreach ($p in $newPkgs) {
        $full = Join-Path $nm ($p -replace '/', '\')
        try {
            Remove-Item -Recurse -Force -LiteralPath $full -ErrorAction Stop
            $removedPackages += $p
            $steps += "移除新装插件目录 node_modules\$p"
            Write-GuardLog "已移除新增插件：$p" -Level ROLLBACK
        } catch {
            $steps += "移除 node_modules\$p 失败：$($_.Exception.Message)"
            Write-GuardLog "移除 $p 失败：$($_.Exception.Message)" -Level WARN
        }
    }

    # 4) 还原 node_modules 镜像（若快照带镜像）：只补齐缺失的包，不动 .pnpm 存储
    if (Test-Path $nmSnap) {
        try {
            $null = & robocopy $nmSnap $nm /E /SL /XC /XN /XO /NFL /NDL /NJH /NJS /NP /R:1 /W:1 2>$null
            $rc = $LASTEXITCODE
            if ($rc -lt 8) { $steps += '已按快照补齐 node_modules 缺失文件'; Write-GuardLog '已按快照补齐 node_modules（robocopy /E /XC /XN /XO）' -Level OK }
            else { $steps += "补齐 node_modules 返回码 $rc"; Write-GuardLog "补齐 node_modules 返回码 $rc" -Level WARN }
        } catch { }
    }

    # 5) 尽力让 pnpm 把依赖树对齐到快照的 lock（离线优先，失败不致命）
    # ⚠️ 2026-09-26：命令改走 $script:PnpmCmd —— 官方桌面端的插件进程 PATH 里没有 pnpm，
    #    要用官方端自带运行时（`node.exe <pnpm.cjs>`）；web 那份不配置时仍是裸 `pnpm`，行为不变。
    $pnpmOk = $null
    $pnpmExe = if ($script:PnpmCmd) { $script:PnpmCmd } else { 'pnpm' }
    try {
        $env:npm_config_yes = 'true'
        $pnpmArgs = @('install', '--offline', '--prefer-offline', '--ignore-scripts=false')
        $out = & cmd /c "cd /d `"$($script:ProfileDir)`" && $pnpmExe install --prefer-offline --reporter=append-only 2>&1"
        $pnpmOk = ($LASTEXITCODE -eq 0)
        $steps += "pnpm install 退出码 $LASTEXITCODE"
        foreach ($l in @($out)) {
            if (Test-ErrorLine -Line "$l") { Write-GuardLog "pnpm: $l" -Level WARN }
        }
    } catch {
        $steps += "pnpm install 异常：$($_.Exception.Message)"
    }

    # 6) 校验还原结果
    $after = Get-ProfileIdentity
    $ok = ($after.hash -eq $goodId.hash)
    if ($ok) {
        $steps += "校验通过：profile 指纹已回到 $($goodId.hash)"
        Write-GuardLog "回滚完成，profile 指纹 $($after.hash) 与快照一致" -Level OK
    } else {
        $steps += "校验警告：指纹 $($after.hash) != 快照 $($goodId.hash)（可能仅剩 node_modules 差异）"
        Write-GuardLog "回滚后指纹不一致：$($after.hash) != $($goodId.hash)" -Level WARN
    }

    return @{ Ok = $ok; Steps = $steps; Message = ($steps -join ' | '); RemovedPackages = $removedPackages; Snapshot = $SnapshotDir }
}

# ---- Start-DshWeb  (源 DshGuard.Core.ps1 第 879-907 行) ----
# 注意：插件版由 watchdog.ps1 **覆盖**成"直接调 dsh web"（原版调的是作者本机的桌面启动器）。
# 这里保留上游实现只为对照，真要改动请看 watchdog.ps1 里那份。
function Start-DshWeb {
    <#  以隐藏窗口方式启动 Web 启动器，返回 @{ Ok; Pid; Message }  #>
    param([switch]$WaitForReady, [int]$ReadyTimeoutSec = 120)
    $launcher = Join-Path $script:GuardRoot 'DshWeb-Launcher.ps1'
    if (-not (Test-Path $launcher)) { return @{ Ok = $false; Pid = 0; Message = "找不到启动器 $launcher" } }

    if (Test-TcpPort) {
        return @{ Ok = $true; Pid = (Get-PortOwnerPid); Message = "端口 $script:WebPort 已在监听，无需重启" }
    }
    try {
        $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$launcher`"", '-NoBrowser', '-NoPause', '-Quiet') `
            -WindowStyle Hidden -PassThru
        Write-GuardLog "已启动 Web 启动器（PID $($p.Id)）" -Level OK
    } catch {
        return @{ Ok = $false; Pid = 0; Message = "启动失败：$($_.Exception.Message)" }
    }

    if ($WaitForReady) {
        $deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-TcpPort) { return @{ Ok = $true; Pid = (Get-PortOwnerPid); Message = "Web 已就绪（$script:WebUrl）" } }
            if (-not (Test-PidAlive -ProcessId $p.Id)) { return @{ Ok = $false; Pid = $p.Id; Message = '启动器进程提前退出' } }
        }
        return @{ Ok = $false; Pid = $p.Id; Message = "等待就绪超时（$ReadyTimeoutSec 秒）" }
    }
    return @{ Ok = $true; Pid = $p.Id; Message = '已启动（未等待就绪）' }
}

# ---- Stop-DshWeb  (源 DshGuard.Core.ps1 第 909-927 行) ----
function Stop-DshWeb {
    <#  停止监听 Web 端口的进程  #>
    param([switch]$Force)
    $pid_ = Get-PortOwnerPid
    if (-not $pid_) { return @{ Ok = $true; Message = 'Web 未在运行' } }
    try {
        $proc = Get-Process -Id $pid_ -ErrorAction Stop
        Write-GuardLog "停止 Web 进程 PID $pid_（$($proc.ProcessName)）" -Level WARN
        if ($Force) { Stop-Process -Id $pid_ -Force -ErrorAction Stop }
        else {
            Stop-Process -Id $pid_ -ErrorAction Stop
            Start-Sleep -Seconds 2
            if (Test-PidAlive -ProcessId $pid_) { Stop-Process -Id $pid_ -Force -ErrorAction Stop }
        }
        return @{ Ok = $true; Message = "已停止 PID $pid_" }
    } catch {
        return @{ Ok = $false; Message = "停止失败：$($_.Exception.Message)" }
    }
}

