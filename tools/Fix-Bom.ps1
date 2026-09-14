<#
  Fix-Bom.ps1 —— 给本项目所有 .ps1 补 UTF-8 BOM（缺哪个补哪个，正文一个字都不动）。

  为什么需要它：
    PowerShell 5.1 读【没有 BOM】的 .ps1 时会按 ANSI(GBK) 解码中文 → 一串**假语法错**
    （现象：明明只改了两行，却报十几处 "The Try statement is missing its Catch"）。
    而各种编辑器/工具（含本项目的 edit 工具）保存时经常把 BOM 丢掉。
    这个坑在 2026-09-14 一个会话里咬了 4 次，所以固化成一条命令。

  用法： powershell -ExecutionPolicy Bypass -File tools\Fix-Bom.ps1
     exit 0 = 全部带 BOM；exit 1 = 仍有文件补不上
  注意：本脚本自己**必须**带 BOM，否则它自己也读不对中文。
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$files = @()
foreach ($dir in @($root, (Join-Path $root 'lib'), (Join-Path $root 'ui'), (Join-Path $root 'tools'))) {
    if (Test-Path -LiteralPath $dir) {
        $files += @(Get-ChildItem -LiteralPath $dir -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
    }
}
$files = $files | Sort-Object FullName -Unique

$fixed = 0; $ok = 0; $bad = 0
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
    if ($hasBom) { $ok++; Write-Host ('  OK   ' + $f.FullName.Substring($root.Length + 1)) -ForegroundColor DarkGray; continue }

    # 读成【无 BOM UTF-8】→ 再写成【带 BOM UTF-8】。正文、行尾都不动。
    try {
        $text = [System.IO.File]::ReadAllText($f.FullName, (New-Object System.Text.UTF8Encoding($false)))
        # 顺手把重复的前导 BOM（历史上出现过 4 个）压成一个
        $text = $text.TrimStart([char]0xFEFF)
        [System.IO.File]::WriteAllText($f.FullName, $text, (New-Object System.Text.UTF8Encoding($true)))
        $fixed++
        Write-Host ('  补了 ' + $f.FullName.Substring($root.Length + 1)) -ForegroundColor Yellow
    } catch {
        $bad++
        Write-Host ('  失败 ' + $f.FullName.Substring($root.Length + 1) + ' : ' + $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ("共 {0} 个 .ps1：本来就有 {1} 个，补了 {2} 个，失败 {3} 个" -f $files.Count, $ok, $fixed, $bad) `
    -ForegroundColor $(if ($bad) { 'Red' } else { 'Green' })
if ($bad) { exit 1 }
exit 0
