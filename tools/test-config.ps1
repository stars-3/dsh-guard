<#
  test-config.ps1 —— 钉住两件"曾经静默失效"的事。

  为什么值得单独写一个测试：这两个 bug 都**不报错**，只是"你设了没用"，
  在真机上表现为"看门狗行为跟配置不符"，极难归因。
    ① DSHGUARD_* 配置覆盖：曾经因为 -replace 大小写不敏感而**全部失效**
    ② 端口优先级：显式传参必须赢过 DSH_WEB_URL（否则第二个实例会盯着第一个实例的端口）

  用法： powershell -ExecutionPolicy Bypass -File tools\test-config.ps1
    exit 0 = 全过
#>
$ErrorActionPreference = 'Stop'
$proj = Split-Path $PSScriptRoot -Parent
$bootstrap = Join-Path $proj 'lib\guard-bootstrap.ps1'

$bad = 0
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Host ("  OK   {0,-32} = {1}" -f $name, $got) -ForegroundColor Green }
    else { Write-Host ("  FAIL {0,-32} = {1}  (期望 {2})" -f $name, $got, $want) -ForegroundColor Red; $script:bad++ }
}

# 影子目录：只用来验路径推导，不创建任何东西
$env:DSHGUARD_HOME = Join-Path $env:TEMP ('guardcfg-test-' + [guid]::NewGuid().ToString('N'))

Write-Host '=== ① DSHGUARD_* 配置覆盖 ===' -ForegroundColor Cyan
$env:DSHGUARD_QUARANTINE_SEC      = '42'
$env:DSHGUARD_KEEP_SNAPSHOTS      = '5'
$env:DSHGUARD_WATCH_INTERVAL_SEC  = '11'
$env:DSHGUARD_AUTO_RESTART        = '0'
$env:DSHGUARD_MAX_ROLLBACK_ATTEMPTS = '7'
. $bootstrap -ProfileName web
Check 'Cfg.QuarantineSec'      $script:Cfg.QuarantineSec      42
Check 'Cfg.KeepSnapshots'      $script:Cfg.KeepSnapshots      5
Check 'Cfg.WatchIntervalSec'   $script:Cfg.WatchIntervalSec   11
Check 'Cfg.AutoRestart'        $script:Cfg.AutoRestart        'False'
Check 'Cfg.MaxRollbackAttempts' $script:Cfg.MaxRollbackAttempts 7
Check 'GuardHome 跟着走'       (Split-Path $script:GuardHome -Leaf).StartsWith('guardcfg-test-') 'True'
# 注：EnableAi 不在 Cfg 里（watchdog.ps1 在点源之后硬设 $false，插件版不做 AI 诊断），
#     所以没有 DSHGUARD_ENABLE_AI 这个东西 —— README 里也不要写它。

Write-Host ''
Write-Host '=== ② 端口优先级 ===' -ForegroundColor Cyan

# (a) 显式传参 + 环境变量都有 → 必须用显式那个
$env:DSH_WEB_URL = 'http://127.0.0.1:3101'
. $bootstrap -ProfileName web -WebPort 4321
Check '(a) port'      $script:WebPort     4321
Check '(a) portFrom'  $script:WebPortFrom 'explicit'
Check '(a) url'       $script:WebUrl      'http://127.0.0.1:4321'

# (b) 只有环境变量 → 用环境变量
. $bootstrap -ProfileName web
Check '(b) port'      $script:WebPort     3101
Check '(b) portFrom'  $script:WebPortFrom 'env'
Check '(b) url'       $script:WebUrl      'http://127.0.0.1:3101'

# (c) 两个都没有 → 3080
Remove-Item Env:DSH_WEB_URL -ErrorAction SilentlyContinue
. $bootstrap -ProfileName web
Check '(c) port'      $script:WebPort     3080
Check '(c) portFrom'  $script:WebPortFrom 'default'

# 清理
foreach ($n in 'DSHGUARD_QUARANTINE_SEC','DSHGUARD_KEEP_SNAPSHOTS','DSHGUARD_WATCH_INTERVAL_SEC',
               'DSHGUARD_AUTO_RESTART','DSHGUARD_MAX_ROLLBACK_ATTEMPTS','DSHGUARD_HOME') {
    Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue
}

Write-Host ''
if ($bad) { Write-Host "结论：$bad 项不合格" -ForegroundColor Red; exit 1 }
Write-Host '结论：全部通过' -ForegroundColor Green
exit 0
