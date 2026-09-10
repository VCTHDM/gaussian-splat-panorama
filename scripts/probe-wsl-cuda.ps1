#Requires -Version 5.1
# Probe NVIDIA visibility inside GS-Ubuntu2204. Does not download CUDA/torch.
[CmdletBinding()]
param([string]$Distro = 'GS-Ubuntu2204')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\WinProcess.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$logDir = Join-Path $repo 'logs\wsl'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$report = [ordered]@{
    schema = 'gs.wsl.cuda-probe.v1'
    distro = $Distro
    wsl_exists = [IO.File]::Exists($wsl)
    started_utc = [DateTime]::UtcNow.ToString('o')
    torch_downloaded = $false
    pgsr_compiled = $false
}

if (-not $report.wsl_exists) {
    $report.error = 'wsl.exe missing'
    $path = Join-Path $repo 'reports\wsl-cuda-probe.json'
    [IO.File]::WriteAllText($path, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Output $path
    exit 2
}

$cmds = @(
    [ordered]@{ name = 'uname'; args = @('-d', $Distro, '--', 'uname', '-a') },
    [ordered]@{ name = 'os-release'; args = @('-d', $Distro, '--', 'bash', '-lc', 'cat /etc/os-release') },
    [ordered]@{ name = 'nvidia-smi'; args = @('-d', $Distro, '--', 'bash', '-lc', 'command -v nvidia-smi; ls -l /usr/lib/wsl/lib 2>/dev/null | head; nvidia-smi -L || nvidia-smi') },
    [ordered]@{ name = 'cuda-lib'; args = @('-d', $Distro, '--', 'bash', '-lc', 'ls /usr/lib/wsl/lib/libcuda.so* 2>/dev/null; echo ---; ls /dev/dxg 2>/dev/null') }
)
$report.probes = @()
foreach ($c in $cmds) {
    $cap = Invoke-ProcessCaptured -FilePath $wsl -ArgumentList @($c.args) -StdoutPath (Join-Path $logDir ("cuda-$($c.name).txt")) -StderrPath (Join-Path $logDir ("cuda-$($c.name).err")) -TimeoutSec 60 -NoStdin
    $report.probes += [ordered]@{
        name = $c.name
        exit_code = $cap.exit_code
        timed_out = [bool]$cap.timed_out
        stdout = Get-FileHeadText (Join-Path $logDir ("cuda-$($c.name).txt")) 4000
        stderr = Get-FileHeadText (Join-Path $logDir ("cuda-$($c.name).err")) 2000
    }
}
$nvs = ($report.probes | Where-Object { $_.name -eq 'nvidia-smi' } | Select-Object -First 1)
$report.cuda_visible = [bool]($nvs -and $nvs.exit_code -eq 0 -and $nvs.stdout -match 'NVIDIA|CUDA')
$report.ended_utc = [DateTime]::UtcNow.ToString('o')
$out = Join-Path $repo 'reports\wsl-cuda-probe.json'
[IO.File]::WriteAllText($out, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Output $out
if ($report.cuda_visible) { exit 0 } else { exit 1 }
