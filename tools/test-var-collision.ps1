<#
  test-var-collision.ps1 —— 静态护栏：dot-source 作用域里的变量名撞车（2026-09-26 新增）

  为什么需要：
    lib\*.ps1 里的 `guard-bootstrap.ps1` / `guard-core.ps1` / `watchdog-core.ps1` 是被
    **dot-source**（`.` 点源）进调用方作用域的 —— 也就是说，这些文件里写的**普通变量**
    和**入口脚本的参数**在**同一个作用域**里。而 PowerShell 变量名**不区分大小写**：
      入口 guard.ps1:  param([int]$Keep = 0)
      bootstrap      :  $keep = @($x -split ';' | Where-Object {...})   # 数组！
    ⇒ 把数组赋给 [int] 约束的参数 → "Cannot convert System.Object[] to type System.Int32"，
    整个初始化失败，而报错信息完全不提变量名。（2026-09-26 真的踩到，花了一轮才定位。）
    同类历史：账本 E15（`build-shell.ps1` 里用 `$Host` 当普通变量）。

  判据：
    · 只查**普通变量**（不含 `script:` / `env:` / `global:` / `private:`）—— 带作用域前缀的
      赋值（如 `$script:WebPort = ...` 故意与参数同名）是**设计如此**，不算撞车；
    · 只查**函数外**的赋值（函数有独立作用域，`param([string]$Path)` 之类不算）；
    · 与"所有入口脚本的参数名"求交集，非空即 FAIL。

  自检（阳性对照）：脚本先用一对合成脚本验证检测逻辑**真的能抓到**这个模式，
  抓不到就直接 FAIL —— 免得护栏本身是瞎的（账本 E33–E39 的教训）。

  用法： powershell -ExecutionPolicy Bypass -File tools\test-var-collision.ps1
     exit 0 = 无撞车；1 = 有撞车或自检失败
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$libDir = Join-Path $root 'lib'

function Get-ParamNames {
    param([string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $names = @()
    if ($ast.ParamBlock) {
        foreach ($p in $ast.ParamBlock.Parameters) { $names += $p.Name.VariablePath.UserPath }
    }
    return $names
}

function Get-PlainTopLevelAssignments {
    <#  返回"普通局部变量名"（函数外、无作用域前缀）的赋值列表  #>
    param([string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $hits = @()
    $all = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($node in $all) {
        if ($node.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $text = $node.Left.Extent.Text
        if ($text -match ':' -or $text -match '\.') { continue }      # script:/env:/global:/private:/drive
        $insideFunc = $false
        $p = $node.Parent
        while ($p) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $insideFunc = $true; break }
            $p = $p.Parent
        }
        if ($insideFunc) { continue }
        $hits += [pscustomobject]@{ Name = $node.Left.VariablePath.UserPath; Line = $node.Extent.StartLineNumber }
    }
    return $hits
}

# ---------------------------------------------------------------- 自检（阳性对照）
$selfDir = Join-Path $env:TEMP ('guard-varcheck-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $selfDir | Out-Null
$fakeEntry = Join-Path $selfDir 'entry.ps1'
$fakeLib   = Join-Path $selfDir 'lib.ps1'
[System.IO.File]::WriteAllText($fakeEntry, "param([int]`$Keep = 0)`n. `$PSScriptRoot\lib.ps1`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($fakeLib,   "`$keep = @(1,2,3)`n`$script:Keep = 9`nfunction F { param([int]`$Keep = 0) `$Keep = 5 }`n", (New-Object System.Text.UTF8Encoding($false)))

$fakeParams = @(Get-ParamNames -Path $fakeEntry)
$fakeHits = @(Get-PlainTopLevelAssignments -Path $fakeLib)
$caught = @($fakeHits | Where-Object { $fakeParams -contains $_.Name }).Count
# 期望：抓到 $keep（撞 [int]$Keep），但**不**把 $script:Keep 与函数内的 $Keep 算进来
if ($caught -ne 1 -or $fakeHits.Count -ne 1) {
    Write-Host ("自检失败：合成样例期望命中 1 条、实际命中 {0} 条（普通赋值共 {1} 条）" -f $caught, $fakeHits.Count) -ForegroundColor Red
    Write-Host '  ⇒ 护栏本身不可信，先修它再用它（账本 E33–E39）' -ForegroundColor Red
    exit 1
}
Write-Host '自检 OK：合成样例被正确抓到，且 script: 前缀与函数内赋值未被误报' -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------- 真检
$entries = @(Get-ChildItem -LiteralPath $libDir -File -Filter '*.ps1')
$paramMap = @{}
foreach ($e in $entries) {
    foreach ($n in @(Get-ParamNames -Path $e.FullName)) {
        $k = $n.ToLower()
        if (-not $paramMap.ContainsKey($k)) { $paramMap[$k] = @() }
        $paramMap[$k] += $e.Name
    }
}
Write-Host ("入口脚本 {0} 个，参数名 {1} 个" -f $entries.Count, $paramMap.Count)

# 被 dot-source 进调用方作用域的文件（这些才有撞车风险）
$dotted = @('guard-bootstrap.ps1', 'guard-core.ps1', 'watchdog-core.ps1')

$bad = 0
foreach ($name in $dotted) {
    $f = Join-Path $libDir $name
    if (-not (Test-Path -LiteralPath $f)) { Write-Host ("  缺少 {0}" -f $name) -ForegroundColor Yellow; continue }
    foreach ($hit in @(Get-PlainTopLevelAssignments -Path $f)) {
        $k = $hit.Name.ToLower()
        if ($paramMap.ContainsKey($k)) {
            $bad++
            Write-Host ("  ✗ {0}:{1}  普通变量 `${2} 与入口参数同名（{3}）" -f $name, $hit.Line, $hit.Name, ($paramMap[$k] -join ', ')) -ForegroundColor Red
        }
    }
}

Write-Host ''
if ($bad -eq 0) {
    Write-Host '结论：OK —— dot-source 文件里没有与入口参数撞名的普通变量' -ForegroundColor Green
    exit 0
}
Write-Host ("结论：发现 {0} 处撞车 —— 改掉变量名（或在入口脚本里改名），否则会在运行期炸成" -f $bad) -ForegroundColor Red
Write-Host '      "Cannot convert System.Object[] to type System.Int32" 这类与变量名无关的报错。' -ForegroundColor Red
exit 1
