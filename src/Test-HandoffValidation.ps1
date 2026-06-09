param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [switch]$RequireLaunchAllowed
)

$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw "Validation failed: $Message"
    }
}

$requiredFiles = @(
    'raw_transcript.jsonl',
    'transcript_analysis.json',
    'context.json'
)

foreach ($file in $requiredFiles) {
    Assert-Condition (Test-Path -LiteralPath (Join-Path $BundlePath $file)) "missing $file"
}

$context = Get-Content -LiteralPath (Join-Path $BundlePath 'context.json') -Raw | ConvertFrom-Json
$requiredContextKeys = @(
    'artifact_type',
    'source_session_id',
    'replacement_session_name',
    'fingerprint',
    'source_of_truth',
    'current_state',
    'major_decisions',
    'active_work_items',
    'open_risks',
    'immediate_next_action',
    'unresolved_gaps',
    'handoff_recommendation'
)

foreach ($key in $requiredContextKeys) {
    Assert-Condition ($context.PSObject.Properties.Name -contains $key) "context.json missing $key"
}

Assert-Condition ($context.source_of_truth.path -eq 'raw_transcript.jsonl') 'source_of_truth.path must be raw_transcript.jsonl'
Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$context.source_of_truth.sha256)) 'source_of_truth.sha256 is required'
Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$context.current_state.summary)) 'current_state.summary is required'
Assert-Condition ($context.unresolved_gaps.Count -ge 1) 'unresolved_gaps must include at least one entry'

$launchAllowed = [bool]$context.handoff_recommendation.launch_allowed
if ($RequireLaunchAllowed) {
    Assert-Condition $launchAllowed 'launch_allowed must be true for handoff launch'
}
else {
    Assert-Condition (-not $launchAllowed) 'launch_allowed must remain false for non-launch validation'
}

$localValidation = [ordered]@{
    passed = $true
    normalized = (Test-Path -LiteralPath (Join-Path $BundlePath 'context.model.json'))
    launch_allowed = $launchAllowed
    checked_at = (Get-Date).ToUniversalTime().ToString('o')
    required_sections_present = $true
    provenance_present = (($context.major_decisions | Select-Object -First 1).provenance.Count -gt 0) -or (($context.current_state.provenance).Count -gt 0)
    errors = @()
    warnings = @()
}

if (-not $localValidation.provenance_present) {
    $localValidation.warnings += 'No provenance found in major decisions or current state.'
}

& (Join-Path $PSScriptRoot 'Test-CompressionContextQuality.ps1') -BundlePath $BundlePath | Out-Null

$localValidation | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'local_validation.json') -Encoding UTF8

[pscustomobject]$localValidation
