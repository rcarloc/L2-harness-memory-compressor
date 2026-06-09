$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:TEMP ('handoff-final-state-test-' + [guid]::NewGuid().ToString('n'))
$Bundle = Join-Path $Root 'bundle'
New-Item -ItemType Directory -Path $Bundle -Force | Out-Null

1..100 | ForEach-Object {
    $type = if ($_ -eq 95) { 'user_message' } else { 'agent_message' }
    $text = if ($_ -eq 95) {
        'User says the first implementation was wrong and asks to use the final corrected path.'
    } elseif ($_ -eq 99) {
        'Final state: test passed 5/5, edited src/final.ts, next action is run browser smoke.'
    } else {
        "Earlier stale event $_"
    }
    [ordered]@{
        source_line = $_
        timestamp = '2026-01-01T00:00:00Z'
        type = $type
        role = if ($type -eq 'user_message') { 'user' } else { 'assistant' }
        text = $text
    } | ConvertTo-Json -Compress
} | Set-Content -LiteralPath (Join-Path $Bundle 'semantic_event_stream.jsonl') -Encoding UTF8

@(
    [ordered]@{
        timestamp = '2026-01-01T00:10:00Z'
        type = 'event_msg'
        payload = [ordered]@{
            type = 'task_complete'
            last_agent_message = @'
Status check complete after pivot.

Files investigated/edited:
- src/run.mjs (patched)
- tests/p251.test.ts (updated)

Tests:
- npm test -- tests/p251.test.ts -> PASS (5/5)

Residual risk: browser smoke remains pending.
'@
        }
    } | ConvertTo-Json -Depth 10 -Compress
) | Set-Content -LiteralPath (Join-Path $Bundle 'raw_transcript.jsonl') -Encoding UTF8

& (Join-Path $PSScriptRoot '..\src\New-FinalStateDigest.ps1') -BundlePath $Bundle -TailPercent 20 -MinTailEvents 10

$digestPath = Join-Path $Bundle 'final_state_digest.json'
if (-not (Test-Path -LiteralPath $digestPath)) { throw 'Missing final_state_digest.json.' }

$digest = Get-Content -LiteralPath $digestPath -Raw | ConvertFrom-Json
if ($digest.tail_event_count -lt 10) { throw 'Tail event count too small.' }
if (($digest.final_state_candidates.text -join ' ') -notmatch 'test passed 5/5') { throw 'Missing final state candidate.' }
if (($digest.final_state_candidates.text -join ' ') -notmatch 'src/run\.mjs') { throw 'Missing raw task_complete edited file.' }
if (($digest.completed_or_verified.text -join ' ') -notmatch 'PASS \(5/5\)') { throw 'Missing raw task_complete verification.' }
if (($digest.user_corrections.text -join ' ') -notmatch 'wrong') { throw 'Missing user correction.' }

Remove-Item -LiteralPath $Root -Recurse -Force
'final-state-digest.tests.ps1 PASS'
