param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [string]$EnvPath = '.env',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-Text {
    param($Item, [string[]]$Names)
    if ($null -eq $Item) { return '' }
    if ($Item -is [string]) { return [string]$Item }
    foreach ($name in $Names) {
        if ($Item.PSObject.Properties.Name -contains $name -and -not [string]::IsNullOrWhiteSpace([string]$Item.$name)) {
            return [string]$Item.$name
        }
    }
    return ''
}

function Add-UniqueText {
    param([System.Collections.ArrayList]$List, [string]$Text)
    $clean = ([string]$Text -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { return }
    if (-not ($List -contains $clean)) {
        [void]$List.Add($clean)
    }
}

$analysisPath = Join-Path $BundlePath 'transcript_analysis.json'
$manifestPath = Join-Path $BundlePath 'session_manifest.json'
if (-not (Test-Path -LiteralPath $analysisPath)) { throw "Missing transcript_analysis.json in $BundlePath" }
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Missing session_manifest.json in $BundlePath" }

$analysis = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if (-not (Test-Path -LiteralPath (Join-Path $BundlePath 'final_state_digest.json'))) {
    & (Join-Path $PSScriptRoot 'New-FinalStateDigest.ps1') -BundlePath $BundlePath | Out-Null
}
$finalDigest = Get-Content -LiteralPath (Join-Path $BundlePath 'final_state_digest.json') -Raw | ConvertFrom-Json

$summaries = @()
$summaryRoot = Join-Path $BundlePath 'chunk_summaries'
if (Test-Path -LiteralPath $summaryRoot) {
    foreach ($dir in Get-ChildItem -LiteralPath $summaryRoot -Directory) {
        foreach ($file in Get-ChildItem -LiteralPath $dir.FullName -Filter 'chunk_*.summary.json' | Sort-Object Name) {
            try {
                $summaries += (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)
            }
            catch {
                throw "Failed to parse summary $($file.FullName): $($_.Exception.Message)"
            }
        }
    }
}

if ($summaries.Count -eq 0) {
    throw "No chunk summaries found in $summaryRoot"
}

$facts = New-Object System.Collections.ArrayList
$decisions = New-Object System.Collections.ArrayList
$work = New-Object System.Collections.ArrayList
$risks = New-Object System.Collections.ArrayList
$next = New-Object System.Collections.ArrayList
$preferredFinalFacts = New-Object System.Collections.ArrayList

foreach ($summary in @($summaries)) {
    foreach ($item in @($summary.facts)) { Add-UniqueText -List $facts -Text (Get-Text $item @('text')) }
    foreach ($item in @($summary.current_state_signals)) { Add-UniqueText -List $facts -Text (Get-Text $item @('text')) }
    foreach ($item in @($summary.decisions)) { Add-UniqueText -List $decisions -Text (Get-Text $item @('text', 'decision')) }
    foreach ($item in @($summary.files)) {
        $fileText = Get-Text $item @('path_or_name', 'path', 'name')
        if ($fileText) { Add-UniqueText -List $facts -Text ("File/artifact: " + $fileText) }
    }
    foreach ($item in @($summary.commands)) { Add-UniqueText -List $facts -Text (Get-Text $item @('text', 'command')) }
    foreach ($item in @($summary.failures)) { Add-UniqueText -List $risks -Text (Get-Text $item @('text', 'risk')) }
    foreach ($item in @($summary.risks_or_open_questions)) { Add-UniqueText -List $risks -Text (Get-Text $item @('text', 'risk')) }
    foreach ($item in @($summary.next_steps)) { Add-UniqueText -List $next -Text (Get-Text $item @('text', 'action')) }
    foreach ($item in @($summary.candidate_next_actions)) { Add-UniqueText -List $next -Text (Get-Text $item @('text', 'action')) }
    foreach ($item in @($summary.active_work_items)) { Add-UniqueText -List $work -Text (Get-Text $item @('text', 'item', 'action')) }
    foreach ($gap in @($summary.unresolved_gaps)) { Add-UniqueText -List $risks -Text ([string]$gap) }
}

foreach ($item in @($finalDigest.final_state_candidates)) { Add-UniqueText -List $facts -Text (Get-Text $item @('text')) }
foreach ($item in @($finalDigest.completed_or_verified)) { Add-UniqueText -List $facts -Text (Get-Text $item @('text')) }
foreach ($item in @($finalDigest.risks_or_caveats)) { Add-UniqueText -List $risks -Text (Get-Text $item @('text')) }
foreach ($item in @($finalDigest.next_steps)) { Add-UniqueText -List $next -Text (Get-Text $item @('text')) }
foreach ($item in @($finalDigest.user_corrections)) { Add-UniqueText -List $decisions -Text ("User correction/preference: " + (Get-Text $item @('text'))) }

foreach ($item in @($finalDigest.final_state_candidates)) {
    if ($item.type -in @('agent_message', 'message', 'task_complete')) {
        Add-UniqueText -List $preferredFinalFacts -Text (Get-Text $item @('text'))
    }
}
foreach ($item in @($finalDigest.completed_or_verified)) {
    if ($item.type -in @('agent_message', 'message', 'task_complete')) {
        Add-UniqueText -List $preferredFinalFacts -Text (Get-Text $item @('text'))
    }
}

$finalFacts = if ($preferredFinalFacts.Count -gt 0) {
    @($preferredFinalFacts | Select-Object -Last 1)
} else {
    @($facts | Select-Object -Last 8)
}
$summaryText = ($finalFacts -join ' ')
if ([string]::IsNullOrWhiteSpace($summaryText)) {
    $summaryText = 'Session context was compressed from chunk summaries; final state requires review.'
}

$nextAction = if ($next.Count -gt 0) { [string]$next[$next.Count - 1] } elseif ($work.Count -gt 0) { [string]$work[$work.Count - 1] } else { 'unknown' }
$unresolved = @($risks | Select-Object -Unique -Last 20)
if ($unresolved.Count -eq 0) { $unresolved = @('No unresolved risks were extracted; verify against raw transcript if high stakes.') }

$context = [ordered]@{
    artifact_type = 'context'
    source_session_id = if ($manifest.source_session_id) { [string]$manifest.source_session_id } else { [string]$analysis.source_session_id }
    replacement_session_name = if ($manifest.replacement_session_name) { [string]$manifest.replacement_session_name } else { 'compression-test' }
    fingerprint = if ($manifest.fingerprint) { [string]$manifest.fingerprint } else { '' }
    source_of_truth = [ordered]@{
        path = 'raw_transcript.jsonl'
        sha256 = [string]$analysis.sha256
        line_count = [int]$analysis.line_count
        size_bytes = [int64]$analysis.size_bytes
    }
    current_state = [ordered]@{
        summary = $summaryText
        status = 'hierarchical_deterministic_merge'
        confidence = 'medium'
        provenance = @()
    }
    major_decisions = @($decisions | Select-Object -Unique -Last 20 | ForEach-Object {
        [ordered]@{ decision = $_; status = 'from_chunk_or_final_state_digest'; provenance = @(); confidence = 'medium' }
    })
    active_work_items = @((@($work) + @($next)) | Select-Object -Unique -Last 20 | ForEach-Object {
        [ordered]@{ item = $_; status = 'open_or_contextual'; evidence = 'from chunk summary or final-state digest'; provenance = @(); next_action = $_; confidence = 'medium' }
    })
    open_risks = @($unresolved | ForEach-Object {
        [ordered]@{ risk = $_; impact = 'may affect continuity'; provenance = @(); confidence = 'medium' }
    })
    immediate_next_action = [ordered]@{
        action = $nextAction
        provenance = @()
        confidence = if ($nextAction -eq 'unknown') { 'low' } else { 'medium' }
    }
    unresolved_gaps = $unresolved
    handoff_recommendation = [ordered]@{
        decision = 'do_not_launch_for_test'
        reason = 'Compression context only.'
        launch_allowed = $false
    }
    provider_summary = [ordered]@{
        merge_strategy = 'hierarchical_deterministic'
        chunk_summary_count = @($summaries).Count
        final_state_digest_used = $true
        dry_run = [bool]$DryRun
    }
}

$context | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath (Join-Path $BundlePath 'context.json') -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    context_path = (Join-Path $BundlePath 'context.json')
    merge_strategy = 'hierarchical_deterministic'
    chunk_summary_count = @($summaries).Count
}
