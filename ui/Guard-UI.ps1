<#
  Guard-UI.ps1 —— DSH Guard 的【独立】图形界面。

  为什么要独立一份：
    插件面板长在 DSH 里面 —— DSH 打不开的时候，它必然也用不了。
    可"DSH 打不开"恰恰是最需要回滚的时刻。
    所以这个窗口**只依赖 PowerShell + profile 目录本身**，DSH 死没死都能开、都能回滚。

  它不自己造轮子：所有动作都调用 lib\guard.ps1（和插件面板、CLI 用的是同一套逻辑），
  区别只是把结果显示在一个 Windows 窗体里，而不是设置页里。

  外观：照 DSH Web 的观感做的（页面浅灰底 + 白色圆角卡片 + 1px 细边框 + 品牌蓝 + 灰色次要文字）。
        控件基本自绘 —— WinForms 默认那套 3D 边框和系统灰跟 DSH 放一起太出戏。

  用法：
    Guard-UI.ps1                        打开窗口（profile 默认 web）
    Guard-UI.ps1 -Profile other         指定别的 profile
    Guard-UI.ps1 -GuardHomeDir <路径>   指定守护数据目录（影子环境/测试）
    Guard-UI.ps1 -WebPort 3101          指定端口（不指定就自动探测）
    Guard-UI.ps1 -TopMost               窗口置顶（看门狗自动弹它时用）
    Guard-UI.ps1 -SelfTest              只跑数据层 + 建控件 + 离屏画一遍，不显示窗口
    Guard-UI.ps1 -ProofSheet <png>      把主题渲染成 PNG（改配色后先自己看一眼，别拿用户的眼睛当测试机）

  关于端口：**不写死任何具体端口**。判定顺序是
    显式 -WebPort > 环境变量 DSH_WEB_URL > "最近启动的那个 node 实例占用的端口" > DSH 默认 3080。
    第三条是关键：独立窗口从资源管理器双击时环境里没有 DSH_WEB_URL，而 DSH 的端口可以随便配，
    写死 3080/3101 等于把作者本机的习惯塞给别人。
#>
[CmdletBinding()]
param(
    [string]$Profile      = 'web',
    [string]$GuardHomeDir = '',
    [int]   $WebPort      = 0,
    [string]$GuardPs1     = '',
    [switch]$TopMost,
    [switch]$SelfTest,
    [string]$ProofSheet   = '',
    [switch]$CreateShortcut,        # 在桌面建一个带图标的快捷方式（.cmd 自己没法带图标）
    [string]$ShortcutDir  = '',     # 快捷方式放哪（默认桌面；测试时可指到别处）
    [string]$Screenshot   = ''      # 把**真实窗口**渲染成 PNG（不显示窗口，用来自己验观感/抓句柄期崩溃）
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================ 主题（照 DSH Web）
$UiPageBg   = [System.Drawing.Color]::FromArgb(244, 246, 249)
$UiCardBg   = [System.Drawing.Color]::FromArgb(255, 255, 255)
$UiBorder   = [System.Drawing.Color]::FromArgb(227, 231, 237)
$UiText     = [System.Drawing.Color]::FromArgb(31, 35, 41)
$UiTextDim  = [System.Drawing.Color]::FromArgb(107, 114, 128)
$UiAccent   = [System.Drawing.Color]::FromArgb(77, 107, 254)
$UiAccentHi = [System.Drawing.Color]::FromArgb(63, 91, 232)
$UiOk       = [System.Drawing.Color]::FromArgb(46, 158, 79)
$UiBad      = [System.Drawing.Color]::FromArgb(217, 48, 37)
$UiWarn     = [System.Drawing.Color]::FromArgb(183, 121, 31)
$UiHover    = [System.Drawing.Color]::FromArgb(240, 243, 248)
$UiHeadBg   = [System.Drawing.Color]::FromArgb(247, 248, 250)
$UiSelBg    = [System.Drawing.Color]::FromArgb(234, 240, 255)

$UiFont      = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$UiFontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$UiFontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$UiFontBold  = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$UiFontMono  = New-Object System.Drawing.Font('Consolas', 9)

# ============================================================ 绘图工具
function New-RoundedPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0 -or $W -le 2 -or $H -le 2) { $p.AddRectangle((New-Object System.Drawing.RectangleF($X, $Y, $W, $H))); return $p }
    $d = $R * 2
    if ($d -gt $W) { $d = $W }
    if ($d -gt $H) { $d = $H }
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# 画一张卡片：圆角白底 + 1px 细边框。
# ⚠️ 卡片的 BackColor 必须设成**页面底色**（不是白色），内部控件还要留 ≥ 圆角的边距：
#    这样四个角露出的是页面底色，圆角才成立，而且边缘是抗锯齿的 ——
#    用 Region 裁切的做法在圆角处会有明显锯齿，跟 DSH 的观感差很远。
function Draw-Card {
    # ⚠️ 必须支持 X/Y 偏移：同一个 Graphics 上要画多张卡时，若永远画在原点，
    #    后画的那张会把先画的**和它上面的文字**整块盖掉。
    #    2026-09-14 踩到：证明页里第二张卡画在 (0,0)，把标题/状态行/按钮标签全盖没了 ——
    #    渲染出来是一张"大白卡片 + 几根彩色细条"，一眼看去像字体坏了，其实是遮挡。
    param($G, [single]$W, [single]$H, [single]$R = 10, [single]$X = 0, [single]$Y = 0)
    if ($W -le 2 -or $H -le 2) { return }
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path = New-RoundedPath -X ($X + 0.5) -Y ($Y + 0.5) -W ($W - 1) -H ($H - 1) -R $R
    $b = New-Object System.Drawing.SolidBrush($UiCardBg)
    $G.FillPath($b, $path)
    $pen = New-Object System.Drawing.Pen($UiBorder, 1)
    $G.DrawPath($pen, $path)
    $b.Dispose(); $pen.Dispose(); $path.Dispose()
}

function Set-RoundedRegion {
    param($Ctrl, [single]$R = 6)
    if ($Ctrl.Width -le 2 -or $Ctrl.Height -le 2) { return }
    $path = New-RoundedPath -X 0 -Y 0 -W $Ctrl.Width -H $Ctrl.Height -R $R
    $Ctrl.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
}

# 画列表里的一个单元格。抽成函数是有意的：
# 自检（-SelfTest）会**直接调用它**在离屏位图上画一遍 —— 这样"自绘代码到底能不能跑"
# 能在没有肉眼看窗口的情况下被验证（列宽、字体、颜色拼错会当场抛异常）。
function Draw-RowCell {
    param($G, $Bounds, [string]$Text, $Font, $Fg, $Bg)
    $G.FillRectangle((New-Object System.Drawing.SolidBrush($Bg)), $Bounds)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.LineAlignment = 'Center'
    # 长文本必须**省略号截断**，不能换行：单元格只有一行高（26px），换行会画出 2~3 行、
    # 视觉上糊成一团（2026-09-14 真机截图里"目录"那一列就是这样）。
    $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $fmt.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $r = New-Object System.Drawing.RectangleF(($Bounds.X + 8), $Bounds.Y, ($Bounds.Width - 10), $Bounds.Height)
    $G.DrawString($Text, $Font, (New-Object System.Drawing.SolidBrush($Fg)), $r, $fmt)
}

# ============================================================ 端口探测（不写死具体端口）
function Get-PortInfo {
    $map = @{}
    try {
        $lines = & netstat -ano 2>$null | Select-String 'LISTENING'
        foreach ($l in $lines) {
            $m = [regex]::Match($l.Line, ':(\d+)\s+\S+\s+LISTENING\s+(\d+)')
            if ($m.Success) { $map[[int]$m.Groups[1].Value] = [int]$m.Groups[2].Value }
        }
    } catch { }

    # "DSH 实例"的判据：占用该端口的是 node 进程（DSH 跑在 node 上），端口 ≥ 1024。
    # 不写死端口号 —— 用户可能把 DSH 配在任何端口上。
    $dsh = @()
    foreach ($p in $map.Keys) {
        if ($p -lt 1024) { continue }
        $proc = Get-Process -Id $map[$p] -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'node') {
            $dsh += [pscustomobject]@{ Port = $p; Pid = $map[$p]; Started = $proc.StartTime }
        }
    }
    return @{ Listening = $map; DshPorts = @($dsh | Sort-Object Started -Descending) }
}

function Resolve-Port {
    param($Info)
    if ($WebPort -gt 0) { return @{ Port = $WebPort; From = '命令行指定' } }
    if ($env:DSH_WEB_URL -match ':(\d+)') { return @{ Port = [int]$Matches[1]; From = '环境变量 DSH_WEB_URL' } }
    if ($Info.DshPorts.Count -ge 1) {
        $p = $Info.DshPorts[0]
        return @{ Port = $p.Port; From = ('最近启动的 DSH 实例（PID ' + $p.Pid + '，' + $p.Started.ToString('HH:mm:ss') + '）') }
    }
    return @{ Port = 3080; From = 'DSH 默认端口（没探测到实例）' }
}

# ============================================================ 数据层（复用 guard.ps1）
$here = Split-Path -Parent $PSCommandPath
$guardCandidates = @()
if ($GuardPs1) { $guardCandidates += $GuardPs1 }
$guardCandidates += (Join-Path $here 'guard.ps1')
$guardCandidates += (Join-Path (Split-Path $here -Parent) 'lib\guard.ps1')
$guardPs1 = $guardCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

if (-not $guardPs1) {
    [void][System.Windows.Forms.MessageBox]::Show(
        "找不到 guard.ps1。`n`n找过这些位置：`n  " + ($guardCandidates -join "`n  ") +
        "`n`n请把本脚本和 lib\ 放在同一个插件目录下（或在 <守护数据目录>\bin 下运行）。",
        'DSH Guard', 'OK', 'Error')
    exit 2
}
$libDir = Split-Path -Parent $guardPs1

$script:PortInfo = Get-PortInfo
$script:PortChoice = Resolve-Port $script:PortInfo
$script:effPort = [int]$script:PortChoice.Port

function Invoke-Guard {
    param([string]$Action, [hashtable]$Extra = @{})
    $out = Join-Path $env:TEMP ('dsh-guard-ui-' + [guid]::NewGuid().ToString('N') + '.json')
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guardPs1,
           '-Action', $Action, '-Out', $out, '-Profile', $Profile)
    if ($GuardHomeDir) { $a += @('-GuardHomeDir', $GuardHomeDir) }
    if ($script:effPort -gt 0) { $a += @('-WebPort', "$($script:effPort)") }
    foreach ($k in $Extra.Keys) { $a += @("-$k", [string]$Extra[$k]) }

    & powershell.exe @a 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    $obj = $null
    if (Test-Path -LiteralPath $out) {
        try { $obj = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
    if (-not $obj) { $obj = [pscustomobject]@{ ok = $false; error = "guard.ps1 没产出结果（退出码 $rc）" } }
    return $obj
}

function Convert-SnapshotList($raw) {
    if (-not $raw) { return @() }
    if ($raw -is [array]) { return @($raw) }
    return @($raw)
}

# 读图标。**不能**直接 `New-Object System.Drawing.Icon`：
#   本项目那个 .ico 的 7 帧全是 PNG 压缩帧，而 .NET 的 Icon 转位图时会解成彩色噪点
#   （实测：把 128x128 的 PNG 帧 DrawIcon 出来是满屏随机像素）。
#   所以这里自己把 PNG 帧抠出来 → Bitmap → GetHicon()，标题栏/任务栏一定是对的。
function Get-GuardIcon {
    param([string]$IcoPath)
    if (-not $IcoPath -or -not (Test-Path -LiteralPath $IcoPath)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($IcoPath)
        if ($bytes.Length -gt 22 -and [BitConverter]::ToUInt16($bytes, 2) -eq 1) {
            $count = [BitConverter]::ToUInt16($bytes, 4)
            $best = $null
            for ($i = 0; $i -lt $count; $i++) {
                $o = 6 + $i * 16
                $w = [int]$bytes[$o]; if ($w -eq 0) { $w = 256 }
                $len = [BitConverter]::ToUInt32($bytes, $o + 8)
                $off = [BitConverter]::ToUInt32($bytes, $o + 12)
                if ($off + 8 -ge $bytes.Length) { continue }
                $isPng = ($bytes[$off] -eq 0x89 -and $bytes[$off + 1] -eq 0x50 -and $bytes[$off + 2] -eq 0x4E -and $bytes[$off + 3] -eq 0x47)
                # 挑 64~128 的帧：够清晰，又不至于在标题栏里缩得难看
                if ($isPng -and $w -ge 64 -and $w -le 128 -and ($null -eq $best -or $w -gt $best.W)) {
                    $best = @{ W = $w; Off = $off; Len = $len }
                }
            }
            if ($best) {
                $ms = New-Object System.IO.MemoryStream($bytes, [int]$best.Off, [int]$best.Len)
                $img = [System.Drawing.Image]::FromStream($ms)
                $bmp = New-Object System.Drawing.Bitmap($img, 64, 64)
                $h = $bmp.GetHicon()
                $icon = [System.Drawing.Icon]::FromHandle($h)
                $img.Dispose(); $ms.Dispose(); $bmp.Dispose()
                if ($icon) { return $icon }
            }
        }
    } catch { }
    try { return (New-Object System.Drawing.Icon($IcoPath)) } catch { return $null }
}

# 建一个带图标的快捷方式。.cmd / .vbs 都不能自带图标，只有 .lnk 能。
# 目标指向 wscript.exe + ui\Open-Guard-UI.vbs：启动时**不会闪控制台窗口**。
function New-GuardShortcut {
    param([string]$Dir)
    if (-not $Dir) { $Dir = [Environment]::GetFolderPath('Desktop') }
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }

    $vbs = Join-Path $here 'Open-Guard-UI.vbs'
    $ico = Join-Path $here 'guard.ico'
    $lnkPath = Join-Path $Dir 'DSH Guard 守护.lnk'

    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($lnkPath)
    if (Test-Path -LiteralPath $vbs) {
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $lnk.Arguments = '"' + $vbs + '"'
    } else {
        $ps1 = Join-Path $here 'Guard-UI.ps1'
        $lnk.TargetPath = 'powershell.exe'
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1 + '"'
    }
    $lnk.WorkingDirectory = $here
    $lnk.Description = 'DSH Guard 守护 —— 不依赖 DSH 的快照/回滚窗口'
    if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = $ico + ',0' }
    $lnk.Save()
    return $lnkPath
}

# ============================================================ 证明页：把主题渲染成 PNG
function New-ProofSheet {
    # ⚠️ 参数绝不能叫 $Path：PowerShell 变量名**不区分大小写**，那么函数体里的局部变量
    #    $path（用来装 GraphicsPath）就和这个参数是**同一个变量**，会被 [string] 约束
    #    静默强转成字符串 —— 报错是 FillPath 收到 String，跟真凶隔了三层。
    #    同族坑这个项目踩过三次：build-shell.ps1 的 $Host、guard.ps1 的 $Home、这里的 $Path。
    #    规矩：**参数名别选可能被当局部变量用的通用词**（Path/Home/Host/Title/Text…）。
    param([string]$OutPath)
    $w = 780; $h = 500
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear($UiPageBg)

    $cardW = $w - 32
    Draw-Card -G $g -W $cardW -H 184 -R 10
    $x0 = 34
    $g.DrawString('DSH Guard 守护', $UiFontTitle, (New-Object System.Drawing.SolidBrush($UiText)), $x0, 14)
    $g.DrawString('不依赖 DSH —— DSH 打不开时也能回滚', $UiFontSmall, (New-Object System.Drawing.SolidBrush($UiTextDim)), ($x0 + 2), 44)
    $g.DrawString('看门狗未运行', $UiFontBold, (New-Object System.Drawing.SolidBrush($UiWarn)), 620, 20)
    $rows = @(
        @('profile', 'web    C:\Users\you\.dsh\profiles\web'),
        @('插件指纹', '9F2C1A44B7E0    依赖 3 项'),
        @('DSH 端口', '3999   ● 在监听    http://127.0.0.1:3999'),
        @('数据目录', 'C:\Users\you\.dsh-guard'),
        @('快照个数', '4')
    )
    $y = 72
    foreach ($r in $rows) {
        $g.DrawString($r[0], $UiFont, (New-Object System.Drawing.SolidBrush($UiTextDim)), $x0, $y)
        $g.DrawString($r[1], $UiFont, (New-Object System.Drawing.SolidBrush($UiText)), ($x0 + 96), $y)
        if ($r[0] -eq 'DSH 端口') { $g.FillEllipse((New-Object System.Drawing.SolidBrush($UiOk)), ($x0 + 156), ($y + 6), 7, 7) }
        $y += 22
    }
    $g.DrawString('提示：看门狗没在跑。没有它的话，DSH 起不来时没人自动回滚，只能靠你在这个窗口点。',
        $UiFont, (New-Object System.Drawing.SolidBrush($UiWarn)), $x0, ($y + 8))

    # 按钮
    $y = 206
    $btns = @(@('刷新', 'secondary'), @('＋ 打一个快照', 'primary'), @('回滚到选中快照', 'primary'),
              @('打开数据目录', 'secondary'), @('停止并卸载看门狗', 'danger'))
    $bx = 16
    foreach ($b in $btns) {
        $sz = $g.MeasureString($b[0], $UiFont)
        $bw = [single]($sz.Width + 26); $bh = [single]28
        $shape = New-RoundedPath -X $bx -Y $y -W $bw -H $bh -R 6
        switch ($b[1]) {
            'primary' { $fill = $UiAccent; $fg = [System.Drawing.Color]::White; $penC = $UiAccent }
            'danger'  { $fill = $UiCardBg; $fg = $UiBad; $penC = [System.Drawing.Color]::FromArgb(233, 190, 188) }
            default   { $fill = $UiCardBg; $fg = $UiText; $penC = $UiBorder }
        }
        $g.FillPath((New-Object System.Drawing.SolidBrush($fill)), $shape)
        $g.DrawPath((New-Object System.Drawing.Pen($penC, 1)), $shape)
        $g.DrawString($b[0], $UiFont, (New-Object System.Drawing.SolidBrush($fg)), ($bx + 13), ($y + 5))
        $shape.Dispose()
        $bx += [int]$bw + 8
    }

    # 列表（表头 + 普通行 + 选中行）
    # ⚠️ 这里必须和真窗口走**同一个** Draw-RowCell。
    #    原来是一串绝对坐标 DrawString，没有裁剪 → 长文本（快照名/标签）会直接溢出、
    #    压到右边一列上。真窗口没这问题（它走 Draw-RowCell，带 NoWrap + 省略号），
    #    于是"预览图"和"真窗口"长得不一样 —— 预览图就失去意义了。
    #    2026-09-14 是靠肉眼看 README 里那张图发现的：标签列的文字压在"原因"列上。
    $ly = 252
    Draw-Card -G $g -W $cardW -H 232 -R 10 -Y $ly
    $g.FillRectangle((New-Object System.Drawing.SolidBrush($UiHeadBg)), 32, ($ly + 8), ($cardW - 32), 26)

    # 列宽权重照抄真窗口的 6 列（时间150/快照名236/标签120/大小70/指纹112/原因80），按可用宽度等比缩放
    $weights = @(150, 236, 120, 70, 112, 80)
    $avail = $cardW - 32 - 8
    $wtSum = ($weights | Measure-Object -Sum).Sum
    $cols = @()
    $cx = 32
    foreach ($wt in $weights) {
        $cw = [int]($avail * $wt / $wtSum)
        $cols += , @{ X = $cx; W = $cw }
        $cx += $cw
    }
    $headers = @('时间', '快照名', '标签', '大小 MB', '指纹', '原因')
    for ($i = 0; $i -lt $cols.Count; $i++) {
        Draw-RowCell -G $g -Bounds (New-Object System.Drawing.Rectangle($cols[$i].X, ($ly + 8), $cols[$i].W, 26)) `
            -Text $headers[$i] -Font $UiFontBold -Fg $UiTextDim -Bg $UiHeadBg
    }
    $g.DrawLine((New-Object System.Drawing.Pen($UiBorder, 1)), 32, ($ly + 33), ($w - 32), ($ly + 33))

    $mockRows = @(
        @{ Bg = $UiCardBg; Cells = @('11:44:43', '20260914-114443_manual', 'manual', '6.59', '9F2C1A44B7E0', 'manual') },
        @{ Bg = $UiSelBg; Cells = @('11:42:48', '20260914-114248_pre-plugin-install', 'pre-plugin-install', '6.45', '5B7D2E9901AC', 'pre-plugin-change') }
    )
    $ry = $ly + 34
    foreach ($row in $mockRows) {
        # 选中行先铺满整条，再逐格画（Draw-RowCell 会用它的 Bg 覆盖自己的那一格）
        $g.FillRectangle((New-Object System.Drawing.SolidBrush($row.Bg)), 32, $ry, ($cardW - 32), 26)
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $cellFont = if ($i -eq 1 -or $i -eq 4) { $UiFontMono } else { $UiFont }
            $cellFg = if ($i -eq 2 -or $i -eq 4 -or $i -eq 5) { $UiTextDim } else { $UiText }
            Draw-RowCell -G $g -Bounds (New-Object System.Drawing.Rectangle($cols[$i].X, $ry, $cols[$i].W, 26)) `
                -Text $row.Cells[$i] -Font $cellFont -Fg $cellFg -Bg $row.Bg
        }
        $ry += 26
    }
    $g.DrawString('已刷新：4 个快照', $UiFont, (New-Object System.Drawing.SolidBrush($UiOk)), 34, ($ly + 200))

    $g.Dispose()
    $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ('证明页已写出：' + $OutPath)
    return $true
}

if ($ProofSheet) {
    [void](New-ProofSheet $ProofSheet)
    exit 0
}

# 建快捷方式（.cmd/.vbs 自己不能带图标，只有 .lnk 能）—— 不需要建窗口，先处理掉
if ($CreateShortcut) {
    $lnkPath = New-GuardShortcut $ShortcutDir
    $ic = Get-GuardIcon (Join-Path $here 'guard.ico')
    Write-Host ('快捷方式: ' + $lnkPath)
    Write-Host ('图标    : ' + $(if ($ic) { 'OK ' + $ic.Width + 'x' + $ic.Height } else { '没找到 ui\guard.ico（快捷方式会没图标）' }))
    exit 0
}

# ============================================================ 窗体骨架
$form = New-Object System.Windows.Forms.Form
$form.Text = 'DSH Guard 守护'
$form.Size = New-Object System.Drawing.Size(1000, 800)
$form.MinimumSize = New-Object System.Drawing.Size(820, 660)
$form.StartPosition = 'CenterScreen'
$form.Font = $UiFont
$form.BackColor = $UiPageBg
$form.ForeColor = $UiText
$form.TopMost = [bool]$TopMost
$form.KeyPreview = $true
# 窗口图标（标题栏 + 任务栏 + Alt-Tab）。走 Get-GuardIcon，不直接用 Icon 构造器 —— 见那里的注释。
$form.Icon = Get-GuardIcon (Join-Path $here 'guard.ico')

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 4
$root.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 10)
$root.BackColor = $UiPageBg
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 216)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 108)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 24)))
[void]$form.Controls.Add($root)

function New-CardPanel {
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = 'Fill'
    $card.BackColor = $UiPageBg
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $card.Add_Paint({ param($s, $e) Draw-Card -G $e.Graphics -W $s.Width -H $s.Height -R 10 })
    return $card
}
function New-UiLabel {
    param([string]$Text, $Font, $Color, [switch]$Dim)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Font = if ($Font) { $Font } else { $UiFont }
    $l.ForeColor = if ($Color) { $Color } else { $UiText }
    $l.AutoSize = $true
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}

# ---- 卡片 1：状态 ----
$card1 = New-CardPanel
[void]$root.Controls.Add($card1, 0, 0)

# 头部用两列表格：左边标题+副标题，右边徽章（避免绝对定位算宽度，窗口一缩放就歪）
$header = New-Object System.Windows.Forms.TableLayoutPanel
$header.Dock = 'Top'
$header.Height = 60
$header.ColumnCount = 2
$header.RowCount = 1
$header.BackColor = [System.Drawing.Color]::Transparent
[void]$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$card1.Controls.Add($header)

$titleBox = New-Object System.Windows.Forms.Panel
$titleBox.Dock = 'Fill'
$titleBox.BackColor = [System.Drawing.Color]::Transparent
$lblTitle = New-UiLabel 'DSH Guard 守护' $UiFontTitle $UiText
$lblTitle.Location = New-Object System.Drawing.Point(18, 12)
[void]$titleBox.Controls.Add($lblTitle)
$lblSub = New-UiLabel '不依赖 DSH —— DSH 打不开时也能回滚' $UiFontSmall $UiTextDim
$lblSub.Location = New-Object System.Drawing.Point(20, 40)
[void]$titleBox.Controls.Add($lblSub)
[void]$header.Controls.Add($titleBox, 0, 0)

$badge = New-Object System.Windows.Forms.Panel
$badge.Size = New-Object System.Drawing.Size(100, 26)
$badge.Margin = New-Object System.Windows.Forms.Padding(0, 20, 18, 0)
$badge.BackColor = $UiPageBg
$badge.Add_Paint({
    param($s, $e)
    $col = if ($script:wdRunning) { $UiOk } else { $UiWarn }
    $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path = New-RoundedPath -X 0.5 -Y 0.5 -W ($s.Width - 1) -H ($s.Height - 1) -R 13
    $e.Graphics.DrawPath((New-Object System.Drawing.Pen($col, 1)), $path)
    $path.Dispose()
})
$lblBadge = New-Object System.Windows.Forms.Label
$lblBadge.Dock = 'Fill'
$lblBadge.TextAlign = 'MiddleCenter'
$lblBadge.BackColor = [System.Drawing.Color]::Transparent
$lblBadge.Font = $UiFontSmall
[void]$badge.Controls.Add($lblBadge)
[void]$header.Controls.Add($badge, 1, 0)

$grid = New-Object System.Windows.Forms.TableLayoutPanel
$grid.Dock = 'Top'
$grid.Height = 120
$grid.ColumnCount = 2
$grid.RowCount = 5
$grid.BackColor = [System.Drawing.Color]::Transparent
[void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 96)))
[void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
for ($i = 0; $i -lt 5; $i++) { [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 24))) }
[void]$card1.Controls.Add($grid)

$statusKeys = @('profile', '插件指纹', 'DSH 端口', '数据目录', '快照个数')
$statusValues = @{}
for ($i = 0; $i -lt $statusKeys.Count; $i++) {
    $k = New-UiLabel $statusKeys[$i] $UiFont $UiTextDim
    $k.Dock = 'Fill'; $k.AutoSize = $false; $k.TextAlign = 'MiddleLeft'
    $k.Margin = New-Object System.Windows.Forms.Padding(18, 0, 0, 0)
    [void]$grid.Controls.Add($k, 0, $i)

    $v = New-Object System.Windows.Forms.Label
    $v.Font = if ($statusKeys[$i] -in @('插件指纹', '数据目录')) { $UiFontMono } else { $UiFont }
    $v.ForeColor = $UiText
    $v.Dock = 'Fill'
    $v.TextAlign = 'MiddleLeft'
    $v.AutoEllipsis = $true
    $v.BackColor = [System.Drawing.Color]::Transparent
    [void]$grid.Controls.Add($v, 1, $i)
    $statusValues[$statusKeys[$i]] = $v
}

$lblWarn = New-Object System.Windows.Forms.Label
$lblWarn.Dock = 'Top'
$lblWarn.AutoSize = $true
$lblWarn.MaximumSize = New-Object System.Drawing.Size(900, 22)   # 只允许一行：多了会压到下面按钮区
$lblWarn.Font = $UiFont
$lblWarn.ForeColor = $UiWarn
$lblWarn.BackColor = [System.Drawing.Color]::Transparent
$lblWarn.Padding = New-Object System.Windows.Forms.Padding(18, 0, 0, 0)
[void]$card1.Controls.Add($lblWarn)
# Dock=Top 的顺序是后加的在上，所以倒着补一次顺序：header 最上、grid 中间、警示最下
$card1.Controls.SetChildIndex($header, 2)
$card1.Controls.SetChildIndex($grid, 1)
$card1.Controls.SetChildIndex($lblWarn, 0)

# ---- 卡片 2：操作 ----
$card2 = New-CardPanel
[void]$root.Controls.Add($card2, 0, 1)

function New-UiButton {
    param([string]$Text, [ValidateSet('primary', 'secondary', 'danger')][string]$Kind = 'secondary')
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Font = $UiFont
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.Padding = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.UseVisualStyleBackColor = $false
    $b.Cursor = 'Hand'
    $b.Tag = $Kind
    switch ($Kind) {
        'primary' {
            $b.BackColor = $UiAccent; $b.ForeColor = [System.Drawing.Color]::White
            $b.FlatAppearance.BorderColor = $UiAccent
            $b.FlatAppearance.MouseOverBackColor = $UiAccentHi
            $b.FlatAppearance.MouseDownBackColor = $UiAccentHi
        }
        'danger' {
            $b.BackColor = $UiCardBg; $b.ForeColor = $UiBad
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(233, 190, 188)
            $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(253, 242, 242)
            $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(253, 242, 242)
        }
        default {
            $b.BackColor = $UiCardBg; $b.ForeColor = $UiText
            $b.FlatAppearance.BorderColor = $UiBorder
            $b.FlatAppearance.MouseOverBackColor = $UiHover
            $b.FlatAppearance.MouseDownBackColor = $UiHover
        }
    }
    $b.Add_SizeChanged({ param($s, $e) Set-RoundedRegion -Ctrl $s -R 6 })
    return $b
}

$row2 = New-Object System.Windows.Forms.FlowLayoutPanel
$row2.Dock = 'Top'
$row2.Height = 44
$row2.BackColor = [System.Drawing.Color]::Transparent
$row2.Padding = New-Object System.Windows.Forms.Padding(18, 10, 18, 0)
[void]$card2.Controls.Add($row2)

$btnRefresh = New-UiButton '刷新' 'secondary'
$btnSnap    = New-UiButton '＋ 打一个快照' 'primary'
$btnRoll    = New-UiButton '回滚到选中快照' 'primary'
$btnDir     = New-UiButton '打开数据目录' 'secondary'
$btnLog     = New-UiButton '看日志' 'secondary'
$btnWdOn    = New-UiButton '安装看门狗（随登录自启）' 'secondary'
$btnWdOff   = New-UiButton '停止并卸载看门狗' 'danger'
foreach ($b in @($btnRefresh, $btnSnap, $btnRoll, $btnDir, $btnLog, $btnWdOn, $btnWdOff)) { [void]$row2.Controls.Add($b) }

$row3 = New-Object System.Windows.Forms.FlowLayoutPanel
$row3.Dock = 'Top'
$row3.Height = 44
$row3.BackColor = [System.Drawing.Color]::Transparent
$row3.Padding = New-Object System.Windows.Forms.Padding(18, 4, 18, 0)
[void]$card2.Controls.Add($row3)

$lblPort = New-UiLabel '端口' $UiFont $UiTextDim
$lblPort.Margin = New-Object System.Windows.Forms.Padding(0, 9, 6, 0)
[void]$row3.Controls.Add($lblPort)

$txtPort = New-Object System.Windows.Forms.TextBox
$txtPort.Width = 74
$txtPort.Font = $UiFontMono
$txtPort.BorderStyle = 'FixedSingle'
$txtPort.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)
[void]$row3.Controls.Add($txtPort)

$btnPort = New-UiButton '用这个端口' 'secondary'
$btnPort.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
[void]$row3.Controls.Add($btnPort)

$lblPortFrom = New-UiLabel '' $UiFontSmall $UiTextDim
$lblPortFrom.Margin = New-Object System.Windows.Forms.Padding(6, 11, 0, 0)
[void]$row3.Controls.Add($lblPortFrom)
$card2.Controls.SetChildIndex($row2, 1)
$card2.Controls.SetChildIndex($row3, 0)

# ---- 卡片 3：快照 ----
$card3 = New-CardPanel
$card3.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
[void]$root.Controls.Add($card3, 0, 2)

# 标题栏用【两列】表格：左边标题+操作提示，右边快照治理按钮。
# ⚠️ 不能像以前那样左边绝对定位、右边 Dock=Right —— 提示文字一长就会钻到按钮底下
#    （2026-09-14 截图里就是这样：提示被两个按钮压住）。
$listHead = New-Object System.Windows.Forms.TableLayoutPanel
$listHead.Dock = 'Top'
$listHead.Height = 42
$listHead.ColumnCount = 2
$listHead.RowCount = 1
$listHead.BackColor = [System.Drawing.Color]::Transparent
[void]$listHead.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$listHead.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$card3.Controls.Add($listHead)

$headLeft = New-Object System.Windows.Forms.FlowLayoutPanel
$headLeft.Dock = 'Fill'
$headLeft.WrapContents = $false
$headLeft.BackColor = [System.Drawing.Color]::Transparent
$headLeft.Padding = New-Object System.Windows.Forms.Padding(18, 10, 0, 0)
[void]$listHead.Controls.Add($headLeft, 0, 0)
$lblListTitle = New-UiLabel '快照' $UiFontBold $UiText
$lblListTitle.Margin = New-Object System.Windows.Forms.Padding(0, 2, 10, 0)
[void]$headLeft.Controls.Add($lblListTitle)
$lblListHint = New-UiLabel '双击某行可直接回滚' $UiFontSmall $UiTextDim
$lblListHint.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
[void]$headLeft.Controls.Add($lblListHint)

# 快照治理按钮（放标题栏右侧）。快照"只增不减"是用户 2026-09-14 报的问题。
$listBtns = New-Object System.Windows.Forms.FlowLayoutPanel
$listBtns.Dock = 'Fill'
$listBtns.AutoSize = $true
$listBtns.FlowDirection = 'RightToLeft'
$listBtns.WrapContents = $false
$listBtns.BackColor = [System.Drawing.Color]::Transparent
$listBtns.Padding = New-Object System.Windows.Forms.Padding(0, 4, 16, 0)
[void]$listHead.Controls.Add($listBtns, 1, 0)
$btnPrune  = New-UiButton '清理旧快照' 'secondary'
$btnDelOne = New-UiButton '删除选中' 'danger'
$btnDelOne.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$btnPrune.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
[void]$listBtns.Controls.Add($btnDelOne)
[void]$listBtns.Controls.Add($btnPrune)

$listHost = New-Object System.Windows.Forms.Panel
$listHost.Dock = 'Fill'
$listHost.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 14)
$listHost.BackColor = [System.Drawing.Color]::Transparent
[void]$card3.Controls.Add($listHost)
$card3.Controls.SetChildIndex($listHead, 1)
$card3.Controls.SetChildIndex($listHost, 0)

$lv = New-Object System.Windows.Forms.ListView
$lv.Dock = 'Fill'
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.MultiSelect = $false
$lv.HideSelection = $false
$lv.GridLines = $false
$lv.BorderStyle = 'None'
$lv.HeaderStyle = 'Nonclickable'
$lv.BackColor = $UiCardBg
$lv.ForeColor = $UiText
$lv.Font = $UiFont
$lv.OwnerDraw = $true
[void]$lv.Columns.Add('时间', 150)
[void]$lv.Columns.Add('快照名', 236)
[void]$lv.Columns.Add('标签', 120)
[void]$lv.Columns.Add('大小 MB', 70)
[void]$lv.Columns.Add('指纹', 112)
[void]$lv.Columns.Add('原因', 80)
# 行高：ListView 没有行高属性，挂一个 1x26 的透明小图把行撑到 26px
$il = New-Object System.Windows.Forms.ImageList
$il.ImageSize = New-Object System.Drawing.Size(1, 26)
$il.ColorDepth = 'Depth32Bit'
# ⚠️ 这张 1x26 的位图**绝对不能 Dispose**：ImageList 要到"建句柄"时才去读它的 Width
#    （CreateBitmap → Image.get_Width），提前释放 = 窗口一显示就
#    ArgumentException("参数无效")。2026-09-14 真机崩过。
#    它必须活得和窗口一样久，所以挂在 $script: 上，窗口销毁时才释放。
$script:rowHeightBmp = New-Object System.Drawing.Bitmap(1, 26)
$il.Images.Add($script:rowHeightBmp) | Out-Null
$lv.SmallImageList = $il
[void]$listHost.Controls.Add($lv)

$lv.Add_DrawColumnHeader({
    param($s, $e)
    $e.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush($UiHeadBg)), $e.Bounds)
    $e.Graphics.DrawLine((New-Object System.Drawing.Pen($UiBorder, 1)),
        $e.Bounds.Left, ($e.Bounds.Bottom - 1), $e.Bounds.Right, ($e.Bounds.Bottom - 1))
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.LineAlignment = 'Center'
    $r = New-Object System.Drawing.RectangleF(($e.Bounds.X + 8), $e.Bounds.Y, ($e.Bounds.Width - 8), $e.Bounds.Height)
    $e.Graphics.DrawString($e.Header.Text, $UiFontBold, (New-Object System.Drawing.SolidBrush($UiTextDim)), $r, $fmt)
})
$lv.Add_DrawSubItem({
    param($s, $e)
    $bg = if ($e.Item.Selected) { $UiSelBg } else { $UiCardBg }
    $fg = if ($e.ColumnIndex -eq 0) { $UiText } else { $UiTextDim }
    $font = if ($e.ColumnIndex -in @(0, 1, 4)) { $UiFontMono } else { $UiFont }
    Draw-RowCell -G $e.Graphics -Bounds $e.Bounds -Text $e.SubItem.Text -Font $font -Fg $fg -Bg $bg
})

# ---- 消息行 ----
$lblMsg = New-Object System.Windows.Forms.Label
$lblMsg.Dock = 'Fill'
$lblMsg.Font = $UiFont
$lblMsg.TextAlign = 'MiddleLeft'
$lblMsg.ForeColor = $UiTextDim
$lblMsg.BackColor = $UiPageBg
[void]$root.Controls.Add($lblMsg, 0, 3)

# ============================================================ 行为
$script:lastStatus = $null
$script:wdRunning = $false

function Set-Msg($text, $kind) {
    $lblMsg.Text = $text
    switch ($kind) {
        'ok'    { $lblMsg.ForeColor = $UiOk }
        'bad'   { $lblMsg.ForeColor = $UiBad }
        'warn'  { $lblMsg.ForeColor = $UiWarn }
        default { $lblMsg.ForeColor = $UiTextDim }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Busy($on) {
    foreach ($b in @($btnRefresh, $btnSnap, $btnRoll, $btnDir, $btnLog, $btnWdOn, $btnWdOff, $btnPort, $btnPrune, $btnDelOne)) { $b.Enabled = -not $on }
    $txtPort.Enabled = -not $on
    $form.Cursor = if ($on) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    [System.Windows.Forms.Application]::DoEvents()
}

function Refresh-All {
    $st = Invoke-Guard 'status'
    $script:lastStatus = $st
    if ($st.ok) {
        $web = $st.web
        $wd = $st.watchdog
        $idn = $st.profileIdentity
        $script:wdRunning = [bool]$wd.running

        $statusValues['profile'].Text = ($st.profile + '    ' + $st.profileDir)
        $statusValues['插件指纹'].Text = ($idn.hash + '    依赖 ' + $idn.depCount + ' 项')
        $mark = if ($web.listening) { '● 在监听' } else { '× 未监听' }
        $statusValues['DSH 端口'].Text = ("$($script:effPort)    " + $mark + '    ' + $web.url)
        $statusValues['DSH 端口'].ForeColor = if ($web.listening) { $UiOk } else { $UiBad }
        $statusValues['数据目录'].Text = $st.guardHome
        $statusValues['快照个数'].Text = [string]$st.snapshotCount

        $lblBadge.Text = if ($wd.running) { '看门狗运行中' } else { '看门狗未运行' }
        $lblBadge.ForeColor = if ($wd.running) { $UiOk } else { $UiWarn }
        $badge.Invalidate()

        $lblPortFrom.Text = ('（判定依据：' + $script:PortChoice.From +
            $(if ($script:PortInfo.DshPorts.Count -gt 1) { '；检测到多个 DSH 端口: ' + (($script:PortInfo.DshPorts | ForEach-Object { $_.Port }) -join ', ') } else { '' }) + '）')

        if ($wd.scriptsStale) {
            # 这条要排在前面：它解释了"为什么某个新功能不生效"（看门狗在跑旧代码）
            $lblWarn.Text = if ($wd.scriptStaleSide -eq 'plugin') {
                '⚠️ 插件目录里的脚本比看门狗的旧（不一致：' + (@($wd.staleFiles) -join '、') + '）—— 重装插件即可，看门狗不用动。'
            } else {
                '⚠️ 看门狗在跑【旧版脚本】（不一致：' + (@($wd.staleFiles) -join '、') + '）—— 点「安装看门狗」重装一次即同步并重启。'
            }
        } elseif (-not $web.listening) {
            $lblWarn.Text = '⚠️ 这个端口上没有 DSH 在监听 —— 如果 DSH 就是打不开，那正该用这个窗口回滚（它不依赖 DSH）。'
        } elseif (-not $wd.running) {
            $lblWarn.Text = '提示：看门狗没在跑。没有它的话，DSH 起不来时没人自动回滚，只能靠你在这个窗口点。'
        } else {
            $lblWarn.Text = ''
        }

        $list = Invoke-Guard 'list'
        $snaps = Convert-SnapshotList $list.snapshots
        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($s in $snaps) {
            # createdAt 带毫秒（2026-09-14 11:50:04.293），列表里太长，截到秒
            $ts = [string]$s.createdAt
            if ($ts.Length -gt 19) { $ts = $ts.Substring(0, 19) }
            $it = New-Object System.Windows.Forms.ListViewItem($ts)
            [void]$it.SubItems.Add([string]$s.name)
            [void]$it.SubItems.Add([string]$s.label)
            [void]$it.SubItems.Add([string]$s.sizeMB)
            [void]$it.SubItems.Add([string]$s.hash)
            [void]$it.SubItems.Add([string]$s.reason)
            $it.Tag = $s
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()
        if ($lv.Items.Count -gt 0 -and $lv.SelectedIndices.Count -eq 0) { $lv.Items[0].Selected = $true }
        $sumMB = 0.0
        foreach ($it in $lv.Items) { if ($it.Tag -and $it.Tag.sizeMB) { $sumMB += [double]$it.Tag.sizeMB } }
        $lblListTitle.Text = ('快照（' + $lv.Items.Count + ' 个 · ' + $sumMB.ToString('N1') + ' MB）')
        Set-Msg ('已刷新：' + $lv.Items.Count + ' 个快照') 'ok'
    } else {
        foreach ($k in $statusValues.Keys) { $statusValues[$k].Text = '' }
        $lblBadge.Text = '读不到状态'
        $lblBadge.ForeColor = $UiBad
        $badge.Invalidate()
        $lblWarn.Text = ('守护脚本报错了：' + $st.error + '　看日志：' + (Join-Path $st.guardHome 'logs\guard.log'))
        Set-Msg ('状态读取失败：' + $st.error) 'bad'
    }
}

function Do-Prune {
    Set-Busy $true
    try {
        $r = Invoke-Guard 'prune'
        if ($r.ok) { Set-Msg ('✓ ' + $r.message) 'ok' } else { Set-Msg ('✗ ' + $r.error) 'bad' }
    } finally { Set-Busy $false }
    Refresh-All
}

function Do-DeleteSnapshot {
    if ($lv.SelectedItems.Count -eq 0) { Set-Msg '先在下面选中一个快照' 'warn'; return }
    $s = $lv.SelectedItems[0].Tag
    $ans = [System.Windows.Forms.MessageBox]::Show($form,
        "确定删除这个快照吗？`n`n  " + $s.name + "`n  " + $s.dir + "`n`n删掉就没了（它可能正是你的回滚点）。",
        '删除快照', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { Set-Msg '已取消删除' 'warn'; return }
    Set-Busy $true
    try {
        $r = Invoke-Guard 'delete' @{ Id = [string]$s.name }
        if ($r.ok) { Set-Msg ('✓ ' + $r.message) 'ok' }
        else { Set-Msg ('✗ ' + $(if ($r.error) { $r.error } else { '删除失败' })) 'bad' }
    } finally { Set-Busy $false }
    Refresh-All
}

function Do-Snapshot {
    Set-Busy $true
    try {
        $r = Invoke-Guard 'snapshot' @{ Reason = 'manual-ui' }
        if ($r.ok) { Set-Msg ('已打快照：' + $r.name + '（' + $r.sizeMB + ' MB）') 'ok' }
        else { Set-Msg ('打快照失败：' + $r.error) 'bad' }
    } finally { Set-Busy $false }
    Refresh-All
}

function Do-Rollback {
    if ($lv.SelectedItems.Count -eq 0) { Set-Msg '先在下面选中一个快照' 'warn'; return }
    $s = $lv.SelectedItems[0].Tag
    $msg = "确定回滚到这个快照吗？`n`n  时间: " + $s.createdAt + "`n  标签: " + $s.label + "`n  目录: " + $s.dir +
           "`n`n回滚会：还原 profile 配置文件、移除快照之后新增的插件目录、跑一次 pnpm install。`n" +
           "回滚前会先把当前状态留档成 pre-rollback-broken，所以这一步本身也有后悔药。`n`n回滚完成后需要重启 DSH 才会生效。"
    $ans = [System.Windows.Forms.MessageBox]::Show($form, $msg, '确认回滚', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { Set-Msg '已取消回滚' 'warn'; return }

    Set-Busy $true
    try {
        Set-Msg '正在回滚…（会跑 pnpm install，可能要几十秒）' 'warn'
        # 传快照目录名（guard.ps1 的 -Id 认快照名或目录）
        $r = Invoke-Guard 'rollback' @{ Id = [string]$s.name }
        if ($r.ok) {
            $detail = ($r.steps -join "`n  · ")
            # 带上 $form 作 owner：对话框跟着本窗口走（位置/图标/模态都对）
            [void][System.Windows.Forms.MessageBox]::Show($form,
                "回滚完成（从 " + $r.restoredFrom + "）。`n`n  · " + $detail + "`n`n现在需要重启 DSH 才会生效。",
                '回滚成功', 'OK', 'Information')
            Set-Msg '回滚完成 —— 请重启 DSH' 'ok'
        } else {
            [void][System.Windows.Forms.MessageBox]::Show($form,
                "回滚失败：`n" + $r.message + "`n" + $r.error, '回滚失败', 'OK', 'Error')
            Set-Msg ('回滚失败：' + $r.message + $r.error) 'bad'
        }
    } finally { Set-Busy $false }
    Refresh-All
}

function Invoke-WatchdogInstall {
    param([string]$What, [switch]$UseStartup)
    $scriptName = if ($What -eq 'install') { 'install-watchdog.ps1' } else { 'uninstall-watchdog.ps1' }
    $target = Join-Path $libDir $scriptName
    if (-not (Test-Path -LiteralPath $target)) { return @{ Ok = $false; Code = 9; Text = '找不到 ' + $target } }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target, '-Profile', $Profile)
    if ($GuardHomeDir) { $a += @('-GuardHomeDir', $GuardHomeDir) }
    if ($script:effPort -gt 0) { $a += @('-WebPort', "$($script:effPort)") }
    if ($UseStartup) { $a += @('-UseStartup') }

    # ⚠️ 必须【前台跑并把输出抓回来】。
    #    以前这里是 Start-Process 另起一个窗口、什么都不捕获 —— 结果就是
    #    "点了没反应 / 一闪而过 / 装没装上都不知道"（2026-09-14 用户就是这么被坑的：
    #    ~\.dsh-guard\bin 根本没建，说明那个子进程连第一步都没走到）。
    $out = & powershell.exe @a 2>&1 | Out-String
    $code = $LASTEXITCODE

    # 留一条**持久**痕迹：万一界面上没看清 / 窗口被关掉，日志里还有
    try {
        $gh = if ($script:lastStatus) { $script:lastStatus.guardHome } else { Join-Path $env:USERPROFILE '.dsh-guard' }
        $logDir = Join-Path $gh 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $tag = if ($code -eq 0) { 'OK' } else { 'FAIL' }
        Add-Content -LiteralPath (Join-Path $logDir 'guard-ui.log') -Encoding UTF8 `
            -Value ("[$stamp] [$tag] 独立窗口按钮: $scriptName" + $(if ($UseStartup) { ' -UseStartup' } else { '' }) + " 退出码=$code")
    } catch { }
    return @{ Ok = ($code -eq 0); Code = $code; Text = ($out.Trim() + "`n`n[退出码 $code]") }
}

function Do-Watchdog($what) {
    Set-Busy $true
    try {
        Set-Msg ('正在' + $(if ($what -eq 'install') { '安装' } else { '卸载' }) + '看门狗…（若弹 UAC 请点允许）') 'warn'
        $r = Invoke-WatchdogInstall $what
        [void][System.Windows.Forms.MessageBox]::Show($form, $r.Text,
            $(if ($what -eq 'install') { '看门狗安装结果' } else { '看门狗卸载结果' }),
            'OK', $(if ($r.Ok) { 'Information' } else { 'Warning' }))

        # 计划任务要管理员权限。被拒/失败时**当场**给"不需要管理员"的替代方案 —— 别让用户自己猜。
        if (-not $r.Ok -and $what -eq 'install') {
            $ans = [System.Windows.Forms.MessageBox]::Show($form,
                "计划任务需要管理员权限，这次没装上。`n`n要不要改用【启动文件夹】方式？`n" +
                "它不需要管理员、不会弹 UAC，登录时由资源管理器自动拉起。`n" +
                "（启动文件夹方式不需要管理员，是所有用户的兜底方案。）",
                '改用启动文件夹？', 'YesNo', 'Question')
            if ($ans -eq 'Yes') {
                Set-Msg '正在改用启动文件夹安装…' 'warn'
                $r2 = Invoke-WatchdogInstall $what -UseStartup
                [void][System.Windows.Forms.MessageBox]::Show($form, $r2.Text, '启动文件夹安装结果',
                    'OK', $(if ($r2.Ok) { 'Information' } else { 'Warning' }))
            }
        }
        if ($r.Ok) { Set-Msg ('看门狗' + $(if ($what -eq 'install') { '安装' } else { '卸载' }) + '完成') 'ok' }
    } finally { Set-Busy $false }
    Refresh-All
}

$btnRefresh.Add_Click({ Set-Busy $true; try { Refresh-All } finally { Set-Busy $false } })
$btnSnap.Add_Click({ Do-Snapshot })
$btnPrune.Add_Click({ Do-Prune })
$btnDelOne.Add_Click({ Do-DeleteSnapshot })
$btnRoll.Add_Click({ Do-Rollback })
$lv.Add_DoubleClick({ Do-Rollback })
$btnPort.Add_Click({
    $v = 0
    if ([int]::TryParse($txtPort.Text.Trim(), [ref]$v) -and $v -gt 0 -and $v -lt 65536) {
        $script:effPort = $v
        $script:PortChoice = @{ Port = $v; From = '你手动指定' }
        $script:PortInfo = Get-PortInfo
        Set-Busy $true; try { Refresh-All } finally { Set-Busy $false }
    } else { Set-Msg '端口要填 1-65535 的数字' 'warn' }
})
$txtPort.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $btnPort.PerformClick(); $_.SuppressKeyPress = $true } })
$btnDir.Add_Click({
    $gh = if ($script:lastStatus) { $script:lastStatus.guardHome } else { Join-Path $env:USERPROFILE '.dsh-guard' }
    if (Test-Path -LiteralPath $gh) { Start-Process -FilePath 'explorer.exe' -ArgumentList $gh } else { Set-Msg ('目录不存在：' + $gh) 'warn' }
})
$btnLog.Add_Click({
    $gh = if ($script:lastStatus) { $script:lastStatus.guardHome } else { Join-Path $env:USERPROFILE '.dsh-guard' }
    $log = Join-Path $gh 'logs\guard.log'
    if (Test-Path -LiteralPath $log) { Start-Process -FilePath 'notepad.exe' -ArgumentList $log } else { Set-Msg ('日志不存在：' + $log) 'warn' }
})
$btnWdOn.Add_Click({ Do-Watchdog 'install' })
$btnWdOff.Add_Click({ Do-Watchdog 'uninstall' })
$form.Add_KeyDown({
    if ($_.KeyCode -eq 'F5') { $btnRefresh.PerformClick() }
    elseif ($_.KeyCode -eq 'Escape') { $form.Close() }
})

# ============================================================ 自检 / 运行
$txtPort.Text = [string]$script:effPort

if ($SelfTest) {
    Refresh-All
    Write-Host '=== Guard-UI SelfTest ==='
    Write-Host ('guard.ps1        : ' + $guardPs1)
    Write-Host ('form 标题         : ' + $form.Text)
    Write-Host ('窗口图标          : ' + $(if ($form.Icon) { 'OK ' + $form.Icon.Width + 'x' + $form.Icon.Height } else { '没有（回退到默认图标）' }))
    Write-Host ('页面底色 / 卡片底色: ' + $form.BackColor.ToString() + '  /  ' + $UiCardBg.ToString())
    Write-Host ('品牌蓝 / 成功 / 危险: ' + $UiAccent.ToString() + '  ' + $UiOk.ToString() + '  ' + $UiBad.ToString())
    Write-Host ('生效端口          : ' + $script:effPort + '   判定依据: ' + $script:PortChoice.From)
    Write-Host ('检测到的 DSH 端口 : ' + $(if ($script:PortInfo.DshPorts.Count) { (($script:PortInfo.DshPorts | ForEach-Object { $_.Port }) -join ', ') } else { '（无）' }))
    Write-Host ('端口输入框        : ' + $txtPort.Text)
    Write-Host '--- 状态行 ---'
    foreach ($k in $statusKeys) { Write-Host ('  ' + $k.PadRight(10) + ' = ' + $statusValues[$k].Text) }
    Write-Host ('徽章              : ' + $lblBadge.Text)
    Write-Host ('警示行            : ' + $lblWarn.Text)
    Write-Host ('快照行数          : ' + $lv.Items.Count)
    foreach ($it in $lv.Items) { Write-Host ('  · ' + $it.Text + '  ' + $it.SubItems[1].Text + '  ' + $it.SubItems[2].Text + '  ' + $it.SubItems[3].Text + 'MB  ' + $it.SubItems[4].Text) }
    Write-Host ('按钮              : ' + (($row2.Controls | ForEach-Object { $_.Text }) -join ' | '))
    Write-Host ('消息行            : ' + $lblMsg.Text)

    # 自绘真的能跑吗？在离屏位图上真画一遍（不用肉眼也能验）
    $paintOk = $true
    try {
        $bmp = New-Object System.Drawing.Bitmap(500, 260)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        Draw-Card -G $g -W 500 -H 260 -R 10
        # 列表单元格用的是同一个函数（Draw-RowCell），这里真调它 —— 拼错颜色/字体/属性会当场抛异常
        Draw-RowCell -G $g -Bounds (New-Object System.Drawing.Rectangle(0, 0, 200, 26)) -Text '20260914-114443_manual' `
            -Font $UiFontMono -Fg $UiText -Bg $UiCardBg
        Draw-RowCell -G $g -Bounds (New-Object System.Drawing.Rectangle(0, 26, 200, 26)) -Text '选中行' `
            -Font $UiFont -Fg $UiTextDim -Bg $UiSelBg
        $g.Dispose(); $bmp.Dispose()
    } catch { $paintOk = $false; Write-Host ('  ✗ 自绘抛异常: ' + $_.Exception.Message) }
    Write-Host ('自绘（卡片+单元格）: ' + $(if ($paintOk) { 'OK' } else { 'FAIL' }))

    # ⚠️ 上面那些都只是"建对象"，窗口句柄一次都没建过 —— 而 ImageList/图标/自绘的坑
    #    恰恰在**建句柄**那一刻才爆（2026-09-14：ImageList 里放了已释放的位图，
    #    自检一路绿灯，用户双击窗口一显示就 ArgumentException）。
    #    所以这里必须把句柄都逼出来。
    $handleOk = $true
    try {
        $null = $form.Handle
        foreach ($ctl in @($lv, $badge, $grid, $row2, $row3, $listHost, $txtPort, $lblMsg)) { $null = $ctl.Handle }
        [System.Windows.Forms.Application]::DoEvents()
    } catch { $handleOk = $false; Write-Host ('  ✗ 建窗口句柄抛异常: ' + $_.Exception.Message) }
    Write-Host ('窗口句柄（含列表 ImageList）: ' + $(if ($handleOk) { 'OK' } else { 'FAIL' }))

    $okStatus = ($script:lastStatus -ne $null) -and $script:lastStatus.ok
    Write-Host ('结论              : ' + $(if ($okStatus -and $paintOk) { 'OK —— 数据层通了、控件建起来了、自绘能跑、句柄能建' } else { '有问题' }))
    $form.Dispose()
    if ($okStatus -and $paintOk -and $handleOk) { exit 0 } else { exit 1 }
}

Refresh-All

# 把**真实窗口**渲染成 PNG。
#
# 为什么要"真显示一下"：Control.DrawToBitmap 对**从未显示过**的窗口只画背景和边框，
# 子控件（卡片/按钮/列表）一个都不画 —— 实测出来是一张纯灰图（只有标题栏和图标）。
# 所以这里把它放到屏幕外 (-4000,-4000)、不进任务栏，真实 Show() 一下再画，画完立刻关：
# 用户看不到任何东西，但走的是和真机完全一样的 建句柄 → 布局 → 自绘 路径。
# 改完界面先跑这个，别拿用户的眼睛当测试机。
if ($Screenshot) {
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $form.ShowInTaskbar = $false
    try {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 600
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($Screenshot, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Host ('窗口截图已写出：' + $Screenshot)
    } catch {
        Write-Host ('截图失败：' + $_.Exception.Message)
    } finally {
        $form.Close()
        $form.Dispose()
    }
    exit 0
}

[void]$form.ShowDialog()
$form.Dispose()
exit 0
