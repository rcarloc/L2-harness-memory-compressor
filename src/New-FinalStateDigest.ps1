param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [int]$TailPercent = 20,
    [int]$MinTailEvents = 30,
    [int]$MaxItemChars = 2400
)

$ErrorActionPreference = 'Stop'

function Limit-Text {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $oneLine = ($Text -replace '\s+', ' ').Trim()
    if ($oneLine.Length -le $MaxItemChars) { return $oneLine }
    return $oneLine.Substring(0, $MaxItemChars)
}

function New-ItemFromEvent {
    param($Event)
    [ordered]@{
        line = [int]$Event.source_line
        timestamp = [string]$Event.timestamp
        type = [string]$Event.type
        text = Limit-Text ([string]$Event.text)
    }
}

function Add-UniqueItem {
    param(
        [System.Collections.ArrayList]$Items,
        $Item
    )

    $key = ([string]$Item.line) + '|' + ([string]$Item.type) + '|' + ([string]$Item.text)
    foreach ($existing in $Items) {
        $existingKey = ([string]$existing.line) + '|' + ([string]$existing.type) + '|' + ([string]$existing.text)
        if ($existingKey -eq $key) { return }
    }
    [void]$Items.Add($Item)
}

function Get-TextFromRawEvent {
    param($RawEvent)

    if ($RawEvent.type -eq 'event_msg') {
        $payload = $RawEvent.payload
        switch ($payload.type) {
            'agent_message' { return [string]$payload.message }
            'task_complete' { return [string]$payload.last_agent_message }
            'patch_apply_end' { return [string]$payload.stdout }
            default { return '' }
        }
    }

    if ($RawEvent.type -eq 'response_item') {
        $payload = $RawEvent.payload
        switch ($payload.type) {
            'message' {
                $parts = @()
                foreach ($content in @($payload.content)) {
                    if ($content.text) { $parts += [string]$content.text }
                }
                return ($parts -join "`n")
            }
            'function_call_output' { return [string]$payload.output }
            'custom_tool_call_output' { return [string]$payload.output }
            default { return '' }
        }
    }

    return ''
}

function New-ItemFromRawEvent {
    param(
        $RawEvent,
        [int]$Line
    )

    [ordered]@{
        line = $Line
        timestamp = [string]$RawEvent.timestamp
        type = if ($RawEvent.payload.type) { [string]$RawEvent.payload.type } else { [string]$RawEvent.type }
        text = Limit-Text (Get-TextFromRawEvent -RawEvent $RawEvent)
    }
}

$streamPath = Join-Path $BundlePath 'semantic_event_stream.jsonl'
if (-not (Test-Path -LiteralPath $streamPath)) {
    throw "Missing semantic_event_stream.jsonl in $BundlePath"
}

$events = @()
foreach ($line in Get-Content -LiteralPath $streamPath) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $events += ($line | ConvertFrom-Json)
}

if ($events.Count -eq 0) {
    throw 'No semantic events available for final-state digest.'
}

$tailCount = [math]::Ceiling($events.Count * ($TailPercent / 100.0))
$tailCount = [math]::Max($tailCount, $MinTailEvents)
$tailCount = [math]::Min($tailCount, $events.Count)
$tail = @($events | Select-Object -Last $tailCount)

$finalState = [System.Collections.ArrayList]::new()
$completed = [System.Collections.ArrayList]::new()
$nextSteps = [System.Collections.ArrayList]::new()
$risks = [System.Collections.ArrayList]::new()
$userCorrections = [System.Collections.ArrayList]::new()

foreach ($event in $tail) {
    $text = [string]$event.text
    $isMessageLike = $event.type -in @('agent_message', 'user_message', 'message', 'task_complete') -or $event.role -in @('assistant', 'user')
    if (-not $isMessageLike) { continue }

    $item = New-ItemFromEvent -Event $event

    if ($text -match '(?i)\b(final state|final|done|completed|passed|verified|implemented|created|saved|restored|merged)\b') {
        Add-UniqueItem -Items $finalState -Item $item
    }
    if ($text -match '(?i)\b(pass|passed|green|verified|success|completed|done|fixed)\b') {
        Add-UniqueItem -Items $completed -Item $item
    }
    if ($text -match '(?i)\b(next|remaining|follow.?up|todo|should|needs?|continue|rerun|verify)\b') {
        Add-UniqueItem -Items $nextSteps -Item $item
    }
    if ($text -match '(?i)\b(risk|blocked|failed|error|unresolved|missing|timeout|mismatch|caveat)\b') {
        Add-UniqueItem -Items $risks -Item $item
    }
    if (($event.role -eq 'user' -or $event.type -eq 'user_message') -and $text -match "(?i)\b(wrong|not good|low quality|instead|prefer|should|do not|don't|redo|criticism)\b") {
        Add-UniqueItem -Items $userCorrections -Item $item
    }
}

$rawTranscriptPath = Join-Path $BundlePath 'raw_transcript.jsonl'
if (Test-Path -LiteralPath $rawTranscriptPath) {
    $rawLines = @(Get-Content -LiteralPath $rawTranscriptPath)
    $rawTailCount = [math]::Max($tailCount, 50)
    $rawStart = [math]::Max(0, $rawLines.Count - $rawTailCount)

    for ($i = $rawStart; $i -lt $rawLines.Count; $i++) {
        $line = $rawLines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try {
            $rawEvent = $line | ConvertFrom-Json
        } catch {
            continue
        }

        $rawText = Get-TextFromRawEvent -RawEvent $rawEvent
        if ([string]::IsNullOrWhiteSpace($rawText)) { continue }

        $rawType = if ($rawEvent.payload.type) { [string]$rawEvent.payload.type } else { [string]$rawEvent.type }
        $isSummaryLike = $rawType -in @('agent_message', 'task_complete', 'message')
        $isPatchLike = $rawType -in @('patch_apply_end', 'custom_tool_call_output') -and $rawText -match '(?i)\b(updated the following files|successfully applied|success\.)\b'
        $isVerificationLike = $rawType -eq 'function_call_output' -and $rawText -match '(?i)\b(pass|passed|tests? run|vitest|pytest|npm test|success)\b'

        if (-not ($isSummaryLike -or $isPatchLike -or $isVerificationLike)) { continue }

        $rawItem = New-ItemFromRawEvent -RawEvent $rawEvent -Line ($i + 1)

        if ($rawText -match '(?i)\b(final state|status check complete|final|done|completed|passed|verified|implemented|created|saved|restored|merged|edited|patched|changed|updated the following files)\b') {
            Add-UniqueItem -Items $finalState -Item $rawItem
        }
        if ($rawText -match '(?i)\b(pass|passed|green|verified|success|completed|done|fixed|updated the following files)\b') {
            Add-UniqueItem -Items $completed -Item $rawItem
        }
        if ($rawText -match '(?i)\b(next|remaining|follow.?up|todo|should|needs?|continue|rerun|verify|pending|residual)\b') {
            Add-UniqueItem -Items $nextSteps -Item $rawItem
        }
        if ($rawText -match '(?i)\b(risk|blocked|failed|error|unresolved|missing|timeout|mismatch|caveat|pending)\b') {
            Add-UniqueItem -Items $risks -Item $rawItem
        }
        if (($rawEvent.payload.role -eq 'user' -or $rawEvent.role -eq 'user') -and $rawText -match "(?i)\b(wrong|not good|low quality|instead|prefer|should|do not|don't|redo|criticism)\b") {
            Add-UniqueItem -Items $userCorrections -Item $rawItem
        }
    }
}

$digest = [ordered]@{
    artifact_type = 'final_state_digest'
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    total_event_count = $events.Count
    tail_event_count = $tail.Count
    tail_percent = $TailPercent
    first_tail_line = [int]$tail[0].source_line
    last_tail_line = [int]$tail[-1].source_line
    final_state_candidates = @($finalState | Select-Object -Last 20)
    completed_or_verified = @($completed | Select-Object -Last 20)
    next_steps = @($nextSteps | Select-Object -Last 20)
    risks_or_caveats = @($risks | Select-Object -Last 20)
    user_corrections = @($userCorrections | Select-Object -Last 20)
}

$digest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'final_state_digest.json') -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    tail_event_count = $tail.Count
    final_state_candidates = $digest.final_state_candidates.Count
}
