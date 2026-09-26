<#
  test-process-mode.ps1 —— 官方桌面端"进程模式"回归夹具（2026-09-26 新增）

  背景：官方桌面端（D:\dsh\DeepSeek Harness.exe）的界面端口**每次启动随机**
  （asar 里是 server.listen(0, "127.0.0.1")），所以看门狗不能按端口判活。
  本夹具验证新增的 HealthMode='process' 这条路径，并且**同时**证明
  "什么都不配 = 老行为"（web 那份不受影响）。

  用例（每个都在**独立子进程**里跑，避免 $script: 状态互相污染）：
    defaults    不传任何新模式参数 → HealthMode=port、PnpmCmd=pnpm（= 上游行为）
    file-cfg    运行模式写进 config-<profile>.json 后能被读到；**不污染别的 profile**
    process-pos process 模式 + 真实进程名（DeepSeek Harness 正在跑）→ PortUp=$true（阳性对照）
    process-neg process 模式 + 不存在的进程名 → PortUp=$false（阴性对照）

  用法： powershell -ExecutionPolicy Bypass -File tools\test-process-mode.ps1
     exit 0 = 全部通过；1 = 有用例失败
#>
[CmdletBinding()]
param(
    [string]$Case   = 'all',
    [string]$Shadow = ''
)

$ErrorActionPreference = 'Continue'

# ============================================================ 子进程：单个用例
if ($Case -ne 'all') {
    $lib = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'
    $fails = 0
    function Check {
        param([string]$What, [bool]$Ok, [string]$Detail = '')
        if ($Ok) { Write-Host ("  OK   {0} {1}" -f $What, $Detail) }
        else { Write-Host ("  FAIL {0} {1}" -f $What, $Detail); $script:fails++ }
    }

    switch ($Case) {
        'defaults' {
            . (Join-Path $lib 'guard-bootstrap.ps1') -ProfileName 'webtest' -GuardHome $Shadow
            Check 'HealthMode 默认 = port' ($script:HealthMode -eq 'port') "→ $($script:HealthMode)"
            Check 'PnpmCmd 默认 = pnpm'   ($script:PnpmCmd -eq 'pnpm')   "→ $($script:PnpmCmd)"
            Check 'AppExe 有默认值'        ([bool]$script:AppExe)         "→ $($script:AppExe)"
        }
        'file-cfg' {
            # 只靠运行模式文件（不传 -HealthMode），且另一个 profile 的文件不能串味
            . (Join-Path $lib 'guard-bootstrap.ps1') -ProfileName 'webtest' -GuardHome $Shadow
            Check 'config-webtest.json 生效 → process' ($script:HealthMode -eq 'process') "→ $($script:HealthMode)"
            Check 'PnpmCmd 来自文件/默认推导' ([bool]$script:PnpmCmd) "→ $($script:PnpmCmd)"

            . (Join-Path $lib 'guard-bootstrap.ps1') -ProfileName 'othertest' -GuardHome $Shadow
            Check 'config-othertest.json 不受污染 → port' ($script:HealthMode -eq 'port') "→ $($script:HealthMode)"
        }
        'process-pos' {
            . (Join-Path $lib 'guard-bootstrap.ps1') -ProfileName 'webtest' -GuardHome $Shadow -HealthMode process
            . (Join-Path $lib 'guard-core.ps1')
            . (Join-Path $lib 'watchdog-core.ps1')
            $h = Get-HealthSnapshot
            Check 'HealthMode=process' ($script:HealthMode -eq 'process')
            Check 'PnpmCmd 指向官方端自带运行时' ($script:PnpmCmd -like '*primary-runtime*') "→ $($script:PnpmCmd)"
            Check '官方端在跑 → PortUp=true' ($h.PortUp -eq $true) "（阳性对照；ProcessUp=$($h.ProcessUp) PID=$($h.PortOwnerPid)）"
            Check '快照里带 HealthMode 字段' ($h.HealthMode -eq 'process')
        }
        'process-neg' {
            . (Join-Path $lib 'guard-bootstrap.ps1') -ProfileName 'webtest' -GuardHome $Shadow -HealthMode process -AppProcess 'NoSuchProcessXYZZY'
            . (Join-Path $lib 'guard-core.ps1')
            . (Join-Path $lib 'watchdog-core.ps1')
            $h = Get-HealthSnapshot
            Check '不存在的进程 → PortUp=false' ($h.PortUp -eq $false) '（阴性对照）'
            $reasons = Test-HealthBad -Health $h -ErrorCount 0
            Check '不健康理由点名官方端进程' (($reasons -join ' ') -like '*官方端进程*') "→ $($reasons -join ' / ')"
        }
        default { Write-Host "未知用例：$Case"; exit 2 }
    }

    if ($fails -gt 0) { exit 1 }
    exit 0
}

# ============================================================ 主进程：把用例串起来
if (-not $Shadow) {
    $Shadow = Join-Path $env:TEMP ('dshguard-shadow-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force -Path $Shadow | Out-Null

Write-Host '=== test-process-mode（官方桌面端 进程模式）==='
Write-Host ("影子 GuardHome：{0}" -f $Shadow)
Write-Host ''

# 造两份运行模式文件：webtest = process（要生效的那份），othertest = port（不能被污染）
$webtestCfg = [ordered]@{ profile = 'webtest'; healthMode = 'process'; appExe = 'D:\dsh\DeepSeek Harness.exe'; appProcess = 'DeepSeek Harness'; pnpmCmd = '' }
$otherCfg   = [ordered]@{ profile = 'othertest'; healthMode = 'port'; appExe = ''; appProcess = ''; pnpmCmd = '' }
[System.IO.File]::WriteAllText((Join-Path $Shadow 'config-webtest.json'),   ($webtestCfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $Shadow 'config-othertest.json'), ($otherCfg   | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

# defaults 用例要在"没有任何运行模式文件"的干净影子目录里跑
$cleanShadow = Join-Path $env:TEMP ('dshguard-clean-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $cleanShadow | Out-Null

$cases = @(
    @{ Name = 'defaults';    Shadow = $cleanShadow; Desc = '不配任何新模式参数 = 老行为' }
    @{ Name = 'file-cfg';    Shadow = $Shadow;      Desc = '运行模式文件（按 profile 分开）' }
    @{ Name = 'process-pos'; Shadow = $Shadow;      Desc = '官方端在跑 → 判活成功（阳性）' }
    @{ Name = 'process-neg'; Shadow = $Shadow;      Desc = '进程不存在 → 判死不健康（阴性）' }
)

$failed = @()
foreach ($c in $cases) {
    Write-Host ("--- {0}：{1}" -f $c.Name, $c.Desc)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Case $c.Name -Shadow $c.Shadow 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($out)) { Write-Host ("    {0}" -f $line) }
    if ($code -ne 0) { $failed += $c.Name }
    Write-Host ''
}

if ($failed.Count -eq 0) {
    Write-Host '结论：全部通过 —— 进程模式可用，且"不配置 = 老行为"成立' -ForegroundColor Green
    exit 0
}
Write-Host ("结论：失败用例 {0} 个：{1}" -f $failed.Count, ($failed -join ', ')) -ForegroundColor Red
exit 1
