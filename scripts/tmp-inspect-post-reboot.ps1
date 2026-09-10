#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$Repo = 'C:\Users\Administrator\Desktop\01_项目与代码\高斯破溅'
$logDir = Join-Path $Repo 'logs\wsl'
$out = Join-Path $logDir 'post-reboot-inspect.json'

function Read-MaybeUtf16([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 4 -and $bytes[1] -eq 0 -and $bytes[3] -eq 0) {
        return [Text.Encoding]::Unicode.GetString($bytes)
    }
    return [Text.Encoding]::UTF8.GetString($bytes)
}

$distroDir = Join-Path $Repo 'env\wsl\GS-Ubuntu2204'
$files = @()
if (Test-Path -LiteralPath $distroDir) {
    Get-ChildItem -LiteralPath $distroDir -Force | ForEach-Object {
        $files += [ordered]@{ name = $_.Name; length = $_.Length; last_write = $_.LastWriteTime.ToString('o'); is_dir = $_.PSIsContainer }
    }
}

$lxss = @()
$lxssPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
if (Test-Path -LiteralPath $lxssPath) {
    Get-ChildItem -LiteralPath $lxssPath | ForEach-Object {
        $p = Get-ItemProperty -LiteralPath $_.PSPath
        $lxss += [ordered]@{
            key = $_.PSChildName
            DistributionName = $p.DistributionName
            Version = $p.Version
            BasePath = $p.BasePath
            DefaultUid = $p.DefaultUid
        }
    }
    try {
        $root = Get-ItemProperty -LiteralPath $lxssPath
        $default = $root.DefaultDistribution
    } catch { $default = $null }
} else { $default = $null }

$obj = [ordered]@{
    list_before = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-wsl-list.txt')
    list_before_err = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-wsl-list.err')
    import_stdout = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-import.txt')
    import_stderr = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-import.err')
    list_after = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-wsl-list-after.txt')
    version = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-wsl-version.txt')
    status = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-wsl-status.txt')
    uname = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-linux-uname.txt')
    os_release = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-linux-os-release.txt')
    nvidia_path = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-linux-nvidia-smi-path.txt')
    nvidia = Read-MaybeUtf16 (Join-Path $logDir 'post-reboot-linux-nvidia-smi.txt')
    distro_dir = $distroDir
    distro_files = $files
    distro_file_count = @($files | Where-Object { -not $_.is_dir }).Count
    lxss_default = $default
    lxss = $lxss
}
[IO.File]::WriteAllText($out, ($obj | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Output $out
