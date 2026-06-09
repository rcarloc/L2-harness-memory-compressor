param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath
)

$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw "Cheap-test validation failed: $Message"
    }
}

foreach ($file in @(
    'raw_transcript.jsonl',
    'transcript_analysis.json',
    'semantic_event_stream.jsonl',
    'semantic_event_manifest.json',
    'semantic_chunk_manifest.json',
    'session_manifest.json'
)) {
    Assert-Condition (Test-Path -LiteralPath (Join-Path $BundlePath $file)) "missing $file"
}

$eventManifest = Get-Content -LiteralPath (Join-Path $BundlePath 'semantic_event_manifest.json') -Raw | ConvertFrom-Json
$chunkManifest = Get-Content -LiteralPath (Join-Path $BundlePath 'semantic_chunk_manifest.json') -Raw | ConvertFrom-Json
$sessionManifestPath = Join-Path $BundlePath 'session_manifest.json'
$sessionManifest = Get-Content -LiteralPath $sessionManifestPath -Raw | ConvertFrom-Json

Assert-Condition ($eventManifest.mode -eq 'cheap-test') 'semantic event manifest mode must be cheap-test'
Assert-Condition ($eventManifest.semantic_events_written -gt 0) 'semantic event stream must retain at least one event'
Assert-Condition ($chunkManifest.mode -eq 'cheap-test') 'chunk manifest mode must be cheap-test'
Assert-Condition ($chunkManifest.chunk_count -gt 0) 'must create at least one chunk'

foreach ($chunk in @($chunkManifest.chunks)) {
    Assert-Condition (Test-Path -LiteralPath (Join-Path $BundlePath $chunk.path)) "missing chunk $($chunk.path)"
    Assert-Condition ($chunk.first_source_line -gt 0) "chunk $($chunk.name) missing first source line"
    Assert-Condition ($chunk.last_source_line -ge $chunk.first_source_line) "chunk $($chunk.name) invalid source line range"
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$chunk.first_timestamp)) "chunk $($chunk.name) missing first timestamp"
}

$sessionManifest.status = 'cheap_test_complete'
$sessionManifest.mode = 'CheapTest'
$sessionManifest.launch_attempted = $false
$sessionManifest.validation = [ordered]@{
    passed = $true
    launch_allowed = $false
    scope = 'model-free extraction and chunking'
}
$sessionManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $sessionManifestPath -Encoding UTF8

$report = @"
# Cheap-Test Handoff Report

Status: cheap_test_complete

No model was called. No new thread was launched.

## Artifacts

- raw_transcript.jsonl
- transcript_analysis.json
- semantic_event_stream.jsonl
- semantic_event_manifest.json
- semantic_chunks/
- semantic_chunk_manifest.json
- session_manifest.json

## Counts

- Semantic events retained: $($eventManifest.semantic_events_written)
- Chunks created: $($chunkManifest.chunk_count)

## Launch

launch_allowed: false

Reason: cheap-test mode validates deterministic extraction/chunking only. Semantic validation is still required before handoff launch.
"@
$report | Set-Content -LiteralPath (Join-Path $BundlePath 'handoff_report.md') -Encoding UTF8

$localValidation = [ordered]@{
    passed = $true
    launch_allowed = $false
    checked_at = (Get-Date).ToUniversalTime().ToString('o')
    scope = 'cheap-test'
    semantic_events_written = [int]$eventManifest.semantic_events_written
    chunk_count = [int]$chunkManifest.chunk_count
    errors = @()
    warnings = @()
}
$localValidation | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'local_validation.json') -Encoding UTF8

[pscustomobject]$localValidation
