param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [string]$EnvPath = '.env',
    [int]$ChunkLimit = 0,
    [int[]]$ChunkIndex,
    [int]$StartChunk,
    [int]$EndChunk,
    [int]$MaxTokens = 5000,
    [int]$ThrottleLimit = 1,
    [switch]$UseDigest,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if ($ThrottleLimit -gt 4) {
    throw 'ThrottleLimit above 4 is intentionally disabled to avoid provider rate-limit and filesystem contention.'
}

function Test-AnySummaryExists {
    param([string]$BundlePath, [int]$Index)
    $name = 'chunk_{0:000}.summary.json' -f $Index
    foreach ($dir in @('chunk_summaries\minimax_m3', 'chunk_summaries\mimo_v25_pro')) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $BundlePath $dir) $name)) {
            return $true
        }
    }
    return $false
}

$manifestPath = Join-Path $BundlePath 'semantic_chunk_manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing semantic_chunk_manifest.json in $BundlePath. Run CheapTest first."
}

$chunkManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$envConfig = & (Join-Path $PSScriptRoot 'Read-HandoffEnv.ps1') -EnvPath $EnvPath -IncludeSecrets
$mimo = $envConfig.providers.mimo

if (-not $DryRun -and -not $mimo.api_key_present) {
    throw 'mimo_api_key or MIMO_API_KEY is required for MiMo summarization.'
}

$summaryDir = Join-Path $BundlePath 'chunk_summaries\mimo_v25_pro'
$runDir = Join-Path $BundlePath 'provider_runs\mimo_v25_pro'
New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

[ordered]@{
    provider = 'mimo'
    model = [string]$mimo.model
    model_profile = 'mimo-v2.5-pro'
    endpoint_kind = [string]$mimo.endpoint_kind
    mode = if ($DryRun) { 'dry_run' } else { 'network' }
    reasoning_effort = 'provider_default'
    fallback_for = 'minimax_429'
    created_at = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'semantic_model_config.json') -Encoding UTF8

$chunks = @($chunkManifest.chunks)
if ($ChunkIndex -and $ChunkIndex.Count -gt 0) {
    $allowed = @{}
    foreach ($idx in $ChunkIndex) { $allowed[[int]$idx] = $true }
    $chunks = @($chunks | Where-Object { $allowed.ContainsKey([int]$_.index) })
}
if (($StartChunk -gt 0) -or ($EndChunk -gt 0)) {
    if ($StartChunk -le 0 -or $EndChunk -le 0) { throw 'StartChunk and EndChunk must both be set and greater than 0.' }
    if ($EndChunk -lt $StartChunk) { throw 'StartChunk must be less than or equal to StartChunk.' }
    $chunks = @($chunks | Where-Object {
        $idx = [int]$_.index
        $idx -ge $StartChunk -and $idx -le $EndChunk
    })
}
if ($ChunkLimit -gt 0) {
    $chunks = @($chunks | Select-Object -First $ChunkLimit)
}

if ($ThrottleLimit -gt 1 -and $chunks.Count -gt 1) {
    $pending = New-Object System.Collections.Queue
    foreach ($chunk in $chunks) { $pending.Enqueue($chunk) }
    $jobs = @()
    $written = @()
    $scriptPath = $MyInvocation.MyCommand.Path

    while ($pending.Count -gt 0 -or $jobs.Count -gt 0) {
        while ($pending.Count -gt 0 -and $jobs.Count -lt $ThrottleLimit) {
            $chunk = $pending.Dequeue()
            $idx = [int]$chunk.index
            $jobs += Start-Job -ScriptBlock {
                param($ScriptPath, $BundlePath, $EnvPath, $Index, $MaxTokens, $UseDigest, $DryRun, $Force)
                & $ScriptPath `
                    -BundlePath $BundlePath `
                    -EnvPath $EnvPath `
                    -ChunkIndex $Index `
                    -MaxTokens $MaxTokens `
                    -ThrottleLimit 1 `
                    -UseDigest:$UseDigest `
                    -DryRun:$DryRun `
                    -Force:$Force
            } -ArgumentList $scriptPath, $BundlePath, $EnvPath, $idx, $MaxTokens, ([bool]$UseDigest), ([bool]$DryRun), ([bool]$Force)
        }

        $done = @($jobs | Wait-Job -Any -Timeout 5)
        foreach ($job in $done) {
            Receive-Job -Job $job -ErrorAction Stop | Out-Null
            Remove-Job -Job $job
        }
        $jobs = @($jobs | Where-Object { $_.State -eq 'Running' })
    }

    foreach ($chunk in $chunks) {
        $idx = [int]$chunk.index
        $summaryPath = Join-Path $summaryDir ('chunk_{0:000}.summary.json' -f $idx)
        $written += [ordered]@{
            index = $idx
            path = $summaryPath
            skipped = $false
            parallel = $true
        }
    }

    [ordered]@{
        artifact_type = 'chunk_summary_manifest'
        provider = 'mimo'
        model = [string]$mimo.model
        mode = if ($DryRun) { 'dry_run' } else { 'network' }
        fallback_for = 'minimax_429'
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        source_chunk_manifest = 'semantic_chunk_manifest.json'
        requested_chunk_count = $chunks.Count
        throttle_limit = $ThrottleLimit
        summaries = $written
        launch_allowed = $false
        launch_attempted = $false
    } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $summaryDir 'summary_manifest.json') -Encoding UTF8

    [pscustomobject]@{
        bundle_path = $BundlePath
        provider = 'mimo'
        model = [string]$mimo.model
        dry_run = [bool]$DryRun
        throttle_limit = $ThrottleLimit
        summaries_written = $chunks.Count
        summaries_skipped = 0
    }
    return
}

$written = @()
foreach ($chunk in $chunks) {
    $idx = [int]$chunk.index
    $summaryPath = Join-Path $summaryDir ('chunk_{0:000}.summary.json' -f $idx)
    if ((Test-AnySummaryExists -BundlePath $BundlePath -Index $idx) -and -not $Force) {
        $written += [ordered]@{ index = $idx; path = $summaryPath; skipped = $true; skip_reason = 'summary_exists' }
        continue
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

    $system = @'
You are a factual extractor for a Codex Durable Handoff system.
The input is derived from a raw transcript. Do not invent status, decisions, files, or next actions.
Extract compact factual atoms for a later merge pass. Do not decide final session state unless the input explicitly says it is final.
Return only one JSON object.
'@

    $user = @"
Summarize this Codex session chunk as factual atoms for later merge.

Rules:
- Keep every item one sentence.
- Use line refs only; do not include long evidence quotes.
- If a section has no evidence, return an empty array.
- Return only one JSON object.

Required JSON schema:
{
  "artifact_type": "chunk_summary",
  "provider": "mimo",
  "model": "$([string]$mimo.model)",
  "fallback_reason": "minimax_429",
  "chunk_index": $idx,
  "source": {
    "chunk_path": "$($chunk.path)",
    "first_source_line": $($chunk.first_source_line),
    "last_source_line": $($chunk.last_source_line)
  },
  "facts": [{"text":"string","lines":[1,2]}],
  "decisions": [{"text":"string","lines":[1,2]}],
  "files": [{"path_or_name":"string","action":"created|modified|read|reported|unknown","lines":[1,2]}],
  "commands": [{"text":"string","result":"pass|fail|unknown","lines":[1,2]}],
  "failures": [{"text":"string","lines":[1,2]}],
  "next_steps": [{"text":"string","lines":[1,2]}],
  "user_preferences": [{"text":"string","lines":[1,2]}],
  "final_state_candidates": [{"text":"string","lines":[1,2]}],
  "unresolved_gaps": ["string"]
}

Caps:
- facts: 8
- decisions: 4
- files: 8
- commands: 6
- failures: 5
- next_steps: 5
- user_preferences: 4
- final_state_candidates: 4

Chunk metadata:
- chunk_index: $idx
- chunk_path: $($chunk.path)
- first_source_line: $($chunk.first_source_line)
- last_source_line: $($chunk.last_source_line)
- first_timestamp: $($chunk.first_timestamp)
- last_timestamp: $($chunk.last_timestamp)

Input type: $inputLabel

Chunk input:
$chunkText
"@

    $messages = @(
        [ordered]@{ role = 'system'; content = $system },
        [ordered]@{ role = 'user'; content = $user }
    )

    $providerResult = & (Join-Path $PSScriptRoot 'Invoke-ProviderChat.ps1') `
        -Provider mimo `
        -Model ([string]$mimo.model) `
        -BaseUrl ([string]$mimo.base_url) `
        -ApiKey ([string]$envConfig.secrets.mimo_api_key) `
        -EndpointKind ([string]$mimo.endpoint_kind) `
        -Messages $messages `
        -MaxTokens $MaxTokens `
        -Temperature 0.1 `
        -RunDir $runDir `
        -RunLabel ('chunk_{0:000}' -f $idx) `
        -DryRun:$DryRun

    if ($DryRun) {
        $summary = [ordered]@{
            artifact_type = 'chunk_summary'
            provider = 'mimo'
            model = [string]$mimo.model
            mode = 'dry_run'
            fallback_reason = 'minimax_429'
            chunk_index = $idx
            source = [ordered]@{
                chunk_path = [string]$chunk.path
                first_source_line = [int]$chunk.first_source_line
                last_source_line = [int]$chunk.last_source_line
            }
            facts = @()
            decisions = @()
            files = @()
            commands = @()
            failures = @()
            next_steps = @()
            user_preferences = @()
            final_state_candidates = @()
            unresolved_gaps = @('Dry run: no model call was made, so semantic summary content is intentionally empty.')
            provider_run = [string]$providerResult.run_path
        }
    }
    else {
        if ($providerResult.finish_reason -eq 'length') {
            throw "MiMo summary for chunk $idx was truncated by the provider. Increase MaxTokens or reduce chunk size."
        }
        $summary = & (Join-Path $PSScriptRoot 'ConvertFrom-ProviderJson.ps1') -Text ([string]$providerResult.output_text)
        if (-not $summary) {
            throw "MiMo summary for chunk $idx did not return a JSON object."
        }
        $summary | Add-Member -NotePropertyName provider_run -NotePropertyValue ([string]$providerResult.run_path) -Force
        $summary | Add-Member -NotePropertyName fallback_reason -NotePropertyValue 'minimax_429' -Force
    }

    $summary | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $written += [ordered]@{ index = $idx; path = $summaryPath; skipped = $false }
}

[ordered]@{
    artifact_type = 'chunk_summary_manifest'
    provider = 'mimo'
    model = [string]$mimo.model
    mode = if ($DryRun) { 'dry_run' } else { 'network' }
    fallback_for = 'minimax_429'
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    source_chunk_manifest = 'semantic_chunk_manifest.json'
    requested_chunk_count = $chunks.Count
    summaries = $written
    launch_allowed = $false
    launch_attempted = $false
} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $summaryDir 'summary_manifest.json') -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    provider = 'mimo'
    model = [string]$mimo.model
    dry_run = [bool]$DryRun
    summaries_written = @($written | Where-Object { -not $_.skipped }).Count
    summaries_skipped = @($written | Where-Object { $_.skipped }).Count
}
