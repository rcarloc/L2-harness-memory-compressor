param(
    [string]$OutRoot = ''
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    $OutRoot = Join-Path $ScriptRoot 'runs\token-monitor\hooks'
}

function Write-JsonNoBom {
    param([string]$Path, [object]$Object, [switch]$Append)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = ($Object | ConvertTo-Json -Depth 50 -Compress) + [Environment]::NewLine
    $encoding = New-Object System.Text.UTF8Encoding($false)
    if ($Append) {
        [System.IO.File]::AppendAllText($Path, $json, $encoding)
    } else {
        [System.IO.File]::WriteAllText($Path, $json, $encoding)
    }
}

function Write-HookError {
    param([string]$Message, [object]$HookInput)
    $errorPath = Join-Path $OutRoot 'hook-errors.jsonl'
    $entry = [ordered]@{
        captured_at = (Get-Date).ToUniversalTime().ToString('o')
        message = $Message
        hook_event_name = if ($HookInput -and $HookInput.hook_event_name) { [string]$HookInput.hook_event_name } else { $null }
        session_id = if ($HookInput -and $HookInput.session_id) { [string]$HookInput.session_id } else { $null }
        turn_id = if ($HookInput -and $HookInput.turn_id) { [string]$HookInput.turn_id } else { $null }
        transcript_path = if ($HookInput -and $HookInput.transcript_path) { [string]$HookInput.transcript_path } else { $null }
    }
    Write-JsonNoBom -Path $errorPath -Object $entry -Append
}

function Get-ExistingSessions {
    param([string]$CurrentPath)
    $sessions = [ordered]@{}
    if (-not (Test-Path -LiteralPath $CurrentPath)) {
        return $sessions
    }
    try {
        $current = Get-Content -LiteralPath $CurrentPath -Raw | ConvertFrom-Json
        if ($current.sessions) {
            foreach ($property in $current.sessions.PSObject.Properties) {
                $sessions[$property.Name] = $property.Value
            }
        }
    }
    catch {
        return [ordered]@{}
    }
    return $sessions
}

function Write-CurrentSnapshot {
    param([object]$Event)
    $currentPath = Join-Path $OutRoot 'current.json'
    $sessions = Get-ExistingSessions -CurrentPath $currentPath
    $sessions[[string]$Event.session_id] = [ordered]@{
        session_id = $Event.session_id
        turn_id = $Event.turn_id
        transcript_path = $Event.transcript_path
        latest_usage = $Event.latest_usage
        size_bytes = $Event.size_bytes
        recommendation = $Event.recommendation
        updated_at = $Event.captured_at
    }
    $current = [ordered]@{
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        sessions = $sessions
    }
    Write-JsonNoBom -Path $currentPath -Object $current
}

function Write-ContinueResponse {
    ([ordered]@{ 'continue' = $true } | ConvertTo-Json -Depth 5 -Compress)
}

try {
    $inputJson = [Console]::In.ReadToEnd()
    $hookInput = $null
    try {
        $hookInput = $inputJson | ConvertFrom-Json
    }
    catch {
        Write-HookError -Message ('Malformed hook JSON: ' + $_.Exception.Message) -HookInput $null
        Write-ContinueResponse
        exit 0
    }

    if ([string]$hookInput.hook_event_name -ne 'Stop') {
        Write-ContinueResponse
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace([string]$hookInput.transcript_path)) {
        Write-HookError -Message 'Stop hook input did not include transcript_path.' -HookInput $hookInput
        Write-ContinueResponse
        exit 0
    }

    if (-not (Test-Path -LiteralPath ([string]$hookInput.transcript_path))) {
        Write-HookError -Message ('Transcript path was not readable: ' + [string]$hookInput.transcript_path) -HookInput $hookInput
        Write-ContinueResponse
        exit 0
    }

    $resolvedTranscript = (Resolve-Path -LiteralPath ([string]$hookInput.transcript_path)).Path
    $analysis = & (Join-Path $ScriptRoot 'src\Read-CodexTokenUsage.ps1') -SourcePath $resolvedTranscript
    $latestUsage = if ($analysis.latest_token_event) { $analysis.latest_token_event.usage } else { $null }
    $eventSessionId = if ($hookInput.session_id) { [string]$hookInput.session_id } elseif ($analysis.session_id) { [string]$analysis.session_id } else { 'unknown-session' }

    $event = [ordered]@{
        captured_at = (Get-Date).ToUniversalTime().ToString('o')
        hook_event_name = [string]$hookInput.hook_event_name
        session_id = $eventSessionId
        turn_id = if ($hookInput.turn_id) { [string]$hookInput.turn_id } else { $null }
        transcript_path = $resolvedTranscript
        latest_usage = $latestUsage
        size_bytes = $analysis.size_bytes
        size_mb = $analysis.size_mb
        record_count = $analysis.record_count
        compacted_count = $analysis.compacted_count
        compressed_only_shape = $analysis.compressed_only_shape
        token_event_count = $analysis.token_event_count
        unique_token_event_count = $analysis.unique_token_event_count
        recommendation = $analysis.recommendation
    }

    Write-JsonNoBom -Path (Join-Path $OutRoot 'events.jsonl') -Object $event -Append
    Write-CurrentSnapshot -Event $event
    Write-ContinueResponse
    exit 0
}
catch {
    try {
        Write-HookError -Message ('Unexpected hook failure: ' + $_.Exception.Message) -HookInput $hookInput
    }
    catch {
        # A hook must not block Codex, even if error logging itself fails.
    }
    Write-ContinueResponse
    exit 0
}
