#Requires -Version 5.1
$ErrorActionPreference = 'Continue'
Write-Output '=== disk ==='
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    '{0} free={1:N2}GiB size={2:N2}GiB' -f $_.DeviceID, ($_.FreeSpace/1GB), ($_.Size/1GB)
}
Write-Output '=== wsl candidates ==='
foreach ($c in @(
    "$env:SystemRoot\System32\wsl.exe",
    "$env:SystemRoot\Sysnative\wsl.exe",
    "$env:LOCALAPPDATA\Microsoft\WindowsApps\wsl.exe"
)) {
    Write-Output ("{0} exists={1}" -f $c, [IO.File]::Exists($c))
}
Write-Output '=== features ==='
foreach ($n in @('VirtualMachinePlatform','Microsoft-Windows-Subsystem-Linux','HypervisorPlatform','Microsoft-Hyper-V-All')) {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $n -ErrorAction Stop
        Write-Output ("{0} state={1} restart={2}" -f $n, $f.State, $f.RestartNeeded)
    } catch {
        Write-Output ("{0} err={1}" -f $n, $_.Exception.Message)
    }
}
Write-Output '=== ps version ==='
$PSVersionTable.PSVersion.ToString()
Write-Output '=== admin ==='
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Output '=== nvidia-smi ==='
try { nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader } catch { $_.Exception.Message }
Write-Output '=== ProcessStartInfo.Environment ==='
$psi = New-Object System.Diagnostics.ProcessStartInfo
try { $null = $psi.Environment; Write-Output 'Environment property: OK' } catch { Write-Output ('Environment property FAIL: ' + $_.Exception.Message) }
try { $null = $psi.EnvironmentVariables; Write-Output 'EnvironmentVariables property: OK' } catch { Write-Output ('EnvironmentVariables property FAIL: ' + $_.Exception.Message) }
Write-Output '=== powershell.exe path ==='
(Get-Command powershell.exe).Source
Write-Output '=== pwsh ==='
Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
