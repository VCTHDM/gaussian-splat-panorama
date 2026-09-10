#Requires -Version 5.1
# Read-only environment doctor. Does not dump env vars or scan credential directories.
# External commands are timed: version queries 15s, DISM 60s. On timeout, only the
# child started here is killed.
[CmdletBinding()]
param(
    [string]$OutJson = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
try { cmd /c "chcp 65001 >nul" | Out-Null } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\WinProcess.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
if ([string]::IsNullOrWhiteSpace($OutJson)) {
    $OutJson = Join-Path $repo 'reports\env-doctor.json'
}

$scratch = Join-Path $repo 'logs\doctor-scratch'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

function Invoke-ExeVersion {
    # Do NOT name a parameter $Args — that is a PowerShell automatic variable.
    # Binding [string[]]$Args silently drops the caller's array; grok.exe then
    # starts with zero arguments and opens the interactive UI.
    param(
        [string]$Path,
        [string[]]$VersionArgs,
        [int]$TimeoutSec = 15
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{
            exists = $false
            path = $Path
            exit_code = $null
            timed_out = $false
            killed_self_child = $false
            stdout_head = $null
            stderr_head = $null
            duration_ms = $null
            pid = $null
            argv = @($VersionArgs)
        }
    }
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outPath = Join-Path $scratch "ver-$tag-stdout.txt"
    $errPath = Join-Path $scratch "ver-$tag-stderr.txt"
    $cap = Invoke-ProcessCaptured -FilePath $Path -ArgumentList $VersionArgs -StdoutPath $outPath -StderrPath $errPath -TimeoutSec $TimeoutSec -NoStdin
    $stdout = Get-FileHeadText $outPath 2000
    $stderr = Get-FileHeadText $errPath 2000
    $head = $null
    if ($cap.timed_out) {
        $head = "TIMEOUT after ${TimeoutSec}s; killed_self_child=$($cap.killed_self_child) pid=$($cap.pid)"
    } else {
        $combined = $(if ($stdout) { $stdout.Trim() } else { '' })
        $head = (($combined -split "`r?`n" | Select-Object -First 8) -join "`n")
        if ([string]::IsNullOrWhiteSpace($head) -and $stderr) {
            $head = (($stderr.Trim() -split "`r?`n" | Select-Object -First 8) -join "`n")
        }
    }
    return [ordered]@{
        exists = $true
        path = $Path
        exit_code = $cap.exit_code
        timed_out = [bool]$cap.timed_out
        killed_self_child = [bool]$cap.killed_self_child
        stdout_head = $head
        stderr_head = $(if ($cap.timed_out) { $stderr } else { (($stderr -split "`r?`n" | Select-Object -First 8) -join "`n") })
        duration_ms = $cap.duration_ms
        pid = $cap.pid
        argv = @($VersionArgs)
        transport_ok = [bool]$cap.transport_ok
        error = $cap.error
        stdout_path = $outPath
        stderr_path = $errPath
    }
}

$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs = Get-CimInstance Win32_ComputerSystem
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    [ordered]@{
        device = $_.DeviceID
        volume = $_.VolumeName
        size_gib = [math]::Round($_.Size / 1GB, 2)
        free_gib = [math]::Round($_.FreeSpace / 1GB, 2)
    }
})
$phys = @(Get-CimInstance Win32_DiskDrive | ForEach-Object {
    [ordered]@{
        model = $_.Model
        size_bytes = $_.Size
        index = $_.Index
        media = $_.MediaType
    }
})
$parts = @(Get-Partition | ForEach-Object {
    [ordered]@{
        disk = $_.DiskNumber
        partition = $_.PartitionNumber
        letter = [string]$_.DriveLetter
        size_gib = [math]::Round($_.Size / 1GB, 2)
    }
})

$gpu = $null
$nvsmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvsmi -and $nvsmi.Source) {
    $gpuVer = Invoke-ExeVersion -Path $nvsmi.Source -VersionArgs @(
        '--query-gpu=name,driver_version,memory.total,memory.used,memory.free',
        '--format=csv,noheader'
    ) -TimeoutSec 15
    if ($gpuVer.transport_ok -and $gpuVer.stdout_head) {
        $g = @($gpuVer.stdout_head -split ',' | ForEach-Object { $_.Trim() })
        if ($g.Count -ge 5) {
            $gpu = [ordered]@{
                name = $g[0]; driver = $g[1]
                memory_total = $g[2]; memory_used = $g[3]; memory_free = $g[4]
                query = $gpuVer
            }
        } else {
            $gpu = [ordered]@{ query = $gpuVer; parse_error = 'csv fields < 5' }
        }
    } else {
        $gpu = [ordered]@{ query = $gpuVer }
    }
}

function Feature-State([string]$Name) {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
        return [ordered]@{ name = $Name; state = [string]$f.State; restart_needed = [bool]$f.RestartNeeded; query_error = $null }
    } catch {
        return [ordered]@{ name = $Name; state = $null; restart_needed = $null; query_error = $_.Exception.Message }
    }
}

$dismExe = Join-Path $env:SystemRoot 'System32\dism.exe'
$dismCap = Invoke-ExeVersion -Path $dismExe -VersionArgs @(
    '/online', '/Get-FeatureInfo', '/FeatureName:Microsoft-Windows-Subsystem-Linux'
) -TimeoutSec 60
$dismText = $null
$dismOutFile = $null
if ($dismCap.exists) {
    $dismFiles = Get-ChildItem -LiteralPath $scratch -Filter 'ver-*-stdout.txt' | Sort-Object LastWriteTime -Descending
    # Prefer the captured stdout from this call via Get-FileHead of latest matching scratch is racy.
    # Re-read from argv-tagged files is hard; store DISM stdout_head directly.
    $dismText = $dismCap.stdout_head
}

$wslExeCandidates = @(
    "$env:SystemRoot\System32\wsl.exe",
    "$env:SystemRoot\Sysnative\wsl.exe",
    "$env:SystemRoot\SysWOW64\wsl.exe",
    "$env:LOCALAPPDATA\Microsoft\WindowsApps\wsl.exe"
)
$wslPresent = @()
foreach ($c in $wslExeCandidates) {
    $wslPresent += [ordered]@{ path = $c; exists = [IO.File]::Exists($c) }
}

$toolsPath = Join-Path $repo 'configs\tools.json'
$tools = Get-Content -LiteralPath $toolsPath -Raw -Encoding UTF8 | ConvertFrom-Json

$chocoFf = 'C:\ProgramData\chocolatey\bin\ffmpeg.exe'
$chocoProbe = 'C:\ProgramData\chocolatey\bin\ffprobe.exe'
$chocoFfTarget = 'C:\ProgramData\chocolatey\lib\ffmpeg\tools\ffmpeg\bin\ffmpeg.exe'

$colmapWhere = @()
try {
    $whereExe = Join-Path $env:SystemRoot 'System32\where.exe'
    $whereCap = Invoke-ExeVersion -Path $whereExe -VersionArgs @('colmap') -TimeoutSec 15
    if ($whereCap.stdout_head) {
        $colmapWhere = @($whereCap.stdout_head -split "`r?`n" | Where-Object { $_ -and ($_ -notmatch 'TIMEOUT') })
    }
} catch { }

$pyIso = Join-Path $repo 'env\gs-control\Scripts\python.exe'

$bcd = $null
$bcdExe = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
$bcdCap = Invoke-ExeVersion -Path $bcdExe -VersionArgs @('/enum', '{current}') -TimeoutSec 15
if ($bcdCap.transport_ok) {
    $bcdRaw = Get-FileHeadText $bcdCap.stdout_path 20000
    if (-not $bcdRaw) { $bcdRaw = [string]$bcdCap.stdout_head }
    $m = [regex]::Match($bcdRaw, 'hypervisorlaunchtype\s+\S+', 'IgnoreCase')
    if ($m.Success) { $bcd = (($m.Value -split '\s+') | Select-Object -Last 1) }
}

function Resolve-CommandPath([string]$Name) {
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return [string]$c.Source }
    return $null
}

$report = [ordered]@{
    collected_utc = [DateTime]::UtcNow.ToString('o')
    doctor_notes = @(
        'Parameter of version helper is VersionArgs, not Args (PowerShell automatic variable).',
        'External version queries timeout 15s; DISM timeout 60s; only self-started children are killed.',
        'Credential directories were not scanned; environment variables were not dumped.'
    )
    host = [ordered]@{
        os_caption = $os.Caption
        os_version = $os.Version
        os_build = $os.BuildNumber
        cpu_name = $cpu.Name
        cpu_cores = $cpu.NumberOfCores
        cpu_logical = $cpu.NumberOfLogicalProcessors
        ram_total_gib = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        ram_free_gib = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        hypervisor_present = [bool]$cs.HypervisorPresent
        manufacturer = $cs.Manufacturer
        model = $cs.Model
        bcd_hypervisorlaunchtype = $bcd
        bcd_query = $bcdCap
    }
    gpu = $gpu
    storage = [ordered]@{
        physical_disks = $phys
        partitions = $parts
        logical = $disks
        note = 'C: and D: are partitions of the same NVMe; splitting work across them does not add independent I/O.'
    }
    wsl = [ordered]@{
        wsl_exe_candidates = $wslPresent
        any_wsl_exe = [bool]($wslPresent | Where-Object { $_.exists })
        lxss_dir_exists = [IO.Directory]::Exists("$env:SystemRoot\System32\lxss")
        wslapi_dll_exists = [IO.File]::Exists("$env:SystemRoot\System32\wslapi.dll")
        optional_features = @(
            (Feature-State 'Microsoft-Windows-Subsystem-Linux'),
            (Feature-State 'VirtualMachinePlatform'),
            (Feature-State 'HypervisorPlatform'),
            (Feature-State 'Microsoft-Hyper-V-All')
        )
        dism_microsoft_windows_subsystem_linux = $dismCap
        distros = $null
        ready = $false
        gap = $null
    }
    tools = [ordered]@{
        grok = (Invoke-ExeVersion -Path $tools.grok_exe -VersionArgs @('--version') -TimeoutSec 15)
        ffmpeg_pinned = (Invoke-ExeVersion -Path $tools.ffmpeg -VersionArgs @('-version') -TimeoutSec 15)
        ffprobe_pinned = (Invoke-ExeVersion -Path $tools.ffprobe -VersionArgs @('-version') -TimeoutSec 15)
        ffmpeg_chocolatey_shim = [ordered]@{
            path = $chocoFf
            exists = [IO.File]::Exists($chocoFf)
            target = $chocoFfTarget
            target_exists = [IO.File]::Exists($chocoFfTarget)
            runnable = $false
            note = 'Shim present; target missing. Do not execute the shim (would fail or hang). Do not use where.exe first hit.'
        }
        colmap_on_path = @($colmapWhere)
        colmap_common_dirs = @{
            'C:\Program Files\COLMAP' = [IO.Directory]::Exists('C:\Program Files\COLMAP')
            'C:\COLMAP' = [IO.Directory]::Exists('C:\COLMAP')
            'D:\COLMAP' = [IO.Directory]::Exists('D:\COLMAP')
        }
        python_isolated = [ordered]@{
            path = $pyIso
            exists = [IO.File]::Exists($pyIso)
            version = $null
            query = $(if (Test-Path -LiteralPath $pyIso) { Invoke-ExeVersion -Path $pyIso -VersionArgs @('-V') -TimeoutSec 15 } else { $null })
        }
        python_system = $(
            $p = Resolve-CommandPath 'python'
            if ($p) { Invoke-ExeVersion -Path $p -VersionArgs @('-V') -TimeoutSec 15 } else { [ordered]@{ exists = $false; path = $null } }
        )
        uv = $(
            $p = Resolve-CommandPath 'uv'
            if ($p) { Invoke-ExeVersion -Path $p -VersionArgs @('--version') -TimeoutSec 15 } else { [ordered]@{ exists = $false; path = $null } }
        )
        nvcc = $(
            $p = Resolve-CommandPath 'nvcc'
            if ($p) { Invoke-ExeVersion -Path $p -VersionArgs @('--version') -TimeoutSec 15 } else { [ordered]@{ exists = $false; path = $null } }
        )
    }
    policy = [ordered]@{
        scanned_credential_dirs = $false
        dumped_environment_variables = $false
        enabled_windows_features = $false
        installed_global_packages = $false
        changed_drivers = $false
        rebooted = $false
        killed_only_self_started_children = $true
    }
}

if ($report.tools.python_isolated.query) {
    $report.tools.python_isolated.version = $report.tools.python_isolated.query.stdout_head
}

$wslGap = @()
if (-not $report.wsl.any_wsl_exe) { $wslGap += 'wsl.exe not present' }
$wslFeat = $report.wsl.optional_features | Where-Object { $_.name -eq 'Microsoft-Windows-Subsystem-Linux' } | Select-Object -First 1
if ($wslFeat -and -not $wslFeat.state) {
    $wslGap += 'Microsoft-Windows-Subsystem-Linux optional feature name unknown or query empty on this image'
}
$vmp = $report.wsl.optional_features | Where-Object { $_.name -eq 'VirtualMachinePlatform' } | Select-Object -First 1
$hv = $report.wsl.optional_features | Where-Object { $_.name -eq 'Microsoft-Hyper-V-All' } | Select-Object -First 1
$report.wsl.gap = (($wslGap -join '; ') + '. VirtualMachinePlatform=' + $(if ($vmp) { $vmp.state } else { 'null' }) + ', Hyper-V-All=' + $(if ($hv) { $hv.state } else { 'null' }) + ', hypervisorlaunchtype=' + $bcd + ', HypervisorPresent=' + $cs.HypervisorPresent + '. Official WSL MSI offline install is the next step; missing inbox optional feature is not a permanent block.')
$report.wsl.ready = $false

New-Item -ItemType Directory -Force -Path (Split-Path $OutJson) | Out-Null
$json = $report | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText($OutJson, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Output $OutJson
