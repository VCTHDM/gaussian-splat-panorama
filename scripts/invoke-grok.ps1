#Requires -Version 5.1
<#
.SYNOPSIS
  Headless Grok CLI wrapper: task file in, independent log + raw JSON + handoff out.
.NOTES
  Does not read credential files or print secrets.
  JSON file existence is not success.
  Transport success is not business success.
  Confirmed business success requires stopReason=end_turn.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TaskFile,

    [Parameter(Position = 1)]
    [string]$ResumeSessionId = '',

    [Parameter(Position = 2)]
    [int]$MaxTurns = 35,

    [string]$Cwd = '',

    [string]$PermissionMode = 'auto',

    [string]$OutDir = '',

    [string]$GrokExe = '',

    [string]$JobId = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\WinProcess.ps1')

function Protect-Utf8Console {
    try { cmd /c "chcp 65001 >nul" | Out-Null } catch { }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [Console]::InputEncoding = $utf8
        [Console]::OutputEncoding = $utf8
        $script:OutputEncoding = $utf8
    } catch { }
}

function Convert-ToFullPath([string]$PathValue, [switch]$MustExist) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $full = $null
    try {
        $resolved = Resolve-Path -LiteralPath $PathValue -ErrorAction SilentlyContinue
        if ($resolved) { $full = [System.IO.Path]::GetFullPath($resolved.Path) }
    } catch { }
    if (-not $full) {
        $full = [System.IO.Path]::GetFullPath($PathValue)
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $full)) {
        throw "Path not found: $PathValue"
    }
    return $full
}

function Read-ToolsJson([string]$RepoRoot) {
    $p = Join-Path $RepoRoot 'configs\tools.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-JsonProperty($obj, [string]$Name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    foreach ($alt in @($Name, ($Name.Substring(0,1).ToLower() + $Name.Substring(1)), $Name.ToLower())) {
        $q = $obj.PSObject.Properties[$alt]
        if ($q) { return $q.Value }
    }
    return $null
}

Protect-Utf8Console

$repoRoot = Convert-ToFullPath (Join-Path $scriptDir '..')

if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = $repoRoot }
$Cwd = Convert-ToFullPath $Cwd -MustExist
$TaskFile = Convert-ToFullPath $TaskFile -MustExist

if ([string]::IsNullOrWhiteSpace($GrokExe)) {
    $tools = Read-ToolsJson $repoRoot
    if ($tools -and $tools.grok_exe) { $GrokExe = [string]$tools.grok_exe }
    else { $GrokExe = 'C:\Users\Administrator\.grok\bin\grok.exe' }
}
$GrokExe = Convert-ToFullPath $GrokExe -MustExist

if ($MaxTurns -lt 1) { throw "MaxTurns must be >= 1, got $MaxTurns" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$uniq = [guid]::NewGuid().ToString('N').Substring(0, 8)
if ([string]::IsNullOrWhiteSpace($JobId)) {
    $JobId = 'grok-' + [IO.Path]::GetFileNameWithoutExtension($TaskFile) + '-' + $stamp + '-' + $uniq
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $repoRoot (Join-Path 'logs' $JobId)
} else {
    $OutDir = [System.IO.Path]::GetFullPath($OutDir)
    $probe = Join-Path $OutDir 'grok-stdout.json'
    if (Test-Path -LiteralPath $probe) {
        $OutDir = $OutDir.TrimEnd('\', '/') + '-' + $uniq
    }
}
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$rawJsonPath = Join-Path $OutDir 'grok-stdout.json'
$stderrPath = Join-Path $OutDir 'grok-stderr.log'
$commandPath = Join-Path $OutDir 'command.txt'
$handoffPath = Join-Path $OutDir 'handoff.json'
$exitPath = Join-Path $OutDir 'exitcode.txt'
$livePath = Join-Path $OutDir 'live-status.json'

$argList = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
    $argList.Add('--resume')
    $argList.Add($ResumeSessionId.Trim())
}
$argList.Add('--prompt-file')
$argList.Add($TaskFile)
$argList.Add('--max-turns')
$argList.Add("$MaxTurns")
$argList.Add('--no-subagents')
$argList.Add('--permission-mode')
$argList.Add($PermissionMode)
$argList.Add('--output-format')
$argList.Add('json')
$argList.Add('--cwd')
$argList.Add($Cwd)

$argArray = @($argList)
$displayCmd = (Quote-WinArg $GrokExe) + ' ' + (Convert-ArgListToCommandLine $argArray)
@(
    "cwd=$Cwd"
    "task_file=$TaskFile"
    "out_dir=$OutDir"
    "resume_session_id_set=$([bool](-not [string]::IsNullOrWhiteSpace($ResumeSessionId)))"
    "command=$displayCmd"
    "note=stdout/stderr stream to grok-stdout.json and grok-stderr.log while the process runs"
) | Set-Content -LiteralPath $commandPath -Encoding UTF8

$live = [ordered]@{
    schema = 'gs.grok.live.v1'
    job_id = $JobId
    phase = 'starting'
    pid = $null
    started_utc = [DateTime]::UtcNow.ToString('o')
    stdout_path = $rawJsonPath
    stderr_path = $stderrPath
}
[IO.File]::WriteAllText($livePath, ($live | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))

$cap = Invoke-ProcessCaptured -FilePath $GrokExe -ArgumentList $argArray -WorkingDirectory $Cwd -StdoutPath $rawJsonPath -StderrPath $stderrPath -TimeoutSec 0 -NoStdin

$live.phase = $(if ($cap.timed_out) { 'timed_out' } elseif ($cap.started) { 'exited' } else { 'start_failed' })
$live.pid = $cap.pid
$live.exit_code = $cap.exit_code
$live.ended_utc = [DateTime]::UtcNow.ToString('o')
$live.duration_ms = $cap.duration_ms
$live.transport_ok = $cap.transport_ok
[IO.File]::WriteAllText($livePath, ($live | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))

$exitCode = $cap.exit_code
if ($null -eq $exitCode) { $exitCode = -1 }
[IO.File]::WriteAllText($exitPath, "$exitCode`n", (New-Object System.Text.UTF8Encoding $false))

$stdoutText = ''
if (Test-Path -LiteralPath $rawJsonPath) {
    $stdoutText = [IO.File]::ReadAllText($rawJsonPath, [Text.UTF8Encoding]::new($false))
}

$parseOk = $false
$parsed = $null
$parseError = $null
$jsonCandidate = $stdoutText.Trim()
if ($jsonCandidate.StartsWith('```')) {
    $jsonCandidate = ($jsonCandidate -replace '^```(?:json)?\s*', '' -replace '\s*```$', '').Trim()
}

try {
    if ([string]::IsNullOrWhiteSpace($jsonCandidate)) {
        $parseError = 'stdout empty'
    } else {
        $parsed = $jsonCandidate | ConvertFrom-Json
        $parseOk = $true
    }
} catch {
    $parseError = $_.Exception.Message
    $parseOk = $false
}

$sessionId = $null
$stopReason = $null
$textValue = $null
$modelName = $null
if ($parseOk) {
    $sessionId = Get-JsonProperty $parsed 'sessionId'
    if (-not $sessionId) { $sessionId = Get-JsonProperty $parsed 'session_id' }
    $stopReason = Get-JsonProperty $parsed 'stopReason'
    if (-not $stopReason) { $stopReason = Get-JsonProperty $parsed 'stop_reason' }
    $textValue = Get-JsonProperty $parsed 'text'
    $modelName = Get-JsonProperty $parsed 'model'
    if (-not $modelName) {
        $mu = Get-JsonProperty $parsed 'modelUsage'
        if ($mu) {
            $props = @($mu.PSObject.Properties | Select-Object -ExpandProperty Name)
            if ($props.Count -ge 1) { $modelName = $props[0] }
        }
    }
}

$failReasons = New-Object System.Collections.Generic.List[string]
$failStop = @('error', 'aborted', 'cancelled', 'canceled', 'refused', 'permission_denied', 'tool_error')
$incompleteStop = @('max_turns', 'maxturns', 'max-turns', 'max_tokens')
$confirmedOkStop = @('end_turn')

$transportOk = [bool]$cap.transport_ok
if (-not $cap.started) { $failReasons.Add('process_start_failed') }
if ($cap.timed_out) { $failReasons.Add('process_timed_out') }
if ($cap.error) { $failReasons.Add("process_error:$($cap.error)") }
if ($null -eq $cap.exit_code) { $failReasons.Add('missing_exit_code') }
elseif ($cap.exit_code -ne 0) { $failReasons.Add("process_exit_code=$($cap.exit_code)") }
if (-not $parseOk) { $failReasons.Add("json_parse_failed:$parseError") }
if ($parseOk -and [string]::IsNullOrWhiteSpace([string]$sessionId)) { $failReasons.Add('missing_sessionId') }
if ($parseOk -and [string]::IsNullOrWhiteSpace([string]$stopReason)) { $failReasons.Add('missing_stopReason') }
if ($parseOk -and $null -eq $textValue) { $failReasons.Add('missing_text_field') }

$stopNorm = $null
if ($stopReason) { $stopNorm = ([string]$stopReason).ToLowerInvariant() }
if ($parseOk -and $stopNorm -and ($failStop -contains $stopNorm)) {
    $failReasons.Add("stopReason=$stopReason")
}

# Transport vs business are separate. status=ok only for confirmed end_turn.
$status = 'failed'
$nextOwner = 'codex'
$businessOk = $false
if ($failReasons.Count -gt 0) {
    $status = 'failed'
    $nextOwner = 'codex'
} elseif ($stopNorm -and ($incompleteStop -contains $stopNorm)) {
    $status = 'incomplete'
    $nextOwner = 'grok'
} elseif ($stopNorm -and ($confirmedOkStop -contains $stopNorm)) {
    $status = 'ok'
    $nextOwner = 'grok'
    $businessOk = $true
} else {
    # Unknown stopReason: not a confirmed success.
    $status = 'needs_review'
    $nextOwner = 'codex'
    $failReasons.Add("unknown_stopReason=$stopReason")
}

$wrapperExit = 1
if ($status -eq 'ok') { $wrapperExit = 0 }
elseif ($status -eq 'incomplete') { $wrapperExit = 2 }
elseif ($status -eq 'needs_review') { $wrapperExit = 3 }

$handoff = [ordered]@{
    schema = 'gs.grok.handoff.v1'
    job_id = $JobId
    status = $status
    transport_ok = $transportOk
    business_ok = $businessOk
    next_owner = $nextOwner
    grok_exit_code = $cap.exit_code
    wrapper_exit_code = $wrapperExit
    json_parse_ok = $parseOk
    json_parse_error = $parseError
    session_id = $(if ($sessionId) { [string]$sessionId } else { $null })
    stop_reason = $(if ($stopReason) { [string]$stopReason } else { $null })
    model = $(if ($modelName) { [string]$modelName } else { $null })
    text_present = $(if ($null -eq $textValue) { $false } else { $true })
    text_length = $(if ($null -eq $textValue) { $null } else { ([string]$textValue).Length })
    pid = $cap.pid
    duration_ms = $cap.duration_ms
    timed_out = [bool]$cap.timed_out
    issues = @($failReasons)
    outputs = @{
        raw_json = $rawJsonPath
        stderr_log = $stderrPath
        command = $commandPath
        exitcode = $exitPath
        handoff = $handoffPath
        live_status = $livePath
    }
    notes = @(
        'JSON file existence is not success; parse + exit code + required fields are required.',
        'transport_ok means the process started, exited, and stdout/stderr were captured. It is not business success.',
        'business_ok / status=ok is allowed only for confirmed stopReason=end_turn.',
        'Unknown stopReason is needs_review (not success). max_turns is incomplete.',
        'stderr MCP/rule warnings are not automatic failure.',
        'This wrapper does not auto-retry. Orchestrator may retry once (max two attempts) then hand to Codex.',
        'Secrets are not logged. resume_session_id_set is a boolean only. Default environment is inherited; auth vars are not read.',
        '--resume is supported as an argument but is not marked verified by this wrapper.'
    )
    created_utc = [DateTime]::UtcNow.ToString('o')
}

$handoffJson = $handoff | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($handoffPath, $handoffJson, (New-Object System.Text.UTF8Encoding $false))

Write-Output $handoffJson
exit $wrapperExit
