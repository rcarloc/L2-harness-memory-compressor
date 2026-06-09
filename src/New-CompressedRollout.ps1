param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$RunId = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Source rollout not found: $SourcePath"
}

$contextPath = Join-Path $BundlePath 'context.json'
if (-not (Test-Path -LiteralPath $contextPath)) {
    throw "Missing context.json in bundle: $BundlePath"
}

function Get-FirstRecordByType {
    param([string]$Path, [string]$Type)
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ([string]$record.type -eq $Type) { return $record }
    }
    return $null
}

function Get-LastRecordByType {
    param([string]$Path, [string]$Type)
    $last = $null
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ([string]$record.type -eq $Type) { $last = $record }
    }
    return $last
}

function Add-Section {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Title,
        [object[]]$Values,
        [string[]]$Names
    )

    $items = @()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        if ($value -is [string]) {
            $text = [string]$value
        } else {
            $text = ''
            foreach ($name in $Names) {
                if ($value.PSObject.Properties.Name -contains $name -and -not [string]::IsNullOrWhiteSpace([string]$value.$name)) {
                    $text = [string]$value.$name
                    break
                }
            }
        }
        $text = ($text -replace '\s+', ' ').Trim()
        if ($text) { $items += $text }
    }

    if ($items.Count -eq 0) { return }
    $Lines.Add('')
    $Lines.Add($Title)
    foreach ($item in @($items | Select-Object -First 30)) {
        $Lines.Add("- $item")
    }
}

$sessionMeta = Get-FirstRecordByType -Path $SourcePath -Type 'session_meta'
if (-not $sessionMeta) {
    throw 'Source rollout must contain a session_meta record.'
}

$turnContext = Get-LastRecordByType -Path $SourcePath -Type 'turn_context'
if (-not $turnContext) {
    $turnContext = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        type = 'turn_context'
        payload = [ordered]@{
            turn_id = 'compressed-handoff'
            cwd = if ($sessionMeta.payload.cwd) { [string]$sessionMeta.payload.cwd } else { '' }
            summary = 'Compressed handoff context.'
        }
    }
}

$context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json
$sourceHash = if ($context.source_of_truth.sha256) {
    [string]$context.source_of_truth.sha256
} else {
    (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
}
$sessionId = if ($context.source_session_id) {
    [string]$context.source_session_id
} elseif ($sessionMeta.payload.id) {
    [string]$sessionMeta.payload.id
} else {
    'unknown'
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("Use this compressed handoff as prior Codex session context.")
$lines.Add("The raw rollout remains source of truth. If compressed context conflicts with raw source, trust raw source.")
$lines.Add('')
$lines.Add('SOURCE')
$lines.Add("- Original session id: $sessionId")
$lines.Add("- Source SHA256: $sourceHash")
if ($RunId) { $lines.Add("- Compression run: $RunId") }
if ($sessionMeta.payload.cwd) { $lines.Add("- Workspace: $($sessionMeta.payload.cwd)") }

$lines.Add('')
$lines.Add('CURRENT STATE')
$summary = if ($context.current_state.summary) { [string]$context.current_state.summary } else { 'Compressed context generated; inspect raw rollout for unresolved details.' }
$lines.Add($summary)

Add-Section -Lines $lines -Title 'MAJOR DECISIONS' -Values @($context.major_decisions) -Names @('decision', 'text')
Add-Section -Lines $lines -Title 'ACTIVE WORK ITEMS' -Values @($context.active_work_items) -Names @('item', 'text')
Add-Section -Lines $lines -Title 'OPEN RISKS' -Values @($context.open_risks) -Names @('risk', 'text')
Add-Section -Lines $lines -Title 'UNRESOLVED GAPS' -Values @($context.unresolved_gaps) -Names @('gap', 'text')

$next = ''
if ($context.immediate_next_action.action) { $next = [string]$context.immediate_next_action.action }
if ($next) {
    $lines.Add('')
    $lines.Add('IMMEDIATE NEXT ACTION')
    $lines.Add($next)
}

$handoffText = ($lines -join "`n")
$now = (Get-Date).ToUniversalTime().ToString('o')

$compacted = [ordered]@{
    timestamp = $now
    type = 'compacted'
    payload = [ordered]@{
        message = ''
        replacement_history = @(
            [ordered]@{
                type = 'message'
                role = 'user'
                content = @(
                    [ordered]@{
                        type = 'input_text'
                        text = $handoffText
                    }
                )
            }
        )
    }
}

$records = @($sessionMeta, $compacted, $turnContext)
$jsonLines = @($records | ForEach-Object { $_ | ConvertTo-Json -Depth 100 -Compress })
& (Join-Path $PSScriptRoot 'Write-Utf8NoBom.ps1') -Path $OutputPath -Text (($jsonLines -join "`n") + "`n") -NoNewline | Out-Null

[pscustomobject]@{
    output_path = $OutputPath
    source_session_id = $sessionId
    source_sha256 = $sourceHash
    replacement_history_count = 1
    handoff_text_chars = $handoffText.Length
}
