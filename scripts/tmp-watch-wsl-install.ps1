#Requires -Version 5.1
param(
    [int]$HostPid,
    [int]$ChildPid,
    [string]$Repo
)
$ErrorActionPreference = 'Continue'
$live = Join-Path $Repo 'logs\wsl\install-live.json'
$result = Join-Path $Repo 'reports\wsl-install-result.json'
$exitFile = Join-Path $Repo 'logs\wsl\install-host.exitcode.txt'
$deadline = [DateTime]::UtcNow.AddMinutes(30)

function Test-Alive([int]$ProcId) {
    if ($ProcId -le 0) { return $false }
    try { Get-Process -Id $ProcId -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

while ([DateTime]::UtcNow -lt $deadline) {
    $hostAlive = Test-Alive $HostPid
    $childAlive = Test-Alive $ChildPid
    if (-not $hostAlive -and -not $childAlive) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $result) {
            Write-Output 'DONE'
            exit 0
        }
        $code = if (Test-Path -LiteralPath $exitFile) { [IO.File]::ReadAllText($exitFile).Trim() } else { 'missing' }
        Write-Output ("FAILED: install host exited without result json; exit_file=" + $code)
        exit 1
    }
    Start-Sleep -Seconds 15
}
Write-Output 'FAILED: 30m timeout; install host still running'
exit 1
