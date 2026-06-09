param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [int]$MaxTextChars = 4000
)

$ErrorActionPreference = 'Stop'

$rawPath = Join-Path $BundlePath 'raw_transcript.jsonl'
if (-not (Test-Path -LiteralPath $rawPath)) {
    throw "Missing raw transcript: $rawPath"
}

$outPath = Join-Path $BundlePath 'semantic_event_stream.jsonl'
$keywords = @(
    'Product PASS',
    'TECH_PASS',
    'PARTIAL',
    'FAIL',
    'BLOCKED',
    'ready-for-worker',
    'worker',
    'dispatch',
    'stale',
    'frozen',
    'No Product PASS',
    '#610',
    '#613',
    '#623',
    '#634',
    'G7',
    'GitHub',
    'GH',
    'actions/runs',
    'issuecomment',
    'PR',
    'merge',
    'label'
)

function Limit-Text {
    param([string]$Text)
    if (-not $Text) { return '' }
    if ($Text.Length -le $MaxTextChars) { return $Text }
    return $Text.Substring(0, $MaxTextChars)
}

function Test-HighSignal {
    param(
        [string]$Text,
        [string[]]$Terms
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($term in $Terms) {
        if ($Text.Contains($term)) { return $true }
    }
    if ($Text -match 'https://github\.com/' -or $Text -match '#\d{3,5}') { return $true }
    return $false
}

function Get-ContentText {
    param($Content)
    if (-not $Content) { return '' }
    if ($Content -is [string]) { return $Content }
    $parts = @()
    foreach ($item in @($Content)) {
        if ($item.text) { $parts += [string]$item.text }
        elseif ($item.content) { $parts += [string]$item.content }
    }
    return ($parts -join "`n")
}

$counts = [ordered]@{}
$lineNo = 0
$kept = 0
$seenTaskComplete = @{}
$writer = [System.IO.StreamWriter]::new($outPath, $false, [System.Text.Encoding]::UTF8)
$reader = [System.IO.File]::OpenText($rawPath)

try {
    while (($line = $reader.ReadLine()) -ne $null) {
        $lineNo++
        try { $obj = $line | ConvertFrom-Json } catch { continue }

        $record = $null
        $type = [string]$obj.type
        $timestamp = if ($obj.timestamp) { [string]$obj.timestamp } else { '' }

        if ($type -eq 'event_msg') {
            $eventType = [string]$obj.payload.type
            if ($eventType -eq 'user_message') {
                $record = [ordered]@{
                    source_line = $lineNo
                    timestamp = $timestamp
                    type = 'user_message'
                    role = 'user'
                    text = Limit-Text ([string]$obj.payload.message)
                }
            }
            elseif ($eventType -eq 'agent_message') {
                $text = [string]$obj.payload.message
                if (Test-HighSignal $text $keywords) {
                    $record = [ordered]@{
                        source_line = $lineNo
                        timestamp = $timestamp
                        type = 'agent_message'
                        role = 'assistant'
                        text = Limit-Text $text
                    }
                }
            }
            elseif ($eventType -eq 'context_compacted') {
                $record = [ordered]@{
                    source_line = $lineNo
                    timestamp = $timestamp
                    type = 'context_compacted'
                    role = 'system'
                    text = Limit-Text ($obj.payload | ConvertTo-Json -Depth 6 -Compress)
                }
            }
            elseif ($eventType -eq 'task_complete') {
                $text = [string]$obj.payload.last_agent_message
                if ((Test-HighSignal $text $keywords) -and -not $seenTaskComplete.ContainsKey($text)) {
                    $seenTaskComplete[$text] = $true
                    $record = [ordered]@{
                        source_line = $lineNo
                        timestamp = $timestamp
                        type = 'task_complete'
                        role = 'system'
                        text = Limit-Text $text
                    }
                }
            }
        }
        elseif ($type -eq 'compacted') {
            $tail = @()
            foreach ($item in @($obj.payload.replacement_history | Select-Object -Last 10)) {
                $text = Get-ContentText $item.content
                if ($text) {
                    $tail += [ordered]@{
                        role = if ($item.role) { [string]$item.role } else { [string]$item.type }
                        text = Limit-Text $text
                    }
                }
            }
            $record = [ordered]@{
                source_line = $lineNo
                timestamp = $timestamp
                type = 'compacted'
                role = 'system'
                replacement_history_tail = $tail
            }
        }

        if ($record) {
            $recordType = [string]$record.type
            if (-not $counts.Contains($recordType)) { $counts[$recordType] = 0 }
            $counts[$recordType]++
            $kept++
            $writer.WriteLine(($record | ConvertTo-Json -Depth 20 -Compress))
        }
    }
}
finally {
    $reader.Close()
    $writer.Close()
}

$manifest = [ordered]@{
    artifact_type = 'semantic_event_manifest'
    mode = 'cheap-test'
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    raw_transcript = 'raw_transcript.jsonl'
    semantic_event_stream = 'semantic_event_stream.jsonl'
    source_lines_scanned = $lineNo
    semantic_events_written = $kept
    max_text_chars = $MaxTextChars
    counts = $counts
    keywords = $keywords
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'semantic_event_manifest.json') -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    semantic_event_stream = $outPath
    semantic_events_written = $kept
}
