param(
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

    [int]$TargetChars = 120000,
    [string]$ArtifactMode = 'chunking',
    [string]$SemanticMode = 'model_free_chunking',
    [string]$ReportTitle = 'Handoff Chunking Report',
    [string]$ReportStatus = 'MODEL_FREE_CHUNKING'
)

$ErrorActionPreference = 'Stop'

function Get-ContentText {
    param($Obj)

    if ($Obj.payload.message) { return [string]$Obj.payload.message }
    if ($Obj.payload.last_agent_message) { return [string]$Obj.payload.last_agent_message }
    if ($Obj.payload.output) { return [string]$Obj.payload.output }
    if ($Obj.payload.arguments) { return [string]$Obj.payload.arguments }

    if ($Obj.payload.content) {
        $parts = @()
        foreach ($item in @($Obj.payload.content)) {
            if ($item.text) { $parts += [string]$item.text }
        }
        if ($parts.Count -gt 0) { return ($parts -join "`n") }
    }

    return ($Obj | ConvertTo-Json -Depth 12 -Compress)
}

function Test-HighSignalText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '(?i)(Product PASS|TECH_PASS|\bBLOCKED\b|\bFAIL\b|ready-for-worker|ready for worker|github\.com|actions/runs|issuecomment|pull/\d+|issues/\d+|PR\s*#?\d+|#\d+|#610|#613|#623|#634)')
}

function Get-SignalSnippet {
    param([string]$Text)

    if ($Text.Length -le 4000) { return $Text }

    $pattern = '(?i)(Product PASS|TECH_PASS|\bBLOCKED\b|\bFAIL\b|ready-for-worker|ready for worker|github\.com|actions/runs|issuecomment|pull/\d+|issues/\d+|PR\s*#?\d+|#\d+|#610|#613|#623|#634)'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -eq 0) { return $Text.Substring(0, 4000) }

    $snippets = @()
    foreach ($match in @($matches | Select-Object -First 8)) {
        $start = [math]::Max(0, $match.Index - 500)
        $length = [math]::Min(1000, $Text.Length - $start)
        $snippets += $Text.Substring($start, $length)
    }
    $snippet = ($snippets -join "`n...[snip]...`n")
    if ($snippet.Length -gt 4000) { return $snippet.Substring(0, 4000) }
    return $snippet
}

function ConvertTo-SemanticEvent {
    param(
        $Obj,
        [int]$SourceLine,
        [string]$EventType,
        [string]$Text,
        [string]$Role,
        [bool]$HighSignal,
        [bool]$Truncated
    )

    $event = [ordered]@{
        source_line = $SourceLine
        timestamp = if ($Obj.timestamp) { [string]$Obj.timestamp } else { '' }
        type = $EventType
    }
    if ($Role) { $event.role = $Role }
    if ($HighSignal) { $event.high_signal = $true }
    if ($Truncated) { $event.truncated = $true }
    $event.text = $Text
    return $event
}

$rawPath = Join-Path $BundlePath 'raw_transcript.jsonl'
if (-not (Test-Path -LiteralPath $rawPath)) {
    throw "Missing raw_transcript.jsonl in $BundlePath"
}

$streamPath = Join-Path $BundlePath 'semantic_event_stream.jsonl'
$chunkDir = Join-Path $BundlePath 'semantic_chunks'
if (Test-Path -LiteralPath $chunkDir) {
    Remove-Item -LiteralPath $chunkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $chunkDir -Force | Out-Null

$events = @()
$counts = [ordered]@{}
$dropped = [ordered]@{
    parse_errors = 0
    token_count = 0
    tool_payload = 0
    thread_goal_updated = 0
    task_complete_duplicate = 0
    task_complete_low_value = 0
    low_signal_response_item = 0
    other_low_signal = 0
}
$seenText = @{}
$sourceLinesScanned = 0
$firstTimestamp = $null
$lastTimestamp = $null

$reader = [System.IO.File]::OpenText($rawPath)
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        $sourceLinesScanned++
        try {
            $obj = $line | ConvertFrom-Json
        }
        catch {
            $dropped.parse_errors++
            continue
        }

        if ($obj.timestamp) {
            if (-not $firstTimestamp) { $firstTimestamp = [string]$obj.timestamp }
            $lastTimestamp = [string]$obj.timestamp
        }

        $rawType = if ($obj.type) { [string]$obj.type } else { 'unknown' }
        $payloadType = if ($obj.payload.type) { [string]$obj.payload.type } else { '' }
        $eventType = if ($payloadType) { $payloadType } else { $rawType }
        $eventRole = ''
        $keep = $false
        $dropReason = ''
        $text = Get-ContentText $obj
        $highSignal = Test-HighSignalText $text

        if ($payloadType -eq 'thread_goal_updated') {
            $dropReason = 'thread_goal_updated'
        }
        elseif ($payloadType -eq 'token_count') {
            $dropReason = 'token_count'
        }
        elseif ($payloadType -eq 'mcp_tool_call_end' -or $payloadType -eq 'mcp_tool_call_begin') {
            $dropReason = 'tool_payload'
        }
        elseif ($rawType -eq 'compacted' -or $payloadType -eq 'context_compacted') {
            $keep = $true
            $eventType = if ($payloadType) { $payloadType } else { 'compacted' }
        }
        elseif ($rawType -eq 'session_meta') {
            $keep = $true
            $eventType = 'session_meta'
            $text = "session_id=$($obj.payload.id); cwd=$($obj.payload.cwd); source=$($obj.payload.source); originator=$($obj.payload.originator)"
        }
        elseif ($payloadType -eq 'user_message') {
            $keep = $true
            $eventRole = 'user'
            $eventType = 'user_message'
        }
        elseif ($payloadType -eq 'agent_message') {
            $keep = $true
            $eventRole = 'assistant'
            $eventType = 'agent_message'
        }
        elseif ($payloadType -eq 'task_complete') {
            $eventType = 'task_complete'
            if (-not $highSignal) {
                $dropReason = 'task_complete_low_value'
            }
            elseif ($seenText.ContainsKey($text)) {
                $dropReason = 'task_complete_duplicate'
            }
            else {
                $keep = $true
            }
        }
        elseif ($rawType -eq 'response_item') {
            if ($payloadType -eq 'reasoning') {
                $dropReason = 'low_signal_response_item'
            }
            elseif ($obj.payload.role -eq 'user' -or $obj.payload.role -eq 'assistant') {
                $dropReason = 'low_signal_response_item'
            }
            elseif ($highSignal) {
                $keep = $true
                $eventType = if ($payloadType) { $payloadType } else { 'response_item' }
            }
            else {
                $dropReason = 'low_signal_response_item'
            }
        }
        elseif ($highSignal) {
            $keep = $true
        }
        else {
            $dropReason = 'other_low_signal'
        }

        if (-not $keep) {
            if (-not $dropped.Contains($dropReason)) { $dropped[$dropReason] = 0 }
            $dropped[$dropReason]++
            continue
        }

        $truncated = $false
        if ($text.Length -gt 4000) {
            $text = if ($highSignal) { Get-SignalSnippet $text } else { $text.Substring(0, 4000) }
            $truncated = $true
        }

        if (-not $counts.Contains($eventType)) { $counts[$eventType] = 0 }
        $counts[$eventType]++
        if (-not $seenText.ContainsKey($text)) { $seenText[$text] = $true }

        $events += ConvertTo-SemanticEvent `
            -Obj $obj `
            -SourceLine $sourceLinesScanned `
            -EventType $eventType `
            -Text $text `
            -Role $eventRole `
            -HighSignal:$highSignal `
            -Truncated:$truncated
    }
}
finally {
    $reader.Close()
}

$writer = [System.IO.StreamWriter]::new($streamPath, $false, [System.Text.UTF8Encoding]::new($false))
try {
    foreach ($event in $events) {
        $writer.WriteLine(($event | ConvertTo-Json -Depth 20 -Compress))
    }
}
finally {
    $writer.Close()
}

function Write-Chunk {
    param(
        [object[]]$ChunkEvents,
        [int]$Index,
        [string]$ChunkDir
    )

    if ($ChunkEvents.Count -eq 0) { return $null }
    $name = ('chunk_{0:000}.jsonl' -f $Index)
    $path = Join-Path $ChunkDir $name
    $chunkWriter = [System.IO.StreamWriter]::new($path, $false, [System.Text.UTF8Encoding]::new($false))
    $charCount = 0
    try {
        foreach ($event in $ChunkEvents) {
            $json = $event | ConvertTo-Json -Depth 20 -Compress
            $charCount += $json.Length + 1
            $chunkWriter.WriteLine($json)
        }
    }
    finally {
        $chunkWriter.Close()
    }

    return [ordered]@{
        index = $Index
        name = $name
        path = "semantic_chunks/$name"
        event_count = $ChunkEvents.Count
        char_count = $charCount
        first_source_line = [int]$ChunkEvents[0].source_line
        last_source_line = [int]$ChunkEvents[$ChunkEvents.Count - 1].source_line
        first_timestamp = [string]$ChunkEvents[0].timestamp
        last_timestamp = [string]$ChunkEvents[$ChunkEvents.Count - 1].timestamp
    }
}

$chunks = @()
$current = @()
$currentChars = 0
$chunkIndex = 1
foreach ($event in $events) {
    $json = $event | ConvertTo-Json -Depth 20 -Compress
    if ($current.Count -gt 0 -and ($currentChars + $json.Length + 1) -gt $TargetChars) {
        $chunk = Write-Chunk -ChunkEvents $current -Index $chunkIndex -ChunkDir $chunkDir
        if ($chunk) { $chunks += $chunk }
        $chunkIndex++
        $current = @()
        $currentChars = 0
    }
    $current += $event
    $currentChars += $json.Length + 1
}

$lastChunk = Write-Chunk -ChunkEvents $current -Index $chunkIndex -ChunkDir $chunkDir
if ($lastChunk) { $chunks += $lastChunk }

$generatedAt = (Get-Date).ToUniversalTime().ToString('o')
$keywords = @('Product PASS', 'TECH_PASS', 'BLOCKED', 'FAIL', 'ready-for-worker', 'GitHub', 'github.com', 'PR', '#610', '#613', '#623', '#634')

$eventManifest = [ordered]@{
    mode = $ArtifactMode
    semantic_mode = $SemanticMode
    generated_at = $generatedAt
    raw_transcript = $rawPath
    semantic_event_stream = $streamPath
    source_session_id = $SessionId
    source_role = $Role
    fingerprint = $Fingerprint
    replacement_session_name = $ReplacementSessionName
    source_lines_scanned = $sourceLinesScanned
    semantic_events_written = $events.Count
    first_timestamp = $firstTimestamp
    last_timestamp = $lastTimestamp
    counts = $counts
    dropped = $dropped
    keywords = $keywords
}
$eventManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'semantic_event_manifest.json') -Encoding UTF8

$chunkManifest = [ordered]@{
    mode = $ArtifactMode
    semantic_mode = $SemanticMode
    generated_at = $generatedAt
    target_chars = $TargetChars
    overlap_events = 0
    chunk_count = $chunks.Count
    chunks = $chunks
}
$chunkManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'semantic_chunk_manifest.json') -Encoding UTF8

$report = @"
# $ReportTitle

Status: $ReportStatus

No model call was made. No thread was launched.

## Evidence

- Raw transcript lines scanned: $sourceLinesScanned
- Semantic events retained: $($events.Count)
- Semantic chunks written: $($chunks.Count)
- First timestamp: $firstTimestamp
- Last timestamp: $lastTimestamp

## Filtering

- Dropped token_count events: $($dropped.token_count)
- Dropped tool payload events: $($dropped.tool_payload)
- Dropped thread_goal_updated events: $($dropped.thread_goal_updated)
- Dropped low-value task_complete events: $($dropped.task_complete_low_value)
- Dropped duplicate task_complete events: $($dropped.task_complete_duplicate)

## Artifacts

- semantic_event_stream.jsonl
- semantic_event_manifest.json
- semantic_chunks/chunk_###.jsonl
- semantic_chunk_manifest.json
"@
$report | Set-Content -LiteralPath (Join-Path $BundlePath 'handoff_report.md') -Encoding UTF8

$sessionManifestPath = Join-Path $BundlePath 'session_manifest.json'
if (Test-Path -LiteralPath $sessionManifestPath) {
    $sessionManifest = Get-Content -LiteralPath $sessionManifestPath -Raw | ConvertFrom-Json
    $sessionManifest.status = if ($ArtifactMode -eq 'cheap-test') { 'cheap_test_complete' } else { 'chunking_complete' }
    $sessionManifest.mode = if ($ArtifactMode -eq 'cheap-test') { 'CheapTest' } else { 'Chunk' }
    $sessionManifest.launch_attempted = $false
    $sessionManifest | Add-Member -NotePropertyName semantic_mode -NotePropertyValue $ArtifactMode -Force
    $sessionManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $sessionManifestPath -Encoding UTF8
}

[pscustomobject]@{
    bundle_path = $BundlePath
    mode = $ArtifactMode
    semantic_events_written = $events.Count
    chunk_count = $chunks.Count
}
