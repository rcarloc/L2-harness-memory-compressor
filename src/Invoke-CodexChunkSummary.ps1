param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [string]$Model = 'gpt-5.3-codex-spark',

    [ValidateSet('minimal', 'low', 'medium')]
    [string]$ReasoningEffort = 'low',

    [int]$ChunkLimit = 0,
    [int[]]$ChunkIndex,
    [int]$ThrottleLimit = 1,
    [switch]$UseDigest,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$RetryFailedChunks
)

$ErrorActionPreference = 'Stop'

if ($ThrottleLimit -gt 1) {
    throw 'Codex provider currently runs chunks sequentially. Use -ThrottleLimit 1.'
}

function Test-ValidSummary {
    param([string]$Path, [int]$ExpectedIndex)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return ($obj.artifact_type -eq 'chunk_summary' -and [int]$obj.chunk_index -eq $ExpectedIndex)
    }
    catch {
        return $false
    }
}

function Write-JsonNoBom {
    param([string]$Path, $Object)
    & (Join-Path $PSScriptRoot 'Write-Utf8NoBom.ps1') -Path $Path -InputObject $Object -Depth 80 | Out-Null
}

$manifestPath = Join-Path $BundlePath 'semantic_chunk_manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing semantic_chunk_manifest.json in $BundlePath. Run Chunk first."
}

$chunkManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$summaryDir = Join-Path $BundlePath 'chunk_summaries\codex'
$runDir = Join-Path $BundlePath 'provider_runs\codex'
New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

[ordered]@{
    provider = 'codex'
    model = $Model
    model_profile = 'codex'
    reasoning_effort = $ReasoningEffort
    mode = if ($DryRun) { 'dry_run' } else { 'codex_exec' }
    created_at = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'semantic_model_config.json') -Encoding UTF8

$chunks = @($chunkManifest.chunks)
if ($ChunkIndex -and $ChunkIndex.Count -gt 0) {
    $allowed = @{}
    foreach ($idx in $ChunkIndex) { $allowed[[int]$idx] = $true }
    $chunks = @($chunks | Where-Object { $allowed.ContainsKey([int]$_.index) })
}
if ($ChunkLimit -gt 0) {
    $chunks = @($chunks | Select-Object -First $ChunkLimit)
}

$schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\chunk-summary.schema.json'
$written = @()
$failed = @()

foreach ($chunk in $chunks) {
    $idx = [int]$chunk.index
    $summaryPath = Join-Path $summaryDir ('chunk_{0:000}.summary.json' -f $idx)
    $isValid = Test-ValidSummary -Path $summaryPath -ExpectedIndex $idx

    if ($isValid -and -not $Force) {
        $written += [ordered]@{ index = $idx; path = $summaryPath; skipped = $true; reason = 'valid_existing' }
        continue
    }
    if ((Test-Path -LiteralPath $summaryPath) -and -not $isValid -and -not $Force -and -not $RetryFailedChunks) {
        throw "Existing summary is invalid for chunk $idx. Rerun with -RetryFailedChunks or -Force."
    }

    $chunkPath = Join-Path $BundlePath ([string]$chunk.path)
    if (-not (Test-Path -LiteralPath $chunkPath)) {
        throw "Missing chunk file: $chunkPath"
    }

    $digestPath = Join-Path $BundlePath ('chunk_digests\chunk_{0:000}.digest.md' -f $idx)
    if ($UseDigest -and (Test-Path -LiteralPath $digestPath)) {
        $chunkText = Get-Content -LiteralPath $digestPath -Raw
        $inputLabel = 'chunk digest markdown'
    }
    else {
        $chunkText = Get-Content -LiteralPath $chunkPath -Raw
        $inputLabel = 'chunk event JSONL'
    }

    $prompt = @"
You are a factual extractor for a Codex session compression system.

Summarize this Codex session chunk as factual atoms for later merge. Return only JSON matching the provided schema. Use low reasoning. Do not quote long text. Do not invent status, decisions, files, commands, failures, or next actions.

Required values:
- artifact_type: chunk_summary
- provider: codex
- model: $Model
- reasoning_effort: $ReasoningEffort
- chunk_index: $idx
- source.chunk_path: $($chunk.path)
- source.first_source_line: $($chunk.first_source_line)
- source.last_source_line: $($chunk.last_source_line)
- source.first_timestamp: $($chunk.first_timestamp)
- source.last_timestamp: $($chunk.last_timestamp)

Caps:
- facts: 8
- decisions: 4
- files: 8
- commands: 6
- failures: 5
- next_steps: 5
- user_preferences: 4
- final_state_candidates: 4

Input type: $inputLabel

Chunk input:
$chunkText
"@

    try {
        $result = & (Join-Path $PSScriptRoot 'Invoke-CodexExecJson.ps1') `
            -Prompt $prompt `
            -SchemaPath $schemaPath `
            -OutputPath $summaryPath `
            -Model $Model `
            -ReasoningEffort $ReasoningEffort `
            -WorkingDirectory (Split-Path -Parent $PSScriptRoot) `
            -DryRun:$DryRun `
            -RunDir $runDir `
            -RunLabel ('chunk_{0:000}' -f $idx)

        $summary = $result.parsed
        $summary.artifact_type = 'chunk_summary'
        $summary.provider = 'codex'
        $summary.model = $Model
        $summary | Add-Member -NotePropertyName reasoning_effort -NotePropertyValue $ReasoningEffort -Force
        if ($DryRun) { $summary | Add-Member -NotePropertyName mode -NotePropertyValue 'dry_run' -Force }
        $summary.chunk_index = $idx
        $summary.source = [ordered]@{
            chunk_path = [string]$chunk.path
            first_source_line = [int]$chunk.first_source_line
            last_source_line = [int]$chunk.last_source_line
            first_timestamp = [string]$chunk.first_timestamp
            last_timestamp = [string]$chunk.last_timestamp
        }
        $summary | Add-Member -NotePropertyName provider_run -NotePropertyValue ([string]$result.run_path) -Force
        Write-JsonNoBom -Path $summaryPath -Object $summary
        $written += [ordered]@{ index = $idx; path = $summaryPath; skipped = $false; reason = 'written' }
    }
    catch {
        $failed += [ordered]@{ index = $idx; path = $summaryPath; error = [string]$_.Exception.Message }
    }
}

$summaryManifest = [ordered]@{
    artifact_type = 'chunk_summary_manifest'
    provider = 'codex'
    model = $Model
    reasoning_effort = $ReasoningEffort
    mode = if ($DryRun) { 'dry_run' } else { 'codex_exec' }
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    source_chunk_manifest = 'semantic_chunk_manifest.json'
    requested_chunk_count = $chunks.Count
    written_count = @($written | Where-Object { -not $_.skipped }).Count
    skipped_count = @($written | Where-Object { $_.skipped }).Count
    failed_count = $failed.Count
    retry_failed_chunks = [bool]$RetryFailedChunks
    summaries = $written
    failures = $failed
    launch_allowed = $false
    launch_attempted = $false
}
Write-JsonNoBom -Path (Join-Path $summaryDir 'summary_manifest.json') -Object $summaryManifest

if ($failed.Count -gt 0) {
    throw ('Codex chunk summarization failed for chunks: ' + (($failed | ForEach-Object { $_.index }) -join ', '))
}

[pscustomobject]@{
    bundle_path = $BundlePath
    provider = 'codex'
    model = $Model
    reasoning_effort = $ReasoningEffort
    dry_run = [bool]$DryRun
    summaries_written = @($written | Where-Object { -not $_.skipped }).Count
    summaries_skipped = @($written | Where-Object { $_.skipped }).Count
}
