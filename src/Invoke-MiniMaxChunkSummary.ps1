param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [string]$EnvPath = '.env',
    [int]$ChunkLimit = 0,
    [int[]]$ChunkIndex,
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

$manifestPath = Join-Path $BundlePath 'semantic_chunk_manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing semantic_chunk_manifest.json in $BundlePath. Run CheapTest first."
}

$chunkManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$envConfig = & (Join-Path $PSScriptRoot 'Read-HandoffEnv.ps1') -EnvPath $EnvPath -IncludeSecrets
$minimax = $envConfig.providers.minimax

if (-not $DryRun -and -not $minimax.api_key_present) {
    throw 'MINIMAX_API_KEY is required for MiniMax summarization.'
}

$summaryDir = Join-Path $BundlePath 'chunk_summaries\minimax_m3'
$runDir = Join-Path $BundlePath 'provider_runs\minimax_m3'
New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$modelConfig = [ordered]@{
    provider = 'minimax'
    model = [string]$minimax.model
    model_profile = 'minimax-m3'
    endpoint_kind = [string]$minimax.endpoint_kind
    mode = if ($DryRun) { 'dry_run' } else { 'network' }
    reasoning_effort = 'provider_default'
    created_at = (Get-Date).ToUniversalTime().ToString('o')
}
$modelConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'semantic_model_config.json') -Encoding UTF8

$chunks = @($chunkManifest.chunks)
if ($ChunkIndex -and $ChunkIndex.Count -gt 0) {
    $allowed = @{}
    foreach ($idx in $ChunkIndex) { $allowed[[int]$idx] = $true }
    $chunks = @($chunks | Where-Object { $allowed.ContainsKey([int]$_.index) })
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
        provider = 'minimax'
        model = [string]$minimax.model
        mode = if ($DryRun) { 'dry_run' } else { 'network' }
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
        provider = 'minimax'
        model = [string]$minimax.model
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
    if ((Test-Path -LiteralPath $summaryPath) -and -not $Force) {
        $written += [ordered]@{ index = $idx; path = $summaryPath; skipped = $true }
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
You are a factual extractor for a Codex session compression system.
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
  "provider": "minimax",
  "model": "$([string]$minimax.model)",
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
        -Provider minimax `
        -Model ([string]$minimax.model) `
        -BaseUrl ([string]$minimax.base_url) `
        -ApiKey ([string]$envConfig.secrets.minimax_api_key) `
        -EndpointKind ([string]$minimax.endpoint_kind) `
        -Messages $messages `
        -MaxTokens $MaxTokens `
        -Temperature 0.1 `
        -RunDir $runDir `
        -RunLabel ('chunk_{0:000}' -f $idx) `
        -DryRun:$DryRun

    if ($DryRun) {
        $summary = [ordered]@{
            artifact_type = 'chunk_summary'
            provider = 'minimax'
            model = [string]$minimax.model
            mode = 'dry_run'
            chunk_index = $idx
            source = [ordered]@{
                chunk_path = [string]$chunk.path
                first_source_line = [int]$chunk.first_source_line
                last_source_line = [int]$chunk.last_source_line
                first_timestamp = [string]$chunk.first_timestamp
                last_timestamp = [string]$chunk.last_timestamp
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
    } else {
        if ($providerResult.finish_reason -eq 'length') {
            throw "MiniMax summary for chunk $idx was truncated by the provider. Increase MaxTokens or reduce chunk size."
        }
        $summary = & (Join-Path $PSScriptRoot 'ConvertFrom-ProviderJson.ps1') -Text ([string]$providerResult.output_text)
        if (-not $summary) {
            throw "MiniMax summary for chunk $idx did not return a JSON object."
        }
        $summary | Add-Member -NotePropertyName provider_run -NotePropertyValue ([string]$providerResult.run_path) -Force
    }

    $summary | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $written += [ordered]@{ index = $idx; path = $summaryPath; skipped = $false }
}

$summaryManifest = [ordered]@{
    artifact_type = 'chunk_summary_manifest'
    provider = 'minimax'
    model = [string]$minimax.model
    mode = if ($DryRun) { 'dry_run' } else { 'network' }
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    source_chunk_manifest = 'semantic_chunk_manifest.json'
    requested_chunk_count = $chunks.Count
    summaries = $written
    launch_allowed = $false
    launch_attempted = $false
}
$summaryManifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $summaryDir 'summary_manifest.json') -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    provider = 'minimax'
    model = [string]$minimax.model
    dry_run = [bool]$DryRun
    summaries_written = @($written | Where-Object { -not $_.skipped }).Count
    summaries_skipped = @($written | Where-Object { $_.skipped }).Count
}
