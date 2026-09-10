#Requires -Version 5.1
# Resume Ubuntu 22.04.5 .wsl. Does not delete the existing partial. Does not install.
# Max 3 curl connections. No new downloader. No msiexec / wsl / winget.
[CmdletBinding()]
param([string]$Repo = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\WinProcess.ps1')
if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
}

$Name = 'ubuntu-22.04.5-wsl-amd64.wsl'
$Url = 'https://releases.ubuntu.com/jammy/ubuntu-22.04.5-wsl-amd64.wsl'
$ExpectedSha = '4499c4fe257f2fc83145b429ce211a0a43fd590e70d6261ede616210947d9f8f'
$ExpectedBytes = [int64]360684292
$Cache = Join-Path $Repo 'env\cache\wsl'
$LogDir = Join-Path $Repo 'logs\wsl'
$ReportDir = Join-Path $Repo 'reports'
New-Item -ItemType Directory -Force -Path $Cache, $LogDir, $ReportDir | Out-Null

$Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$Original = Join-Path $Cache $Name
$Candidate = Join-Path $Cache ($Name + '.candidate')
$LivePath = Join-Path $LogDir 'ubuntu-download-live.json'
$LiveLog = Join-Path $LogDir 'ubuntu-download-live.log'
$ResultPath = Join-Path $ReportDir 'ubuntu-download-result.json'
$Utf8 = [Text.UTF8Encoding]::new($false)

function Write-JsonFile {
    param([string]$Path, $Object)
    [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 10), $Utf8)
}

function Write-LiveLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date).ToString('o'), $Message
    [IO.File]::AppendAllText($LiveLog, $line + [Environment]::NewLine, $Utf8)
}

function New-ReportBase {
    return [ordered]@{
        schema            = 'gs.ubuntu.offline.download.v1'
        pid               = $PID
        started_local     = (Get-Date).ToString('o')
        started_utc       = [DateTime]::UtcNow.ToString('o')
        msiexec_ran       = $false
        url               = $Url
        expected_bytes    = $ExpectedBytes
        expected_sha256   = $ExpectedSha
        original_path     = $Original
        original_bytes    = $(if (Test-Path -LiteralPath $Original) { [IO.FileInfo]::new($Original).Length } else { 0 })
        method            = $null
        status            = 'running'
        range_probe       = $null
        parts             = @()
        candidate_path    = $Candidate
        candidate_bytes   = $null
        sha256            = $null
        sha256_ok         = $false
        partial_backup    = $null
        error             = $null
        result_path       = $ResultPath
        live_path         = $LivePath
        ended_local       = $null
        ended_utc         = $null
    }
}

$report = New-ReportBase
Write-JsonFile $LivePath $report
Write-JsonFile $ResultPath $report
Write-LiveLog ("start pid=$PID original_bytes=$($report.original_bytes)")

function Complete-Report {
    param([string]$Status, [string]$ErrorMessage = $null)
    $report.status = $Status
    if ($ErrorMessage) { $report.error = $ErrorMessage }
    $report.ended_local = (Get-Date).ToString('o')
    $report.ended_utc = [DateTime]::UtcNow.ToString('o')
    if (Test-Path -LiteralPath $Candidate) {
        $report.candidate_bytes = [IO.FileInfo]::new($Candidate).Length
    }
    Write-JsonFile $LivePath $report
    Write-JsonFile $ResultPath $report
    Write-LiveLog ("complete status=$Status error=$ErrorMessage")
}

function Invoke-CurlWait {
    param([string[]]$ArgumentList, [string]$StdoutPath, [string]$StderrPath, [int]$TimeoutSec)
    $cap = Invoke-ProcessCaptured -FilePath $Curl -ArgumentList $ArgumentList -StdoutPath $StdoutPath -StderrPath $StderrPath -TimeoutSec $TimeoutSec -NoStdin
    return $cap
}

function Get-RangeProbe {
    $headPath = Join-Path $LogDir 'ubuntu-offline-head.txt'
    $hdrPath = Join-Path $LogDir 'ubuntu-offline-range.hdr'
    $bodyPath = Join-Path $LogDir 'ubuntu-offline-range.bin'
    $head = Invoke-CurlWait -ArgumentList @('-sI','-L','--connect-timeout','20','--max-time','40','--output',$headPath,$Url) -StdoutPath (Join-Path $LogDir 'ubuntu-offline-head.stdout.log') -StderrPath (Join-Path $LogDir 'ubuntu-offline-head.stderr.log') -TimeoutSec 50
    $rng = Invoke-CurlWait -ArgumentList @('-s','-D',$hdrPath,'--output',$bodyPath,'--connect-timeout','20','--max-time','40','-H','Range: bytes=0-0','-L',$Url) -StdoutPath (Join-Path $LogDir 'ubuntu-offline-range.stdout.log') -StderrPath (Join-Path $LogDir 'ubuntu-offline-range.stderr.log') -TimeoutSec 50
    $headText = Get-FileHeadText -Path $headPath -MaxChars 4000
    $hdrText = Get-FileHeadText -Path $hdrPath -MaxChars 4000
    $accept = $false
    $etag = $null
    $len = $null
    if ($headText -match '(?im)^Accept-Ranges:\s*bytes') { $accept = $true }
    if ($headText -match '(?im)^ETag:\s*(.+)$') { $etag = $Matches[1].Trim() }
    if ($headText -match '(?im)^Content-Length:\s*(\d+)') { $len = [int64]$Matches[1] }
    $http206 = $false
    if ($hdrText -match 'HTTP/\S+\s+206') { $http206 = $true }
    $ok = [bool]($head.transport_ok -and $head.exit_code -eq 0 -and $rng.transport_ok -and $rng.exit_code -eq 0 -and $accept -and $http206 -and $len -eq $ExpectedBytes)
    return [ordered]@{
        ok              = $ok
        accept_ranges   = $accept
        http_206        = $http206
        etag            = $etag
        content_length  = $len
        head_exit       = $head.exit_code
        range_exit      = $rng.exit_code
        head_path       = $headPath
        range_hdr_path  = $hdrPath
    }
}

function Start-CurlProcess {
    param([string[]]$ArgumentList, [string]$StdoutPath, [string]$StderrPath)
    foreach ($p in @($StdoutPath, $StderrPath)) {
        $dir = Split-Path -Parent $p
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Curl
    $psi.Arguments = Convert-ArgListToCommandLine $ArgumentList
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $outFs = New-Object System.IO.FileStream($StdoutPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $errFs = New-Object System.IO.FileStream($StderrPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $started = $proc.Start()
    if (-not $started) {
        $outFs.Dispose(); $errFs.Dispose()
        throw "curl Start returned false"
    }
    try { $proc.StandardInput.Close() } catch { }
    $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($outFs)
    $errCopy = $proc.StandardError.BaseStream.CopyToAsync($errFs)
    return [pscustomobject]@{
        Proc     = $proc
        OutFs    = $outFs
        ErrFs    = $errFs
        OutCopy  = $outCopy
        ErrCopy  = $errCopy
        Pid      = $proc.Id
        Args     = $psi.Arguments
    }
}

function Close-CurlProcess {
    param($Job)
    try { [void]$Job.OutCopy.Wait(15000) } catch { }
    try { [void]$Job.ErrCopy.Wait(15000) } catch { }
    try { $Job.OutFs.Flush() } catch { }
    try { $Job.ErrFs.Flush() } catch { }
    try { $Job.OutFs.Dispose() } catch { }
    try { $Job.ErrFs.Dispose() } catch { }
    $code = $null
    if ($Job.Proc.HasExited) { $code = $Job.Proc.ExitCode }
    try { $Job.Proc.Dispose() } catch { }
    return $code
}

function Merge-Candidate {
    param([string[]]$Sources, [string]$Dest, [int64]$ExpectLen)
    $dst = [IO.File]::Open($Dest, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        foreach ($src in $Sources) {
            $fs = [IO.File]::OpenRead($src)
            try { [void]$fs.CopyTo($dst) } finally { $fs.Dispose() }
        }
    } finally {
        $dst.Dispose()
    }
    $len = [IO.FileInfo]::new($Dest).Length
    if ($len -ne $ExpectLen) {
        throw "candidate bytes=$len expected=$ExpectLen"
    }
}

function Test-AndPromote {
    param([string]$PathToHash)
    $hash = (Get-FileHash -LiteralPath $PathToHash -Algorithm SHA256).Hash.ToLowerInvariant()
    $report.sha256 = $hash
    $report.candidate_bytes = [IO.FileInfo]::new($PathToHash).Length
    $report.sha256_ok = ($hash -eq $ExpectedSha -and $report.candidate_bytes -eq $ExpectedBytes)
    if (-not $report.sha256_ok) { return $false }
    $backup = Join-Path $Cache ($Name + '.partial-' + $report.original_bytes)
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $Original -Destination $backup -Force
    }
    $report.partial_backup = $backup
    Copy-Item -LiteralPath $PathToHash -Destination $Original -Force
    return $true
}

function Get-MatchingCurls {
    param([string[]]$Needles)
    $all = @(Get-CimInstance Win32_Process -Filter "Name='curl.exe'" -ErrorAction SilentlyContinue)
    $hit = @()
    foreach ($c in $all) {
        $cl = $c.CommandLine
        if ([string]::IsNullOrWhiteSpace($cl)) { continue }
        foreach ($n in $Needles) {
            if ($cl.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $hit += $c
                break
            }
        }
    }
    return $hit
}

try {
    if (-not (Test-Path -LiteralPath $Original)) {
        throw "missing original partial: $Original"
    }
    $origLen = [IO.FileInfo]::new($Original).Length
    if ($origLen -le 0 -or $origLen -ge $ExpectedBytes) {
        throw "unexpected original size $origLen"
    }

    $existingCurls = @(Get-MatchingCurls @(($Name + '.part')))
    $existingParts = @(Get-ChildItem -LiteralPath $Cache -Filter ($Name + '.part*') -File -ErrorAction SilentlyContinue)
    $adopt = ($existingCurls.Count -gt 0 -or $existingParts.Count -gt 0)
    if ($adopt) {
        $probe = [ordered]@{
            ok = $true; adopted = $true; accept_ranges = $true; http_206 = $true
            etag = '"157f9b04-64c981d810a80"'; content_length = $ExpectedBytes
            skipped_probe = $true
        }
        Write-LiveLog ("adopt existing curls=$($existingCurls.Count) parts=$($existingParts.Count)")
    } else {
        $probe = Get-RangeProbe
        Write-LiveLog ("range_probe ok=$($probe.ok) etag=$($probe.etag) len=$($probe.content_length)")
    }
    $report.range_probe = $probe
    Write-JsonFile $LivePath $report

    $didRange = $false
    if ($probe.ok) {
        $remain = $ExpectedBytes - $origLen
        $n = 3
        $base = [int64][Math]::Floor($remain / $n)
        $ranges = @()
        $start = $origLen
        for ($i = 0; $i -lt $n; $i++) {
            $end = if ($i -eq ($n - 1)) { $ExpectedBytes - 1 } else { $start + $base - 1 }
            $partPath = Join-Path $Cache ('{0}.part{1}' -f $Name, $i)
            $expect = [int64]($end - $start + 1)
            $have = [int64]0
            if (Test-Path -LiteralPath $partPath) { $have = [IO.FileInfo]::new($partPath).Length }
            $ranges += [ordered]@{
                index      = $i
                path       = $partPath
                range      = ('{0}-{1}' -f $start, $end)
                expected   = $expect
                bytes      = $have
                pid        = $null
                exit_code  = $null
                skipped    = $false
                adopted    = $false
            }
            $start = $end + 1
        }

        $jobs = @()
        $activeStarts = 0
        foreach ($r in $ranges) {
            if ([int64]$r.bytes -eq [int64]$r.expected) {
                $r.skipped = $true
                Write-LiveLog ("part$($r.index) already complete $($r.expected)")
                continue
            }
            $running = @(Get-MatchingCurls @($r.path))
            if ($running.Count -gt 0) {
                $r.adopted = $true
                $r.pid = $running[0].ProcessId
                Write-LiveLog ("part$($r.index) adopt pid=$($r.pid) bytes=$($r.bytes)")
                continue
            }
            if ($activeStarts -ge 3) { throw 'refusing to start more than 3 curl connections' }
            $stdout = Join-Path $LogDir ("ubuntu-part{0}.stdout.log" -f $r.index)
            $stderr = Join-Path $LogDir ("ubuntu-part{0}.stderr.log" -f $r.index)
            $args = @(
                '-L','--fail','--connect-timeout','30','--max-time','1800',
                '--speed-time','120','--speed-limit','1024',
                '--retry','1','--retry-delay','3',
                '--range', $r.range,
                '--output', $r.path,
                $Url
            )
            $job = Start-CurlProcess -ArgumentList $args -StdoutPath $stdout -StderrPath $stderr
            $r.pid = $job.Pid
            $activeStarts++
            $jobs += [pscustomobject]@{ Range = $r; Job = $job }
            Write-LiveLog ("part$($r.index) started pid=$($job.Pid) range=$($r.range)")
        }

        $report.method = 'range-3'
        $report.parts = $ranges
        Write-JsonFile $LivePath $report

        $deadline = [DateTime]::UtcNow.AddSeconds(1900)
        while ($true) {
            $got = [int64]0
            $need = $false
            foreach ($r in $ranges) {
                if (Test-Path -LiteralPath $r.path) { $r.bytes = [IO.FileInfo]::new($r.path).Length } else { $r.bytes = [int64]0 }
                $got += [int64]$r.bytes
                if ([int64]$r.bytes -ne [int64]$r.expected) { $need = $true }
            }
            $partPaths = @($ranges | ForEach-Object { $_.path })
            $aliveCurls = @(Get-MatchingCurls $partPaths)
            $aliveJobs = @($jobs | Where-Object { $_.Job.Proc -and -not $_.Job.Proc.HasExited })
            $report.parts = $ranges
            Write-JsonFile $LivePath $report
            Write-LiveLog ("range-3 got=$got need=$need curls=$($aliveCurls.Count) jobs=$($aliveJobs.Count)")
            if (-not $need) { break }
            if ($aliveCurls.Count -eq 0 -and $aliveJobs.Count -eq 0) {
                Start-Sleep -Seconds 2
                $need = $false
                foreach ($r in $ranges) {
                    if (Test-Path -LiteralPath $r.path) { $r.bytes = [IO.FileInfo]::new($r.path).Length }
                    if ([int64]$r.bytes -ne [int64]$r.expected) { $need = $true }
                }
                if ($need) { throw 'range-3 curls exited before parts complete' }
                break
            }
            if ([DateTime]::UtcNow -gt $deadline) { throw 'range-3 deadline 1900s' }
            Start-Sleep -Seconds 5
        }

        foreach ($j in $jobs) {
            $code = Close-CurlProcess $j.Job
            $j.Range.exit_code = $code
            if (Test-Path -LiteralPath $j.Range.path) { $j.Range.bytes = [IO.FileInfo]::new($j.Range.path).Length }
        }
        $report.parts = $ranges
        Write-JsonFile $LivePath $report

        $bad = @($ranges | Where-Object { [int64]$_.bytes -ne [int64]$_.expected })
        if ($bad.Count -eq 0) {
            $sources = @($Original) + @($ranges | ForEach-Object { $_.path })
            Merge-Candidate -Sources $sources -Dest $Candidate -ExpectLen $ExpectedBytes
            if (Test-AndPromote -PathToHash $Candidate) {
                $didRange = $true
                Complete-Report -Status 'ok'
                exit 0
            }
            Write-LiveLog ("range-3 sha mismatch got=$($report.sha256)")
        } else {
            Write-LiveLog ('range-3 part mismatch: ' + (($bad | ForEach-Object { "part$($_.index) bytes=$($_.bytes)/$($_.expected)" }) -join '; '))
        }
    }

    $stillRange = @(Get-MatchingCurls @(($Name + '.part')))
    if ($stillRange.Count -gt 0) {
        throw "not starting curl -C - while $($stillRange.Count) range curls still running"
    }

    # One different fallback: curl -C - onto a copy of the partial. Do not clobber the original until SHA matches.
    $report.method = $(if ($probe.ok) { 'range-3-then-curl-C' } else { 'curl-C' })
    Write-LiveLog ("fallback method=$($report.method)")
    $work = Join-Path $Cache ($Name + '.resume-work')
    Copy-Item -LiteralPath $Original -Destination $work -Force
    $cap = Invoke-CurlWait -ArgumentList @(
        '-L','--fail','--connect-timeout','30','--max-time','1800',
        '--speed-time','120','--speed-limit','1024',
        '--retry','1','--retry-delay','3',
        '-C','-','--output',$work,$Url
    ) -StdoutPath (Join-Path $LogDir 'ubuntu-resume-C.stdout.log') -StderrPath (Join-Path $LogDir 'ubuntu-resume-C.stderr.log') -TimeoutSec 1860
    $report.fallback_curl = [ordered]@{
        pid          = $cap.pid
        exit_code    = $cap.exit_code
        timed_out    = $cap.timed_out
        transport_ok = $cap.transport_ok
        duration_ms  = $cap.duration_ms
        work_bytes   = $(if (Test-Path -LiteralPath $work) { [IO.FileInfo]::new($work).Length } else { 0 })
    }
    Write-JsonFile $LivePath $report
    if (-not $cap.transport_ok -or $cap.exit_code -ne 0) {
        throw "curl -C - exit=$($cap.exit_code) timeout=$($cap.timed_out)"
    }
    if ([IO.FileInfo]::new($work).Length -ne $ExpectedBytes) {
        throw "resume-work bytes=$($report.fallback_curl.work_bytes) expected=$ExpectedBytes"
    }
    Copy-Item -LiteralPath $work -Destination $Candidate -Force
    if (Test-AndPromote -PathToHash $Candidate) {
        Complete-Report -Status 'ok'
        exit 0
    }
    throw "sha256 mismatch got=$($report.sha256) expected=$ExpectedSha"
} catch {
    Complete-Report -Status 'failed' -ErrorMessage $_.Exception.Message
    exit 1
}
