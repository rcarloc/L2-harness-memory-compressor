param(
    [string]$SessionId = '',
    [string]$SourcePath = '',
    [string]$SessionRoot = '',
    [switch]$Watch,
    [double]$Minutes = 30,
    [int]$IntervalSeconds = 5,
    [int]$StableSeconds = 20,
    [string]$OutRoot = '',
    [switch]$Live
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($SessionRoot)) {
    $SessionRoot = Join-Path $env:USERPROFILE '.codex\sessions'
}
if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    $OutRoot = Join-Path $ScriptRoot 'runs\token-monitor'
}
if ($IntervalSeconds -lt 1) {
    throw 'IntervalSeconds must be at least 1.'
}
if ($Minutes -lt 0) {
    throw 'Minutes must be zero or greater.'
}
if ($StableSeconds -lt 0) {
    throw 'StableSeconds must be zero or greater.'
}

function Resolve-CodexRolloutPath {
    param(
        [string]$ExplicitSourcePath,
        [string]$LookupSessionId,
        [string]$LookupRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitSourcePath)) {
        if (-not (Test-Path -LiteralPath $ExplicitSourcePath)) {
            throw "Source rollout not found: $ExplicitSourcePath"
        }
        return (Resolve-Path -LiteralPath $ExplicitSourcePath).Path
    }

    if ([string]::IsNullOrWhiteSpace($LookupSessionId)) {
        throw 'Provide either -SourcePath or -SessionId.'
    }
    if (-not (Test-Path -LiteralPath $LookupRoot)) {
        throw "SessionRoot not found: $LookupRoot"
    }

    $filenameHits = @(Get-ChildItem -LiteralPath $LookupRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$LookupSessionId*" } |
        Sort-Object LastWriteTime -Descending)
    if ($filenameHits.Count -gt 0) {
        return $filenameHits[0].FullName
    }

    $embeddedHits = New-Object System.Collections.ArrayList
    Get-ChildItem -LiteralPath $LookupRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
        $path = $_.FullName
        $matched = $false
        try {
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            try {
                while (($line = $reader.ReadLine()) -ne $null) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    try { $obj = $line | ConvertFrom-Json } catch { continue }
                    if ($obj.type -eq 'session_meta' -and [string]$obj.payload.id -eq $LookupSessionId) {
                        $matched = $true
                        break
                    }
                    if ($obj.type -eq 'session_meta') { break }
                }
            }
            finally {
                $reader.Close()
                $stream.Close()
            }
        }
        catch {
            $matched = $false
        }
        if ($matched) {
            [void]$embeddedHits.Add($_)
        }
    }

    $embeddedHits = @($embeddedHits | Sort-Object LastWriteTime -Descending)
    if ($embeddedHits.Count -gt 0) {
        return $embeddedHits[0].FullName
    }

    throw "No Codex rollout found for session id: $LookupSessionId"
}

function Convert-MonitorSnapshot {
    param([object]$Analysis)
    $latest = $Analysis.latest_token_event
    $usage = if ($latest) { $latest.usage } else { $null }
    [ordered]@{
        captured_at = (Get-Date).ToUniversalTime().ToString('o')
        path = $Analysis.path
        session_id = $Analysis.session_id
        size_bytes = $Analysis.size_bytes
        size_mb = $Analysis.size_mb
        last_write_time = $Analysis.last_write_time
        record_count = $Analysis.record_count
        compacted_count = $Analysis.compacted_count
        compressed_only_shape = $Analysis.compressed_only_shape
        token_event_count = $Analysis.token_event_count
        unique_token_event_count = $Analysis.unique_token_event_count
        latest_token_event = $latest
        latest_usage = $usage
        recent_tool_outputs = $Analysis.recent_tool_outputs
        recommendation = $Analysis.recommendation
    }
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

function Format-NullableNumber {
    param([object]$Value)
    if ($null -eq $Value) { return '-' }
    return ([int64]$Value).ToString('N0')
}

function Write-LiveSnapshot {
    param([string]$Kind, [object]$Snapshot)
    $usage = $Snapshot.latest_usage
    $input = if ($usage) { Format-NullableNumber $usage.input_tokens } else { '-' }
    $cached = if ($usage) { Format-NullableNumber $usage.cached_input_tokens } else { '-' }
    $uncached = if ($usage) { Format-NullableNumber $usage.uncached_input_tokens } else { '-' }
    $output = if ($usage) { Format-NullableNumber $usage.output_tokens } else { '-' }
    $reasoning = if ($usage) { Format-NullableNumber $usage.reasoning_output_tokens } else { '-' }
    $status = if ($usage) { [string]$usage.status } else { 'unknown' }
    $pressure = if ($usage -and $null -ne $usage.context_pressure_pct) { ([string]$usage.context_pressure_pct) + '%' } else { '-' }
    $tool = '-'
    if ($Snapshot.recent_tool_outputs -and @($Snapshot.recent_tool_outputs).Count -gt 0) {
        $top = @($Snapshot.recent_tool_outputs)[0]
        if ($null -ne $top.original_token_count) {
            $tool = (Format-NullableNumber $top.original_token_count) + ' tok'
        } else {
            $tool = (Format-NullableNumber $top.output_chars) + ' chars'
        }
    }
    $line = '{0,-9} {1:HH:mm:ss} input={2,9} cached={3,9} uncached={4,8} out={5,6} reas={6,6} pressure={7,7} status={8,-7} size={9,8}MB rec={10,6} tool={11,10} :: {12}' -f `
        $Kind,
        (Get-Date),
        $input,
        $cached,
        $uncached,
        $output,
        $reasoning,
        $pressure,
        $status,
        ([string]$Snapshot.size_mb),
        ([string]$Snapshot.record_count),
        $tool,
        ([string]$Snapshot.recommendation)
    Write-Host $line
}

$resolvedPath = Resolve-CodexRolloutPath -ExplicitSourcePath $SourcePath -LookupSessionId $SessionId -LookupRoot $SessionRoot

if (-not $Watch) {
    $analysis = & (Join-Path $ScriptRoot 'src\Read-CodexTokenUsage.ps1') -SourcePath $resolvedPath
    $snapshot = Convert-MonitorSnapshot -Analysis $analysis
    [pscustomobject]$snapshot
    return
}

$baselineAnalysis = & (Join-Path $ScriptRoot 'src\Read-CodexTokenUsage.ps1') -SourcePath $resolvedPath
$baseline = Convert-MonitorSnapshot -Analysis $baselineAnalysis
$baselineFingerprint = if ($baseline.latest_token_event) { [string]$baseline.latest_token_event.fingerprint } else { '' }

$safeSession = if ($baseline.session_id) { [string]$baseline.session_id } elseif ($SessionId) { $SessionId } else { [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath) }
$safeSession = ($safeSession -replace '[^A-Za-z0-9_.-]', '_')
$runId = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss-fffZ') + '-' + $safeSession
$runDir = Join-Path $OutRoot $runId
$observationsPath = Join-Path $runDir 'observations.jsonl'
$summaryPath = Join-Path $runDir 'summary.json'
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

Write-JsonNoBom -Path $observationsPath -Object ([ordered]@{ kind = 'baseline'; snapshot = $baseline }) -Append
if ($Live) {
    Write-Host "Watching Codex rollout:"
    Write-Host "  $resolvedPath"
    Write-Host "Evidence:"
    Write-Host "  $runDir"
    Write-LiveSnapshot -Kind 'baseline' -Snapshot $baseline
}

$foundNext = $null
$lastSeenFingerprint = $baselineFingerprint
$lastSeenSize = [int64]$baseline.size_bytes
$lastSeenRecords = [int64]$baseline.record_count
$lastChangeAt = Get-Date
$deadline = (Get-Date).AddSeconds([int]([math]::Round($Minutes * 60)))

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $IntervalSeconds
    $analysis = & (Join-Path $ScriptRoot 'src\Read-CodexTokenUsage.ps1') -SourcePath $resolvedPath
    $snapshot = Convert-MonitorSnapshot -Analysis $analysis
    $fingerprint = if ($snapshot.latest_token_event) { [string]$snapshot.latest_token_event.fingerprint } else { '' }
    $size = [int64]$snapshot.size_bytes
    $records = [int64]$snapshot.record_count

    Write-JsonNoBom -Path $observationsPath -Object ([ordered]@{ kind = 'sample'; snapshot = $snapshot }) -Append
    if ($Live) {
        $kind = if ($fingerprint -ne $baselineFingerprint -and -not [string]::IsNullOrWhiteSpace($fingerprint)) { 'next/live' } else { 'sample' }
        Write-LiveSnapshot -Kind $kind -Snapshot $snapshot
    }

    if ($fingerprint -ne $lastSeenFingerprint -or $size -ne $lastSeenSize -or $records -ne $lastSeenRecords) {
        $lastChangeAt = Get-Date
        $lastSeenFingerprint = $fingerprint
        $lastSeenSize = $size
        $lastSeenRecords = $records
    }

    if ($null -eq $foundNext -and -not [string]::IsNullOrWhiteSpace($fingerprint) -and $fingerprint -ne $baselineFingerprint) {
        $foundNext = $snapshot
    }

    if ($null -ne $foundNext) {
        $stableFor = ((Get-Date) - $lastChangeAt).TotalSeconds
        if ($stableFor -ge $StableSeconds) {
            break
        }
    }
}

$finalAnalysis = & (Join-Path $ScriptRoot 'src\Read-CodexTokenUsage.ps1') -SourcePath $resolvedPath
$final = Convert-MonitorSnapshot -Analysis $finalAnalysis
$summary = [ordered]@{
    run_id = $runId
    run_dir = $runDir
    source_path = $resolvedPath
    watch = [ordered]@{
        minutes = $Minutes
        interval_seconds = $IntervalSeconds
        stable_seconds = $StableSeconds
        found_next_turn = ($null -ne $foundNext)
    }
    baseline = $baseline
    next_turn = $foundNext
    final = $final
}
Write-JsonNoBom -Path $summaryPath -Object $summary
if ($Live) {
    Write-LiveSnapshot -Kind 'final' -Snapshot $final
    Write-Host "Summary: $summaryPath"
}

[pscustomobject]@{
    run_id = $runId
    run_dir = $runDir
    source_path = $resolvedPath
    found_next_turn = ($null -ne $foundNext)
    baseline_input_tokens = if ($baseline.latest_usage) { $baseline.latest_usage.input_tokens } else { $null }
    next_input_tokens = if ($foundNext -and $foundNext.latest_usage) { $foundNext.latest_usage.input_tokens } else { $null }
    final_input_tokens = if ($final.latest_usage) { $final.latest_usage.input_tokens } else { $null }
    final_status = if ($final.latest_usage) { $final.latest_usage.status } else { 'unknown' }
    recommendation = $final.recommendation
    observations = $observationsPath
    summary = $summaryPath
}
