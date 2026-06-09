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
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return $null }
    return $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

$envConfig = & (Join-Path $PSScriptRoot 'Read-HandoffEnv.ps1') -EnvPath $EnvPath -IncludeSecrets
$glm = $envConfig.providers.glm
$validationPath = Join-Path $BundlePath 'semantic_validation.glm.json'

if (-not $glm.usable_for_validation) {
    $reason = 'GLM validation disabled. Z.AI Coding Plan docs limit Coding Plan usage to supported tools; set GLM_VALIDATION_ENABLED=true and GLM_VALIDATION_POLICY_SAFE=true only when this use is policy-safe for your key.'
    $validation = [ordered]@{
        artifact_type = 'semantic_validation'
        provider = 'glm'
        model = [string]$glm.model
        enabled = $false
        policy_safe = [bool]$glm.policy_safe
        api_key_present = [bool]$glm.api_key_present
        key_name = [string]$glm.key_name
        skipped = $true
        reason = $reason
        passed = $false
        launch_allowed = $false
        checked_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $validation | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $validationPath -Encoding UTF8
    return [pscustomobject]$validation
}

if ($DryRun) {
    $validation = [ordered]@{
        artifact_type = 'semantic_validation'
        provider = 'glm'
        model = [string]$glm.model
        enabled = $true
        policy_safe = $true
        dry_run = $true
        skipped = $true
        reason = 'Dry run: GLM validation network call was not made.'
        passed = $false
        launch_allowed = $false
        checked_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $validation | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $validationPath -Encoding UTF8
    return [pscustomobject]$validation
}

$contextPath = Join-Path $BundlePath 'context.json'
if (-not (Test-Path -LiteralPath $contextPath)) {
    throw "Missing context.json in $BundlePath"
}

$contextText = Get-Content -LiteralPath $contextPath -Raw
$summaryDir = Join-Path $BundlePath 'chunk_summaries\minimax_m3'
$summaryFiles = @(Get-ChildItem -LiteralPath $summaryDir -Filter 'chunk_*.summary.json' -ErrorAction SilentlyContinue | Sort-Object Name)
$summarySample = @()
foreach ($file in @($summaryFiles | Select-Object -First 8)) {
    $summarySample += (Get-Content -LiteralPath $file.FullName -Raw)
}

$system = @'
You validate Codex handoff state for groundedness.
Check for invented status, invented next actions, missing required sections, contradictions, and absent provenance.
Return only one JSON object.
'@

$user = @"
Validate context.json against MiniMax chunk summary evidence.

Required output:
{
  "artifact_type": "semantic_validation",
  "provider": "glm",
  "passed": boolean,
  "launch_allowed": false,
  "findings": [{"severity":"low|medium|high","text":"string","evidence":"string"}],
  "missing_required_sections": ["string"],
  "invented_or_ungrounded_claims": ["string"],
  "confidence": "low|medium|high",
  "unresolved_gaps": ["string"]
}

context.json:
$contextText

chunk summary sample:
$($summarySample -join "`n---SUMMARY---`n")
"@

$runDir = Join-Path $BundlePath 'provider_runs\glm'
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$messages = @(
    [ordered]@{ role = 'system'; content = $system },
    [ordered]@{ role = 'user'; content = $user }
)

$providerResult = & (Join-Path $PSScriptRoot 'Invoke-ProviderChat.ps1') `
    -Provider glm `
    -Model ([string]$glm.model) `
    -BaseUrl ([string]$glm.coding_base_url) `
    -ApiKey ([string]$envConfig.secrets.glm_api_key) `
    -EndpointKind 'chat_completions' `
    -Messages $messages `
    -MaxTokens 6000 `
    -Temperature 0.1 `
    -RunDir $runDir `
    -RunLabel 'glm_validation'

$validation = ConvertFrom-JsonObjectText ([string]$providerResult.output_text)
if (-not $validation) {
    throw 'GLM validation did not return a JSON object.'
}
$validation.launch_allowed = $false
$validation | Add-Member -NotePropertyName provider_run -NotePropertyValue ([string]$providerResult.run_path) -Force
$validation | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $validationPath -Encoding UTF8

[pscustomobject]$validation
