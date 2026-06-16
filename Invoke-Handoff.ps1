param(
    [ValidateSet('Checkpoint', 'Chunk', 'Digest', 'FinalState', 'CheapTest', 'Summarize', 'SummarizeMiniMax', 'SummarizeMiMo', 'SummarizeCodex', 'MergeMiniMax', 'MergeHierarchical', 'MergeCodex', 'ValidateGLM', 'ValidateMiniMax', 'ValidateContextQuality', 'ValidateCodex', 'Validate', 'PrepareLaunch', 'RecordLaunch', 'Handoff')]
    [string]$Mode = 'Checkpoint',

    [Parameter(Mandatory = $true)]
    [string]$Role,

    [Parameter(Mandatory = $true)]
    [string]$SessionId,

    [Parameter(Mandatory = $true)]
    [string]$Fingerprint,

    [string]$SourcePath,
    [string]$OutRoot = '',
    [string]$ReplacementSessionName,
    [string]$Model = 'MiniMax-M3',
    [string]$ReasoningEffort = 'provider_default',
    [string]$EnvPath = '',
    [int]$ChunkLimit = 0,
    [int[]]$ChunkIndex,
    [int]$StartChunk = 0,
    [int]$EndChunk = 0,
    [int]$MaxTokens = 5000,
    [int]$ThrottleLimit = 1,
    [string]$RemoteHost = '',
    [switch]$NoLaunch,
    [switch]$Wait,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$UseDigest,
    [switch]$RetryFailedChunks,
    [switch]$ApproveLaunch,
    [string]$ReplacementThreadId,
    [string]$ReplacementThreadName,
    [string]$LauncherSurface = 'codex_app_agent',
    [string]$LauncherTool = 'create_thread'
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    $OutRoot = Join-Path $ScriptRoot 'runs'
}
if ([string]::IsNullOrWhiteSpace($EnvPath)) {
    $EnvPath = Join-Path $ScriptRoot '.env'
}

$isCheapTest = ($Model -eq 'cheap-test' -or $Model -eq 'model-free' -or $Model -eq 'none')

if (-not $ReplacementSessionName) {
    $dateStamp = Get-Date -Format 'dd-MM-yy'
    $ReplacementSessionName = "$Role #$dateStamp - $Fingerprint"
}

$bundlePath = Join-Path $OutRoot (Join-Path $Role $Fingerprint)
New-Item -ItemType Directory -Path $bundlePath -Force | Out-Null

$isModelFreeSetup = ($Mode -eq 'CheapTest' -or $Mode -eq 'Chunk')
$isCodexMode = ($Mode -like '*Codex*')
$codexModel = if ($isCodexMode -and $Model -eq 'MiniMax-M3') { 'gpt-5.3-codex-spark' } else { $Model }
$codexReasoningEffort = if ($ReasoningEffort -in @('minimal', 'low', 'medium')) { $ReasoningEffort } else { 'low' }
$effectiveModel = if ($isModelFreeSetup) { 'none' } elseif ($isCodexMode) { $codexModel } else { $Model }
$effectiveEffort = if ($isModelFreeSetup) { 'none' } elseif ($isCodexMode) { $codexReasoningEffort } else { $ReasoningEffort }
$effectiveModelProfile = if ($Mode -eq 'Chunk') { 'chunking' } elseif ($Mode -eq 'CheapTest') { 'cheap-test' } elseif ($Mode -like '*MiniMax*') { 'minimax-m3' } elseif ($Mode -like '*MiMo*') { 'mimo-v2.5-pro' } elseif ($Mode -like '*Codex*') { 'codex' } else { 'provider-default' }

$modelConfig = [ordered]@{
    model = $effectiveModel
    reasoning_effort = $effectiveEffort
    model_profile = $effectiveModelProfile
    created_at = (Get-Date).ToUniversalTime().ToString('o')
}
$modelConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $bundlePath 'semantic_model_config.json') -Encoding UTF8

if ($Mode -in @('Checkpoint', 'Chunk', 'CheapTest', 'Summarize', 'Handoff') -and -not $SourcePath) {
    throw 'SourcePath is required in the public package. Live transcript discovery is intentionally not enabled by default.'
}

if ($Mode -in @('Checkpoint', 'Chunk', 'CheapTest', 'Summarize', 'Handoff')) {
    & (Join-Path $ScriptRoot 'src\New-Checkpoint.ps1') `
        -SourcePath $SourcePath `
        -BundlePath $bundlePath `
        -SessionId $SessionId `
        -Role $Role `
        -Fingerprint $Fingerprint `
        -ReplacementSessionName $ReplacementSessionName `
        -Model $effectiveModel `
        -ReasoningEffort $effectiveEffort `
        -ModelProfile $effectiveModelProfile | Out-Null
}

if ($Mode -eq 'Chunk') {
    & (Join-Path $ScriptRoot 'src\Invoke-CheapSemanticSummary.ps1') `
        -BundlePath $bundlePath `
        -SessionId $SessionId `
        -Role $Role `
        -Fingerprint $Fingerprint `
        -ReplacementSessionName $ReplacementSessionName `
        -ArtifactMode 'chunking' `
        -SemanticMode 'model_free_chunking' `
        -ReportTitle 'Handoff Chunking Report' `
        -ReportStatus 'MODEL_FREE_CHUNKING' | Out-Null
}

if ($Mode -eq 'Digest') {
    & (Join-Path $ScriptRoot 'src\New-ChunkDigest.ps1') `
        -BundlePath $bundlePath | Out-Null
}

if ($Mode -eq 'FinalState') {
    & (Join-Path $ScriptRoot 'src\New-FinalStateDigest.ps1') `
        -BundlePath $bundlePath | Out-Null
}

if ($Mode -eq 'CheapTest') {
    & (Join-Path $ScriptRoot 'src\Invoke-CheapSemanticSummary.ps1') `
        -BundlePath $bundlePath `
        -SessionId $SessionId `
        -Role $Role `
        -Fingerprint $Fingerprint `
        -ReplacementSessionName $ReplacementSessionName `
        -ArtifactMode 'cheap-test' `
        -SemanticMode 'model_free_cheap_test' `
        -ReportTitle 'Handoff Cheap-Test Report' `
        -ReportStatus 'MODEL_FREE_CHEAP_TEST' | Out-Null

    & (Join-Path $ScriptRoot 'src\Test-CheapTestValidation.ps1') `
        -BundlePath $bundlePath | Out-Null
}

if ($Mode -eq 'SummarizeMiniMax') {
    & (Join-Path $ScriptRoot 'src\Invoke-MiniMaxChunkSummary.ps1') `
        -BundlePath $bundlePath `
        -EnvPath $EnvPath `
        -ChunkLimit $ChunkLimit `
        -ChunkIndex $ChunkIndex `
        -MaxTokens $MaxTokens `
        -ThrottleLimit $ThrottleLimit `
        -UseDigest:$UseDigest `
        -DryRun:$DryRun `
        -Force:$Force | Out-Null
}

if ($Mode -eq 'SummarizeMiMo') {
    & (Join-Path $ScriptRoot 'src\Invoke-MiMoChunkSummary.ps1') `
        -BundlePath $bundlePath `
        -EnvPath $EnvPath `
        -ChunkLimit $ChunkLimit `
        -ChunkIndex $ChunkIndex `
        -StartChunk $StartChunk `
        -EndChunk $EndChunk `
        -MaxTokens $MaxTokens `
        -ThrottleLimit $ThrottleLimit `
        -UseDigest:$UseDigest `
        -DryRun:$DryRun `
        -Force:$Force | Out-Null
}

if ($Mode -eq 'SummarizeCodex') {
    & (Join-Path $ScriptRoot 'src\Invoke-CodexChunkSummary.ps1') `
        -BundlePath $bundlePath `
        -Model $codexModel `
        -ReasoningEffort $codexReasoningEffort `
        -ChunkLimit $ChunkLimit `
        -ChunkIndex $ChunkIndex `
        -ThrottleLimit $ThrottleLimit `
        -UseDigest:$UseDigest `
        -DryRun:$DryRun `
        -Force:$Force `
        -RetryFailedChunks:$RetryFailedChunks | Out-Null
}

if ($Mode -eq 'MergeMiniMax') {
    & (Join-Path $ScriptRoot 'src\Merge-MiniMaxSummaries.ps1') `
        -BundlePath $bundlePath `
        -EnvPath $EnvPath `
        -DryRun:$DryRun `
        -Force:$Force | Out-Null
}

if ($Mode -eq 'MergeHierarchical') {
    & (Join-Path $ScriptRoot 'src\Merge-ContextHierarchical.ps1') `
        -BundlePath $bundlePath `
        -EnvPath $EnvPath `
        -DryRun:$DryRun `
        -Force:$Force | Out-Null
}

if ($Mode -eq 'MergeCodex') {
    & (Join-Path $ScriptRoot 'src\Merge-CodexSummaries.ps1') `
        -BundlePath $bundlePath `
        -Model $codexModel `
        -ReasoningEffort $codexReasoningEffort `
        -DryRun:$DryRun `
        -Force:$Force | Out-Null
}

if ($Mode -eq 'ValidateContextQuality') {
    & (Join-Path $ScriptRoot 'src\Test-CompressionContextQuality.ps1') `
        -BundlePath $bundlePath | Out-Null
}

if ($Mode -eq 'ValidateCodex') {
    & (Join-Path $ScriptRoot 'src\Invoke-CodexContextValidation.ps1') `
        -BundlePath $bundlePath `
        -Model $codexModel `
        -ReasoningEffort $codexReasoningEffort `
        -DryRun:$DryRun | Out-Null
}

if ($Mode -eq 'ValidateGLM') {
    & (Join-Path $ScriptRoot 'src\Invoke-GlmValidation.ps1') `
        -BundlePath $bundlePath `
        -EnvPath $EnvPath `
        -DryRun:$DryRun | Out-Null
}

if ($Mode -eq 'ValidateMiniMax') {
    & (Join-Path $ScriptRoot 'src\Invoke-MiniMaxValidation.ps1') `
        -BundlePath $bundlePath `
        -EnvPath $EnvPath `
        -DryRun:$DryRun | Out-Null
}

if ($Mode -eq 'PrepareLaunch') {
    if (-not $NoLaunch) {
        throw 'PrepareLaunch is metadata-only in V1 and requires -NoLaunch.'
    }

    & (Join-Path $ScriptRoot 'src\Invoke-Handoff.PrepareLaunch.ps1') `
        -Role $Role `
        -SessionId $SessionId `
        -Fingerprint $Fingerprint `
        -OutRoot $OutRoot `
        -ApproveLaunch:$ApproveLaunch | Out-Null
}

if ($Mode -eq 'RecordLaunch') {
    & (Join-Path $ScriptRoot 'src\Invoke-Handoff.RecordLaunch.ps1') `
        -Role $Role `
        -SessionId $SessionId `
        -Fingerprint $Fingerprint `
        -OutRoot $OutRoot `
        -ReplacementThreadId $ReplacementThreadId `
        -ReplacementThreadName $ReplacementThreadName `
        -LauncherSurface $LauncherSurface `
        -LauncherTool $LauncherTool | Out-Null
}

if ($Mode -in @('Summarize', 'Handoff')) {
    if ($isCheapTest) {
        & (Join-Path $ScriptRoot 'src\Invoke-CheapSemanticSummary.ps1') `
            -BundlePath $bundlePath `
            -SessionId $SessionId `
            -Role $Role `
            -Fingerprint $Fingerprint `
            -ReplacementSessionName $ReplacementSessionName | Out-Null
    }
    else {
        throw 'Legacy remote Summarize/Handoff mode is not packaged for public use. Use SummarizeMiniMax, SummarizeMiMo, or Compress-CodexSession.ps1.'
    }
}

if ($Mode -in @('Validate', 'Handoff')) {
    if (Test-Path -LiteralPath (Join-Path $bundlePath 'context.model.json')) {
        & (Join-Path $ScriptRoot 'src\Normalize-Context.ps1') `
            -BundlePath $bundlePath `
            -SessionId $SessionId `
            -Role $Role `
            -Fingerprint $Fingerprint `
            -ReplacementSessionName $ReplacementSessionName | Out-Null
    }

    & (Join-Path $ScriptRoot 'src\Test-HandoffValidation.ps1') `
        -BundlePath $bundlePath `
        -RequireLaunchAllowed:($Mode -eq 'Handoff' -and -not $NoLaunch) | Out-Null
}

if ($Mode -eq 'Handoff' -and -not $NoLaunch) {
    throw 'Thread launch is intentionally not implemented in V1. Run PrepareLaunch or run Handoff with -NoLaunch until the Multi-Agent V2 launcher is exposed.'
}

[pscustomobject]@{
    mode = $Mode
    role = $Role
    session_id = $SessionId
    fingerprint = $Fingerprint
    bundle_path = $bundlePath
    model = $effectiveModel
    reasoning_effort = $effectiveEffort
    dry_run = [bool]$DryRun
    launch_attempted = $false
}
