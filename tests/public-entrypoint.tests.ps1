$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Read-JsonLines {
    param([string]$Path)
    return @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

$root = Join-Path $env:TEMP ('l2-public-entrypoint-' + [guid]::NewGuid().ToString('n'))
$source = Join-Path $root 'sample-rollout.jsonl'
$outRoot = Join-Path $root 'runs'
$envPath = Join-Path $root '.env'

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    @(
        '{"timestamp":"2026-06-09T00:00:00.000Z","type":"session_meta","payload":{"id":"sample-public-session","timestamp":"2026-06-09T00:00:00.000Z","cwd":"C:\\demo","originator":"test"}}',
        '{"timestamp":"2026-06-09T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Compress this session for durable handoff.","images":[]}}',
        '{"timestamp":"2026-06-09T00:00:02.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Final state: public packaging complete. Next action: run tests.","phase":"final"}}',
        '{"timestamp":"2026-06-09T00:00:03.000Z","type":"turn_context","payload":{"turn_id":"turn-public-test","cwd":"C:\\demo","model":"gpt-5","summary":"sample turn"}}'
    ) | Set-Content -LiteralPath $source -Encoding UTF8
    & (Join-Path $RepoRoot 'Compress-CodexSession.ps1') `
        -SourcePath $source `
        -OutRoot $outRoot `
        -Provider codex `
        -EnvPath $envPath `
        -DryRun `
        -UseDigest `
        -RetryFailedChunks | Out-Null

    $runDirs = @(Get-ChildItem -LiteralPath $outRoot -Directory)
    Assert-True ($runDirs.Count -eq 1) 'Wrapper should create exactly one run directory'
    $compressed = Join-Path $runDirs[0].FullName 'compressed-rollout.jsonl'
    Assert-True (Test-Path -LiteralPath $compressed) 'Wrapper should write compressed-rollout.jsonl'

    $bytes = [System.IO.File]::ReadAllBytes($compressed)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)) 'Compressed rollout must be UTF-8 without BOM'

    $records = Read-JsonLines -Path $compressed
    Assert-True ($records.Count -eq 3) 'Compressed rollout should have exactly three JSONL records'
    Assert-True ($records[0].type -eq 'session_meta') 'Line 1 should be session_meta'
    Assert-True ($records[1].type -eq 'compacted') 'Line 2 should be compacted'
    Assert-True ($records[2].type -eq 'turn_context') 'Line 3 should be turn_context'

    $replacement = @($records[1].payload.replacement_history)
    Assert-True ($replacement.Count -eq 1) 'replacement_history should contain one handoff message'
    Assert-True ($replacement[0].type -eq 'message') 'replacement_history item should be raw message ResponseItem'
    Assert-True ($replacement[0].role -eq 'user') 'replacement_history message should be user role'
    Assert-True (@($replacement[0].content).Count -gt 0) 'replacement_history message should have content'
    Assert-True ($replacement[0].content[0].type -eq 'input_text') 'replacement_history content should use input_text'
    Assert-True ([string]$replacement[0].content[0].text -match 'raw rollout remains source of truth') 'handoff text should preserve source-of-truth warning'

    $manifest = Get-Content -LiteralPath (Join-Path $runDirs[0].FullName 'run-manifest.json') -Raw | ConvertFrom-Json
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$manifest.source.sha256)) 'Run manifest should record source SHA'
    Assert-True ($manifest.outputs.compressed_rollout -eq 'compressed-rollout.jsonl') 'Run manifest should point to compressed rollout'
    Assert-True ($manifest.provider -eq 'codex') 'Run manifest should record codex provider'
    Assert-True ($manifest.codex_model -eq 'gpt-5.3-codex-spark') 'Run manifest should record Codex model'
    Assert-True ($manifest.codex_reasoning_effort -eq 'low') 'Run manifest should record Codex reasoning effort'
    Assert-True ($manifest.retry_failed_chunks -eq $true) 'Run manifest should record retry_failed_chunks'

    $oldMiniMax = [Environment]::GetEnvironmentVariable('MINIMAX_API_KEY')
    $oldMiniMaxProcess = $env:MINIMAX_API_KEY
    $missingKeyFailed = $false
    try {
        [Environment]::SetEnvironmentVariable('MINIMAX_API_KEY', '', 'Process')
        $env:MINIMAX_API_KEY = ''
        & (Join-Path $RepoRoot 'Compress-CodexSession.ps1') `
            -SourcePath $source `
            -OutRoot (Join-Path $root 'missing-key-runs') `
            -Provider minimax `
            -EnvPath (Join-Path $root 'missing.env') | Out-Null
    }
    catch {
        $missingKeyFailed = ([string]$_.Exception.Message -match 'MINIMAX_API_KEY is required')
    }
    finally {
        [Environment]::SetEnvironmentVariable('MINIMAX_API_KEY', $oldMiniMax, 'Process')
        $env:MINIMAX_API_KEY = $oldMiniMaxProcess
    }
    Assert-True $missingKeyFailed 'Missing provider key should fail with a clear MINIMAX_API_KEY message'

    'public-entrypoint.tests.ps1 PASS'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
