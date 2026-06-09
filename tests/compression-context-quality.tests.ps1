$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:TEMP ('handoff-quality-test-' + [guid]::NewGuid().ToString('n'))
$Bundle = Join-Path $Root 'bundle'
New-Item -ItemType Directory -Path $Bundle -Force | Out-Null

$good = [ordered]@{
    artifact_type = 'context'
    current_state = [ordered]@{ summary = 'Final state: implementation complete and tests passed.' }
    immediate_next_action = [ordered]@{ action = 'Run browser smoke.' }
    active_work_items = @([ordered]@{ item = 'Run browser smoke.' })
    open_risks = @([ordered]@{ risk = 'Browser smoke not rerun.' })
    unresolved_gaps = @('Browser smoke not rerun.')
    handoff_recommendation = [ordered]@{ launch_allowed = $false }
}
$good | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Bundle 'context.json') -Encoding UTF8
& (Join-Path $PSScriptRoot '..\src\Test-CompressionContextQuality.ps1') -BundlePath $Bundle | Out-Null

$bad = [ordered]@{
    artifact_type = 'context'
    current_state = [ordered]@{ summary = '' }
    immediate_next_action = [ordered]@{ action = '' }
    active_work_items = @()
    open_risks = @()
    unresolved_gaps = @()
    handoff_recommendation = [ordered]@{ launch_allowed = $false }
}
$bad | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Bundle 'context.json') -Encoding UTF8

$failed = $false
try {
    & (Join-Path $PSScriptRoot '..\src\Test-CompressionContextQuality.ps1') -BundlePath $Bundle | Out-Null
}
catch {
    $failed = $true
}

if (-not $failed) { throw 'Bad context unexpectedly passed quality validation.' }

Remove-Item -LiteralPath $Root -Recurse -Force
'compression-context-quality.tests.ps1 PASS'
