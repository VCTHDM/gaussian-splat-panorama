#Requires -Version 5.1
# Stub tests for invoke-grok.ps1. Does not call the real grok model.
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { cmd /c "chcp 65001 >nul" | Out-Null } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scripts = Split-Path -Parent $here
$repo = Split-Path -Parent $scripts
. (Join-Path $scripts 'lib\WinProcess.ps1')

$results = New-Object System.Collections.Generic.List[object]
$failed = 0

function Add-Result([string]$Name, [bool]$Ok, [string]$Detail) {
    $script:results.Add([ordered]@{ name = $Name; ok = $Ok; detail = $Detail })
    if (-not $Ok) { $script:failed++ }
    Write-Host ("[{0}] {1} :: {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
}

# --- Quote-WinArg unit tests (CRT rules) ---
Add-Result 'quote-plain' ((Quote-WinArg 'foo') -eq 'foo') (Quote-WinArg 'foo')
Add-Result 'quote-space' ((Quote-WinArg 'a b') -eq '"a b"') (Quote-WinArg 'a b')
Add-Result 'quote-empty' ((Quote-WinArg '') -eq '""') (Quote-WinArg '')
Add-Result 'quote-trailing-slash' ((Quote-WinArg 'C:\path with space\') -eq '"C:\path with space\\"') (Quote-WinArg 'C:\path with space\')
Add-Result 'quote-inner-quote' ((Quote-WinArg 'say "hi"') -eq '"say \"hi\""') (Quote-WinArg 'say "hi"')
Add-Result 'quote-slash-then-quote' ((Quote-WinArg 'dir\"x') -eq '"dir\\\"x"') (Quote-WinArg 'dir\"x')

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    throw "csc.exe not found at $csc"
}
$stubExe = Join-Path $here 'grok-cli-stub.exe'
& $csc /nologo /optimize+ /out:$stubExe (Join-Path $here 'grok-cli-stub.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stubExe)) {
    throw "failed to compile grok-cli-stub.exe"
}

$wrapper = Join-Path $scripts 'invoke-grok.ps1'
$testRoot = Join-Path $repo 'logs\wrapper-stub-tests'
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

# Chinese + spaces path for task file and cwd (cwd also ends with backslash)
$cnDir = Join-Path $testRoot '路径 with space'
New-Item -ItemType Directory -Force -Path $cnDir | Out-Null
$taskFile = Join-Path $cnDir '任务.md'
[IO.File]::WriteAllText($taskFile, "# stub task`n", (New-Object System.Text.UTF8Encoding $false))
$cwdSlash = $cnDir.TrimEnd('\') + '\'

function Invoke-WrapperCase {
    param(
        [string]$Name,
        [string]$Mode,
        [string]$OutDir,
        [int]$MaxTurns = 3,
        [string]$Cwd = $cnDir
    )
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $stubLog = Join-Path $OutDir 'stub-capture'
    New-Item -ItemType Directory -Force -Path $stubLog | Out-Null
    $env:GROK_STUB_MODE = $Mode
    $env:GROK_STUB_LOGDIR = $stubLog
    $env:GROK_STUB_STDERR = "stub-stderr $Name`n"
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Quote every path for Start-Process joining; trailing-backslash cwd must use CRT rules.
    $argLine = (
        '-NoProfile -ExecutionPolicy Bypass -File {0} -TaskFile {1} -MaxTurns {2} -Cwd {3} -OutDir {4} -GrokExe {5} -JobId {6}' -f
        (Quote-WinArg $wrapper),
        (Quote-WinArg $taskFile),
        $MaxTurns,
        (Quote-WinArg $Cwd),
        (Quote-WinArg $OutDir),
        (Quote-WinArg $stubExe),
        (Quote-WinArg "stub-$Name")
    )
    $wrapOut = Join-Path $testRoot ("wrapper-stdout-$Name.json")
    $wrapErr = Join-Path $testRoot ("wrapper-stderr-$Name.log")
    $p = Start-Process -FilePath $ps -ArgumentList $argLine -Wait -PassThru -NoNewWindow -RedirectStandardOutput $wrapOut -RedirectStandardError $wrapErr
    Remove-Item Env:GROK_STUB_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:GROK_STUB_LOGDIR -ErrorAction SilentlyContinue
    Remove-Item Env:GROK_STUB_STDERR -ErrorAction SilentlyContinue
    $handoff = $null
    if (Test-Path -LiteralPath $wrapOut) {
        $raw = [IO.File]::ReadAllText($wrapOut, [Text.UTF8Encoding]::new($false)).Trim()
        if ($raw) {
            try { $handoff = $raw | ConvertFrom-Json } catch { $handoff = $null }
        }
    }
    $outDirUsed = $OutDir
    if ($handoff -and $handoff.outputs -and $handoff.outputs.handoff) {
        $outDirUsed = Split-Path -Parent ([string]$handoff.outputs.handoff)
    }
    return [pscustomobject]@{
        name = $Name
        wrapper_exit = $p.ExitCode
        handoff = $handoff
        stdout_file = Join-Path $outDirUsed 'grok-stdout.json'
        stderr_file = Join-Path $outDirUsed 'grok-stderr.log'
        stub_argv = Join-Path $stubLog 'stub-argv.txt'
        stub_cmd = Join-Path $stubLog 'stub-commandline.txt'
        out_dir_used = $outDirUsed
    }
}

function Read-Text([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

# 1. output reading + end_turn success
$c1 = Invoke-WrapperCase -Name 'end_turn' -Mode 'end_turn' -OutDir (Join-Path $testRoot 'case-end_turn') -Cwd $cwdSlash
$h1 = $c1.handoff
$stdout1 = Read-Text $c1.stdout_file
$stderr1 = Read-Text $c1.stderr_file
$argv1 = Read-Text $c1.stub_argv
Add-Result 'end_turn-wrapper-exit0' ($c1.wrapper_exit -eq 0) "exit=$($c1.wrapper_exit)"
Add-Result 'end_turn-status-ok' ($h1.status -eq 'ok' -and $h1.business_ok -eq $true -and $h1.transport_ok -eq $true) "status=$($h1.status) business=$($h1.business_ok) transport=$($h1.transport_ok)"
Add-Result 'end_turn-stdout-captured' ($stdout1 -match 'end_turn' -and $stdout1 -match 'stub-session-0001') ('len=' + $(if ($stdout1) { $stdout1.Length } else { 0 }))
Add-Result 'end_turn-stderr-captured' ($stderr1 -match 'stub-stderr') ('stderr=' + $stderr1)
Add-Result 'end_turn-max-turns-arg' ($argv1 -match '--max-turns' -and $argv1 -match '3') $argv1
Add-Result 'end_turn-cn-task' ($argv1 -match '任务.md') $argv1
Add-Result 'end_turn-cwd-backslash-survived' ($argv1 -match [regex]::Escape($cnDir)) $argv1

# 2. non-zero exit
$c2 = Invoke-WrapperCase -Name 'nonzero' -Mode 'nonzero' -OutDir (Join-Path $testRoot 'case-nonzero')
Add-Result 'nonzero-wrapper-exit1' ($c2.wrapper_exit -eq 1) "exit=$($c2.wrapper_exit)"
Add-Result 'nonzero-status-failed' ($c2.handoff.status -eq 'failed' -and $c2.handoff.business_ok -eq $false) "status=$($c2.handoff.status)"
Add-Result 'nonzero-transport-ok-business-fail' ($c2.handoff.transport_ok -eq $true -and $c2.handoff.grok_exit_code -eq 7) "transport=$($c2.handoff.transport_ok) grok_exit=$($c2.handoff.grok_exit_code)"

# 3. empty stdout
$c3 = Invoke-WrapperCase -Name 'empty' -Mode 'empty' -OutDir (Join-Path $testRoot 'case-empty')
Add-Result 'empty-failed' ($c3.wrapper_exit -eq 1 -and $c3.handoff.status -eq 'failed') "exit=$($c3.wrapper_exit) status=$($c3.handoff.status)"
Add-Result 'empty-parse-error' ([string]$c3.handoff.json_parse_error -match 'empty') [string]$c3.handoff.json_parse_error

# 4. max_turns
$c4 = Invoke-WrapperCase -Name 'max_turns' -Mode 'max_turns' -OutDir (Join-Path $testRoot 'case-max_turns')
Add-Result 'max_turns-incomplete' ($c4.wrapper_exit -eq 2 -and $c4.handoff.status -eq 'incomplete') "exit=$($c4.wrapper_exit) status=$($c4.handoff.status)"
Add-Result 'max_turns-not-ok' ($c4.handoff.business_ok -eq $false) "business=$($c4.handoff.business_ok)"

# 5. unknown stopReason
$c5 = Invoke-WrapperCase -Name 'unknown_stop' -Mode 'unknown_stop' -OutDir (Join-Path $testRoot 'case-unknown_stop')
Add-Result 'unknown-needs-review' ($c5.wrapper_exit -eq 3 -and $c5.handoff.status -eq 'needs_review') "exit=$($c5.wrapper_exit) status=$($c5.handoff.status)"
Add-Result 'unknown-not-success' ($c5.handoff.business_ok -eq $false) "business=$($c5.handoff.business_ok)"

# 6. unique OutDir suffix when colliding
$collide = Join-Path $testRoot 'case-collide'
$c6a = Invoke-WrapperCase -Name 'collide-a' -Mode 'end_turn' -OutDir $collide
$c6b = Invoke-WrapperCase -Name 'collide-b' -Mode 'end_turn' -OutDir $collide
$h6aOut = [string]$c6a.handoff.outputs.raw_json
$h6bOut = [string]$c6b.handoff.outputs.raw_json
Add-Result 'collide-second-not-overwrite' ($h6bOut -and $h6aOut -and ($h6bOut -ne $h6aOut)) "first=$h6aOut second=$h6bOut"

# ProcessStartInfo.Environment compatibility note (measured, not used by wrapper)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$envPropOk = $false
$envVarsOk = $false
try { $null = $psi.Environment; $envPropOk = $true } catch { }
try { $null = $psi.EnvironmentVariables; $envVarsOk = $true } catch { }
Add-Result 'psi-Environment-property-exists' $envPropOk "Environment=$envPropOk EnvironmentVariables=$envVarsOk"
Add-Result 'wrapper-does-not-assign-Environment' (
    -not (Select-String -LiteralPath $wrapper -Pattern 'psi\.Environment' -Quiet)
) 'invoke-grok.ps1 does not touch ProcessStartInfo.Environment'

$report = [ordered]@{
    created_utc = [DateTime]::UtcNow.ToString('o')
    failed = $failed
    passed = @($results | Where-Object { $_.ok }).Count
    total = $results.Count
    results = @($results | ForEach-Object { [ordered]@{ name = $_.name; ok = [bool]$_.ok; detail = [string]$_.detail } })
    stub_exe = $stubExe
    test_root = $testRoot
}
$reportPath = Join-Path $repo 'reports\wrapper-stub-tests.json'
New-Item -ItemType Directory -Force -Path (Split-Path $reportPath) | Out-Null
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
Write-Output $reportPath
if ($failed -gt 0) { exit 1 }
exit 0
