param(
    [Parameter(Mandatory)]
    [string]$Role,

    [Parameter(Mandatory)]
    [string]$SessionId,

    [Parameter(Mandatory)]
    [string]$Fingerprint,

    [Parameter(Mandatory)]
    [string]$OutRoot,

    [switch]$ApproveLaunch
)

$requiredArtifacts = @(
    'context.json',
    'context.md',
    'session_state.json',
    'bootstrap_prompt.txt',
    'handoff_report.md',
    'session_manifest.json'
)

$bundleRoot = Join-Path -Path (Join-Path -Path $OutRoot -ChildPath $Role) -ChildPath $Fingerprint
foreach ($artifact in $requiredArtifacts) {
    $path = Join-Path -Path $bundleRoot -ChildPath $artifact
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required artifact: $artifact"
    }
}

function Get-JsonFile {
    param([Parameter(Mandatory)] [string]$Path)
    try {
        $jsonText = Get-Content -Path $Path -Raw -ErrorAction Stop
        return ($jsonText | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "Failed to read JSON artifact '$Path': $($_.Exception.Message)"
    }
}

$manifestPath = Join-Path -Path $bundleRoot -ChildPath 'session_manifest.json'
$contextPath = Join-Path -Path $bundleRoot -ChildPath 'context.json'
$manifest = Get-JsonFile -Path $manifestPath
$context = Get-JsonFile -Path $contextPath

$sourceSessionId = $manifest.source_session_id
if ([string]::IsNullOrWhiteSpace([string]$sourceSessionId)) {
    $sourceSessionId = $context.source_session_id
}
if ([string]::IsNullOrWhiteSpace([string]$sourceSessionId)) {
    throw "Missing source_session_id in session_manifest.json/context.json"
}

$manifestFingerprint = $manifest.fingerprint
if (-not [string]::IsNullOrWhiteSpace([string]$manifestFingerprint) -and $Fingerprint -ne $manifestFingerprint) {
    throw "Fingerprint mismatch: parameter '$Fingerprint' does not match manifest '$manifestFingerprint'."
}

$replacementSessionName = $manifest.replacement_session_name
if ([string]::IsNullOrWhiteSpace([string]$replacementSessionName)) {
    $replacementSessionName = $context.replacement_session_name
}
if ([string]::IsNullOrWhiteSpace([string]$replacementSessionName)) {
    throw "Missing replacement_session_name in session_manifest.json/context.json"
}
if (-not [string]::IsNullOrWhiteSpace([string]$sourceSessionId) -and $SessionId -ne $sourceSessionId) {
    throw "SessionId '$SessionId' does not match source_session_id '$sourceSessionId'."
}

$requestPath = Join-Path -Path $bundleRoot -ChildPath 'thread_launch_request.json'
$payload = @{}
if (Test-Path -LiteralPath $requestPath -PathType Leaf) {
    try {
        $current = Get-Content -Path $requestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $current.PSObject.Properties | ForEach-Object {
            $payload[$_.Name] = $_.Value
        }
    }
    catch {
        throw "Failed to read existing thread_launch_request.json: $($_.Exception.Message)"
    }
}

if ($payload.ContainsKey('replacement_thread_id')) {
    $payload.Remove('replacement_thread_id')
}

$payload.launch_allowed = [bool]$ApproveLaunch.IsPresent
$payload.launch_approved_at = if ($ApproveLaunch) {
    (Get-Date).ToUniversalTime().ToString('o')
} else {
    $null
}
$payload.launch_attempted = $false
$payload.launcher_status = if ($ApproveLaunch) { 'awaiting_app_create_thread' } else { 'approval_required' }
$payload.reason = if ($ApproveLaunch) {
    'CLI package is approved for clean Codex app peer-thread launch via create_thread.'
} else {
    'Prepared only. Pass -ApproveLaunch after user approval to allow app create_thread launch.'
}
$bootstrapPromptPath = Join-Path -Path $bundleRoot -ChildPath 'bootstrap_prompt.txt'
$payload.bootstrap_prompt_path = $bootstrapPromptPath
$payload.replacement_session_name = $replacementSessionName
$payload.source_session_id = $sourceSessionId
$payload.fingerprint = $Fingerprint
$payload.launcher_abstraction = 'create_durable_peer_session'
$payload.launch_contract = [ordered]@{
    preferred_surface = 'codex_app_agent'
    preferred_tool = 'create_thread'
    cli_surface = 'codex_cli'
    cli_default = 'package_only'
    non_context_reducing_cli_option = 'codex fork'
    target_kind = 'clean_peer_session'
    requested_thread_name = $replacementSessionName
    requested_model = 'provider_default'
    requested_reasoning_effort = 'high'
    first_message_source = 'bootstrap_prompt.txt'
    first_message_path = $bootstrapPromptPath
    app_agent_instruction = "Call create_thread with name '$replacementSessionName' and first message from bootstrap_prompt.txt."
    expected_result_fields = @(
        'replacement_thread_id',
        'replacement_thread_name',
        'launch_attempted_at',
        'launch_result'
    )
}

$payloadJson = $payload | ConvertTo-Json -Depth 20
Set-Content -Path $requestPath -Value $payloadJson -Encoding UTF8

Write-Output (ConvertFrom-Json $payloadJson)
