#Requires -Version 5.1
# Download and verify pinned WSL MSI + Ubuntu 22.04.5 .wsl. Does not run msiexec.
[CmdletBinding()]
param([string]$Repo = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\WinProcess.ps1')
if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
}
$cache = Join-Path $Repo 'env\cache\wsl'
$logDir = Join-Path $Repo 'logs\wsl'
New-Item -ItemType Directory -Force -Path $cache, $logDir | Out-Null

$items = @(
    [ordered]@{
        name = 'wsl.2.7.13.0.x64.msi'
        url = 'https://github.com/microsoft/WSL/releases/download/2.7.13/wsl.2.7.13.0.x64.msi'
        sha256 = 'a3505a50f4cc585551d11d9de824ba4375448d7a68f2e71d3fb315fa986fc754'
        bytes = 258985984
    },
    [ordered]@{
        name = 'ubuntu-22.04.5-wsl-amd64.wsl'
        url = 'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-wsl-amd64.wsl'
        sha256 = '4499c4fe257f2fc83145b429ce211a0a43fd590e70d6261ede616210947d9f8f'
        bytes = 360684292
    }
)

$report = [ordered]@{
    schema = 'gs.wsl.download.v1'
    started_utc = [DateTime]::UtcNow.ToString('o')
    msiexec_ran = $false
    items = @()
}

$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$okAll = $true
foreach ($it in $items) {
    $dest = Join-Path $cache $it.name
    $need = $true
    if (Test-Path -LiteralPath $dest) {
        $h = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -eq $it.sha256) { $need = $false }
        else { Remove-Item -LiteralPath $dest -Force }
    }
    if ($need) {
        $cap = Invoke-ProcessCaptured -FilePath $curl -ArgumentList @(
            '-L', '--fail', '--retry', '3', '--output', $dest, $it.url
        ) -StdoutPath (Join-Path $logDir ("curl-{0}.log" -f $it.name)) -StderrPath (Join-Path $logDir ("curl-{0}.err" -f $it.name)) -TimeoutSec 600 -NoStdin
        if (-not $cap.transport_ok -or $cap.exit_code -ne 0) {
            $report.items += [ordered]@{ name = $it.name; ok = $false; error = "curl exit=$($cap.exit_code) timeout=$($cap.timed_out)" }
            $okAll = $false
            continue
        }
    }
    $len = [IO.FileInfo]::new($dest).Length
    $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
    $sig = $null
    if ($it.name -like '*.msi') {
        $s = Get-AuthenticodeSignature -FilePath $dest
        $sig = [ordered]@{
            status = [string]$s.Status
            subject = $(if ($s.SignerCertificate) { $s.SignerCertificate.Subject } else { $null })
            thumbprint = $(if ($s.SignerCertificate) { $s.SignerCertificate.Thumbprint } else { $null })
        }
    }
    $ok = ($hash -eq $it.sha256)
    if ($sig -and $sig.status -ne 'Valid') { $ok = $false }
    if ($sig -and $sig.subject -notmatch 'Microsoft') { $ok = $false }
    $report.items += [ordered]@{
        name = $it.name; path = $dest; ok = $ok; bytes = $len
        sha256 = $hash; expected_sha256 = $it.sha256; signature = $sig; skipped_download = (-not $need)
    }
    if (-not $ok) { $okAll = $false }
}

$report.ended_utc = [DateTime]::UtcNow.ToString('o')
$report.all_ok = $okAll
$path = Join-Path $Repo 'reports\wsl-download-result.json'
[IO.File]::WriteAllText($path, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Output $path
if ($okAll) { exit 0 } else { exit 1 }
