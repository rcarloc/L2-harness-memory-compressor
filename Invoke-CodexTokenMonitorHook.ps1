param(
    [string]$OutRoot = ''
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    $OutRoot = Join-Path $ScriptRoot 'runs\token-monitor\hooks'
}

function Write-JsonNoBom {
    param([string]$Path, [object]$Object, [switch]$Append)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = ($Object | ConvertTo-Json -Depth 50 -Compress) + [Environment]::NewLine
    $encoding = New-Object System.Text.UTF8Encoding($false)
    if ($Append) {
        [System.IO.File]::AppendAllText($Path, $json, $encoding)
    } else {
        [System.IO.File]::WriteAllText($Path, $json, $encoding)
    }
}

function Write-HookError {
    param([string]$Message, [object]$HookInput)
    $errorPath = Join-Path $OutRoot 'hook-errors.jsonl'
    $entry = [ordered]@{
        captured_at = (Get-Date).ToUniversalTime().ToString('o')
        message = $Message
        hook_event_name = if ($HookInput -and $HookInput.hook_event_name) { [string]$HookInput.hook_event_name } else { $null }
        session_id = if ($HookInput -and $HookInput.session_id) { [string]$HookInput.session_id } else { $null }
        turn_id = if ($HookInput -and $HookInput.turn_id) { [string]$HookInput.turn_id } else { $null }
        transcript_path = if ($HookInput -and $HookInput.transcript_path) { [string]$HookInput.transcript_path } else { $null }
    }
    Write-JsonNoBom -Path $errorPath -Object $entry -Append
}

function Get-ExistingSessions {
    param([string]$CurrentPath)
    $sessions = [ordered]@{}
    if (-not (Test-Path -LiteralPath $CurrentPath)) {
        return $sessions
    }
    try {
        $current = Get-Content -LiteralPath $CurrentPath -Raw | ConvertFrom-Json
        if ($current.sessions) {
            foreach ($property in $current.sessions.PSObject.Properties) {
                $sessions[$property.Name] = $property.Value
            }
        }
    }
    catch {
        return [ordered]@{}
    }
    return $sessions
}

function Get-TokenStatus {
    param([Nullable[Int64]]$InputTokens)
    if ($null -eq $InputTokens) { return 'unknown' }
    if ($InputTokens -lt 35000) { return 'strong' }
    if ($InputTokens -lt 60000) { return 'pass' }
    if ($InputTokens -le 100000) { return 'warn' }
    return 'fail'
}

function Get-UsageFingerprint {
    param([object]$Usage, [object]$ContextWindow)
    if ($null -eq $Usage) { return '' }
    $parts = @(
        [string]$Usage.input_tokens,
        [string]$Usage.cached_input_tokens,
        [string]$Usage.output_tokens,
        [string]$Usage.reasoning_output_tokens,
        [string]$Usage.total_tokens,
        [string]$ContextWindow
    )
    return ($parts -join '|')
}

function Convert-Usage {
    param([object]$Usage, [object]$ContextWindow)
    if ($null -eq $Usage) { return $null }

    $inputTokens = if ($null -ne $Usage.input_tokens) { [int64]$Usage.input_tokens } else { $null }
    $cachedTokens = if ($null -ne $Usage.cached_input_tokens) { [int64]$Usage.cached_input_tokens } else { $null }
    $uncachedTokens = $null
    if ($null -ne $inputTokens -and $null -ne $cachedTokens) {
        $uncachedTokens = [int64]([math]::Max(0, $inputTokens - $cachedTokens))
    }

    $window = if ($null -ne $ContextWindow) { [int64]$ContextWindow } else { $null }
    $pressure = $null
    if ($null -ne $inputTokens -and $null -ne $window -and $window -gt 0) {
        $pressure = [math]::Round(([double]$inputTokens / [double]$window) * 100, 2)
    }

    [ordered]@{
        input_tokens = $inputTokens
        cached_input_tokens = $cachedTokens
        uncached_input_tokens = $uncachedTokens
        output_tokens = if ($null -ne $Usage.output_tokens) { [int64]$Usage.output_tokens } else { $null }
        reasoning_output_tokens = if ($null -ne $Usage.reasoning_output_tokens) { [int64]$Usage.reasoning_output_tokens } else { $null }
        total_tokens = if ($null -ne $Usage.total_tokens) { [int64]$Usage.total_tokens } else { $null }
        model_context_window = $window
        context_pressure_pct = $pressure
        status = Get-TokenStatus -InputTokens $inputTokens
    }
}

function Get-Recommendation {
    param([object]$Usage, [int64]$SizeBytes, [int64]$CompactedCount)
    if ($null -eq $Usage) { return 'no token data available yet' }
    $status = [string]$Usage.status
    if ($status -eq 'fail' -and ($SizeBytes -ge (3 * 1024 * 1024) -or $CompactedCount -ge 2)) {
        return 'consider compression'
    }
    if ($status -eq 'fail') {
        return 'monitor one more turn or compress if continuing'
    }
    if ($status -eq 'warn') {
        return 'monitor next turn'
    }
    return 'no compression needed'
}

function Read-IncrementalTokenUsage {
    param(
        [string]$Path,
        [int64]$StartByteOffset,
        [object]$Previous
    )

    $fileInfo = Get-Item -LiteralPath $Path
    $recordCount = if ($Previous.record_count) { [int64]$Previous.record_count } else { 0 }
    $compactedCount = if ($Previous.compacted_count) { [int64]$Previous.compacted_count } else { 0 }
    $tokenEventCount = if ($Previous.token_event_count) { [int64]$Previous.token_event_count } else { 0 }
    $uniqueTokenEventCount = if ($Previous.unique_token_event_count) { [int64]$Previous.unique_token_event_count } else { 0 }
    $lastFingerprint = if ($Previous.last_fingerprint) { [string]$Previous.last_fingerprint } else { '' }
    $latestUsage = $Previous.latest_usage
    $latestEvent = [ordered]@{
        line = $null
        timestamp = $null
        fingerprint = $lastFingerprint
        usage = $latestUsage
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek($StartByteOffset, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        try {
            while (($line = $reader.ReadLine()) -ne $null) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $recordCount++
                try { $obj = $line | ConvertFrom-Json } catch { continue }
                $type = if ($obj.type) { [string]$obj.type } else { 'unknown' }
                if ($type -eq 'compacted') {
                    $compactedCount++
                }
                if ($type -eq 'event_msg' -and $obj.payload.type -eq 'token_count') {
                    $info = $obj.payload.info
                    $usage = Convert-Usage -Usage $info.last_token_usage -ContextWindow $info.model_context_window
                    $fingerprint = Get-UsageFingerprint -Usage $info.last_token_usage -ContextWindow $info.model_context_window
                    $tokenEventCount++
                    if (-not [string]::IsNullOrWhiteSpace($fingerprint) -and $fingerprint -ne $lastFingerprint) {
                        $uniqueTokenEventCount++
                        $lastFingerprint = $fingerprint
                    }
                    $latestUsage = $usage
                    $latestEvent = [ordered]@{
                        line = $recordCount
                        timestamp = [string]$obj.timestamp
                        fingerprint = $fingerprint
                        usage = $usage
                    }
                }
            }
        }
        finally {
            $reader.Close()
        }
    }
    finally {
        $stream.Close()
    }

    [pscustomobject]@{
        path = $Path
        session_id = [string]$Previous.session_id
        size_bytes = [int64]$fileInfo.Length
        size_mb = [math]::Round(([double]$fileInfo.Length / 1MB), 3)
        record_count = $recordCount
        compacted_count = $compactedCount
        compressed_only_shape = [bool]$Previous.compressed_only_shape
        token_event_count = $tokenEventCount
        unique_token_event_count = $uniqueTokenEventCount
        latest_token_event = $latestEvent
        recommendation = Get-Recommendation -Usage $latestUsage -SizeBytes ([int64]$fileInfo.Length) -CompactedCount $compactedCount
        read_mode = 'incremental'
        bytes_scanned = [int64]([math]::Max(0, ([int64]$fileInfo.Length - $StartByteOffset)))
        byte_offset = [int64]$fileInfo.Length
        last_fingerprint = $lastFingerprint
    }
}

function Write-CurrentSnapshot {
    param([object]$Event)
    $currentPath = Join-Path $OutRoot 'current.json'
    $sessions = Get-ExistingSessions -CurrentPath $currentPath
    $sessions[[string]$Event.session_id] = [ordered]@{
        session_id = $Event.session_id
        turn_id = $Event.turn_id
        transcript_path = $Event.transcript_path
        latest_usage = $Event.latest_usage
        size_bytes = $Event.size_bytes
        size_mb = $Event.size_mb
        record_count = $Event.record_count
        compacted_count = $Event.compacted_count
        compressed_only_shape = $Event.compressed_only_shape
        token_event_count = $Event.token_event_count
        unique_token_event_count = $Event.unique_token_event_count
        byte_offset = $Event.byte_offset
        last_fingerprint = $Event.last_fingerprint
        read_mode = $Event.read_mode
        bytes_scanned = $Event.bytes_scanned
        recommendation = $Event.recommendation
        updated_at = $Event.captured_at
    }
    $current = [ordered]@{
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        sessions = $sessions
    }
    Write-JsonNoBom -Path $currentPath -Object $current
}

function Write-ContinueResponse {
    ([ordered]@{ 'continue' = $true } | ConvertTo-Json -Depth 5 -Compress)
}

try {
    $inputJson = [Console]::In.ReadToEnd()
    $hookInput = $null
    try {
        $hookInput = $inputJson | ConvertFrom-Json
    }
    catch {
        Write-HookError -Message ('Malformed hook JSON: ' + $_.Exception.Message) -HookInput $null
        Write-ContinueResponse
        exit 0
    }

    if ([string]$hookInput.hook_event_name -ne 'Stop') {
        Write-ContinueResponse
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace([string]$hookInput.transcript_path)) {
        Write-HookError -Message 'Stop hook input did not include transcript_path.' -HookInput $hookInput
        Write-ContinueResponse
        exit 0
    }

    if (-not (Test-Path -LiteralPath ([string]$hookInput.transcript_path))) {
        Write-HookError -Message ('Transcript path was not readable: ' + [string]$hookInput.transcript_path) -HookInput $hookInput
        Write-ContinueResponse
        exit 0
    }

    $resolvedTranscript = (Resolve-Path -LiteralPath ([string]$hookInput.transcript_path)).Path
    $currentPath = Join-Path $OutRoot 'current.json'
    $sessions = Get-ExistingSessions -CurrentPath $currentPath
    $priorSessionId = if ($hookInput.session_id) { [string]$hookInput.session_id } else { '' }
    $prior = if (-not [string]::IsNullOrWhiteSpace($priorSessionId) -and $sessions.Contains($priorSessionId)) { $sessions[$priorSessionId] } else { $null }
    $fileInfo = Get-Item -LiteralPath $resolvedTranscript

    if ($prior -and [string]$prior.transcript_path -eq $resolvedTranscript -and $prior.byte_offset -and [int64]$prior.byte_offset -le [int64]$fileInfo.Length) {
        $analysis = Read-IncrementalTokenUsage -Path $resolvedTranscript -StartByteOffset ([int64]$prior.byte_offset) -Previous $prior
    } else {
        $analysis = & (Join-Path $ScriptRoot 'src\Read-CodexTokenUsage.ps1') -SourcePath $resolvedTranscript
        $analysis | Add-Member -NotePropertyName read_mode -NotePropertyValue 'full' -Force
        $analysis | Add-Member -NotePropertyName bytes_scanned -NotePropertyValue ([int64]$analysis.size_bytes) -Force
        $analysis | Add-Member -NotePropertyName byte_offset -NotePropertyValue ([int64]$analysis.size_bytes) -Force
        $lastFingerprint = if ($analysis.latest_token_event) { [string]$analysis.latest_token_event.fingerprint } else { '' }
        $analysis | Add-Member -NotePropertyName last_fingerprint -NotePropertyValue $lastFingerprint -Force
    }
    $latestUsage = if ($analysis.latest_token_event) { $analysis.latest_token_event.usage } else { $null }
    $eventSessionId = if ($hookInput.session_id) { [string]$hookInput.session_id } elseif ($analysis.session_id) { [string]$analysis.session_id } else { 'unknown-session' }

    $event = [ordered]@{
        captured_at = (Get-Date).ToUniversalTime().ToString('o')
        hook_event_name = [string]$hookInput.hook_event_name
        session_id = $eventSessionId
        turn_id = if ($hookInput.turn_id) { [string]$hookInput.turn_id } else { $null }
        transcript_path = $resolvedTranscript
        latest_usage = $latestUsage
        size_bytes = $analysis.size_bytes
        size_mb = $analysis.size_mb
        record_count = $analysis.record_count
        compacted_count = $analysis.compacted_count
        compressed_only_shape = $analysis.compressed_only_shape
        token_event_count = $analysis.token_event_count
        unique_token_event_count = $analysis.unique_token_event_count
        read_mode = $analysis.read_mode
        bytes_scanned = $analysis.bytes_scanned
        byte_offset = $analysis.byte_offset
        last_fingerprint = $analysis.last_fingerprint
        recommendation = $analysis.recommendation
    }

    Write-JsonNoBom -Path (Join-Path $OutRoot 'events.jsonl') -Object $event -Append
    Write-CurrentSnapshot -Event $event
    Write-ContinueResponse
    exit 0
}
catch {
    try {
        Write-HookError -Message ('Unexpected hook failure: ' + $_.Exception.Message) -HookInput $hookInput
    }
    catch {
        # A hook must not block Codex, even if error logging itself fails.
    }
    Write-ContinueResponse
    exit 0
}
