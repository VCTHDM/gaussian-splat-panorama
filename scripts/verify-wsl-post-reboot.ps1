#Requires -Version 5.1
# Post-reboot WSL readiness: last boot, CBS pending, IWslSupport, then WSL/Ubuntu/GPU.
# Does not install MSI, Enable-Feature, download Ubuntu, or reboot.
[CmdletBinding()]
param(
    [switch]$SkipImport,
    [switch]$SkipGpu
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
try { cmd /c "chcp 65001 >nul" | Out-Null } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\WinProcess.ps1')
$Repo = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$logDir = Join-Path $Repo 'logs\wsl'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$wslPreferred = 'C:\Program Files\WSL\wsl.exe'
$distroName = 'GS-Ubuntu2204'
$distroRoot = Join-Path $Repo 'env\wsl\GS-Ubuntu2204'
$ubPath = Join-Path $Repo 'env\cache\wsl\ubuntu-22.04.5-wsl-amd64.wsl'
$iwslKey = 'HKLM:\Software\Classes\Interface\{46f3c96d-ffa3-42f0-b052-52f5e7ecbb08}'
$cbsPendingKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$cbsEnableLocal = [datetime]'2026-09-09T21:05:32'
$resultPath = Join-Path $Repo 'reports\wsl-post-reboot-verify.json'
$livePath = Join-Path $logDir 'post-reboot-verify-live.json'

function Save-Json([string]$Path, $Obj) {
    [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}

function Read-TextSafe([string]$Path, [int]$MaxChars = 4000) {
    return Get-FileHeadText $Path $MaxChars
}

$report = [ordered]@{
    schema = 'gs.wsl.post-reboot.verify.v1'
    started_utc = [DateTime]::UtcNow.ToString('o')
    started_local = [DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ssK')
    executor = 'grok-4.6-build'
    host_pid = $PID
    permission_mode = 'auto'
    approval_mechanism_changed = $false
    reboot_performed = $false
    reboot_required = $null
    ubuntu_ready = $false
    gpu_visible = $false
    msi_reinstalled = $false
    feature_enable_rerun = $false
    ubuntu_redownloaded = $false
    steps = New-Object System.Collections.Generic.List[object]
}

function Add-Step([string]$Name, $Ok, $Detail) {
    $script:report.steps.Add([ordered]@{
        name = $Name
        ok = [bool]$Ok
        detail = $Detail
        utc = [DateTime]::UtcNow.ToString('o')
    })
}

Save-Json $livePath ([ordered]@{ status = 'starting'; host_pid = $PID; utc = $report.started_utc })

# --- 1. Last boot / CBS / IWslSupport (no DISM) ---
$os = $null
$lastBoot = $null
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $lastBoot = [datetime]$os.LastBootUpTime
} catch {
    Add-Step 'last-boot' $false $_.Exception.Message
}

$cbsPending = Test-Path -LiteralPath $cbsPendingKey
$wuReboot = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$iwslPresent = Test-Path -LiteralPath $iwslKey
$iwslDefault = $null
if ($iwslPresent) {
    try { $iwslDefault = (Get-ItemProperty -LiteralPath $iwslKey -ErrorAction Stop).'(default)' } catch { $iwslDefault = $_.Exception.Message }
}

$pendingRename = $null
try {
    $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) {
        $pendingRename = @($sm.PendingFileRenameOperations)
    }
} catch { }

$report.last_boot_utc = if ($lastBoot) { $lastBoot.ToUniversalTime().ToString('o') } else { $null }
$report.last_boot_local = if ($lastBoot) { $lastBoot.ToString('yyyy-MM-ddTHH:mm:ssK') } else { $null }
$report.cbs_enable_local = $cbsEnableLocal.ToString('yyyy-MM-ddTHH:mm:ss')
$report.boot_after_cbs_enable = if ($lastBoot) { $lastBoot -gt $cbsEnableLocal } else { $null }
$report.cbs_reboot_pending = $cbsPending
$report.windows_update_reboot_required = $wuReboot
$report.pending_file_rename_count = if ($pendingRename) { $pendingRename.Count } else { 0 }
$report.iwslsupport_present = $iwslPresent
$report.iwslsupport_default = $iwslDefault
$report.iwslsupport_key = 'HKLM\Software\Classes\Interface\{46f3c96d-ffa3-42f0-b052-52f5e7ecbb08}'

Add-Step 'last-boot' ($null -ne $lastBoot) ("last_boot_local=$($report.last_boot_local); after_cbs=$($report.boot_after_cbs_enable)")
Add-Step 'cbs-reboot-pending' $true ("Test-Path $cbsPendingKey => $cbsPending")
Add-Step 'iwslsupport' $iwslPresent ("Test-Path $iwslKey => $iwslPresent default=$iwslDefault")

$stillNeedReboot = $false
$rebootReason = $null
if (-not $lastBoot) {
    $stillNeedReboot = $true
    $rebootReason = 'LastBootUpTime query failed'
} elseif (-not $report.boot_after_cbs_enable) {
    $stillNeedReboot = $true
    $rebootReason = 'LastBootUpTime is not after CBS enable 2026-09-09 21:05:32'
} elseif ($cbsPending) {
    $stillNeedReboot = $true
    $rebootReason = 'CBS RebootPending key still present'
} elseif (-not $iwslPresent) {
    # After a real reboot, missing IWslSupport is a different failure, not "still waiting to reboot"
    $stillNeedReboot = $false
}

$report.reboot_performed = [bool]($lastBoot -and $report.boot_after_cbs_enable)
$report.reboot_required = [bool]$stillNeedReboot
$report.reboot_reason = $rebootReason

Save-Json $livePath ([ordered]@{
    status = 'boot-checked'
    reboot_performed = $report.reboot_performed
    reboot_required = $report.reboot_required
    cbs_reboot_pending = $cbsPending
    iwslsupport_present = $iwslPresent
    utc = [DateTime]::UtcNow.ToString('o')
})

if ($stillNeedReboot) {
    $report.status = 'awaiting_windows_restart'
    $report.next_owner = 'user_restart_then_codex'
    $report.next_task = '.grok-tasks/09-after-reboot-ubuntu.md'
    $report.ended_utc = [DateTime]::UtcNow.ToString('o')
    Save-Json $resultPath $report
    Save-Json $livePath ([ordered]@{ status = 'stopped_awaiting_reboot'; reason = $rebootReason; utc = $report.ended_utc })
    Write-Output $resultPath
    exit 20
}

# --- 2. WSL exe / service / version / status / list ---
$wslExe = $null
if ([IO.File]::Exists($wslPreferred)) {
    $wslExe = $wslPreferred
} elseif ([IO.File]::Exists((Join-Path $env:SystemRoot 'System32\wsl.exe'))) {
    $wslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
}
$report.wsl_exe = $wslExe
$report.wsl_preferred_exists = [IO.File]::Exists($wslPreferred)
$report.wsl_system32_exists = [IO.File]::Exists((Join-Path $env:SystemRoot 'System32\wsl.exe'))
Add-Step 'wsl-exe' ($null -ne $wslExe) ("preferred=$wslPreferred exists=$($report.wsl_preferred_exists); system32=$($report.wsl_system32_exists); using=$wslExe")

$svc = $null
try { $svc = Get-Service -Name 'WslService' -ErrorAction Stop } catch { }
$report.wslservice = $null
if ($svc) {
    $report.wslservice = [ordered]@{
        name = $svc.Name
        status = [string]$svc.Status
        start_type = [string]$svc.StartType
    }
    try {
        $cim = Get-CimInstance Win32_Service -Filter "Name='WslService'" -ErrorAction Stop
        $report.wslservice.win32_exit_code = $cim.ExitCode
        $report.wslservice.process_id = $cim.ProcessId
        $report.wslservice.state = $cim.State
        $report.wslservice.start_mode = $cim.StartMode
    } catch { }
}
Add-Step 'wslservice-query' ($null -ne $svc) ($(if ($svc) { "Status=$($svc.Status) StartType=$($svc.StartType)" } else { 'WslService not found' }))

if ($svc -and $svc.Status -ne 'Running' -and $iwslPresent) {
    try {
        Start-Service -Name 'WslService' -ErrorAction Stop
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name 'WslService'
        $report.wslservice.status = [string]$svc.Status
        $report.wslservice.start_attempted = $true
        Add-Step 'wslservice-start' ($svc.Status -eq 'Running') ("after Start-Service Status=$($svc.Status)")
    } catch {
        $report.wslservice.start_attempted = $true
        $report.wslservice.start_error = $_.Exception.Message
        Add-Step 'wslservice-start' $false $_.Exception.Message
    }
}

$wslQueries = @()
if ($wslExe) {
    foreach ($q in @(
        [ordered]@{ name = 'version'; args = @('--version') },
        [ordered]@{ name = 'status'; args = @('--status') },
        [ordered]@{ name = 'list'; args = @('--list', '--verbose') }
    )) {
        $stdout = Join-Path $logDir ("post-reboot-wsl-$($q.name).txt")
        $stderr = Join-Path $logDir ("post-reboot-wsl-$($q.name).err")
        $cap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @($q.args) -StdoutPath $stdout -StderrPath $stderr -TimeoutSec 15 -NoStdin
        $item = [ordered]@{
            name = $q.name
            args = $q.args
            exit_code = $cap.exit_code
            timed_out = [bool]$cap.timed_out
            killed_self_child = [bool]$cap.killed_self_child
            transport_ok = [bool]$cap.transport_ok
            duration_ms = $cap.duration_ms
            pid = $cap.pid
            stdout = Read-TextSafe $stdout 4000
            stderr = Read-TextSafe $stderr 2000
            stdout_path = $stdout
            stderr_path = $stderr
        }
        $wslQueries += $item
        Add-Step ("wsl-$($q.name)") ($cap.transport_ok -and $cap.exit_code -eq 0) ("exit=$($cap.exit_code) timed_out=$($cap.timed_out) duration_ms=$($cap.duration_ms)")
    }
}
$report.wsl_queries = $wslQueries

$listCombined = ''
foreach ($q in $wslQueries) {
    if ($q.name -eq 'list') {
        $listCombined = ([string]$q.stdout) + "`n" + ([string]$q.stderr)
    }
}
$hasGs = [bool]($listCombined -match 'GS-Ubuntu2204')
$report.gs_ubuntu_listed = $hasGs

$otherDistros = @()
if ($listCombined) {
    foreach ($line in ($listCombined -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -and $t -notmatch '^(NAME|NAME\s+STATE)' -and $t -notmatch 'GS-Ubuntu2204' -and $t -notmatch 'Windows Subsystem' -and $t -notmatch '^-+$') {
            $otherDistros += $t
        }
    }
}
$report.other_distro_lines = $otherDistros

$serviceUsable = $false
if ($svc -and [string]$svc.Status -eq 'Running') { $serviceUsable = $true }
$versionOk = $false
foreach ($q in $wslQueries) {
    if ($q.name -eq 'version' -and $q.exit_code -eq 0) { $versionOk = $true }
}
$report.wsl_usable = [bool]($iwslPresent -and $serviceUsable -and $versionOk)

if (-not $report.wsl_usable) {
    $report.status = 'wsl_not_usable'
    $report.ubuntu_ready = $false
    $report.gpu_visible = $false
    $report.next_owner = 'codex'
    $report.next_task = '.grok-tasks/09-after-reboot-ubuntu.md'
    $report.ended_utc = [DateTime]::UtcNow.ToString('o')
    Save-Json $resultPath $report
    Save-Json $livePath ([ordered]@{ status = $report.status; iwsl = $iwslPresent; service = $(if ($svc) { [string]$svc.Status } else { $null }); utc = $report.ended_utc })
    Write-Output $resultPath
    exit 21
}

# --- 3. Import only if needed ---
$report.import = [ordered]@{
    attempted = $false
    skipped_exists = $false
    exit_code = $null
    timed_out = $false
}
if ($hasGs) {
    $report.import.skipped_exists = $true
    Add-Step 'import' $true 'GS-Ubuntu2204 already listed; reuse, no import'
} elseif ($SkipImport) {
    Add-Step 'import' $false 'SkipImport set and distro not listed'
} else {
    if (-not [IO.File]::Exists($ubPath)) {
        Add-Step 'import' $false "ubuntu cache missing: $ubPath"
        $report.status = 'ubuntu_cache_missing'
        $report.ended_utc = [DateTime]::UtcNow.ToString('o')
        Save-Json $resultPath $report
        Write-Output $resultPath
        exit 22
    }
    New-Item -ItemType Directory -Force -Path $distroRoot | Out-Null
    $report.import.attempted = $true
    Save-Json $livePath ([ordered]@{ status = 'importing'; utc = [DateTime]::UtcNow.ToString('o') })
    $cap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @(
        '--import', $distroName, $distroRoot, $ubPath, '--version', '2'
    ) -StdoutPath (Join-Path $logDir 'post-reboot-import.txt') -StderrPath (Join-Path $logDir 'post-reboot-import.err') -TimeoutSec 600 -NoStdin
    $report.import.exit_code = $cap.exit_code
    $report.import.timed_out = [bool]$cap.timed_out
    $report.import.transport_ok = [bool]$cap.transport_ok
    $report.import.duration_ms = $cap.duration_ms
    $report.import.pid = $cap.pid
    $report.import.stdout = Read-TextSafe (Join-Path $logDir 'post-reboot-import.txt') 4000
    $report.import.stderr = Read-TextSafe (Join-Path $logDir 'post-reboot-import.err') 2000
    Add-Step 'import' ($cap.transport_ok -and $cap.exit_code -eq 0) ("exit=$($cap.exit_code) timed_out=$($cap.timed_out) duration_ms=$($cap.duration_ms)")

    $listAfter = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @('--list', '--verbose') -StdoutPath (Join-Path $logDir 'post-reboot-wsl-list-after.txt') -StderrPath (Join-Path $logDir 'post-reboot-wsl-list-after.err') -TimeoutSec 15 -NoStdin
    $report.import.list_after_exit = $listAfter.exit_code
    $report.import.list_after = Read-TextSafe (Join-Path $logDir 'post-reboot-wsl-list-after.txt') 4000
    $hasGs = [bool]((([string]$report.import.list_after) + [string](Read-TextSafe (Join-Path $logDir 'post-reboot-wsl-list-after.err') 2000)) -match 'GS-Ubuntu2204')
    $report.gs_ubuntu_listed = $hasGs
}

# --- 4. GPU / OS probe as root ---
$report.linux_probes = @()
if ($hasGs -and -not $SkipGpu) {
    $linuxCmds = @(
        [ordered]@{ name = 'uname'; args = @('-d', $distroName, '-u', 'root', '--', 'uname', '-a') },
        [ordered]@{ name = 'os-release'; args = @('-d', $distroName, '-u', 'root', '--', 'cat', '/etc/os-release') },
        [ordered]@{ name = 'nvidia-smi-path'; args = @('-d', $distroName, '-u', 'root', '--', 'ls', '-l', '/usr/lib/wsl/lib/nvidia-smi') },
        [ordered]@{ name = 'nvidia-smi'; args = @('-d', $distroName, '-u', 'root', '--', '/usr/lib/wsl/lib/nvidia-smi', '-L') }
    )
    foreach ($c in $linuxCmds) {
        $stdout = Join-Path $logDir ("post-reboot-linux-$($c.name).txt")
        $stderr = Join-Path $logDir ("post-reboot-linux-$($c.name).err")
        $cap = Invoke-ProcessCaptured -FilePath $wslExe -ArgumentList @($c.args) -StdoutPath $stdout -StderrPath $stderr -TimeoutSec 60 -NoStdin
        $item = [ordered]@{
            name = $c.name
            exit_code = $cap.exit_code
            timed_out = [bool]$cap.timed_out
            transport_ok = [bool]$cap.transport_ok
            duration_ms = $cap.duration_ms
            stdout = Read-TextSafe $stdout 4000
            stderr = Read-TextSafe $stderr 2000
        }
        $report.linux_probes += $item
        Add-Step ("linux-$($c.name)") ($cap.transport_ok -and $cap.exit_code -eq 0) ("exit=$($cap.exit_code) timed_out=$($cap.timed_out)")
    }
}

$osRelease = ''
$uname = ''
$nvsPathOk = $false
$nvsOk = $false
foreach ($p in $report.linux_probes) {
    if ($p.name -eq 'os-release') { $osRelease = [string]$p.stdout; if ($p.exit_code -eq 0 -and $osRelease -match '22\.04') { $report.ubuntu_22_04 = $true } }
    if ($p.name -eq 'uname') { $uname = [string]$p.stdout }
    if ($p.name -eq 'nvidia-smi-path' -and $p.exit_code -eq 0) { $nvsPathOk = $true }
    if ($p.name -eq 'nvidia-smi' -and $p.exit_code -eq 0 -and (([string]$p.stdout) -match 'NVIDIA|GPU')) { $nvsOk = $true }
}
$report.uname = $uname.Trim()
$report.os_release_excerpt = if ($osRelease.Length -gt 800) { $osRelease.Substring(0, 800) } else { $osRelease }
$report.ubuntu_ready = [bool]($hasGs -and $report.ubuntu_22_04 -and $uname)
$report.gpu_visible = [bool]($nvsPathOk -or $nvsOk)
$report.gpu_nvidia_smi_ok = $nvsOk
$report.gpu_nvidia_smi_path_ok = $nvsPathOk

if ($report.ubuntu_ready -and $report.gpu_visible) {
    $report.status = 'ready_for_sfm'
    $report.next_owner = 'codex'
    $report.next_task = '.grok-tasks/03-shortest-sfm.md'
} elseif ($report.ubuntu_ready) {
    $report.status = 'ubuntu_ready_gpu_not_visible'
    $report.next_owner = 'codex'
    $report.next_task = '.grok-tasks/03-shortest-sfm.md'
} else {
    $report.status = 'ubuntu_not_ready'
    $report.next_owner = 'codex'
    $report.next_task = '.grok-tasks/09-after-reboot-ubuntu.md'
}

$report.ended_utc = [DateTime]::UtcNow.ToString('o')
Save-Json $resultPath $report
Save-Json $livePath ([ordered]@{
    status = $report.status
    ubuntu_ready = $report.ubuntu_ready
    gpu_visible = $report.gpu_visible
    utc = $report.ended_utc
})
Write-Output $resultPath
if ($report.ubuntu_ready) { exit 0 } else { exit 23 }
