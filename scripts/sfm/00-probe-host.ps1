#Requires -Version 5.1
# Host + Linux SfM probe. No nested powershell.exe. No Start-Process.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { cmd /c "chcp 65001 >nul" | Out-Null } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir '..\lib\WinProcess.ps1')
$Repo = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))
$logDir = Join-Path $Repo 'logs\sfm'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$wsl = 'C:\Program Files\WSL\wsl.exe'

function Save-Json([string]$Path, $Obj) {
    [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Convert-WinToWsl([string]$WinPath) {
    $full = [IO.Path]::GetFullPath($WinPath)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $rest = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

$os = Get-CimInstance Win32_OperatingSystem
$c = Get-PSDrive -Name C
$hostFacts = Join-Path $logDir 'host-probe.json'
$hostReport = [ordered]@{
    schema = 'gs.sfm.host.probe.v1'
    utc = [DateTime]::UtcNow.ToString('o')
    local = [DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ssK')
    total_ram_bytes = [int64]$os.TotalVisibleMemorySize * 1024
    free_ram_bytes = [int64]$os.FreePhysicalMemory * 1024
    free_ram_gib = [math]::Round(([int64]$os.FreePhysicalMemory * 1024) / 1GB, 2)
    ram_gate_ok = (([int64]$os.FreePhysicalMemory * 1024) -ge 4GB)
    c_free_bytes = [int64]$c.Free
    c_free_gib = [math]::Round($c.Free / 1GB, 2)
    c_gate_ok = ($c.Free -ge 60GB)
    wsl_exe = $wsl
    wsl_exe_exists = [IO.File]::Exists($wsl)
}
Save-Json $hostFacts $hostReport

if (-not $hostReport.ram_gate_ok) {
    Write-Output "RAM_GATE_FAIL free_gib=$($hostReport.free_ram_gib)"
    exit 3
}
if (-not $hostReport.c_gate_ok) {
    Write-Output "C_DISK_GATE_FAIL free_gib=$($hostReport.c_free_gib)"
    exit 4
}

$linuxScriptWin = Join-Path $scriptDir 'linux\00-probe.sh'
$linuxScript = Convert-WinToWsl $linuxScriptWin
$linuxOut = '/tmp/gs-sfm-probe.json'
$hostOut = Join-Path $logDir 'linux-probe.json'
$hostOutWsl = Convert-WinToWsl $hostOut
$runnerWin = Join-Path $logDir 'run-probe.sh'
$runner = @"
#!/usr/bin/env bash
set -eu
export LANG=C.UTF-8
sed 's/\r`$//' '$linuxScript' > /tmp/gs-sfm-00-probe.sh
chmod +x /tmp/gs-sfm-00-probe.sh
bash /tmp/gs-sfm-00-probe.sh '$linuxOut'
cp -f '$linuxOut' '$hostOutWsl'
echo PROBE_COPY_OK
"@
[IO.File]::WriteAllText($runnerWin, $runner.Replace("`r`n","`n").Replace("`r","`n"), [Text.UTF8Encoding]::new($false))
$runnerWsl = Convert-WinToWsl $runnerWin

$unameCap = Invoke-ProcessCaptured -FilePath $wsl -ArgumentList @('-d','GS-Ubuntu2204','--user','root','--','uname','-a') -StdoutPath (Join-Path $logDir 'uname-stdout.txt') -StderrPath (Join-Path $logDir 'uname-stderr.txt') -TimeoutSec 60 -NoStdin

$runCap = Invoke-ProcessCaptured -FilePath $wsl -ArgumentList @('-d','GS-Ubuntu2204','--user','root','--','bash',$runnerWsl) -StdoutPath (Join-Path $logDir 'probe-run-stdout.txt') -StderrPath (Join-Path $logDir 'probe-run-stderr.txt') -TimeoutSec 180 -NoStdin

$summary = [ordered]@{
    host = $hostFacts
    linux_script = $linuxScript
    runner = $runnerWsl
    uname_exit = $unameCap.exit_code
    uname_stdout = Get-FileHeadText (Join-Path $logDir 'uname-stdout.txt') 2000
    uname_stderr = Get-FileHeadText (Join-Path $logDir 'uname-stderr.txt') 2000
    run_exit = $runCap.exit_code
    run_timed_out = $runCap.timed_out
    run_duration_ms = $runCap.duration_ms
    linux_report = $hostOut
    run_stdout = Get-FileHeadText (Join-Path $logDir 'probe-run-stdout.txt') 2000
    run_stderr = Get-FileHeadText (Join-Path $logDir 'probe-run-stderr.txt') 4000
}
Save-Json (Join-Path $logDir 'probe-summary.json') $summary
Write-Output ("PROBE_DONE uname_exit=" + $unameCap.exit_code + " run_exit=" + $runCap.exit_code + " duration_ms=" + $runCap.duration_ms)
if ($runCap.exit_code -eq 0) { exit 0 } else { exit 6 }
