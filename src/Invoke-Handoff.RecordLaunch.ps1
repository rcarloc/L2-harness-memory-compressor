param(
    [Parameter(Mandatory)]
    [string]$Role,

    [Parameter(Mandatory)]
    [string]$SessionId,

    [Parameter(Mandatory)]
    [string]$Fingerprint,

    [Parameter(Mandatory)]
    [string]$OutRoot,

    [Parameter(Mandatory)]
    [string]$ReplacementThreadId,

    [Parameter(Mandatory)]
    [string]$ReplacementThreadName,

    [string]$LauncherSurface = 'codex_app_agent',
    [string]$LauncherTool = 'create_thread'
)

$ErrorActionPreference = 'Stop'

$bundleRoot = Join-Path -Path (Join-Path -Path $OutRoot -ChildPath $Role) -ChildPath $Fingerprint
$requestPath = Join-Path -Path $bundleRoot -ChildPath 'thread_launch_request.json'
if (-not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
    throw "Missing thread_launch_request.json: $requestPath"
}

$payload = @{}
$current = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
$current.PSObject.Properties | ForEach-Object {
    $payload[$_.Name] = $_.Value
}

if ($payload.source_session_id -ne $SessionId) {
    throw "SessionId '$SessionId' does not match launch request source_session_id '$($payload.source_session_id)'."
}
if ($payload.fingerprint -ne $Fingerprint) {
    throw "Fingerprint '$Fingerprint' does not match launch request fingerprint '$($payload.fingerprint)'."
}
if (-not [bool]$payload.launch_allowed) {
    throw 'Launch request is not approved. Run PrepareLaunch with -ApproveLaunch first.'
}

$payload.launch_attempted = $true
$payload.launch_attempted_at = (Get-Date).ToUniversalTime().ToString('o')
$payload.launch_result = 'created_peer_thread'
$payload.launcher_status = 'launched'
$payload.launcher_surface = $LauncherSurface
$payload.launcher_tool = $LauncherTool
$payload.replacement_thread_id = $ReplacementThreadId
$payload.replacement_thread_name = $ReplacementThreadName
$payload.reason = 'Peer Codex app thread created and recorded.'

$payload | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $requestPath -Encoding UTF8
Write-Output (Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json)
