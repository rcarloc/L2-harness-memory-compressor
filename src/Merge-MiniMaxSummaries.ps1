param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [string]$EnvPath = '.env',
    [switch]$DryRun,
    [switch]$Force
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

function ConvertTo-ProvenanceList {
    param($Items)
    $out = @()
    foreach ($item in @($Items)) {
        foreach ($p in @($item.provenance)) {
            $out += [ordered]@{
                line = if ($p.source_line) { [int]$p.source_line } elseif ($p.line) { [int]$p.line } else { $null }
                timestamp = if ($p.timestamp) { [string]$p.timestamp } else { '' }
                evidence = if ($p.evidence) { [string]$p.evidence } else { '' }
            }
        }
    }
    return $out
}

function New-DryRunContext {
    param($Analysis, $Manifest, $Summaries)

    $firstSummary = @($Summaries | Select-Object -First 1)
    $prov = @()
    if ($firstSummary.Count -gt 0 -and $firstSummary[0].source) {
        $prov += [ordered]@{
            line = [int]$firstSummary[0].source.first_source_line
            timestamp = [string]$firstSummary[0].source.first_timestamp
            evidence = 'Dry-run chunk summary placeholder; semantic merge not performed.'
        }
    }

    [ordered]@{
        artifact_type = 'context'
        source_session_id = [string]$Manifest.source_session_id
        replacement_session_name = [string]$Manifest.replacement_session_name
        fingerprint = [string]$Manifest.fingerprint
        source_of_truth = [ordered]@{
            path = 'raw_transcript.jsonl'
            sha256 = [string]$Analysis.sha256
            line_count = [int]$Analysis.line_count
            size_bytes = [int64]$Analysis.size_bytes
        }
        current_state = [ordered]@{
            summary = 'MiniMax merge dry run completed; semantic content was not generated because no model call was made.'
            status = 'dry_run_only'
            confidence = 'low'
            provenance = $prov
        }
        major_decisions = @()
        active_work_items = @()
        open_risks = @([ordered]@{
            risk = 'Dry-run output is not a semantic PM handoff summary.'
            impact = 'Cannot be used to bootstrap a replacement PM thread.'
            provenance = $prov
            confidence = 'high'
        })
        immediate_next_action = [ordered]@{
            action = 'Run MiniMax summarization and merge without -DryRun when ready to spend provider tokens.'
            provenance = $prov
            confidence = 'high'
        }
        unresolved_gaps = @('Dry run: no MiniMax merge model call was made.', 'No new thread should be launched from this artifact.')
        handoff_recommendation = [ordered]@{
            decision = 'do_not_launch'
            reason = 'Provider merge is dry-run only.'
            launch_allowed = $false
        }
        provider_summary = [ordered]@{
            merge_provider = 'minimax'
            summary_count = @($Summaries).Count
            dry_run = $true
        }
    }
}

function Write-DerivedArtifacts {
    param(
        $Context,
        [string]$BundlePath
    )

    # Field-name tolerant extraction. The merge model returns a flat structured
    # current_state (e.g. {g7_progress_pct, g7_2_a_status, product_pass_claimed, ...})
    # and immediate_next_action as {text, provenance, confidence, ...}, but older
    # shapes or string-valued fields are possible. Build a summary and a next-action
    # text that works regardless of shape.

    function Get-CurrentStateSummary {
        param($Ctx)
        $cs = $Ctx.current_state
        if ($null -eq $cs) { return '(no current_state in context.json)' }
        # 1) Prefer an explicit summary field if present and non-empty
        if ($cs -is [System.Management.Automation.PSObject] -and -not ($cs -is [string])) {
            $hasSummary = $cs.PSObject.Properties.Name -contains 'summary'
            if ($hasSummary -and -not [string]::IsNullOrWhiteSpace([string]$cs.summary)) {
                $s = [string]$cs.summary
                if ($s -match 'Merge model did not return') { return $null }
                return $s
            }
        } elseif ($cs -is [string] -and -not [string]::IsNullOrWhiteSpace($cs)) {
            return $cs
        }
        # 2) Synthesize from high-signal fields the model typically emits
        if ($cs -is [System.Management.Automation.PSObject]) {
            $parts = @()
            $keys = @(
                'overall_status','g7_2a_status','g7_2_a_status','g7_2_a',
                'g7_progress','g7_progress_pct','g7_progress_ceiling_pct',
                'product_pass','product_pass_claimed','evidence_harness_stable',
                'phase_1','phase_2','phase_3',
                'technical_pass_scope','operating_model','codex_cli_version',
                'runner_status','minimax_status','local_shell_status',
                'pm_loop_status','em_session_token_at_close','token_usage_high'
            )
            foreach ($k in $keys) {
                if ($cs.PSObject.Properties.Name -contains $k) {
                    $v = [string]$cs.$k
                    if (-not [string]::IsNullOrWhiteSpace($v)) {
                        $parts += ("{0}={1}" -f $k, $v)
                    }
                }
            }
            if ($parts.Count -gt 0) { return ($parts -join '; ') }
        }
        return $null
    }

    function Get-ImmediateNextActionText {
        param($Ctx)
        $ina = $Ctx.immediate_next_action
        if ($null -eq $ina) { return '' }
        if ($ina -is [string]) { return $ina }
        if ($ina -is [System.Management.Automation.PSObject]) {
            # Prefer 'text', then 'action', then a stringify of all fields
            foreach ($k in @('text','action','summary','description')) {
                if ($ina.PSObject.Properties.Name -contains $k -and -not [string]::IsNullOrWhiteSpace([string]$ina.$k)) {
                    return [string]$ina.$k
                }
            }
            # Fallback: stringify
            return ($ina | ConvertTo-Json -Depth 5 -Compress)
        }
        return ''
    }

    function Get-CurrentStatus {
        param($Ctx)
        $cs = $Ctx.current_state
        if ($null -eq $cs) { return '' }
        if ($cs -is [string]) { return $cs }
        if ($cs -is [System.Management.Automation.PSObject]) {
            foreach ($k in @('overall_status','status','g7_2a_status','g7_2_a_status')) {
                if ($cs.PSObject.Properties.Name -contains $k -and -not [string]::IsNullOrWhiteSpace([string]$cs.$k)) {
                    return [string]$cs.$k
                }
            }
        }
        return ''
    }

    $summaryText = Get-CurrentStateSummary -Ctx $Context
    $actionText = Get-ImmediateNextActionText -Ctx $Context
    $statusText = Get-CurrentStatus -Ctx $Context
    if ([string]::IsNullOrWhiteSpace($summaryText)) { $summaryText = '(context.json did not yield a synthesized summary; check current_state keys directly.)' }
    if ([string]::IsNullOrWhiteSpace($actionText)) { $actionText = '(context.json did not include an immediate_next_action; see major_decisions and active_work_items.)' }


    $contextPath = Join-Path $BundlePath 'context.json'
    $Context | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $contextPath -Encoding UTF8
    $fingerprint = [string]$Context.fingerprint
    $contextAliasName = "context_$fingerprint.json"
    $contextAliasPath = Join-Path $BundlePath $contextAliasName
    $Context | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $contextAliasPath -Encoding UTF8

    $rawPath = Join-Path $BundlePath 'raw_transcript.jsonl'
    $rawAliasName = "raw_transcript_$fingerprint.jsonl"
    $rawAliasPath = Join-Path $BundlePath $rawAliasName
    if ((Test-Path -LiteralPath $rawPath) -and -not (Test-Path -LiteralPath $rawAliasPath)) {
        try {
            New-Item -ItemType HardLink -Path $rawAliasPath -Target $rawPath -ErrorAction Stop | Out-Null
        } catch {
            Copy-Item -LiteralPath $rawPath -Destination $rawAliasPath -ErrorAction SilentlyContinue
        }
    }
    $rawPromptPath = if (Test-Path -LiteralPath $rawAliasPath) { $rawAliasPath } else { $rawPath }
    $rawPromptName = Split-Path -Path $rawPromptPath -Leaf

    $md = @"
# PM Handoff Context

Status: $statusText

$summaryText

## Immediate Next Action

$actionText

## Launch

Launch allowed: $($Context.handoff_recommendation.launch_allowed)
Reason: $($Context.handoff_recommendation.reason)
"@
    $md | Set-Content -LiteralPath (Join-Path $BundlePath 'context.md') -Encoding UTF8

    $sessionState = [ordered]@{
        artifact_type = 'session_state'
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        source_session_id = [string]$Context.source_session_id
        fingerprint = [string]$Context.fingerprint
        status = $statusText
        context_path = 'context.json'
        launch_allowed = $false
        immediate_next_action = $actionText
    }
    $sessionState | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $BundlePath 'session_state.json') -Encoding UTF8

    $bootstrap = @"
You are continuing the PM session from a durable handoff checkpoint.

Use context.json and raw_transcript.jsonl as the local state bundle. Raw transcript remains the source of truth; context files are derived artifacts.

Source session id: $($Context.source_session_id)
Fingerprint: $($Context.fingerprint)
Replacement/session name: $($Context.replacement_session_name)

Current state:
$summaryText

Immediate next action:
$actionText

Do not assume launch was validated. launch_allowed=false unless an explicit later validation changes it.

**Messaging other app threads:**
If you need to send a message to another app thread or agent and `send_message_to_thread` is not available, use the multi-agent v1 tools:
1. `tool_search` for `multi_agent_v1` to discover the tools
2. `multi_agent_v1.resume_agent({id:"<target_thread_id>"})` to confirm the target is reachable
3. `multi_agent_v1.send_input({target:"<target_thread_id>", interrupt:true, message:"<your message>"})` to deliver the message
4. `multi_agent_v1.wait_agent({targets:["<target_thread_id>"], timeout_ms:30000})` to wait for a response

This pattern is the fallback when `send_message_to_thread` is not exposed in the current tool registry.
"@
    $bootstrap | Set-Content -LiteralPath (Join-Path $BundlePath 'bootstrap_prompt.txt') -Encoding UTF8

    $roleName = [string]$Context.replacement_session_name
    if ($roleName.Contains('#')) {
        $roleName = $roleName.Split('#')[0].Trim()
    }
    if ([string]::IsNullOrWhiteSpace($roleName)) {
        $roleName = 'Codex'
    }

    $manualPrompt = @"
You are continuing the $roleName session from a durable handoff checkpoint.

Use these local state bundle files:
- Context: $contextAliasPath
- Raw transcript: $rawPromptPath

Raw transcript remains the source of truth. Context files are derived artifacts.

Source session id: $($Context.source_session_id)
Fingerprint: $fingerprint
Replacement/session name: $($Context.replacement_session_name)

First read the context file. Use the raw transcript only when you need provenance, exact wording, or to resolve uncertainty.

Current state:
$summaryText

Immediate next action:
$actionText

Do not invent status, decisions, or next actions. If the context conflicts with the raw transcript, trust the raw transcript and state the conflict.

**Messaging other app threads:**
If you need to send a message to another app thread or agent and `send_message_to_thread` is not available, use the multi-agent v1 tools:
1. `tool_search` for `multi_agent_v1` to discover the tools
2. `multi_agent_v1.resume_agent({id:"<target_thread_id>"})` to confirm the target is reachable
3. `multi_agent_v1.send_input({target:"<target_thread_id>", interrupt:true, message:"<your message>"})` to deliver the message
4. `multi_agent_v1.wait_agent({targets:["<target_thread_id>"], timeout_ms:30000})` to wait for a response

This pattern is the fallback when `send_message_to_thread` is not exposed in the current tool registry.
"@
    $manualPrompt | Set-Content -LiteralPath (Join-Path $BundlePath 'manual_new_chat_prompt.txt') -Encoding UTF8
}

$analysisPath = Join-Path $BundlePath 'transcript_analysis.json'
$manifestPath = Join-Path $BundlePath 'session_manifest.json'
$chunkManifestPath = Join-Path $BundlePath 'semantic_chunk_manifest.json'
if (-not (Test-Path -LiteralPath $analysisPath)) { throw "Missing transcript_analysis.json in $BundlePath" }
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Missing session_manifest.json in $BundlePath" }
if (-not (Test-Path -LiteralPath $chunkManifestPath)) { throw "Missing semantic_chunk_manifest.json in $BundlePath" }

$analysis = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$chunkManifest = Get-Content -LiteralPath $chunkManifestPath -Raw | ConvertFrom-Json
$expectedChunkCount = [int]$chunkManifest.chunk_count
if ($expectedChunkCount -le 0) {
    $expectedChunkCount = @($chunkManifest.chunks).Count
}
if ($expectedChunkCount -le 0) {
    throw "semantic_chunk_manifest.json does not contain any chunks in $BundlePath"
}
$summaryDirs = @(
    Join-Path $BundlePath 'chunk_summaries\minimax_m3'
    Join-Path $BundlePath 'chunk_summaries\mimo_v25_pro'
)
$summaryProviderCounts = [ordered]@{
    minimax_m3 = 0
    mimo_v25_pro = 0
}
$summaryEntries = @()
foreach ($summaryDir in $summaryDirs) {
    $providerKey = Split-Path -Path $summaryDir -Leaf
    $entries = @(Get-ChildItem -LiteralPath $summaryDir -Filter 'chunk_*.summary.json' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.BaseName -match 'chunk_(?<chunk>\d+)') {
                [pscustomobject]@{
                    Path       = $_.FullName
                    ChunkIndex = [int]$matches.chunk
                    Provider   = $providerKey
                }
            }
            else {
                throw "Could not parse chunk index from '$($_.Name)' in $summaryDir"
            }
        })
    if ($summaryProviderCounts.Contains($providerKey)) {
        $summaryProviderCounts[$providerKey] = $entries.Count
    }
    $summaryEntries += $entries
}

if ($summaryEntries.Count -eq 0) {
    throw "No chunk summaries found in $($summaryDirs -join ', ')"
}

$summaryFiles = @($summaryEntries | Sort-Object ChunkIndex, Path)
if ($summaryFiles.Count -ne $expectedChunkCount) {
    throw "Expected $expectedChunkCount chunk summaries for merge, found $($summaryFiles.Count) in $($summaryDirs -join ', ')"
}

$summaries = @()
foreach ($entry in $summaryFiles) {
    $summaries += (Get-Content -LiteralPath $entry.Path -Raw | ConvertFrom-Json)
}

if ($summaries.Count -gt 8 -and -not $DryRun) {
    & (Join-Path $PSScriptRoot 'Merge-ContextHierarchical.ps1') `
        -BundlePath $BundlePath `
        -EnvPath $EnvPath `
        -Force:$Force | Out-Null
    return
}

$envConfig = & (Join-Path $PSScriptRoot 'Read-HandoffEnv.ps1') -EnvPath $EnvPath -IncludeSecrets
$minimax = $envConfig.providers.minimax
$runDir = Join-Path $BundlePath 'provider_runs\minimax_m3'
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

if ($DryRun) {
    $context = New-DryRunContext -Analysis $analysis -Manifest $manifest -Summaries $summaries
} else {
    if (-not $minimax.api_key_present) {
        throw 'MINIMAX_API_KEY is required for MiniMax merge.'
    }

    $system = @'
You merge chunk summaries into canonical Codex handoff state.
Raw transcript is source of truth, but you only have derived chunk summaries here.
Do not invent status, decisions, or next actions. Mark missing evidence as unresolved.
Return only one JSON object matching the requested context schema.
'@

    $summaryJson = $summaries | ConvertTo-Json -Depth 80
    $user = @"
Create canonical context.json for this PM handoff bundle.

Required top-level keys:
artifact_type, source_session_id, replacement_session_name, fingerprint, source_of_truth, current_state, major_decisions, active_work_items, open_risks, immediate_next_action, unresolved_gaps, handoff_recommendation, provider_summary.

Rules:
- source_of_truth.path must be raw_transcript.jsonl.
- launch_allowed must be false.
- Every decision/risk/work item should include provenance where available.
- If summaries are insufficient, put that in unresolved_gaps.

Source facts:
- source_session_id: $($manifest.source_session_id)
- replacement_session_name: $($manifest.replacement_session_name)
- fingerprint: $($manifest.fingerprint)
- raw sha256: $($analysis.sha256)
- raw line_count: $($analysis.line_count)
- raw size_bytes: $($analysis.size_bytes)

Chunk summaries:
$summaryJson
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
        -MaxTokens 12000 `
        -Temperature 0.1 `
        -RunDir $runDir `
        -RunLabel 'merge_context' `
        -DryRun:$false

    $contextObj = & (Join-Path $PSScriptRoot 'ConvertFrom-ProviderJson.ps1') -Text ([string]$providerResult.output_text)
    if (-not $contextObj) {
        throw 'MiniMax merge did not return a JSON object.'
    }
    $context = [ordered]@{}
    foreach ($prop in $contextObj.PSObject.Properties) {
        $context[$prop.Name] = $prop.Value
    }

    # Defensive: ensure handoff_recommendation is a structured object with launch_allowed=false
    $hr = $context['handoff_recommendation']
    $hrIsObject = $hr -and ($hr -is [System.Management.Automation.PSObject]) -and -not ($hr -is [string]) -and -not ($hr -is [array])
    if (-not $hrIsObject) {
        $reasonText = if ($hr) { [string]$hr } else { 'Merge output did not include handoff_recommendation object.' }
        $context['handoff_recommendation'] = [ordered]@{
            decision = 'review'
            reason = $reasonText
            launch_allowed = $false
        }
    } else {
        $hrHas = $hr.PSObject.Properties.Name -contains 'launch_allowed'
        if (-not $hrHas) { Add-Member -InputObject $hr -NotePropertyName launch_allowed -NotePropertyValue $false -Force }
        elseif ([bool]$hr.launch_allowed) { $hr.launch_allowed = $false }
    }

    # Defensive: ensure launch_allowed is false at top level if model emitted it as a top-level key
    if ($context.Contains('launch_allowed') -and [bool]$context['launch_allowed']) {
        $context['launch_allowed'] = $false
    }

    # Defensive: ensure current_state.summary is a non-empty string. If the model returned
    # a structured object without a top-level summary, synthesize one from the structured fields
    # and keep the original fields alongside.
    $cs = $context['current_state']
    $csIsObject = $cs -and ($cs -is [System.Management.Automation.PSObject]) -and -not ($cs -is [string])
    if ($csIsObject) {
        $hasSummary = ($cs.PSObject.Properties.Name -contains 'summary') -and -not [string]::IsNullOrWhiteSpace([string]$cs.summary)
        if (-not $hasSummary) {
            $parts = @()
            $keysToShow = @('g7_progress','g7_phase','g7_2a_status','product_pass','phase_1','phase_2','runner_status','minimax_status','overall_status')
            foreach ($k in $keysToShow) {
                if ($cs.PSObject.Properties.Name -contains $k) {
                    $parts += ("{0}={1}" -f $k, [string]$cs.$k)
                }
            }
            if ($parts.Count -gt 0) {
                $summaryText = "Synthesized from structured current_state: " + ($parts -join '; ')
            } else {
                $summaryText = "Merge model did not return current_state.summary; structured current_state object preserved."
            }
            if ($cs.PSObject.Properties.Name -contains 'summary') {
                $cs.summary = $summaryText
            } else {
                Add-Member -InputObject $cs -NotePropertyName summary -NotePropertyValue $summaryText -Force
            }
            if (-not ($cs.PSObject.Properties.Name -contains 'summary_synthesized')) {
                Add-Member -InputObject $cs -NotePropertyName summary_synthesized -NotePropertyValue $true -Force
            }
        }
    } elseif ($cs -is [string]) {
        $context['current_state'] = [ordered]@{
            summary = [string]$cs
            original_string_value = [string]$cs
        }
    }

    # Defensive: ensure provider_summary exists as an object
    if (-not $context.Contains('provider_summary') -or $null -eq $context['provider_summary']) {
        $context['provider_summary'] = [ordered]@{}
    }
    $ps = $context['provider_summary']
    $psIsObject = $ps -is [System.Management.Automation.PSObject] -and -not ($ps -is [string])
    if ($psIsObject) {
        $ps | Add-Member -NotePropertyName merge_provider_run -NotePropertyValue ([string]$providerResult.run_path) -Force
    }
}

Write-DerivedArtifacts -Context $context -BundlePath $BundlePath

$report = @"
# PM Handoff Merge

Status: MERGE_COMPLETE

- Merge provider: MiniMax
- Merge model: $($minimax.model)
- Chunk summary providers: MiniMax M3=$($summaryProviderCounts.minimax_m3), MiMo v2.5 Pro=$($summaryProviderCounts.mimo_v25_pro)
- Dry run: $([bool]$DryRun)
- Chunk summaries: $($summaryFiles.Count)
- Launch allowed: false
- Launch attempted: false
"@
$report | Set-Content -LiteralPath (Join-Path $BundlePath 'handoff_report.md') -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    provider = 'mixed_chunk_summaries'
    merge_provider = 'minimax'
    model = [string]$minimax.model
    chunk_summary_providers = $summaryProviderCounts
    dry_run = [bool]$DryRun
    summaries_merged = $summaryFiles.Count
    launch_allowed = $false
}
