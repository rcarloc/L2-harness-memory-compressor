param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [string]$EnvPath = '.env',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-JsonObjectText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    # Helper: find a balanced object starting at StartIdx
    function Get-BalancedObject {
        param([string]$Text, [int]$StartIdx)
        $depth = 0
        $inStr = $false
        $escape = $false
        for ($i = $StartIdx; $i -lt $Text.Length; $i++) {
            $ch = $Text[$i]
            if ($escape) { $escape = $false; continue }
            if ($ch -eq '\') { $escape = $true; continue }
            if ($ch -eq '"') { $inStr = -not $inStr; continue }
            if ($inStr) { continue }
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { return $Text.Substring($StartIdx, $i - $StartIdx + 1) }
            }
        }
        return $null
    }

    # Strategy 1: try markdown code fence ```json ... ``` and try each match
    $fenceMatches = [regex]::Matches($Text, '(?s)```(?:json)?\s*(\{[\s\S]*?\})\s*```')
    foreach ($m in $fenceMatches) {
        try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {}
    }

    # Strategy 2: walk each '{' from first to last (outermost first), take the balanced object that closes there
    $idx = -1
    while ($true) {
        $idx = $Text.IndexOf('{', $idx + 1)
        if ($idx -lt 0) { break }
        $candidate = Get-BalancedObject -Text $Text -StartIdx $idx
        if ($candidate) {
            try { return ($candidate | ConvertFrom-Json) } catch {}
        }
    }

    return $null
}

$envConfig = & (Join-Path $PSScriptRoot 'Read-HandoffEnv.ps1') -EnvPath $EnvPath -IncludeSecrets
$minimax = $envConfig.providers.minimax
$validationPath = Join-Path $BundlePath 'semantic_validation.minimax.json'

if ($DryRun) {
    $validation = [ordered]@{
        artifact_type = 'semantic_validation'
        provider = 'minimax'
        model = [string]$minimax.model
        dry_run = $true
        skipped = $true
        reason = 'Dry run: MiniMax validation network call was not made.'
        passed = $false
        launch_allowed = $false
        checked_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $validation | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $validationPath -Encoding UTF8
    return [pscustomobject]$validation
}

if (-not $minimax.api_key_present) {
    throw 'MINIMAX_API_KEY is required for MiniMax validation.'
}

$contextPath = Join-Path $BundlePath 'context.json'
if (-not (Test-Path -LiteralPath $contextPath)) {
    throw "Missing context.json in $BundlePath"
}

$contextText = Get-Content -LiteralPath $contextPath -Raw
$summaryDirs = @(
    Join-Path $BundlePath 'chunk_summaries\minimax_m3'
    Join-Path $BundlePath 'chunk_summaries\mimo_v25_pro'
)

$summaryFiles = @()
foreach ($dir in $summaryDirs) {
    $summaryFiles += @(Get-ChildItem -LiteralPath $dir -Filter 'chunk_*.summary.json' -ErrorAction SilentlyContinue | Sort-Object Name)
}

$summarySample = @()
foreach ($file in @($summaryFiles | Select-Object -First 12)) {
    $summarySample += (Get-Content -LiteralPath $file.FullName -Raw)
}

$system = @'
You validate Codex Durable Handoff state for groundedness.
Raw transcript is the source of truth; chunk summaries are derived evidence.
Check for invented status, invented next actions, missing required sections, contradictions, and weak provenance.
Return only one JSON object.
'@

$user = @"
Validate context.json against available chunk summary evidence.

Required output:
{
  "artifact_type": "semantic_validation",
  "provider": "minimax",
  "model": "$($minimax.model)",
  "passed": boolean,
  "launch_allowed": false,
  "findings": [{"severity":"low|medium|high","text":"string","evidence":"string"}],
  "missing_required_sections": ["string"],
  "invented_or_ungrounded_claims": ["string"],
  "confidence": "low|medium|high",
  "unresolved_gaps": ["string"]
}

Rules:
- launch_allowed must always be false. This validation does not launch a thread.
- Do not claim full raw-transcript equivalence from this sample.
- Mark uncertainty explicitly.

context.json:
$contextText

chunk summary sample:
$($summarySample -join "`n---SUMMARY---`n")
"@

$runDir = Join-Path $BundlePath 'provider_runs\minimax_validation'
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

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
    -MaxTokens 6000 `
    -Temperature 0.1 `
    -RunDir $runDir `
    -RunLabel 'minimax_validation'

if ($providerResult.finish_reason -eq 'length') {
    throw 'MiniMax validation was truncated by the provider. Increase MaxTokens or reduce validation context.'
}

$validation = ConvertFrom-JsonObjectText ([string]$providerResult.output_text)
if (-not $validation) {
    throw 'MiniMax validation did not return a JSON object.'
}

$validation.launch_allowed = $false
$validation | Add-Member -NotePropertyName provider_run -NotePropertyValue ([string]$providerResult.run_path) -Force
$validation | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $validationPath -Encoding UTF8

[pscustomobject]$validation
