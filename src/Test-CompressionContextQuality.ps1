param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath
)

$ErrorActionPreference = 'Stop'

$contextPath = Join-Path $BundlePath 'context.json'
if (-not (Test-Path -LiteralPath $contextPath)) {
    throw "Missing context.json in $BundlePath"
}

$context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json
$errors = @()
$warnings = @()

if ([string]::IsNullOrWhiteSpace([string]$context.current_state.summary)) {
    $errors += 'current_state.summary is required.'
}

if ([string]::IsNullOrWhiteSpace([string]$context.immediate_next_action.action)) {
    $errors += 'immediate_next_action.action is required.'
}

if (@($context.active_work_items).Count -eq 0 -and @($context.unresolved_gaps).Count -eq 0) {
    $warnings += 'No active_work_items and no unresolved_gaps; confirm session truly ended closed.'
}

if (Test-Path -LiteralPath (Join-Path $BundlePath 'final_state_digest.json')) {
    $finalDigest = Get-Content -LiteralPath (Join-Path $BundlePath 'final_state_digest.json') -Raw | ConvertFrom-Json
    $finalText = (@($finalDigest.final_state_candidates) + @($finalDigest.completed_or_verified) + @($finalDigest.next_steps) | ForEach-Object { [string]$_.text }) -join ' '
    if (-not [string]::IsNullOrWhiteSpace($finalText)) {
        $summaryWords = ([string]$context.current_state.summary).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
        $hits = 0
        foreach ($word in $summaryWords | Select-Object -First 40) {
            if ($word.Length -ge 5 -and $finalText.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $hits++
            }
        }
        if ($hits -lt 2) {
            $warnings += 'current_state.summary has low lexical overlap with final_state_digest.'
        }
    }
}
else {
    $warnings += 'final_state_digest.json missing; large-session final-state protection not available.'
}

$result = [ordered]@{
    passed = ($errors.Count -eq 0)
    checked_at = (Get-Date).ToUniversalTime().ToString('o')
    errors = $errors
    warnings = $warnings
}

$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'compression_context_quality.json') -Encoding UTF8

if ($errors.Count -gt 0) {
    throw ('Compression context quality failed: ' + ($errors -join '; '))
}

[pscustomobject]$result
