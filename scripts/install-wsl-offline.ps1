#Requires -Version 5.1
# Download and install pinned stable WSL MSI + Ubuntu 22.04 distro. No auto-reboot.
[CmdletBinding()]
param(
    [string]$Repo = '',
    [switch]$SkipMsiIfPresent,
    [switch]$NoDownload
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { cmd /c "chcp 65001 >nul" | Out-Null } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\WinProcess.ps1')
if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
}

$cache = Join-Path $Repo 'env\cache\wsl'
$distroRoot = Join-Path $Repo 'env\wsl\GS-Ubuntu2204'
$logDir = Join-Path $Repo 'logs\wsl'
New-Item -ItemType Directory -Force -Path $cache, $logDir, (Join-Path $Repo 'env\wsl') | Out-Null

$msiUrl = 'https://github.com/microsoft/WSL/releases/download/2.7.13/wsl.2.7.13.0.x64.msi'
$msiSha = 'a3505a50f4cc585551d11d9de824ba4375448d7a68f2e71d3fb315fa986fc754'
$msiName = 'wsl.2.7.13.0.x64.msi'
$msiExpectedBytes = 258985984

$ubUrl = 'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-wsl-amd64.wsl'
$ubSha = '4499c4fe257f2fc83145b429ce211a0a43fd590e70d6261ede616210947d9f8f'
$ubName = 'ubuntu-22.04.5-wsl-amd64.wsl'
$ubExpectedBytes = 360684292
$downloadCapBytes = 4GB

$report = [ordered]@{
    schema = 'gs.wsl.install.v1'
    started_utc = [DateTime]::UtcNow.ToString('o')
    pinned = [ordered]@{
        wsl_msi = [ordered]@{ url = $msiUrl; sha256 = $msiSha; bytes = $msiExpectedBytes; version = '2.7.13'; prerelease = $false }
        ubuntu = [ordered]@{ url = $ubUrl; sha256 = $ubSha; bytes = $ubExpectedBytes; name = 'GS-Ubuntu2204'; version = '22.04.5' }
    }
    steps = New-Object System.Collections.Generic.List[object]
    reboot_required = $false
    reboot_performed = $false
    user_action_required = $null
    ready_to_start_distro = $false
}

function Add-Step($Name, $Ok, $Detail) {
    $script:report.steps.Add([ordered]@{ name = $Name; ok = [bool]$Ok; detail = $Detail; utc = [DateTime]::UtcNow.ToString('o') })
    $line = ('[{0}] {1} :: {2}' -f $(if ($Ok) { 'OK' } else { 'FAIL' }), $Name, $Detail)
    Write-Host $line
    [IO.File]::AppendAllText((Join-Path $logDir 'install-trace.log'), $line + "`r`n", [Text.UTF8Encoding]::new($false))
}

function Get-FreeBytes([string]$Path) {
    $root = [IO.Path]::GetPathRoot($Path)
    $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='$($root.TrimEnd('\'))'")
    return [int64]$d.FreeSpace
}

function Save-Report {
    $script:report.ended_utc = [DateTime]::UtcNow.ToString('o')
    $path = Join-Path $Repo 'reports\wsl-install-result.json'
    [IO.File]::WriteAllText($path, ($script:report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    return $path
}

function Find-WslExe {
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\wsl.exe'),
        (Join-Path ${env:ProgramFiles} 'WSL\wsl.exe'),
        (Join-Path ${env:ProgramFiles} 'Windows Subsystem for Linux\wsl.exe')
    )
    $found = @()
    foreach ($c in $candidates) {
        $exists = [IO.File]::Exists($c)
        $found += [ordered]@{ path = $c; exists = $exists }
        if ($exists) { return [pscustomobject]@{ path = $c; candidates = $found } }
    }
    $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and [IO.File]::Exists($cmd.Source)) {
        $found += [ordered]@{ path = $cmd.Source; exists = $true; via = 'Get-Command' }
        return [pscustomobject]@{ path = $cmd.Source; candidates = $found }
    }
    return [pscustomobject]@{ path = $null; candidates = $found }
}

function Get-Download([string]$Url, [string]$Dest, [string]$Sha, [int64]$ExpectedBytes) {
    if (Test-Path -LiteralPath $Dest) {
        $h = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -eq $Sha.ToLowerInvariant()) {
            Add-Step "download-skip:$([IO.Path]::GetFileName($Dest))" $true "already present sha256 ok"
            return $true
        }
        if ($NoDownload) {
            Add-Step "download-local:$([IO.Path]::GetFileName($Dest))" $false "NoDownload hash mismatch local=$h expected=$Sha"
            return $false
        }
        Add-Step "download-reget:$([IO.Path]::GetFileName($Dest))" $true "hash mismatch local=$h expected=$Sha"
        Remove-Item -LiteralPath $Dest -Force
    }
    if ($NoDownload) {
        Add-Step "download-local:$([IO.Path]::GetFileName($Dest))" $false 'NoDownload and local file missing'
        return $false
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $dlLog = Join-Path $logDir ("curl-{0}.log" -f [IO.Path]::GetFileName($Dest))
    $cap = Invoke-ProcessCaptured -FilePath $curl -ArgumentList @(
        '-L', '--fail', '--retry', '3', '--retry-all-errors',
        '--output', $Dest, $Url
    ) -StdoutPath $dlLog -StderrPath ($dlLog + '.err') -TimeoutSec 600 -NoStdin
    if (-not $cap.transport_ok -or $cap.exit_code -ne 0) {
        Add-Step "download:$([IO.Path]::GetFileName($Dest))" $false "curl exit=$($cap.exit_code) timeout=$($cap.timed_out) err=$($cap.error)"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Dest)) {
        Add-Step "download:$([IO.Path]::GetFileName($Dest))" $false 'file missing after curl'
        return $false
    }
    $len = [IO.FileInfo]::new($Dest).Length
    $h = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash.ToLowerInvariant()
    $ok = ($h -eq $Sha.ToLowerInvariant())
    Add-Step "hash:$([IO.Path]::GetFileName($Dest))" $ok "bytes=$len expected_bytes=$ExpectedBytes sha=$h"
    return $ok
}

# --- space ---
$free = Get-FreeBytes $cache
$need = [int64]($msiExpectedBytes + $ubExpectedBytes + 2GB)
$report.disk = [ordered]@{ cache = $cache; free_bytes = $free; free_gib = [math]::Round($free / 1GB, 2); need_bytes = $need }
if ($free -lt $need) {
    Add-Step 'disk' $false "free=$free need=$need"
    $report.user_action_required = 'free disk space on C:'
    Save-Report | Out-Null
    exit 10
}
Add-Step 'disk' $true ("free_gib={0}" -f [math]::Round($free / 1GB, 2))
if (($msiExpectedBytes + $ubExpectedBytes) -gt $downloadCapBytes) {
    Add-Step 'download-cap' $false 'planned downloads exceed 4GB cap'
    Save-Report | Out-Null
    exit 11
}
Add-Step 'download-cap' $true 'MSI+Ubuntu ~591MB < 4GB'

# --- no competing same-target install ---
$related = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^(msiexec|wsl|wslservice|wslhost|wslrelay)\.exe$'
})
$sameTarget = @($related | Where-Object {
    $cmd = [string]$_.CommandLine
    ($cmd -match 'wsl\.2\.7\.13') -or ($cmd -match 'GS-Ubuntu2204')
})
$report.pre_processes = @($related | ForEach-Object {
    [ordered]@{ pid = $_.ProcessId; name = $_.Name; cmd = $_.CommandLine }
})
if ($sameTarget.Count -gt 0) {
    Add-Step 'same-target-process' $false ("count=" + $sameTarget.Count)
    $report.user_action_required = 'same-target msiexec/wsl already running; not starting a second install'
    Save-Report | Out-Null
    exit 17
}
Add-Step 'same-target-process' $true ('related=' + @($related).Count)

# --- MSI ---
$msiPath = Join-Path $cache $msiName
if (-not (Get-Download $msiUrl $msiPath $msiSha $msiExpectedBytes)) {
    $report.user_action_required = 'MSI download or hash failed; do not retry blindly if 404/auth.'
    Save-Report | Out-Null
    exit 12
}
$sig = Get-AuthenticodeSignature -FilePath $msiPath
$sigOk = ($sig.Status -eq 'Valid') -and ($sig.SignerCertificate.Subject -match 'Microsoft')
$report.msi_signature = [ordered]@{
    status = [string]$sig.Status
    subject = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null })
    issuer = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Issuer } else { $null })
    thumbprint = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { $null })
}
Add-Step 'authenticode' $sigOk ("status={0} subject={1}" -f $sig.Status, $report.msi_signature.subject)
if (-not $sigOk) {
    $report.user_action_required = 'MSI Authenticode not Valid Microsoft; install aborted'
    Save-Report | Out-Null
    exit 13
}

$wslNow = [IO.File]::Exists((Join-Path $env:SystemRoot 'System32\wsl.exe'))
$msiexecLog = Join-Path $logDir 'msiexec-wsl-2.7.13.log'
$msiExit = $null
if ($wslNow -and $SkipMsiIfPresent) {
    Add-Step 'msiexec' $true 'wsl.exe already present; skipped'
    $msiExit = 0
} else {
    $msiArgs = @('/i', $msiPath, '/qn', '/norestart', '/L*v', $msiexecLog)
    $cap = Invoke-ProcessCaptured -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $msiArgs -StdoutPath (Join-Path $logDir 'msiexec-stdout.txt') -StderrPath (Join-Path $logDir 'msiexec-stderr.txt') -TimeoutSec 900 -NoStdin
    $msiExit = $cap.exit_code
    $report.msiexec = [ordered]@{
        exit_code = $msiExit
        timed_out = [bool]$cap.timed_out
        killed_self_child = [bool]$cap.killed_self_child
        pid = $cap.pid
        log = $msiexecLog
        transport_ok = [bool]$cap.transport_ok
        error = $cap.error
    }
    # 0 = success, 3010 = success reboot required
    $msiOk = ($msiExit -eq 0 -or $msiExit -eq 3010)
    Add-Step 'msiexec' $msiOk "exit=$msiExit timeout=$($cap.timed_out)"
    if ($msiExit -eq 3010) { $report.reboot_required = $true }
    if ($cap.timed_out) {
        $report.user_action_required = 'msiexec timed out; child killed; inspect msiexec log. No blind retry of system repair.'
        Save-Report | Out-Null
        exit 14
    }
    if (-not $msiOk) {
        $report.user_action_required = "msiexec exit $msiExit is not success; do not DISM-repair or retry blindly. See $msiexecLog"
        Save-Report | Out-Null
        exit 15
    }
}

$located = Find-WslExe
if (-not $located.path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not $located.path -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 1
        $located = Find-WslExe
    }
}
$wslExe = $located.path
$wslExists = [bool]$wslExe
if (-not $wslExe) { $wslExe = Join-Path $env:SystemRoot 'System32\wsl.exe' }
$report.wsl_candidates = $located.candidates
Add-Step 'wsl.exe-present' $wslExists $wslExe
$report.wsl_exe = $wslExe
$report.wsl_exe_exists = $wslExists

if ($wslExists) {
    $verCap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @('--version') -StdoutPath (Join-Path $logDir 'wsl-version.txt') -StderrPath (Join-Path $logDir 'wsl-version.err') -TimeoutSec 15 -NoStdin
    $stCap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @('--status') -StdoutPath (Join-Path $logDir 'wsl-status.txt') -StderrPath (Join-Path $logDir 'wsl-status.err') -TimeoutSec 15 -NoStdin
    $helpCap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @('--help') -StdoutPath (Join-Path $logDir 'wsl-help.txt') -StderrPath (Join-Path $logDir 'wsl-help.err') -TimeoutSec 15 -NoStdin
    $report.wsl_version = [ordered]@{
        exit_code = $verCap.exit_code; timed_out = [bool]$verCap.timed_out
        stdout = Get-FileHeadText (Join-Path $logDir 'wsl-version.txt') 4000
        stderr = Get-FileHeadText (Join-Path $logDir 'wsl-version.err') 2000
    }
    $report.wsl_status = [ordered]@{
        exit_code = $stCap.exit_code; timed_out = [bool]$stCap.timed_out
        stdout = Get-FileHeadText (Join-Path $logDir 'wsl-status.txt') 4000
        stderr = Get-FileHeadText (Join-Path $logDir 'wsl-status.err') 2000
    }
    Add-Step 'wsl --version' ($verCap.transport_ok) ("exit=$($verCap.exit_code) timeout=$($verCap.timed_out)")
    Add-Step 'wsl --status' ($stCap.transport_ok) ("exit=$($stCap.exit_code) timeout=$($stCap.timed_out)")
    $stText = (($report.wsl_status.stdout) + "`n" + ($report.wsl_status.stderr))
    if ($stText -match '(?i)reboot|restart') {
        $report.reboot_required = $true
        Add-Step 'reboot-detected-in-status' $true $stText
    }
}

# Ubuntu image always downloaded (offline prep even if reboot needed)
$ubPath = Join-Path $cache $ubName
if (-not (Get-Download $ubUrl $ubPath $ubSha $ubExpectedBytes)) {
    $report.user_action_required = 'Ubuntu .wsl download/hash failed'
    Save-Report | Out-Null
    exit 16
}

if ($report.reboot_required -and -not $wslExists) {
    $report.user_action_required = 'WSL MSI installed or pending, but wsl.exe missing until reboot. Do not auto-reboot.'
    Save-Report | Out-Null
    exit 20
}

if (-not $wslExists) {
    $report.user_action_required = 'wsl.exe still missing after MSI. Likely reboot required. Do not auto-reboot.'
    $report.reboot_required = $true
    Save-Report | Out-Null
    exit 21
}

# Distro import needs WslService. If the service is down, skip import (15s client cap, no 900s wait).
$listCap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @('--list', '--verbose') -StdoutPath (Join-Path $logDir 'wsl-list-before.txt') -StderrPath (Join-Path $logDir 'wsl-list-before.err') -TimeoutSec 15 -NoStdin
$report.distros_before = Get-FileHeadText (Join-Path $logDir 'wsl-list-before.txt') 4000
$helpText = Get-FileHeadText (Join-Path $logDir 'wsl-help.txt') 20000
$report.wsl_help_has_from_file = [bool]($helpText -match '--from-file')
$report.wsl_help_has_location = [bool]($helpText -match '--location')
$report.wsl_help_has_name = [bool]($helpText -match '--name')
$report.wsl_help_has_no_launch = [bool]($helpText -match '--no-launch')
$report.wsl_help_has_import = [bool]($helpText -match '--import')

New-Item -ItemType Directory -Force -Path $distroRoot | Out-Null

$svc = Get-CimInstance Win32_Service -Filter "Name='WslService'" -ErrorAction SilentlyContinue
$report.wsl_service = [ordered]@{
    present = [bool]$svc
    Name = $(if ($svc) { $svc.Name } else { $null })
    State = $(if ($svc) { $svc.State } else { $null })
    StartMode = $(if ($svc) { $svc.StartMode } else { $null })
    ExitCode = $(if ($svc) { $svc.ExitCode } else { $null })
}
$svcRunning = [bool]($svc -and $svc.State -eq 'Running')
Add-Step 'wsl-service-running' $svcRunning ("state=$($report.wsl_service.State) exit=$($report.wsl_service.ExitCode)")
if (-not $svcRunning) {
    Add-Step 'distro-install' $false 'skipped: WslService not running; no long import wait'
    $report.distro_install = [ordered]@{
        kind = 'skipped-service-down'
        args = @()
        exit_code = $null
        timed_out = $false
        stdout = ''
        stderr = 'WslService not running; import not attempted (15s client cap)'
    }
    $report.user_action_required = 'WslService stopped (Win32 1058 / missing IWslSupport). See reports/wsl-service-diagnosis.json. OS component enable needs explicit approval. Do not auto-reboot.'
    $report.ready_to_start_distro = $false
    $path = Save-Report
    Write-Output $path
    exit 23
}

$installArgs = $null
$installKind = $null
if ($report.wsl_help_has_from_file) {
    $installKind = 'from-file'
    $installArgs = New-Object System.Collections.Generic.List[string]
    [void]$installArgs.Add('--install')
    [void]$installArgs.Add('--from-file')
    [void]$installArgs.Add($ubPath)
    if ($report.wsl_help_has_name) { [void]$installArgs.Add('--name'); [void]$installArgs.Add('GS-Ubuntu2204') }
    if ($report.wsl_help_has_location) { [void]$installArgs.Add('--location'); [void]$installArgs.Add($distroRoot) }
    if ($report.wsl_help_has_no_launch) { [void]$installArgs.Add('--no-launch') }
} elseif ($report.wsl_help_has_import) {
    $installKind = 'import'
    $installArgs = [System.Collections.Generic.List[string]]@('--import', 'GS-Ubuntu2204', $distroRoot, $ubPath, '--version', '2')
} else {
    Add-Step 'distro-install-method' $false 'wsl.exe has neither --from-file nor --import'
    $report.user_action_required = 'wsl.exe installed but distro import flags unknown; see logs/wsl/wsl-help.txt'
    Save-Report | Out-Null
    exit 22
}

$report.distro_install = [ordered]@{ kind = $installKind; args = @($installArgs) }
$impCap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @($installArgs) -StdoutPath (Join-Path $logDir 'wsl-distro-install.txt') -StderrPath (Join-Path $logDir 'wsl-distro-install.err') -TimeoutSec 900 -NoStdin
$report.distro_install.exit_code = $impCap.exit_code
$report.distro_install.timed_out = [bool]$impCap.timed_out
$report.distro_install.stdout = Get-FileHeadText (Join-Path $logDir 'wsl-distro-install.txt') 4000
$report.distro_install.stderr = Get-FileHeadText (Join-Path $logDir 'wsl-distro-install.err') 4000
$impOk = ($impCap.transport_ok -and $impCap.exit_code -eq 0)
Add-Step 'distro-install' $impOk ("kind=$installKind exit=$($impCap.exit_code) timeout=$($impCap.timed_out)")

$listAfter = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @('--list', '--verbose') -StdoutPath (Join-Path $logDir 'wsl-list-after.txt') -StderrPath (Join-Path $logDir 'wsl-list-after.err') -TimeoutSec 15 -NoStdin
$report.distros_after = Get-FileHeadText (Join-Path $logDir 'wsl-list-after.txt') 4000
$report.distros_after_err = Get-FileHeadText (Join-Path $logDir 'wsl-list-after.err') 2000

$hasDistro = [bool](($report.distros_after + $report.distros_after_err) -match 'GS-Ubuntu2204')
Add-Step 'distro-listed' $hasDistro $report.distros_after

# Probe start only if not reboot-required
$started = $false
$startOut = $null
if ($hasDistro -and -not $report.reboot_required) {
    $echoCap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @('-d', 'GS-Ubuntu2204', '--user', 'root', '--', 'bash', '-lc', 'uname -a && cat /etc/os-release | head -n 5') -StdoutPath (Join-Path $logDir 'ubuntu-uname.txt') -StderrPath (Join-Path $logDir 'ubuntu-uname.err') -TimeoutSec 120 -NoStdin
    $startOut = Get-FileHeadText (Join-Path $logDir 'ubuntu-uname.txt') 4000
    $startErr = Get-FileHeadText (Join-Path $logDir 'ubuntu-uname.err') 4000
    $report.ubuntu_probe = [ordered]@{
        exit_code = $echoCap.exit_code; timed_out = [bool]$echoCap.timed_out
        stdout = $startOut; stderr = $startErr
    }
    $started = ($echoCap.transport_ok -and $echoCap.exit_code -eq 0)
    Add-Step 'ubuntu-start-probe' $started ("exit=$($echoCap.exit_code) timeout=$($echoCap.timed_out)")
    if (-not $started -and (($startErr + $startOut) -match '(?i)reboot|restart|0x80040326|WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED')) {
        $report.reboot_required = $true
        $report.user_action_required = 'Ubuntu import may have succeeded but VM start needs reboot. Do not auto-reboot.'
    }
    if ($started) {
        $gpuCmd = 'if [ -x /usr/lib/wsl/lib/nvidia-smi ]; then /usr/lib/wsl/lib/nvidia-smi -L; elif command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi -L; else ls -l /usr/lib/wsl/lib 2>/dev/null; command -v nvidia-smi; nvidia-smi -L; fi'
        $gpuCap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @('-d', 'GS-Ubuntu2204', '--user', 'root', '--', 'bash', '-lc', $gpuCmd) -StdoutPath (Join-Path $logDir 'ubuntu-nvidia-smi.txt') -StderrPath (Join-Path $logDir 'ubuntu-nvidia-smi.err') -TimeoutSec 60 -NoStdin
        $gpuOut = Get-FileHeadText (Join-Path $logDir 'ubuntu-nvidia-smi.txt') 4000
        $gpuErr = Get-FileHeadText (Join-Path $logDir 'ubuntu-nvidia-smi.err') 4000
        $gpuVisible = ($gpuCap.transport_ok -and $gpuCap.exit_code -eq 0 -and (($gpuOut + $gpuErr) -match 'NVIDIA|4070'))
        $report.gpu_probe = [ordered]@{
            exit_code = $gpuCap.exit_code
            timed_out = [bool]$gpuCap.timed_out
            stdout = $gpuOut
            stderr = $gpuErr
            visible = [bool]$gpuVisible
            meaning = 'driver interface only; CUDA toolkit/torch not verified'
        }
        Add-Step 'gpu-nvidia-smi' $gpuVisible ("exit=$($gpuCap.exit_code) visible=$gpuVisible")
    }
} elseif ($report.reboot_required) {
    Add-Step 'ubuntu-start-probe' $true 'skipped because reboot_required; offline files prepared'
    $report.user_action_required = 'Reboot required before WSL VM can start. User must reboot; this script will not.'
}

$report.ready_to_start_distro = [bool]$started
$report.distro_name = 'GS-Ubuntu2204'
$report.distro_location = $distroRoot
$report.set_default_ran = $false
$path = Save-Report
Write-Output $path
if ($started) { exit 0 }
if ($report.reboot_required) { exit 20 }
if ($hasDistro) { exit 20 }
exit 1
