$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Write-TestRollout {
    param([string]$Path, [string]$SessionId, [array]$ExtraLines)
    $lines = @(
        ('{"timestamp":"2026-06-10T00:00:00.000Z","type":"session_meta","payload":{"id":"' + $SessionId + '","timestamp":"2026-06-10T00:00:00.000Z","cwd":"C:\\demo","originator":"test"}}'),
        '{"timestamp":"2026-06-10T00:00:01.000Z","type":"event_msg","payload":{"type":"agent_message","message":"monitor fixture","phase":"commentary"}}'
    ) + $ExtraLines + @(
        '{"timestamp":"2026-06-10T00:00:09.000Z","type":"turn_context","payload":{"turn_id":"turn-token-monitor","cwd":"C:\\demo","model":"gpt-5","summary":"sample turn"}}'
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

$root = Join-Path $env:TEMP ('l2-token-monitor-' + [guid]::NewGuid().ToString('n'))

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $sessionId = 'monitor-fixture-session'
    $source = Join-Path $root 'rollout-monitor-fixture-session.jsonl'
    $tokenA = '{"timestamp":"2026-06-10T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50000,"cached_input_tokens":40000,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":50100},"last_token_usage":{"input_tokens":50000,"cached_input_tokens":40000,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":50100},"model_context_window":200000}}}'
    $tokenADuplicate = '{"timestamp":"2026-06-10T00:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50000,"cached_input_tokens":40000,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":50100},"last_token_usage":{"input_tokens":50000,"cached_input_tokens":40000,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":50100},"model_context_window":200000}}}'
    $tokenB = '{"timestamp":"2026-06-10T00:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120000,"cached_input_tokens":90000,"output_tokens":250,"reasoning_output_tokens":40,"total_tokens":120250},"last_token_usage":{"input_tokens":120000,"cached_input_tokens":90000,"output_tokens":250,"reasoning_output_tokens":40,"total_tokens":120250},"model_context_window":240000}}}'
    $toolOut = '{"timestamp":"2026-06-10T00:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_tool","output":"Chunk ID: abc123\nWall time: 1.0 seconds\nProcess exited with code 0\nOriginal token count: 17780\nOutput:\nlarge log body"}}'
    Write-TestRollout -Path $source -SessionId $sessionId -ExtraLines @($tokenA, $tokenADuplicate, $tokenB, $toolOut)

    $analysis = & (Join-Path $RepoRoot 'src\Read-CodexTokenUsage.ps1') -SourcePath $source
    Assert-True ($analysis.session_id -eq $sessionId) 'Parser should read session_meta.payload.id'
    Assert-True ($analysis.token_event_count -eq 3) 'Parser should count raw token events'
    Assert-True ($analysis.unique_token_event_count -eq 2) 'Parser should de-dupe consecutive repeated token events'
    Assert-True ($analysis.latest_token_event.usage.input_tokens -eq 120000) 'Parser should read latest input tokens'
    Assert-True ($analysis.latest_token_event.usage.cached_input_tokens -eq 90000) 'Parser should read cached input tokens'
    Assert-True ($analysis.latest_token_event.usage.uncached_input_tokens -eq 30000) 'Parser should compute uncached input tokens'
    Assert-True ($analysis.latest_token_event.usage.context_pressure_pct -eq 50) 'Parser should compute context pressure'
    Assert-True ($analysis.latest_token_event.usage.status -eq 'fail') 'Parser should classify fail threshold'
    Assert-True ($analysis.recent_tool_outputs[0].original_token_count -eq 17780) 'Parser should extract Original token count from tool output'
    Assert-True ($analysis.recommendation -match 'tool output|compression|monitor') 'Parser should emit a recommendation'

    $compressed = Join-Path $root 'compressed.jsonl'
    @(
        ('{"timestamp":"2026-06-10T00:00:00.000Z","type":"session_meta","payload":{"id":"' + $sessionId + '","timestamp":"2026-06-10T00:00:00.000Z"}}'),
        '{"timestamp":"2026-06-10T00:00:01.000Z","type":"compacted","payload":{"message":"summary","replacement_history":[{"type":"message","role":"user","content":[{"type":"input_text","text":"handoff"}]}]}}',
        '{"timestamp":"2026-06-10T00:00:02.000Z","type":"turn_context","payload":{"turn_id":"turn"}}'
    ) | Set-Content -LiteralPath $compressed -Encoding UTF8
    $compressedAnalysis = & (Join-Path $RepoRoot 'src\Read-CodexTokenUsage.ps1') -SourcePath $compressed
    Assert-True ($compressedAnalysis.compressed_only_shape -eq $true) 'Parser should detect compressed-only rollout shape'

    $bySource = & (Join-Path $RepoRoot 'Measure-CodexSessionTokens.ps1') -SourcePath $source
    Assert-True ($bySource.latest_usage.input_tokens -eq 120000) 'Public script should resolve by SourcePath'

    $byFilename = & (Join-Path $RepoRoot 'Measure-CodexSessionTokens.ps1') -SessionId $sessionId -SessionRoot $root
    Assert-True ($byFilename.path -eq (Resolve-Path -LiteralPath $source).Path) 'Public script should resolve by filename containing SessionId'

    $embeddedRoot = Join-Path $root 'embedded'
    $embeddedPath = Join-Path $embeddedRoot 'rollout-hidden-name.jsonl'
    Write-TestRollout -Path $embeddedPath -SessionId 'embedded-session-id' -ExtraLines @($tokenA)
    $byEmbedded = & (Join-Path $RepoRoot 'Measure-CodexSessionTokens.ps1') -SessionId 'embedded-session-id' -SessionRoot $embeddedRoot
    Assert-True ($byEmbedded.path -eq (Resolve-Path -LiteralPath $embeddedPath).Path) 'Public script should resolve by embedded session_meta id'

    $watchSource = Join-Path $root 'watch-rollout.jsonl'
    Write-TestRollout -Path $watchSource -SessionId 'watch-session' -ExtraLines @($tokenA)
    $watchOut = Join-Path $root 'watch-runs'
    $job = Start-Job -ScriptBlock {
        param($RepoRootArg, $SourceArg, $OutArg)
        & (Join-Path $RepoRootArg 'Measure-CodexSessionTokens.ps1') -SourcePath $SourceArg -Watch -Minutes 0.2 -IntervalSeconds 1 -StableSeconds 1 -OutRoot $OutArg
    } -ArgumentList $RepoRoot, $watchSource, $watchOut
    Start-Sleep -Seconds 2
    Add-Content -LiteralPath $watchSource -Value $tokenB
    Wait-Job $job -Timeout 30 | Out-Null
    Assert-True ($job.State -eq 'Completed') 'Watch monitor job should complete'
    $watchResult = Receive-Job $job
    Remove-Job $job
    Assert-True ($watchResult.found_next_turn -eq $true) 'Watch monitor should find next unique token event'
    Assert-True (Test-Path -LiteralPath $watchResult.summary) 'Watch monitor should write summary.json'
    $summary = Get-Content -LiteralPath $watchResult.summary -Raw | ConvertFrom-Json
    Assert-True ($summary.watch.found_next_turn -eq $true) 'summary.json should record found_next_turn'
    Assert-True ($summary.baseline.latest_usage.input_tokens -eq 50000) 'summary.json should record baseline usage'
    Assert-True ($summary.next_turn.latest_usage.input_tokens -eq 120000) 'summary.json should record next-turn usage'

    'token-monitor.tests.ps1 PASS'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
