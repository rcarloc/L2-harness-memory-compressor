$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$root = Join-Path $env:TEMP ('l2-rollout-shape-' + [guid]::NewGuid().ToString('n'))
$source = Join-Path $root 'source.jsonl'
$bundle = Join-Path $root 'bundle'
$out = Join-Path $root 'compressed-rollout.jsonl'

try {
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    @(
        '{"timestamp":"2026-06-09T00:00:00.000Z","type":"session_meta","payload":{"id":"shape-test","cwd":"C:\\demo"}}',
        '{"timestamp":"2026-06-09T00:00:01.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Final state: shape test complete."}}',
        '{"timestamp":"2026-06-09T00:00:02.000Z","type":"turn_context","payload":{"turn_id":"shape-turn","cwd":"C:\\demo"}}'
    ) | Set-Content -LiteralPath $source -Encoding UTF8

    [ordered]@{
        artifact_type = 'context'
        source_session_id = 'shape-test'
        source_of_truth = [ordered]@{
            path = 'raw_transcript.jsonl'
            sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            line_count = 3
            size_bytes = (Get-Item -LiteralPath $source).Length
        }
        current_state = [ordered]@{
            summary = 'Final state: shape test complete.'
            status = 'test'
            confidence = 'high'
        }
        major_decisions = @()
        active_work_items = @([ordered]@{ item = 'Run public tests.' })
        open_risks = @()
        immediate_next_action = [ordered]@{ action = 'Run public tests.' }
        unresolved_gaps = @()
        handoff_recommendation = [ordered]@{ launch_allowed = $false }
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $bundle 'context.json') -Encoding UTF8

    & (Join-Path $RepoRoot 'src\New-CompressedRollout.ps1') `
        -SourcePath $source `
        -BundlePath $bundle `
        -OutputPath $out | Out-Null

    & (Join-Path $RepoRoot 'src\Test-CompressedRollout.ps1') -Path $out | Out-Null

    $records = @(Get-Content -LiteralPath $out | ForEach-Object { $_ | ConvertFrom-Json })
    $keys = $records | ForEach-Object { $_.type }
    Assert-True (($keys -join ',') -eq 'session_meta,compacted,turn_context') 'Compressed rollout should contain only session_meta, compacted, turn_context'

    $bad = Join-Path $root 'bad.jsonl'
    @(
        '{"timestamp":"2026-06-09T00:00:00.000Z","type":"session_meta","payload":{"id":"shape-test"}}',
        '{"timestamp":"2026-06-09T00:00:01.000Z","type":"compacted","payload":{"message":"","replacement_history":[{"type":"message","role":"user","content":"wrong"}]}}',
        '{"timestamp":"2026-06-09T00:00:02.000Z","type":"turn_context","payload":{"turn_id":"shape-turn"}}'
    ) | Set-Content -LiteralPath $bad -Encoding UTF8

    $failed = $false
    try { & (Join-Path $RepoRoot 'src\Test-CompressedRollout.ps1') -Path $bad | Out-Null } catch { $failed = $true }
    Assert-True $failed 'Validator should reject non-array replacement_history content'

    'rollout-shape.tests.ps1 PASS'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
