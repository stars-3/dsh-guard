<#
  test-cfg-keys.ps1 —— 静态核对：核心代码引用的每个 $script:Cfg.<键> 都必须有定义

  ── 为什么要有这个（2026-09-14 夹具抓到的真 bug）──────────────────────────────
    `watchdog-core.ps1` 里判"最近装过插件"用的是 `$script:Cfg.PluginChangeWindowSec`，
    但配置表（`guard-bootstrap.ps1` 的 `$script:Cfg`）里**从来没有这个键**。
    PowerShell 取不存在的键得到 `$null`，比较 `-lt $null` 恒为假 →
    「近期动过插件」**永远为假** → 自动回滚这条救命能力实际上一直是哑的。
    真机那次能回滚，纯属隔离期 `$inQuarantine` 恰好为真 —— 这种"静默失效"最难查。

  所以：**凡是核心引用的键，配置表里必须都有**。本脚本把这个约定钉死。
  判据：键定义在 guard-bootstrap.ps1 的 $script:Cfg 块里，或在 watchdog.ps1 里补过
        （后者是插件版对上游 Cfg 的补充赋值）。

  用法：powershell -File tools\test-cfg-keys.ps1
  退出码：0 = 全部有定义；1 = 有键没定义
#>
$ErrorActionPreference = 'Stop'
$proj = Split-Path $PSScriptRoot -Parent
$lib = Join-Path $proj 'lib'

# ---- 1. 收集核心代码里用到的键 ----
$used = [ordered]@{}
foreach ($f in (Get-ChildItem $lib -Filter '*.ps1' -File)) {
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.UTF8Encoding]::new($true))
    foreach ($m in [regex]::Matches($text, '\$script:Cfg\.([A-Za-z_][A-Za-z0-9_]*)')) {
        $k = $m.Groups[1].Value
        # ⚠️ 必须排掉 OrderedDictionary 自己的成员名。踩过的坑（本测试自己的 bug）：
        #    bootstrap 里有 `@($script:Cfg.Keys)`（遍历环境覆盖），正则会把 `Keys` 当成"配置键"；
        #    而 $used 里一旦存在名为 Keys 的键，后面写 `$used.Keys` 取到的就是**那个值**而不是键集合
        #    （PowerShell 认键优先于属性）→ 枚举全乱，表现为"只报一个键、名字还是个文件名"。
        if ($k -eq 'Keys' -or $k -eq 'Values' -or $k -eq 'Count' -or $k -eq 'Item') { continue }
        if (-not $used.Contains($k)) { $used[$k] = New-Object System.Collections.Generic.List[string] }
        if (-not $used[$k].Contains($f.Name)) { $used[$k].Add($f.Name) }
    }
}

# ---- 2. 收集已定义的键（bootstrap 的 Cfg 块 + watchdog.ps1 里的补充赋值）----
$defined = @{}
$bt = [System.IO.File]::ReadAllText((Join-Path $lib 'guard-bootstrap.ps1'), [System.Text.UTF8Encoding]::new($true))
$block = [regex]::Match($bt, '(?s)\$script:Cfg\s*=\s*\[ordered\]@\{(.*?)\n\}')
if (-not $block.Success) { Write-Host '  ✗ 找不到 $script:Cfg 定义块（bootstrap 结构变了？）'; exit 1 }
foreach ($m in [regex]::Matches($block.Groups[1].Value, '(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=')) {
    $defined[$m.Groups[1].Value] = 'guard-bootstrap.ps1'
}
$wd = [System.IO.File]::ReadAllText((Join-Path $lib 'watchdog.ps1'), [System.Text.UTF8Encoding]::new($true))
foreach ($m in [regex]::Matches($wd, '\$script:Cfg\.([A-Za-z_][A-Za-z0-9_]*)\s*=')) {
    $defined[$m.Groups[1].Value] = 'watchdog.ps1（补充赋值）'
}

Write-Host ''
Write-Host ("  核心引用 {0} 个配置键；已定义 {1} 个（bootstrap {2} + watchdog 补充 {3}）" -f `
        $used.Count, $defined.Count, `
    (@($defined.Values | Where-Object { $_ -eq 'guard-bootstrap.ps1' }).Count), `
    (@($defined.Values | Where-Object { $_ -ne 'guard-bootstrap.ps1' }).Count))

$missing = @()
foreach ($k in $used.Keys) {
    if (-not $defined.ContainsKey($k)) { $missing += $k }
}
if ($missing.Count) {
    Write-Host ''
    Write-Host '  ✗ 下列键被核心引用、但没有任何地方定义（取到 $null，判断会静默失效）：'
    foreach ($k in $missing) { Write-Host ("      {0,-24} 用于 {1}" -f $k, ($used[$k] -join ', ')) }
    Write-Host ''
    Write-Host '  修法：在 guard-bootstrap.ps1 的 $script:Cfg 里补上它（并在 watchdog.ps1 的"参数：…"那行打印出来）。'
    Write-Host '  结论：FAIL'
    exit 1
}

Write-Host '  ✓ 所有被引用的键都有定义'
Write-Host '  结论：OK —— 配置键完整，不会有"引用了一个不存在的键导致判断静默失效"的情况'
exit 0
