$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:TEMP ('handoff-digest-test-' + [guid]::NewGuid().ToString('n'))
$Bundle = Join-Path $Root 'bundle'
$ChunkDir = Join-Path $Bundle 'semantic_chunks'
New-Item -ItemType Directory -Path $ChunkDir -Force | Out-Null

$chunk = @(
    @{ source_line = 10; timestamp = '2026-01-01T00:00:00Z'; type = 'user_message'; role = 'user'; text = 'Please implement the regression test first.' },
    @{ source_line = 11; timestamp = '2026-01-01T00:01:00Z'; type = 'agent_message'; role = 'assistant'; text = 'I am reading src/example.ts and tests/example.test.ts.' },
    @{ source_line = 12; timestamp = '2026-01-01T00:02:00Z'; type = 'task_complete'; role = 'system'; text = 'Tests passed: 3/3 in tests/example.test.ts.' },
    @{ source_line = 13; timestamp = '2026-01-01T00:03:00Z'; type = 'agent_message'; role = 'assistant'; text = 'Next action is to commit the focused fix.' }
)

$chunk | ForEach-Object { $_ | ConvertTo-Json -Compress } |
    Set-Content -LiteralPath (Join-Path $ChunkDir 'chunk_001.jsonl') -Encoding UTF8

@{
    chunks = @(@{
        index = 1
        path = 'semantic_chunks/chunk_001.jsonl'
        first_source_line = 10
        last_source_line = 13
    })
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Bundle 'semantic_chunk_manifest.json') -Encoding UTF8

& (Join-Path $PSScriptRoot '..\src\New-ChunkDigest.ps1') -BundlePath $Bundle

$digestJsonPath = Join-Path $Bundle 'chunk_digests\chunk_001.digest.json'
$digestMdPath = Join-Path $Bundle 'chunk_digests\chunk_001.digest.md'
if (-not (Test-Path -LiteralPath $digestJsonPath)) { throw 'Missing digest JSON.' }
if (-not (Test-Path -LiteralPath $digestMdPath)) { throw 'Missing digest markdown.' }

$digest = Get-Content -LiteralPath $digestJsonPath -Raw | ConvertFrom-Json
if ($digest.chunk_index -ne 1) { throw 'Wrong chunk index.' }
if ($digest.sections.user_intent.Count -lt 1) { throw 'Missing user_intent section.' }
if ($digest.sections.commands_or_results.Count -lt 1) { throw 'Missing commands_or_results section.' }
if ($digest.sections.next_steps.Count -lt 1) { throw 'Missing next_steps section.' }

Remove-Item -LiteralPath $Root -Recurse -Force
'chunk-digest.tests.ps1 PASS'
