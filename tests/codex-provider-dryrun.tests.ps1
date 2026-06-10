$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Read-JsonFile {
    param([string]$Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$testRoot = Join-Path $env:TEMP ('codex-provider-dryrun-' + [guid]::NewGuid().ToString('N'))
$sourcePath = Join-Path $testRoot 'synthetic.jsonl'
$sessionId = 'codex-provider-dryrun'
$bundle = Join-Path $testRoot 'session\compressed'

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    @(
        '{"timestamp":"2026-06-09T00:00:00.000Z","type":"session_meta","payload":{"id":"codex-provider-dryrun","cwd":"C:\\demo","source":"codex","originator":"test"}}',
        '{"timestamp":"2026-06-09T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Compress this session with Codex-native summarization.","images":[]}}',
        '{"timestamp":"2026-06-09T00:00:02.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Decision: Codex provider should create durable handoff context without MiniMax keys.","phase":"commentary"}}',
        '{"timestamp":"2026-06-09T00:00:03.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Final state: tests should verify retry failed chunks and keep live rollout untouched.","phase":"final"}}'
    ) | Set-Content -LiteralPath $sourcePath -Encoding UTF8

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode Chunk `
        -Role session `
        -SessionId $sessionId `
        -Fingerprint compressed `
        -SourcePath $sourcePath `
        -OutRoot $testRoot `
        -NoLaunch | Out-Null

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode Digest `
        -Role session `
        -SessionId $sessionId `
        -Fingerprint compressed `
        -OutRoot $testRoot `
        -NoLaunch | Out-Null

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode FinalState `
        -Role session `
        -SessionId $sessionId `
        -Fingerprint compressed `
        -OutRoot $testRoot `
        -NoLaunch | Out-Null

    $manifestPath = Join-Path $bundle 'semantic_chunk_manifest.json'
    $manifest = Read-JsonFile $manifestPath
    $chunkOne = $manifest.chunks[0]
    Copy-Item -LiteralPath (Join-Path $bundle ([string]$chunkOne.path)) -Destination (Join-Path $bundle 'semantic_chunks\chunk_002.jsonl') -Force
    $chunkTwo = [ordered]@{
        index = 2
        name = 'chunk_002.jsonl'
        path = 'semantic_chunks/chunk_002.jsonl'
        event_count = [int]$chunkOne.event_count
        char_count = if ($chunkOne.PSObject.Properties.Name -contains 'char_count') { [int]$chunkOne.char_count } else { 100 }
        first_source_line = [int]$chunkOne.first_source_line
        last_source_line = [int]$chunkOne.last_source_line
        first_timestamp = [string]$chunkOne.first_timestamp
        last_timestamp = [string]$chunkOne.last_timestamp
    }
    $manifest.chunk_count = 2
    $manifest.chunks = @($chunkOne, $chunkTwo)
    & (Join-Path $RepoRoot 'src\Write-Utf8NoBom.ps1') -Path $manifestPath -InputObject $manifest -Depth 20 | Out-Null

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode SummarizeCodex `
        -Role session `
        -SessionId $sessionId `
        -Fingerprint compressed `
        -OutRoot $testRoot `
        -Model gpt-5.3-codex-spark `
        -ReasoningEffort low `
        -DryRun `
        -NoLaunch | Out-Null

    $summaryOnePath = Join-Path $bundle 'chunk_summaries\codex\chunk_001.summary.json'
    $summaryTwoPath = Join-Path $bundle 'chunk_summaries\codex\chunk_002.summary.json'
    Assert-True (Test-Path -LiteralPath $summaryOnePath) 'Codex dry-run chunk 1 summary should be written'
    Assert-True (Test-Path -LiteralPath $summaryTwoPath) 'Codex dry-run chunk 2 summary should be written'
    $summaryOne = Read-JsonFile $summaryOnePath
    Assert-True ($summaryOne.provider -eq 'codex') 'Codex summary should identify provider'
    Assert-True ($summaryOne.reasoning_effort -eq 'low') 'Codex summary should record reasoning effort'
    Assert-True ([int]$summaryOne.chunk_index -eq 1) 'Codex summary should record chunk index'

    $firstWrite = (Get-Item -LiteralPath $summaryOnePath).LastWriteTimeUtc
    Start-Sleep -Seconds 1
    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode SummarizeCodex `
        -Role session `
        -SessionId $sessionId `
        -Fingerprint compressed `
        -OutRoot $testRoot `
        -DryRun `
        -NoLaunch | Out-Null
    $secondWrite = (Get-Item -LiteralPath $summaryOnePath).LastWriteTimeUtc
    Assert-True ($firstWrite -eq $secondWrite) 'Valid existing summary should be skipped without Force'

    'not-json' | Set-Content -LiteralPath $summaryTwoPath -Encoding UTF8
    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode SummarizeCodex `
        -Role session `
        -SessionId $sessionId `
        -Fingerprint compressed `
        -OutRoot $testRoot `
        -DryRun `
        -RetryFailedChunks `
        -NoLaunch | Out-Null
    $summaryTwo = Read-JsonFile $summaryTwoPath
    Assert-True ($summaryTwo.provider -eq 'codex') 'RetryFailedChunks should rewrite invalid summary'
    Assert-True ([int]$summaryTwo.chunk_index -eq 2) 'RetryFailedChunks should preserve failed chunk index'

    $firstWriteAfterRetry = (Get-Item -LiteralPath $summaryOnePath).LastWriteTimeUtc
    Assert-True ($firstWriteAfterRetry -eq $secondWrite) 'RetryFailedChunks should not rerun valid chunk 1'

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode MergeCodex `
        -Role session `
        -SessionId $sessionId `
        -Fingerprint compressed `
        -OutRoot $testRoot `
        -Model gpt-5.3-codex-spark `
        -ReasoningEffort low `
        -DryRun `
        -NoLaunch | Out-Null

    $contextPath = Join-Path $bundle 'context.json'
    Assert-True (Test-Path -LiteralPath $contextPath) 'Codex merge should write context.json'
    $context = Read-JsonFile $contextPath
    Assert-True ($context.provider_summary.provider -eq 'codex') 'Codex context should record provider'
    Assert-True ($context.handoff_recommendation.launch_allowed -eq $false) 'Codex context must keep launch disabled'

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode ValidateCodex `
        -Role session `
        -SessionId $sessionId `
        -Fingerprint compressed `
        -OutRoot $testRoot `
        -Model gpt-5.3-codex-spark `
        -ReasoningEffort low `
        -DryRun `
        -NoLaunch | Out-Null

    $quality = Read-JsonFile (Join-Path $bundle 'compression_context_quality.json')
    Assert-True ($quality.passed -eq $true) 'Codex validation should pass dry-run artifacts'
    $qualityKeys = @($quality.PSObject.Properties.Name)
    Assert-True (($qualityKeys -join ',') -eq 'passed,checked_at,errors,warnings') 'Codex quality report should match strict schema keys'

    $oldPath = $env:PATH
    $missingFailed = $false
    try {
        $emptyPath = Join-Path $testRoot 'empty-path'
        New-Item -ItemType Directory -Path $emptyPath -Force | Out-Null
        $env:PATH = $emptyPath
        & (Join-Path $RepoRoot 'src\Invoke-CodexExecJson.ps1') `
            -Prompt 'Return JSON.' `
            -SchemaPath (Join-Path $RepoRoot 'schemas\context-quality.schema.json') `
            -OutputPath (Join-Path $testRoot 'missing-codex.json') `
            -DryRun:$false | Out-Null
    }
    catch {
        $missingFailed = ([string]$_.Exception.Message -match 'Codex CLI was not found on PATH')
    }
    finally {
        $env:PATH = $oldPath
    }
    Assert-True $missingFailed 'Missing Codex CLI should fail with clear message'

    $runText = ''
    foreach ($run in Get-ChildItem -LiteralPath (Join-Path $bundle 'provider_runs\codex') -File -Filter '*.json') {
        $runText += Get-Content -LiteralPath $run.FullName -Raw
    }
    Assert-True ($runText -notmatch 'dummy-minimax-secret') 'Codex provider runs must not contain MiniMax secret'
    Assert-True ($runText -notmatch 'dummy-mimo-secret') 'Codex provider runs must not contain MiMo secret'
    Assert-True ($runText -notmatch 'Authorization') 'Codex provider runs must not contain authorization headers'

    Write-Host 'PASS codex provider dry-run test'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
