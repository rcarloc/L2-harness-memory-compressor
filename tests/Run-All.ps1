$ErrorActionPreference = 'Stop'

$tests = @(
    'provider-json-parser.tests.ps1',
    'compression-context-quality.tests.ps1',
    'chunk-digest.tests.ps1',
    'final-state-digest.tests.ps1',
    'Test-HandoffProvidersNoNetwork.ps1',
    'rollout-shape.tests.ps1',
    'public-entrypoint.tests.ps1'
)

foreach ($test in $tests) {
    $path = Join-Path $PSScriptRoot $test
    Write-Host "RUN $test"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path
    if ($LASTEXITCODE -ne 0) {
        throw "$test failed with exit code $LASTEXITCODE"
    }
}

Write-Host 'ALL TESTS PASS'
