#Requires -Version 5.1
param([int]$PollSec = 15, [int]$MaxWaitSec = 700)
$ErrorActionPreference = 'Continue'
$logDir = 'C:\Users\Administrator\Desktop\01_项目与代码\高斯破溅\logs\sfm'
$stdout = Join-Path $logDir 'setup-env-stdout.txt'
$stderr = Join-Path $logDir 'setup-env-stderr.txt'
$summary = Join-Path $logDir 'setup-env-summary.json'
$deadline = (Get-Date).AddSeconds($MaxWaitSec)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $summary) {
        $txt = Get-Content -LiteralPath $summary -Raw -ErrorAction SilentlyContinue
        if ($txt -match '"exit_code":\s*0') { Write-Output 'DONE'; exit 0 }
        if ($txt -match '"timed_out":\s*true') { Write-Output 'FAILED timeout'; exit 1 }
        if ($txt -match '"exit_code":\s*([1-9][0-9]*)') { Write-Output "FAILED exit=$($Matches[1])"; exit 1 }
    }
    Start-Sleep -Seconds $PollSec
}
Write-Output 'FAILED wait-exceeded'
exit 1
