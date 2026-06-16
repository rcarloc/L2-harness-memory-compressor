param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [string]$Model = 'gpt-5.3-codex-spark',

    [ValidateSet('minimal', 'low', 'medium')]
    [string]$ReasoningEffort = 'low',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-JsonNoBom {
    param([string]$Path, $Object)
    & (Join-Path $PSScriptRoot 'Write-Utf8NoBom.ps1') -Path $Path -InputObject $Object -Depth 40 | Out-Null
}

$errors = @()
$warnings = @()

$contextPath = Join-Path $BundlePath 'context.json'
$finalStatePath = Join-Path $BundlePath 'final_state_digest.json'
$summaryManifestPath = Join-Path $BundlePath 'chunk_summaries\codex\summary_manifest.json'

if (-not (Test-Path -LiteralPath $contextPath)) { $errors += 'context.json is required.' }
if (-not (Test-Path -LiteralPath $finalStatePath)) { $errors += 'final_state_digest.json is required.' }
if (-not (Test-Path -LiteralPath $summaryManifestPath)) { $errors += 'chunk_summaries/codex/summary_manifest.json is required.' }

if ($errors.Count -eq 0) {
    try { $context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json } catch { $errors += "context.json is invalid JSON: $($_.Exception.Message)" }
    try { $null = Get-Content -LiteralPath $finalStatePath -Raw | ConvertFrom-Json } catch { $errors += "final_state_digest.json is invalid JSON: $($_.Exception.Message)" }
    try { $summaryManifest = Get-Content -LiteralPath $summaryManifestPath -Raw | ConvertFrom-Json } catch { $errors += "Codex summary manifest is invalid JSON: $($_.Exception.Message)" }

    if ($context) {
        if ([string]::IsNullOrWhiteSpace([string]$context.current_state.summary)) { $errors += 'current_state.summary is required.' }
        if ([string]::IsNullOrWhiteSpace([string]$context.immediate_next_action.action)) { $errors += 'immediate_next_action.action is required.' }
        if ($context.handoff_recommendation.launch_allowed -ne $false) { $errors += 'handoff_recommendation.launch_allowed must be false.' }
    }
    if ($summaryManifest -and [int]$summaryManifest.failed_count -gt 0) {
        $errors += 'Codex summary manifest has failed chunks.'
    }
}

if ($DryRun) {
    $warnings += 'Dry run: validation checked artifact structure only.'
}

$result = [ordered]@{
    passed = ($errors.Count -eq 0)
    checked_at = (Get-Date).ToUniversalTime().ToString('o')
    errors = $errors
    warnings = $warnings
}

Write-JsonNoBom -Path (Join-Path $BundlePath 'compression_context_quality.json') -Object $result

if ($errors.Count -gt 0) {
    throw ('Codex context validation failed: ' + ($errors -join '; '))
}

[pscustomobject]$result
