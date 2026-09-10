#Requires -Version 5.1
# Run a Linux bash script in GS-Ubuntu2204. Strips CRLF. No nested powershell.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LinuxScriptWin,
    [string[]]$LinuxArgs = @(),
    [int]$TimeoutSec = 300,
    [string]$LogName = 'wsl-run'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { cmd /c "chcp 65001 >nul" | Out-Null } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir '..\lib\WinProcess.ps1')
$Repo = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))
$logDir = Join-Path $Repo 'logs\sfm'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$wsl = 'C:\Program Files\WSL\wsl.exe'

function Convert-WinToWsl([string]$WinPath) {
    $full = [IO.Path]::GetFullPath($WinPath)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $rest = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

$linuxScript = Convert-WinToWsl $LinuxScriptWin
$argLine = ""
foreach ($a in $LinuxArgs) {
    $argLine += " '" + ($a.Replace("'", "'\''")) + "'"
}
$runnerWin = Join-Path $logDir ("run-" + $LogName + ".sh")
$runner = @"
#!/usr/bin/env bash
set -eu
export LANG=C.UTF-8
sed 's/\r`$//' '$linuxScript' > /tmp/gs-sfm-run-$LogName.sh
chmod +x /tmp/gs-sfm-run-$LogName.sh
bash /tmp/gs-sfm-run-$LogName.sh$argLine
"@
[IO.File]::WriteAllText($runnerWin, $runner.Replace("`r`n","`n").Replace("`r","`n"), [Text.UTF8Encoding]::new($false))
$runnerWsl = Convert-WinToWsl $runnerWin

$cap = Invoke-ProcessCaptured -FilePath $wsl -ArgumentList @('-d','GS-Ubuntu2204','--user','root','--','bash',$runnerWsl) -StdoutPath (Join-Path $logDir ($LogName + '-stdout.txt')) -StderrPath (Join-Path $logDir ($LogName + '-stderr.txt')) -TimeoutSec $TimeoutSec -NoStdin

$summary = [ordered]@{
    linux_script = $linuxScript
    args = $LinuxArgs
    exit_code = $cap.exit_code
    timed_out = $cap.timed_out
    duration_ms = $cap.duration_ms
    pid = $cap.pid
    stdout = Get-FileHeadText (Join-Path $logDir ($LogName + '-stdout.txt')) 4000
    stderr = Get-FileHeadText (Join-Path $logDir ($LogName + '-stderr.txt')) 4000
}
[IO.File]::WriteAllText((Join-Path $logDir ($LogName + '-summary.json')), ($summary | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Output ("WSL_DONE name=" + $LogName + " exit=" + $cap.exit_code + " timeout=" + $cap.timed_out + " ms=" + $cap.duration_ms)
if ($cap.timed_out) { exit 124 }
if ($null -eq $cap.exit_code) { exit 7 }
exit [int]$cap.exit_code
