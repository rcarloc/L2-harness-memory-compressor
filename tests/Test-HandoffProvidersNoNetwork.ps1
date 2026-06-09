param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Read-JsonFile {
    param([string]$Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$testRoot = Join-Path $env:TEMP ('handoff-provider-test-' + [guid]::NewGuid().ToString('N'))
$sourcePath = Join-Path $testRoot 'synthetic.jsonl'
$envPath = Join-Path $testRoot '.env'
$sessionId = 'provider-no-network-test'
$bundle = Join-Path $testRoot 'PM\DRY'

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    @(
        'MINIMAX_API_KEY=dummy-minimax-secret',
        'MINIMAX_MODEL=MiniMax-M3',
        'mimo_api_key=dummy-mimo-secret',
        'Z_GLM_API_KEY=dummy-glm-secret'
    ) | Set-Content -LiteralPath $envPath -Encoding UTF8

    @(
        '{"timestamp":"2026-06-05T20:00:00.000Z","type":"session_meta","payload":{"id":"provider-no-network-test","cwd":"C:\\Users\\rcarl","source":"codex","originator":"test"}}',
        '{"timestamp":"2026-06-05T20:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"PM checkpoint: confirm MiniMax M3 summarization and GLM validation policy gate before handoff.","images":[],"local_images":[],"text_elements":[]}}',
        '{"timestamp":"2026-06-05T20:00:02.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Decision: keep launch_allowed=false and treat this as durable state only. Risk: invented next actions must be blocked by validation.","phase":"commentary"}}'
    ) | Set-Content -LiteralPath $sourcePath -Encoding UTF8

    $config = & (Join-Path $RepoRoot 'src\Read-HandoffEnv.ps1') -EnvPath $envPath
    Assert-True ($config.providers.minimax.api_key_present -eq $true) 'MiniMax dummy key should be detected'
    Assert-True ($config.providers.mimo.api_key_present -eq $true) 'MiMo dummy key should be detected'
    Assert-True ($config.providers.mimo.model -eq 'mimo-v2.5-pro') 'MiMo dummy config should default to mimo-v2.5-pro'
    Assert-True ($config.providers.glm.api_key_present -eq $true) 'GLM dummy key should be detected'
    Assert-True (-not ($config.PSObject.Properties.Name -contains 'secrets')) 'Default env loader output should be masked'

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode CheapTest `
        -Role PM `
        -SessionId $sessionId `
        -Fingerprint DRY `
        -SourcePath $sourcePath `
        -OutRoot $testRoot `
        -NoLaunch | Out-Null

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode SummarizeMiniMax `
        -Role PM `
        -SessionId $sessionId `
        -Fingerprint DRY `
        -OutRoot $testRoot `
        -EnvPath $envPath `
        -ChunkLimit 1 `
        -DryRun `
        -NoLaunch | Out-Null

    $summaryPath = Join-Path $bundle 'chunk_summaries\minimax_m3\chunk_001.summary.json'
    Assert-True (Test-Path -LiteralPath $summaryPath) 'MiniMax dry-run chunk summary should be written'
    $summary = Read-JsonFile $summaryPath
    Assert-True ($summary.mode -eq 'dry_run') 'MiniMax chunk summary should mark dry_run'
    Assert-True ($summary.provider -eq 'minimax') 'MiniMax chunk summary should identify provider'
    $modelConfig = Read-JsonFile (Join-Path $bundle 'semantic_model_config.json')
    Assert-True ($modelConfig.provider -eq 'minimax') 'Provider mode should identify MiniMax in semantic_model_config.json'
    Assert-True ($modelConfig.model -eq 'MiniMax-M3') 'Provider mode should identify MiniMax-M3 in semantic_model_config.json'
    Assert-True ($modelConfig.model_profile -eq 'minimax-m3') 'Provider mode should identify minimax-m3 profile'

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode SummarizeMiMo `
        -Role PM `
        -SessionId $sessionId `
        -Fingerprint DRY `
        -OutRoot $testRoot `
        -EnvPath $envPath `
        -ChunkIndex 1 `
        -DryRun `
        -Force `
        -NoLaunch | Out-Null

    $mimoSummaryPath = Join-Path $bundle 'chunk_summaries\mimo_v25_pro\chunk_001.summary.json'
    Assert-True (Test-Path -LiteralPath $mimoSummaryPath) 'MiMo dry-run chunk summary should be written'
    $mimoSummary = Read-JsonFile $mimoSummaryPath
    Assert-True ($mimoSummary.mode -eq 'dry_run') 'MiMo chunk summary should mark dry_run'
    Assert-True ($mimoSummary.provider -eq 'mimo') 'MiMo chunk summary should identify provider'
    Assert-True ($mimoSummary.model -eq 'mimo-v2.5-pro') 'MiMo chunk summary should identify mimo-v2.5-pro'
    $mimoModelConfig = Read-JsonFile (Join-Path $bundle 'semantic_model_config.json')
    Assert-True ($mimoModelConfig.provider -eq 'mimo') 'Provider mode should identify MiMo in semantic_model_config.json'
    Assert-True ($mimoModelConfig.model -eq 'mimo-v2.5-pro') 'Provider mode should identify MiMo v2.5 Pro in semantic_model_config.json'

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode MergeHierarchical `
        -Role PM `
        -SessionId $sessionId `
        -Fingerprint DRY `
        -OutRoot $testRoot `
        -EnvPath $envPath `
        -DryRun `
        -NoLaunch | Out-Null

    foreach ($file in @('context.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $bundle $file)) "Hierarchical dry-run merge should write $file"
    }

    $context = Read-JsonFile (Join-Path $bundle 'context.json')
    Assert-True ($context.handoff_recommendation.launch_allowed -eq $false) 'MiniMax merge must keep launch disabled'

    & (Join-Path $RepoRoot 'Invoke-Handoff.ps1') `
        -Mode ValidateGLM `
        -Role PM `
        -SessionId $sessionId `
        -Fingerprint DRY `
        -OutRoot $testRoot `
        -EnvPath $envPath `
        -DryRun `
        -NoLaunch | Out-Null

    $glmValidation = Read-JsonFile (Join-Path $bundle 'semantic_validation.glm.json')
    Assert-True ($glmValidation.skipped -eq $true) 'GLM validation should be skipped without policy-safe opt-in'
    Assert-True ($glmValidation.launch_allowed -eq $false) 'GLM validation must keep launch disabled'

    $runFile = Get-ChildItem -LiteralPath (Join-Path $bundle 'provider_runs\minimax_m3') -Filter '*chunk_001.json' | Select-Object -First 1
    Assert-True ($null -ne $runFile) 'MiniMax provider run artifact should exist'
    $artifactText = Get-Content -LiteralPath $runFile.FullName -Raw
    Assert-True ($artifactText -notmatch 'dummy-minimax-secret') 'Provider run artifact must not contain MiniMax secret'
    Assert-True ($artifactText -notmatch 'dummy-mimo-secret') 'Provider run artifact must not contain MiMo secret'
    Assert-True ($artifactText -notmatch 'dummy-glm-secret') 'Provider run artifact must not contain GLM secret'

    Write-Host 'PASS handoff provider no-network test'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
