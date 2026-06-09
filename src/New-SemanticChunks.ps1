param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [int]$TargetChars = 50000,
    [int]$MaxChars = 60000,
    [int]$OverlapEvents = 5
)

$ErrorActionPreference = 'Stop'

$streamPath = Join-Path $BundlePath 'semantic_event_stream.jsonl'
if (-not (Test-Path -LiteralPath $streamPath)) {
    throw "Missing semantic_event_stream.jsonl in $BundlePath"
}

$chunksDir = Join-Path $BundlePath 'semantic_chunks'
if (Test-Path -LiteralPath $chunksDir) {
    Remove-Item -LiteralPath $chunksDir -Recurse -Force
}
New-Item -ItemType Directory -Path $chunksDir -Force | Out-Null

$chunks = New-Object System.Collections.Generic.List[object]
$current = New-Object System.Collections.Generic.List[string]
$currentChars = 0

function Add-Chunk {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [System.Collections.Generic.List[object]]$ChunkList
    )
    if ($Lines.Count -eq 0) { return }
    $copy = @($Lines.ToArray())
    $ChunkList.Add($copy)
}

$reader = [System.IO.File]::OpenText($streamPath)
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        if ($current.Count -gt 0 -and ($currentChars + $line.Length + 1) -gt $MaxChars) {
            Add-Chunk $current $chunks
            $overlap = @($current.ToArray() | Select-Object -Last $OverlapEvents)
            $current.Clear()
            foreach ($item in $overlap) { $current.Add($item) }
            $currentChars = ($overlap | ForEach-Object { $_.Length + 1 } | Measure-Object -Sum).Sum
        }

        $current.Add($line)
        $currentChars += $line.Length + 1

        if ($currentChars -ge $TargetChars -and $current.Count -gt $OverlapEvents) {
            Add-Chunk $current $chunks
            $overlap = @($current.ToArray() | Select-Object -Last $OverlapEvents)
            $current.Clear()
            foreach ($item in $overlap) { $current.Add($item) }
            $currentChars = ($overlap | ForEach-Object { $_.Length + 1 } | Measure-Object -Sum).Sum
        }
    }
}
finally {
    $reader.Close()
}

if ($current.Count -gt $OverlapEvents -or $chunks.Count -eq 0) {
    Add-Chunk $current $chunks
}

$chunkMeta = @()
for ($i = 0; $i -lt $chunks.Count; $i++) {
    $chunkLines = @($chunks[$i])
    $first = $chunkLines[0] | ConvertFrom-Json
    $last = $chunkLines[$chunkLines.Count - 1] | ConvertFrom-Json
    $name = 'chunk_{0:000}.jsonl' -f ($i + 1)
    $chunkPath = Join-Path $chunksDir $name
    $chunkLines | Set-Content -LiteralPath $chunkPath -Encoding UTF8
    $size = (Get-Item -LiteralPath $chunkPath).Length
    $chunkMeta += [ordered]@{
        index = $i + 1
        name = $name
        path = "semantic_chunks/$name"
        event_count = $chunkLines.Count
        size_bytes = [int64]$size
        first_source_line = [int]$first.source_line
        last_source_line = [int]$last.source_line
        first_timestamp = [string]$first.timestamp
        last_timestamp = [string]$last.timestamp
    }
}

$manifest = [ordered]@{
    artifact_type = 'semantic_chunk_manifest'
    mode = 'cheap-test'
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    target_chars = $TargetChars
    max_chars = $MaxChars
    overlap_events = $OverlapEvents
    chunk_count = $chunkMeta.Count
    chunks = $chunkMeta
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $BundlePath 'semantic_chunk_manifest.json') -Encoding UTF8

[pscustomobject]@{
    bundle_path = $BundlePath
    chunk_count = $chunkMeta.Count
}
