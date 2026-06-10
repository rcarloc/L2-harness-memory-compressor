param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [int]$RecentToolOutputLimit = 5
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Codex rollout not found: $SourcePath"
}

function Get-TokenStatus {
    param([Nullable[Int64]]$InputTokens)
    if ($null -eq $InputTokens) { return 'unknown' }
    if ($InputTokens -lt 35000) { return 'strong' }
    if ($InputTokens -lt 60000) { return 'pass' }
    if ($InputTokens -le 100000) { return 'warn' }
    return 'fail'
}

function Get-UsageFingerprint {
    param([object]$Usage, [object]$ContextWindow)
    if ($null -eq $Usage) { return '' }
    $parts = @(
        [string]$Usage.input_tokens,
        [string]$Usage.cached_input_tokens,
        [string]$Usage.output_tokens,
        [string]$Usage.reasoning_output_tokens,
        [string]$Usage.total_tokens,
        [string]$ContextWindow
    )
    return ($parts -join '|')
}

function Convert-Usage {
    param([object]$Usage, [object]$ContextWindow)

    if ($null -eq $Usage) { return $null }

    $inputTokens = if ($null -ne $Usage.input_tokens) { [int64]$Usage.input_tokens } else { $null }
    $cachedTokens = if ($null -ne $Usage.cached_input_tokens) { [int64]$Usage.cached_input_tokens } else { $null }
    $uncachedTokens = $null
    if ($null -ne $inputTokens -and $null -ne $cachedTokens) {
        $uncachedTokens = [int64]([math]::Max(0, $inputTokens - $cachedTokens))
    }

    $window = if ($null -ne $ContextWindow) { [int64]$ContextWindow } else { $null }
    $pressure = $null
    if ($null -ne $inputTokens -and $null -ne $window -and $window -gt 0) {
        $pressure = [math]::Round(([double]$inputTokens / [double]$window) * 100, 2)
    }

    [ordered]@{
        input_tokens = $inputTokens
        cached_input_tokens = $cachedTokens
        uncached_input_tokens = $uncachedTokens
        output_tokens = if ($null -ne $Usage.output_tokens) { [int64]$Usage.output_tokens } else { $null }
        reasoning_output_tokens = if ($null -ne $Usage.reasoning_output_tokens) { [int64]$Usage.reasoning_output_tokens } else { $null }
        total_tokens = if ($null -ne $Usage.total_tokens) { [int64]$Usage.total_tokens } else { $null }
        model_context_window = $window
        context_pressure_pct = $pressure
        status = Get-TokenStatus -InputTokens $inputTokens
    }
}

$resolved = (Resolve-Path -LiteralPath $SourcePath).Path
$fileInfo = Get-Item -LiteralPath $resolved
$sessionId = $null
$recordCount = 0
$parseErrors = 0
$compactedCount = 0
$types = New-Object System.Collections.ArrayList
$tokenEvents = New-Object System.Collections.ArrayList
$uniqueTokenEvents = New-Object System.Collections.ArrayList
$toolOutputs = New-Object System.Collections.ArrayList
$lastFingerprint = $null
$firstTimestamp = $null
$lastTimestamp = $null

$stream = [System.IO.File]::Open($resolved, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $recordCount++
        try {
            $obj = $line | ConvertFrom-Json
        }
        catch {
            $parseErrors++
            continue
        }

        $type = if ($obj.type) { [string]$obj.type } else { 'unknown' }
        [void]$types.Add($type)
        if ($obj.timestamp) {
            if (-not $firstTimestamp) { $firstTimestamp = [string]$obj.timestamp }
            $lastTimestamp = [string]$obj.timestamp
        }

        $payload = $obj.payload
        if ($type -eq 'session_meta' -and $payload.id) {
            $sessionId = [string]$payload.id
        }
        if ($type -eq 'compacted') {
            $compactedCount++
        }

        if ($type -eq 'event_msg' -and $payload.type -eq 'token_count') {
            $info = $payload.info
            $usage = $info.last_token_usage
            $contextWindow = $info.model_context_window
            $fingerprint = Get-UsageFingerprint -Usage $usage -ContextWindow $contextWindow
            $converted = Convert-Usage -Usage $usage -ContextWindow $contextWindow
            $event = [ordered]@{
                line = $recordCount
                timestamp = [string]$obj.timestamp
                fingerprint = $fingerprint
                usage = $converted
            }
            [void]$tokenEvents.Add($event)
            if (-not [string]::IsNullOrWhiteSpace($fingerprint) -and $fingerprint -ne $lastFingerprint) {
                [void]$uniqueTokenEvents.Add($event)
                $lastFingerprint = $fingerprint
            }
        }

        if ($type -eq 'response_item') {
            $item = $payload
            if ($payload.item) { $item = $payload.item }
            if ($item.type -eq 'function_call_output') {
                $output = if ($null -ne $item.output) { [string]$item.output } else { '' }
                $originalTokenCount = $null
                $match = [regex]::Match($output, 'Original token count:\s*([0-9]+)')
                if ($match.Success) {
                    $originalTokenCount = [int64]$match.Groups[1].Value
                }
                $preview = $output
                if ($preview.Length -gt 300) { $preview = $preview.Substring(0, 300) }
                [void]$toolOutputs.Add([ordered]@{
                    line = $recordCount
                    timestamp = [string]$obj.timestamp
                    call_id = [string]$item.call_id
                    original_token_count = $originalTokenCount
                    output_chars = [int64]$output.Length
                    preview = $preview
                })
            }
        }
    }
}
finally {
    $reader.Close()
    $stream.Close()
}

$typeList = @($types)
$compressedOnly = ($typeList.Count -eq 3 -and (($typeList -join ',') -eq 'session_meta,compacted,turn_context'))
$latestUnique = if ($uniqueTokenEvents.Count -gt 0) { $uniqueTokenEvents[$uniqueTokenEvents.Count - 1] } else { $null }

$recentToolOutputs = @($toolOutputs | Sort-Object `
    @{ Expression = { if ($null -ne $_.original_token_count) { [int64]$_.original_token_count } else { 0 } }; Descending = $true },
    @{ Expression = { [int64]$_.output_chars }; Descending = $true } |
    Select-Object -First $RecentToolOutputLimit)

$recommendation = 'no token data available yet'
if ($latestUnique -and $latestUnique.usage) {
    $status = [string]$latestUnique.usage.status
    $largestToolTokens = 0
    if ($recentToolOutputs.Count -gt 0 -and $null -ne $recentToolOutputs[0].original_token_count) {
        $largestToolTokens = [int64]$recentToolOutputs[0].original_token_count
    }
    if ($status -eq 'fail' -and ($fileInfo.Length -ge (3 * 1024 * 1024) -or $compactedCount -ge 2)) {
        $recommendation = 'consider compression'
    }
    elseif ($status -eq 'fail' -and $largestToolTokens -ge 10000) {
        $recommendation = 'investigate recent tool output before compression'
    }
    elseif ($status -eq 'fail') {
        $recommendation = 'monitor one more turn or compress if continuing'
    }
    elseif ($status -eq 'warn') {
        $recommendation = 'monitor next turn'
    }
    else {
        $recommendation = 'no compression needed'
    }
}

[pscustomobject]@{
    path = $resolved
    session_id = $sessionId
    size_bytes = [int64]$fileInfo.Length
    size_mb = [math]::Round(([double]$fileInfo.Length / 1MB), 3)
    last_write_time = $fileInfo.LastWriteTime.ToString('o')
    record_count = $recordCount
    parse_errors = $parseErrors
    first_timestamp = $firstTimestamp
    last_timestamp = $lastTimestamp
    compacted_count = $compactedCount
    compressed_only_shape = [bool]$compressedOnly
    token_event_count = $tokenEvents.Count
    unique_token_event_count = $uniqueTokenEvents.Count
    latest_token_event = $latestUnique
    recent_tool_outputs = $recentToolOutputs
    recommendation = $recommendation
}
