param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [Parameter(Mandatory = $true)]
    [string]$SessionId,

    [Parameter(Mandatory = $true)]
    [string]$Role,

    [Parameter(Mandatory = $true)]
    [string]$Fingerprint,

    [Parameter(Mandatory = $true)]
    [string]$ReplacementSessionName,

    [string]$Model = 'MiniMax-M3',
    [string]$ReasoningEffort = 'provider_default',
    [string]$ModelProfile = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Source transcript does not exist: $SourcePath"
}

New-Item -ItemType Directory -Path $BundlePath -Force | Out-Null

$rawPath = Join-Path $BundlePath 'raw_transcript.jsonl'
Copy-Item -LiteralPath $SourcePath -Destination $rawPath -Force

$hash = (Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash.ToLowerInvariant()
$fileInfo = Get-Item -LiteralPath $rawPath

$stats = [ordered]@{
    source_path = $SourcePath
    raw_transcript = $rawPath
    source_session_id = $SessionId
    role = $Role
    fingerprint = $Fingerprint
    replacement_session_name = $ReplacementSessionName
    size_bytes = [int64]$fileInfo.Length
    sha256 = $hash
    line_count = 0
    parse_errors = 0
    types = [ordered]@{}
    event_types = [ordered]@{}
    first_timestamp = $null
    last_timestamp = $null
    user_messages = 0
    agent_messages = 0
    compacted = 0
    context_compacted = 0
    token_count_events = 0
    latest_context = $null
    recent_messages = @()
}

$reader = [System.IO.File]::OpenText($rawPath)
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        $stats.line_count++
        try {
            $obj = $line | ConvertFrom-Json
        }
        catch {
            $stats.parse_errors++
            continue
        }

        $type = if ($obj.type) { [string]$obj.type } else { 'unknown' }
        if (-not $stats.types.Contains($type)) { $stats.types[$type] = 0 }
        $stats.types[$type]++

        if ($obj.timestamp) {
            if (-not $stats.first_timestamp) { $stats.first_timestamp = [string]$obj.timestamp }
            $stats.last_timestamp = [string]$obj.timestamp
        }

        if ($type -eq 'compacted') {
            $stats.compacted++
        }

        if ($type -eq 'event_msg') {
            $eventType = if ($obj.payload.type) { [string]$obj.payload.type } else { 'unknown' }
            if (-not $stats.event_types.Contains($eventType)) { $stats.event_types[$eventType] = 0 }
            $stats.event_types[$eventType]++

            if ($eventType -eq 'context_compacted') {
                $stats.context_compacted++
            }

            if ($eventType -eq 'user_message' -or $eventType -eq 'agent_message') {
                $roleName = if ($eventType -eq 'user_message') { 'user' } else { 'assistant' }
                if ($roleName -eq 'user') { $stats.user_messages++ } else { $stats.agent_messages++ }

                $message = if ($obj.payload.message) { [string]$obj.payload.message } else { '' }
                if ($message.Length -gt 1200) { $message = $message.Substring(0, 1200) }
                $stats.recent_messages += [ordered]@{
                    line = $stats.line_count
                    timestamp = [string]$obj.timestamp
                    role = $roleName
                    text = $message
                }
                if ($stats.recent_messages.Count -gt 20) {
                    $stats.recent_messages = @($stats.recent_messages | Select-Object -Last 20)
                }
            }

            if ($eventType -eq 'token_count') {
                $stats.token_count_events++
                $window = $obj.payload.info.model_context_window
                $inputTokens = $obj.payload.info.last_token_usage.input_tokens
                if ($window -and $inputTokens) {
                    $pct = [math]::Round(([double]$inputTokens / [double]$window) * 100, 2)
                    $stats.latest_context = [ordered]@{
                        line = $stats.line_count
                        timestamp = [string]$obj.timestamp
                        input_tokens = [int64]$inputTokens
                        model_context_window = [int64]$window
                        pct = $pct
                    }
                }
            }
        }
    }
}
finally {
    $reader.Close()
}

$stats | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'transcript_analysis.json') -Encoding UTF8

$effectiveModelProfile = 'custom'
if (-not [string]::IsNullOrWhiteSpace($ModelProfile)) {
    $effectiveModelProfile = $ModelProfile
} elseif ($Model -eq 'none' -and $ReasoningEffort -eq 'none') {
    $effectiveModelProfile = 'model-free'
} elseif ($Model -eq 'MiniMax-M3') {
    $effectiveModelProfile = 'minimax-m3'
}

$modelConfig = [ordered]@{
    model = $Model
    reasoning_effort = $ReasoningEffort
    model_profile = $effectiveModelProfile
    created_at = (Get-Date).ToUniversalTime().ToString('o')
}
$modelConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $BundlePath 'semantic_model_config.json') -Encoding UTF8

$manifest = [ordered]@{
    artifact_type = 'session_manifest'
    status = 'checkpoint_complete'
    source_session_id = $SessionId
    source_role = $Role
    replacement_session_name = $ReplacementSessionName
    fingerprint = $Fingerprint
    mode = 'Checkpoint'
    model = $Model
    reasoning_effort = $ReasoningEffort
    model_profile = $effectiveModelProfile
    launch_attempted = $false
    created_at = (Get-Date).ToUniversalTime().ToString('o')
    raw_transcript = [ordered]@{
        available = $true
        path = 'raw_transcript.jsonl'
        sha256 = $hash
        line_count = $stats.line_count
        size_bytes = [int64]$fileInfo.Length
    }
    validation = [ordered]@{
        passed = $true
        scope = 'raw export and mechanical checkpoint only'
    }
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'session_manifest.json') -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    raw_transcript = $rawPath
    sha256 = $hash
    line_count = $stats.line_count
}
