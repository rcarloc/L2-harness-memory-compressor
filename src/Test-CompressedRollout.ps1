param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Compressed rollout not found: $Path"
}

$bytes = [System.IO.File]::ReadAllBytes($Path)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
    throw 'Compressed rollout has UTF-8 BOM; Codex rollout files must be UTF-8 without BOM.'
}

$records = @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
if ($records.Count -ne 3) {
    throw "Compressed rollout must contain exactly 3 records; found $($records.Count)."
}

$types = @($records | ForEach-Object { [string]$_.type })
if (($types -join ',') -ne 'session_meta,compacted,turn_context') {
    throw "Compressed rollout types must be session_meta,compacted,turn_context; found $($types -join ',')."
}

$replacement = @($records[1].payload.replacement_history)
if ($replacement.Count -lt 1) {
    throw 'compacted.payload.replacement_history is required.'
}

foreach ($item in $replacement) {
    if ([string]$item.type -ne 'message') {
        throw 'replacement_history items must use raw ResponseItem message shape: type=message.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.role)) {
        throw 'replacement_history message role is required.'
    }
    if (-not ($item.PSObject.Properties.Name -contains 'content')) {
        throw 'replacement_history message content is required.'
    }
    if ($item.content -is [string]) {
        throw 'replacement_history message content must be an array, not a string.'
    }
    $content = @($item.content)
    if ($content.Count -eq 0) {
        throw 'replacement_history message content array must not be empty.'
    }
    foreach ($part in $content) {
        if ([string]::IsNullOrWhiteSpace([string]$part.type)) {
            throw 'replacement_history content part type is required.'
        }
        if ($part.type -in @('input_text', 'output_text') -and [string]::IsNullOrWhiteSpace([string]$part.text)) {
            throw 'replacement_history text content must include text.'
        }
    }
}

[pscustomobject]@{
    path = $Path
    records = $records.Count
    replacement_history_count = $replacement.Count
    valid = $true
}
