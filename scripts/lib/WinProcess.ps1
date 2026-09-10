#Requires -Version 5.1
# Shared Windows process helpers. Compatible with Windows PowerShell 5.1 and PowerShell 7.
# Do not dump environment variables. Do not read credential files.

function Quote-WinArg {
    <#
    .SYNOPSIS
      Quote one argument for Windows CRT / CommandLineToArgvW.
    .NOTES
      Backslashes are literal unless they immediately precede a double quote.
      Trailing backslashes before a closing quote must be doubled, otherwise
      the closing quote is escaped (paths that end with '\' break).
    #>
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $needQuote = ($Value.Length -eq 0) -or ($Value -match '[\s"]')
    if (-not $needQuote) { return $Value }
    $bsChar = [char]0x5C
    $quoteChar = [char]0x22
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($quoteChar)
    $bs = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq $bsChar) {
            $bs++
        } elseif ($ch -eq $quoteChar) {
            if ($bs -gt 0) { [void]$sb.Append($bsChar, $bs * 2) }
            $bs = 0
            [void]$sb.Append($bsChar)
            [void]$sb.Append($quoteChar)
        } else {
            if ($bs -gt 0) {
                [void]$sb.Append($bsChar, $bs)
                $bs = 0
            }
            [void]$sb.Append($ch)
        }
    }
    if ($bs -gt 0) {
        [void]$sb.Append($bsChar, $bs * 2)
    }
    [void]$sb.Append($quoteChar)
    return $sb.ToString()
}

function Convert-ArgListToCommandLine {
    param([string[]]$ArgumentList)
    if ($null -eq $ArgumentList -or $ArgumentList.Count -eq 0) { return '' }
    return (($ArgumentList | ForEach-Object { Quote-WinArg $_ }) -join ' ')
}

function Invoke-ProcessCaptured {
    <#
    .SYNOPSIS
      Start a process, inherit the default environment, stream stdout/stderr to files,
      optionally timeout and kill only this child.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [int]$TimeoutSec = 0,
        [switch]$NoStdin
    )

    $result = [ordered]@{
        started          = $false
        exists           = [IO.File]::Exists($FilePath)
        path             = $FilePath
        command_line     = $null
        pid              = $null
        exit_code        = $null
        timed_out        = $false
        killed_self_child = $false
        duration_ms      = $null
        stdout_path      = $StdoutPath
        stderr_path      = $StderrPath
        transport_ok     = $false
        error            = $null
    }

    if (-not $result.exists) {
        $result.error = "executable not found: $FilePath"
        return [pscustomobject]$result
    }

    foreach ($p in @($StdoutPath, $StderrPath)) {
        $dir = Split-Path -Parent $p
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Convert-ArgListToCommandLine $ArgumentList
    $result.command_line = (Quote-WinArg $FilePath) + $(if ($psi.Arguments) { ' ' + $psi.Arguments } else { '' })
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    # Inherit default environment. Do not touch ProcessStartInfo.Environment /
    # EnvironmentVariables (old .NET vs Core property names; also avoids reading auth vars).

    $utf8 = New-Object System.Text.UTF8Encoding $false
    $outFs = $null
    $errFs = $null
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $outFs = New-Object System.IO.FileStream($StdoutPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $errFs = New-Object System.IO.FileStream($StderrPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $started = $proc.Start()
        if (-not $started) {
            $result.error = "Process.Start returned false for $FilePath"
            return [pscustomobject]$result
        }
        $result.started = $true
        $result.pid = $proc.Id
        try { $proc.StandardInput.Close() } catch { }

        $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($outFs)
        $errCopy = $proc.StandardError.BaseStream.CopyToAsync($errFs)

        $exited = $true
        if ($TimeoutSec -gt 0) {
            $exited = $proc.WaitForExit($TimeoutSec * 1000)
        } else {
            $proc.WaitForExit()
        }

        if (-not $exited) {
            $result.timed_out = $true
            try {
                if (-not $proc.HasExited) {
                    $proc.Kill()
                    $result.killed_self_child = $true
                    [void]$proc.WaitForExit(8000)
                }
            } catch {
                $result.error = "timeout kill failed: $($_.Exception.Message)"
            }
        }

        try { [void]$outCopy.Wait(15000) } catch { }
        try { [void]$errCopy.Wait(15000) } catch { }
        try { $outFs.Flush() } catch { }
        try { $errFs.Flush() } catch { }

        if ($proc.HasExited) {
            $result.exit_code = $proc.ExitCode
        }
        $result.transport_ok = [bool]($result.started -and -not $result.timed_out -and $null -ne $result.exit_code)
    } catch {
        $result.error = $_.Exception.Message
        $result.transport_ok = $false
    } finally {
        $sw.Stop()
        $result.duration_ms = $sw.ElapsedMilliseconds
        if ($outFs) { try { $outFs.Dispose() } catch { } }
        if ($errFs) { try { $errFs.Dispose() } catch { } }
        try { $proc.Dispose() } catch { }
    }

    return [pscustomobject]$result
}

function Get-FileHeadText {
    param([string]$Path, [int]$MaxChars = 4000)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -eq 0) { return '' }
        $enc = $null
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $enc = [Text.Encoding]::Unicode
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $enc = [Text.Encoding]::BigEndianUnicode
        } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $enc = New-Object Text.UTF8Encoding $true
        } else {
            $sample = [Math]::Min($bytes.Length, 400)
            if (($bytes.Length % 2) -eq 0 -and $bytes.Length -ge 4) {
                $nulOdd = 0
                for ($i = 1; $i -lt $sample; $i += 2) {
                    if ($bytes[$i] -eq 0) { $nulOdd++ }
                }
                $pairs = [int][Math]::Floor($sample / 2)
                if ($pairs -gt 0 -and $nulOdd -ge [Math]::Max(4, [int]($pairs * 0.6))) {
                    $enc = [Text.Encoding]::Unicode
                }
            }
            if ($null -eq $enc) {
                $enc = New-Object Text.UTF8Encoding $false
            }
        }
        $text = $enc.GetString($bytes)
        if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
            $text = $text.Substring(1)
        }
        if ($text.Length -le $MaxChars) { return $text }
        return $text.Substring(0, $MaxChars)
    } catch {
        return $null
    }
}
