param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    [Parameter(Mandatory = $true)]
    [string]$SchemaPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$Model = 'gpt-5.3-codex-spark',

    [ValidateSet('minimal', 'low', 'medium')]
    [string]$ReasoningEffort = 'low',

    [string]$WorkingDirectory = (Get-Location).Path,

    [switch]$DryRun,

    [string]$RunDir = '',

    [string]$RunLabel = 'codex'
)

$ErrorActionPreference = 'Stop'

function New-EmptyArray { return @() }

function New-DryRunJson {
    param([string]$SchemaName)

    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ($SchemaName -eq 'chunk-summary.schema.json') {
        return [ordered]@{
            artifact_type = 'chunk_summary'
            provider = 'codex'
            model = $Model
            reasoning_effort = $ReasoningEffort
            mode = 'dry_run'
            chunk_index = 0
            source = [ordered]@{
                chunk_path = ''
                first_source_line = 0
                last_source_line = 0
            }
            facts = New-EmptyArray
            decisions = New-EmptyArray
            files = New-EmptyArray
            commands = New-EmptyArray
            failures = New-EmptyArray
            next_steps = New-EmptyArray
            user_preferences = New-EmptyArray
            final_state_candidates = New-EmptyArray
            unresolved_gaps = @('Dry run: no Codex model call was made.')
        }
    }

    if ($SchemaName -eq 'context.schema.json') {
        return [ordered]@{
            artifact_type = 'context'
            source_session_id = 'dry-run'
            replacement_session_name = 'dry-run'
            fingerprint = 'dry-run'
            source_of_truth = [ordered]@{ path = 'raw_transcript.jsonl'; sha256 = ''; line_count = 0; size_bytes = 0 }
            current_state = [ordered]@{ summary = 'Dry run context.'; status = 'dry_run'; confidence = 'low'; provenance = @() }
            major_decisions = @()
            active_work_items = @()
            open_risks = @()
            immediate_next_action = [ordered]@{ action = 'Dry run: no model merge was made.'; provenance = @(); confidence = 'low' }
            unresolved_gaps = @('Dry run: no model merge was made.')
            handoff_recommendation = [ordered]@{ decision = 'do_not_launch_for_test'; reason = 'Dry run.'; launch_allowed = $false; launch_attempted = $false }
            provider_summary = [ordered]@{ merge_strategy = 'codex_dry_run'; chunk_summary_count = 0; dry_run = $true }
        }
    }

    return [ordered]@{
        passed = $true
        checked_at = $now
        errors = @()
        warnings = @('Dry run: no Codex validation model call was made.')
    }
}

function Write-JsonNoBom {
    param([string]$Path, $Object)
    & (Join-Path $PSScriptRoot 'Write-Utf8NoBom.ps1') -Path $Path -InputObject $Object -Depth 80 | Out-Null
}

if (-not (Test-Path -LiteralPath $SchemaPath)) {
    throw "Schema not found: $SchemaPath"
}

$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($RunDir)) {
    $RunDir = Join-Path (Split-Path -Parent $OutputPath) 'provider_runs\codex'
}
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
$safeLabel = if ([string]::IsNullOrWhiteSpace($RunLabel)) { 'codex' } else { $RunLabel -replace '[^A-Za-z0-9_.-]', '_' }
$runPath = Join-Path $RunDir ("{0}-{1}.json" -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')), $safeLabel)

$schemaName = [System.IO.Path]::GetFileName($SchemaPath)
if ($DryRun) {
    $dry = New-DryRunJson -SchemaName $schemaName
    Write-JsonNoBom -Path $OutputPath -Object $dry
    $run = [ordered]@{
        provider = 'codex'
        model = $Model
        reasoning_effort = $ReasoningEffort
        dry_run = $true
        schema = $SchemaPath
        output_path = $OutputPath
        prompt_chars = $Prompt.Length
        exit_code = 0
        started_at = (Get-Date).ToUniversalTime().ToString('o')
        completed_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-JsonNoBom -Path $runPath -Object $run
    $parsed = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
    $parsed | Add-Member -NotePropertyName provider_run -NotePropertyValue $runPath -Force
    Write-JsonNoBom -Path $OutputPath -Object $parsed
    return [pscustomobject]@{
        output_path = $OutputPath
        run_path = $runPath
        parsed = $parsed
        dry_run = $true
        exit_code = 0
    }
}

$codex = Get-Command codex -ErrorAction SilentlyContinue
if (-not $codex) {
    throw 'Codex CLI was not found on PATH. Install Codex CLI or choose -Provider minimax/mimo.'
}

$promptPath = Join-Path $RunDir ("{0}-{1}.prompt.txt" -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')), $safeLabel)
[System.IO.File]::WriteAllText($promptPath, $Prompt, [System.Text.Encoding]::UTF8)

$started = (Get-Date).ToUniversalTime().ToString('o')
$args = @(
    '--sandbox', 'read-only',
    '-a', 'never',
    'exec',
    '--skip-git-repo-check',
    '--model', $Model,
    '--config', ('model_reasoning_effort="{0}"' -f $ReasoningEffort),
    '--output-schema', $SchemaPath,
    '--output-last-message', $OutputPath,
    '--cd', $WorkingDirectory,
    '-'
)

$stdout = ''
$exitCode = 0
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $stdout = Get-Content -LiteralPath $promptPath -Raw | & $codex.Source @args 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
}
catch {
    $stdout = [string]$_.Exception.Message
    $exitCode = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

$completed = (Get-Date).ToUniversalTime().ToString('o')
$runRecord = [ordered]@{
    provider = 'codex'
    model = $Model
    reasoning_effort = $ReasoningEffort
    dry_run = $false
    schema = $SchemaPath
    output_path = $OutputPath
    prompt_chars = $Prompt.Length
    exit_code = $exitCode
    stdout = $stdout
    started_at = $started
    completed_at = $completed
}
Write-JsonNoBom -Path $runPath -Object $runRecord

if ($exitCode -ne 0) {
    throw "Codex exec failed with exit code $exitCode. Provider run: $runPath"
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "Codex exec did not write output file: $OutputPath"
}

try {
    $parsed = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
}
catch {
    throw "Codex exec output was not valid JSON: $OutputPath. $($_.Exception.Message)"
}

$parsed | Add-Member -NotePropertyName provider_run -NotePropertyValue $runPath -Force
Write-JsonNoBom -Path $OutputPath -Object $parsed

[pscustomobject]@{
    output_path = $OutputPath
    run_path = $runPath
    parsed = $parsed
    dry_run = $false
    exit_code = $exitCode
}
