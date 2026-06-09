param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [int]$MaxItemChars = 420,
    [int]$MaxItemsPerSection = 24
)

$ErrorActionPreference = 'Stop'

function Limit-Text {
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $oneLine = ($Text -replace '\s+', ' ').Trim()
    if ($oneLine.Length -le $Max) { return $oneLine }
    return $oneLine.Substring(0, $Max)
}

function New-DigestItem {
    param($Event)
    [ordered]@{
        line = [int]$Event.source_line
        timestamp = [string]$Event.timestamp
        text = Limit-Text -Text ([string]$Event.text) -Max $MaxItemChars
    }
}

function Add-Limited {
    param([System.Collections.ArrayList]$List, $Item)
    if ($List.Count -lt $MaxItemsPerSection -and -not [string]::IsNullOrWhiteSpace($Item.text)) {
        [void]$List.Add($Item)
    }
}

$manifestPath = Join-Path $BundlePath 'semantic_chunk_manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing semantic_chunk_manifest.json in $BundlePath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$digestDir = Join-Path $BundlePath 'chunk_digests'
if (Test-Path -LiteralPath $digestDir) {
    Remove-Item -LiteralPath $digestDir -Recurse -Force
}
New-Item -ItemType Directory -Path $digestDir -Force | Out-Null

$all = @()
foreach ($chunk in @($manifest.chunks)) {
    $chunkPath = Join-Path $BundlePath ([string]$chunk.path)
    if (-not (Test-Path -LiteralPath $chunkPath)) {
        throw "Missing chunk file: $chunkPath"
    }

    $sections = [ordered]@{
        user_intent = New-Object System.Collections.ArrayList
        assistant_actions = New-Object System.Collections.ArrayList
        files_or_artifacts = New-Object System.Collections.ArrayList
        commands_or_results = New-Object System.Collections.ArrayList
        decisions = New-Object System.Collections.ArrayList
        failures_or_blockers = New-Object System.Collections.ArrayList
        next_steps = New-Object System.Collections.ArrayList
        user_preferences = New-Object System.Collections.ArrayList
    }

    $events = @()
    foreach ($line in Get-Content -LiteralPath $chunkPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json
        $events += $event
        $text = [string]$event.text
        $item = New-DigestItem -Event $event

        if ($event.role -eq 'user' -or $event.type -eq 'user_message') {
            Add-Limited -List $sections.user_intent -Item $item
            if ($text -match "(?i)\b(prefer|don't|do not|should|style|criticism|wrong|quality|instead|constraint|scope)\b") {
                Add-Limited -List $sections.user_preferences -Item $item
            }
        }
        if ($event.role -eq 'assistant' -or $event.type -eq 'agent_message') {
            Add-Limited -List $sections.assistant_actions -Item $item
        }
        if ($text -match '(?i)([A-Za-z]:\\|/[^ ]+|\.ps1|\.jsonl|\.json|\.md|\.ts|\.tsx|\.js|\.mjs|\.py|artifact|report|output|saved|created|modified|edited)') {
            Add-Limited -List $sections.files_or_artifacts -Item $item
        }
        if ($text -match '(?i)\b(npm|node|git|gh|pytest|vitest|test|passed|failed|PASS|FAIL|command|stdout|stderr)\b') {
            Add-Limited -List $sections.commands_or_results -Item $item
        }
        if ($text -match '(?i)\b(decided|decision|chose|approved|rejected|final|use |switch to|scope)\b') {
            Add-Limited -List $sections.decisions -Item $item
        }
        if ($text -match '(?i)\b(blocked|failed|error|exception|invalid|timeout|mismatch|risk|unresolved|gotcha|bug)\b') {
            Add-Limited -List $sections.failures_or_blockers -Item $item
        }
        if ($text -match '(?i)\b(next|todo|follow.?up|remaining|continue|rerun|verify|needs?|should)\b') {
            Add-Limited -List $sections.next_steps -Item $item
        }
    }

    $digest = [ordered]@{
        artifact_type = 'chunk_digest'
        chunk_index = [int]$chunk.index
        source = [ordered]@{
            chunk_path = [string]$chunk.path
            first_source_line = [int]$chunk.first_source_line
            last_source_line = [int]$chunk.last_source_line
        }
        event_count = $events.Count
        sections = $sections
    }

    $jsonPath = Join-Path $digestDir ('chunk_{0:000}.digest.json' -f [int]$chunk.index)
    $mdPath = Join-Path $digestDir ('chunk_{0:000}.digest.md' -f [int]$chunk.index)
    $digest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# Chunk $($chunk.index) Digest")
    $md.Add("")
    foreach ($sectionName in $sections.Keys) {
        $title = ($sectionName -replace '_', ' ')
        $md.Add("## $title")
        foreach ($item in @($sections[$sectionName])) {
            $md.Add("- [$($item.line)] $($item.text)")
        }
        if ($sections[$sectionName].Count -eq 0) {
            $md.Add("- none observed")
        }
        $md.Add("")
    }
    $md | Set-Content -LiteralPath $mdPath -Encoding UTF8

    $all += [ordered]@{
        index = [int]$chunk.index
        digest_json = "chunk_digests/" + (Split-Path -Leaf $jsonPath)
        digest_md = "chunk_digests/" + (Split-Path -Leaf $mdPath)
    }
}

[ordered]@{
    artifact_type = 'chunk_digest_manifest'
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    chunk_count = $all.Count
    digests = $all
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'chunk_digest_manifest.json') -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    digest_count = $all.Count
}
