param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$OutRoot = '',

    [ValidateSet('codex', 'minimax', 'mimo')]
    [string]$Provider = 'codex',

    [string]$CodexModel = 'gpt-5.3-codex-spark',

    [ValidateSet('minimal', 'low', 'medium')]
    [string]$CodexReasoningEffort = 'low',

    [string]$EnvPath = '',

    [int]$MaxTokens = 5000,
    [int]$ThrottleLimit = 1,
    [switch]$UseDigest,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$RetryFailedChunks
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    $OutRoot = Join-Path $ScriptRoot 'runs'
}
if ([string]::IsNullOrWhiteSpace($EnvPath)) {
    $EnvPath = Join-Path $ScriptRoot '.env'
}

if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Source rollout not found: $SourcePath"
}

$resolvedSource = (Resolve-Path -LiteralPath $SourcePath).Path
$sourceHashBefore = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash.ToLowerInvariant()
$sourceInfo = Get-Item -LiteralPath $resolvedSource

function Get-SourceSessionId {
    param([string]$Path)
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ([string]$record.type -eq 'session_meta' -and $record.payload.id) {
            return [string]$record.payload.id
        }
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

$sessionId = Get-SourceSessionId -Path $resolvedSource
$safeSession = ($sessionId -replace '[^A-Za-z0-9_.-]', '_')
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss-fffZ')
$runId = "$stamp-$safeSession"
$runDir = Join-Path $OutRoot $runId
$handoffOutRoot = Join-Path $runDir 'session-handoff'
$role = 'session'
$fingerprint = 'compressed'
$bundlePath = Join-Path (Join-Path $handoffOutRoot $role) $fingerprint

New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$envConfig = & (Join-Path $ScriptRoot 'src\Read-HandoffEnv.ps1') -EnvPath $EnvPath
if (-not $DryRun) {
    if ($Provider -eq 'minimax' -and -not $envConfig.providers.minimax.api_key_present) {
        throw 'MINIMAX_API_KEY is required for provider minimax. Set it in process env or .env, or rerun with -DryRun.'
    }
    if ($Provider -eq 'mimo' -and -not $envConfig.providers.mimo.api_key_present) {
        throw 'MIMO_API_KEY or mimo_api_key is required for provider mimo. Set it in process env or .env, or rerun with -DryRun.'
    }
}

$common = @{
    Role = $role
    SessionId = $sessionId
    Fingerprint = $fingerprint
    OutRoot = $handoffOutRoot
    NoLaunch = $true
}

& (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common -Mode Chunk -SourcePath $resolvedSource | Out-Null
& (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common -Mode Digest | Out-Null
& (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common -Mode FinalState | Out-Null

if ($Provider -eq 'codex') {
    & (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common `
        -Mode SummarizeCodex `
        -Model $CodexModel `
        -ReasoningEffort $CodexReasoningEffort `
        -MaxTokens $MaxTokens `
        -ThrottleLimit $ThrottleLimit `
        -UseDigest:$UseDigest `
        -DryRun:$DryRun `
        -Force:$Force `
        -RetryFailedChunks:$RetryFailedChunks | Out-Null
} elseif ($Provider -eq 'minimax') {
    & (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common `
        -Mode SummarizeMiniMax `
        -EnvPath $EnvPath `
        -MaxTokens $MaxTokens `
        -ThrottleLimit $ThrottleLimit `
        -UseDigest:$UseDigest `
        -DryRun:$DryRun `
        -Force:$Force | Out-Null
} else {
    & (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common `
        -Mode SummarizeMiMo `
        -EnvPath $EnvPath `
        -MaxTokens $MaxTokens `
        -ThrottleLimit $ThrottleLimit `
        -UseDigest:$UseDigest `
        -DryRun:$DryRun `
        -Force:$Force | Out-Null
}

if ($Provider -eq 'codex') {
    & (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common `
        -Mode MergeCodex `
        -Model $CodexModel `
        -ReasoningEffort $CodexReasoningEffort `
        -DryRun:$DryRun `
        -Force:$Force | Out-Null
    & (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common `
        -Mode ValidateCodex `
        -Model $CodexModel `
        -ReasoningEffort $CodexReasoningEffort `
        -DryRun:$DryRun | Out-Null
} else {
    & (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common -Mode MergeHierarchical -EnvPath $EnvPath -DryRun:$DryRun -Force:$Force | Out-Null
    & (Join-Path $ScriptRoot 'Invoke-Handoff.ps1') @common -Mode ValidateContextQuality | Out-Null
}

$compressedPath = Join-Path $runDir 'compressed-rollout.jsonl'
$rolloutResult = & (Join-Path $ScriptRoot 'src\New-CompressedRollout.ps1') `
    -SourcePath $resolvedSource `
    -BundlePath $bundlePath `
    -OutputPath $compressedPath `
    -RunId $runId

$validation = & (Join-Path $ScriptRoot 'src\Test-CompressedRollout.ps1') -Path $compressedPath

$sourceHashAfter = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceHashAfter -ne $sourceHashBefore) {
    throw 'Source rollout SHA changed during compression. Aborting because raw source must remain canonical.'
}

$manifest = [ordered]@{
    artifact_type = 'l2_compression_run_manifest'
    run_id = $runId
    provider = $Provider
    codex_model = if ($Provider -eq 'codex') { $CodexModel } else { $null }
    codex_reasoning_effort = if ($Provider -eq 'codex') { $CodexReasoningEffort } else { $null }
    retry_failed_chunks = [bool]$RetryFailedChunks
    dry_run = [bool]$DryRun
    source = [ordered]@{
        path = $resolvedSource
        session_id = $sessionId
        sha256 = $sourceHashBefore
        size_bytes = [int64]$sourceInfo.Length
    }
    outputs = [ordered]@{
        run_dir = $runDir
        bundle = 'session-handoff/session/compressed'
        context = 'session-handoff/session/compressed/context.json'
        compressed_rollout = 'compressed-rollout.jsonl'
    }
    validation = [ordered]@{
        compressed_rollout_valid = [bool]$validation.valid
        source_sha_restored = ($sourceHashAfter -eq $sourceHashBefore)
    }
    created_at = (Get-Date).ToUniversalTime().ToString('o')
}
& (Join-Path $ScriptRoot 'src\Write-Utf8NoBom.ps1') -Path (Join-Path $runDir 'run-manifest.json') -InputObject $manifest -Depth 30 | Out-Null

[pscustomobject]@{
    run_id = $runId
    run_dir = $runDir
    session_id = $sessionId
    provider = $Provider
    codex_model = if ($Provider -eq 'codex') { $CodexModel } else { $null }
    codex_reasoning_effort = if ($Provider -eq 'codex') { $CodexReasoningEffort } else { $null }
    retry_failed_chunks = [bool]$RetryFailedChunks
    dry_run = [bool]$DryRun
    source_sha256 = $sourceHashBefore
    compressed_rollout = $compressedPath
    bundle_path = $bundlePath
    validation = $validation
    handoff_text_chars = $rolloutResult.handoff_text_chars
}
