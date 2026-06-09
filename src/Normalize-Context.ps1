param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [Parameter(Mandatory = $true)]
    [string]$SessionId,

    [Parameter(Mandatory = $true)]
    [string]$Role,

    [Parameter(Mandatory = $true)]
    [string]$Fingerprint,

    [Parameter(Mandatory = $true)]
    [string]$ReplacementSessionName
)

$ErrorActionPreference = 'Stop'

function Convert-Provenance {
    param($Items)
    $out = @()
    if ($Items) {
        foreach ($item in @($Items)) {
            $out += [ordered]@{
                line = if ($item.line) { [int]$item.line } else { $null }
                timestamp = if ($item.timestamp) { [string]$item.timestamp } else { '' }
                evidence = if ($item.evidence) { [string]$item.evidence } else { '' }
            }
        }
    }
    return $out
}

$analysisPath = Join-Path $BundlePath 'transcript_analysis.json'
if (-not (Test-Path -LiteralPath $analysisPath)) {
    throw "Missing transcript_analysis.json in $BundlePath"
}
$analysis = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json

$modelContextPath = Join-Path $BundlePath 'context.model.json'
$contextPath = Join-Path $BundlePath 'context.json'

if (-not (Test-Path -LiteralPath $modelContextPath)) {
    if (Test-Path -LiteralPath $contextPath) {
        Copy-Item -LiteralPath $contextPath -Destination $modelContextPath -Force
    }
    else {
        throw "Missing context.model.json or context.json in $BundlePath"
    }
}

$modelContext = Get-Content -LiteralPath $modelContextPath -Raw | ConvertFrom-Json

$normalized = [ordered]@{
    artifact_type = 'context'
    source_session_id = if ($modelContext.bundle.session_id) { [string]$modelContext.bundle.session_id } else { $SessionId }
    replacement_session_name = if ($modelContext.bundle.replacement_session_name) { [string]$modelContext.bundle.replacement_session_name } else { $ReplacementSessionName }
    fingerprint = if ($modelContext.bundle.fingerprint) { [string]$modelContext.bundle.fingerprint } else { $Fingerprint }
    source_of_truth = [ordered]@{
        path = 'raw_transcript.jsonl'
        sha256 = [string]$analysis.sha256
        line_count = [int]$analysis.line_count
        size_bytes = [int64]$analysis.size_bytes
    }
    current_state = [ordered]@{
        summary = if ($modelContext.goal) { [string]$modelContext.goal } elseif ($modelContext.state.current_task) { [string]$modelContext.state.current_task } else { "$Role handoff checkpoint" }
        status = if ($modelContext.state.status) { [string]$modelContext.state.status } else { 'unknown' }
        confidence = 'medium'
        provenance = Convert-Provenance $(if ($modelContext.goal_provenance) { $modelContext.goal_provenance } else { $modelContext.state_provenance })
    }
    major_decisions = @()
    active_work_items = @()
    open_risks = @()
    immediate_next_action = [ordered]@{
        action = 'unknown'
        provenance = @()
        confidence = 'low'
    }
    unresolved_gaps = @()
    handoff_recommendation = [ordered]@{
        decision = 'do_not_launch_for_test'
        reason = 'Launch remains disabled until validation and launcher checks pass.'
        launch_allowed = $false
    }
}

foreach ($decision in @($modelContext.decision_set)) {
    $normalized.major_decisions += [ordered]@{
        decision = [string]$decision.text
        status = 'accepted_in_discussion'
        provenance = Convert-Provenance $decision.provenance
        confidence = 'medium'
    }
}

foreach ($item in @($modelContext.next_task)) {
    $normalized.active_work_items += [ordered]@{
        item = [string]$item.text
        status = 'open'
        evidence = 'extracted from model context next_task'
        provenance = Convert-Provenance $item.provenance
        next_action = [string]$item.text
        confidence = 'medium'
    }
}

foreach ($risk in @($modelContext.risks)) {
    $normalized.open_risks += [ordered]@{
        risk = [string]$risk.text
        impact = 'may affect reliable automated handoff'
        provenance = Convert-Provenance $risk.provenance
        confidence = 'medium'
    }
}

if ($normalized.active_work_items.Count -gt 0) {
    $first = $normalized.active_work_items[0]
    $normalized.immediate_next_action = [ordered]@{
        action = $first.next_action
        provenance = $first.provenance
        confidence = 'medium'
    }
}

$normalized.unresolved_gaps += 'Model output required deterministic normalization; original preserved as context.model.json.'
foreach ($risk in @($normalized.open_risks)) {
    if ($risk.risk) { $normalized.unresolved_gaps += $risk.risk }
}

$normalized | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $contextPath -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    context_path = $contextPath
    normalized = $true
}
