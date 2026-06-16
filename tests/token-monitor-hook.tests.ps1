$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Write-TestRollout {
    param([string]$Path, [string]$SessionId)
    $lines = @(
        ('{"timestamp":"2026-06-10T00:00:00.000Z","type":"session_meta","payload":{"id":"' + $SessionId + '","timestamp":"2026-06-10T00:00:00.000Z","cwd":"C:\\demo","originator":"test"}}'),
        '{"timestamp":"2026-06-10T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":64000,"cached_input_tokens":50000,"output_tokens":220,"reasoning_output_tokens":30,"total_tokens":64220},"model_context_window":200000}}}',
        '{"timestamp":"2026-06-10T00:00:03.000Z","type":"turn_context","payload":{"turn_id":"turn-token-monitor-hook","cwd":"C:\\demo","model":"gpt-5","summary":"sample turn"}}'
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $encoding)
}

function Add-TestLine {
    param([string]$Path, [string]$Line)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, ($Line + [Environment]::NewLine), $encoding)
}

function Invoke-Hook {
    param([string]$InputJson, [string]$OutRoot)
    $script = Join-Path $RepoRoot 'Invoke-CodexTokenMonitorHook.ps1'
    $output = $InputJson | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -OutRoot $OutRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Hook exited with $LASTEXITCODE"
    }
    return ($output | Out-String).Trim()
}

$root = Join-Path $env:TEMP ('l2-token-monitor-hook-' + [guid]::NewGuid().ToString('n'))

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $outRoot = Join-Path $root 'hooks'
    $sessionId = 'hook-fixture-session'
    $source = Join-Path $root 'rollout-hook-fixture-session.jsonl'
    Write-TestRollout -Path $source -SessionId $sessionId

    $stopInput = @{
        hook_event_name = 'Stop'
        session_id = $sessionId
        turn_id = 'turn-token-monitor-hook'
        transcript_path = $source
    } | ConvertTo-Json -Compress

    $stdout = Invoke-Hook -InputJson $stopInput -OutRoot $outRoot
    $response = $stdout | ConvertFrom-Json
    Assert-True ($response.continue -eq $true) 'Hook should always return continue=true'

    $eventsPath = Join-Path $outRoot 'events.jsonl'
    Assert-True (Test-Path -LiteralPath $eventsPath) 'Hook should write events.jsonl'
    $events = @(Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($events.Count -eq 1) 'Stop hook should append one observation'
    Assert-True ($events[0].hook_event_name -eq 'Stop') 'Observation should include hook event name'
    Assert-True ($events[0].session_id -eq $sessionId) 'Observation should include session id'
    Assert-True ($events[0].turn_id -eq 'turn-token-monitor-hook') 'Observation should include turn id'
    Assert-True ($events[0].transcript_path -eq (Resolve-Path -LiteralPath $source).Path) 'Observation should include resolved transcript path'
    Assert-True ($events[0].latest_usage.input_tokens -eq 64000) 'Observation should include latest token usage'
    Assert-True ($events[0].size_bytes -gt 0) 'Observation should include size_bytes'
    Assert-True (-not [string]::IsNullOrWhiteSpace($events[0].recommendation)) 'Observation should include recommendation'

    $currentPath = Join-Path $outRoot 'current.json'
    Assert-True (Test-Path -LiteralPath $currentPath) 'Hook should write current.json'
    $current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
    Assert-True ($current.sessions.$sessionId.session_id -eq $sessionId) 'current.json should index latest state by session id'
    Assert-True ($current.sessions.$sessionId.latest_usage.input_tokens -eq 64000) 'current.json should include latest usage'
    Assert-True ($current.sessions.$sessionId.byte_offset -gt 0) 'current.json should include byte offset for incremental hook reads'
    $firstOffset = [int64]$current.sessions.$sessionId.byte_offset

    $nextTokenLine = '{"timestamp":"2026-06-10T00:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":33000,"cached_input_tokens":24000,"output_tokens":120,"reasoning_output_tokens":10,"total_tokens":33120},"model_context_window":200000}}}'
    Add-TestLine -Path $source -Line $nextTokenLine
    [void](Invoke-Hook -InputJson $stopInput -OutRoot $outRoot)
    $events = @(Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($events[-1].latest_usage.input_tokens -eq 33000) 'Second hook run should read appended token usage'
    Assert-True ($events[-1].read_mode -eq 'incremental') 'Second hook run should use incremental read mode'
    Assert-True ($events[-1].bytes_scanned -lt $firstOffset) 'Incremental run should scan fewer bytes than the original file prefix'
    $current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
    Assert-True ($current.sessions.$sessionId.latest_usage.input_tokens -eq 33000) 'current.json should update latest usage from incremental read'
    Assert-True ($current.sessions.$sessionId.byte_offset -gt $firstOffset) 'current.json should advance byte offset after incremental read'

    $secondSession = 'hook-second-session'
    $secondSource = Join-Path $root 'rollout-hook-second-session.jsonl'
    Write-TestRollout -Path $secondSource -SessionId $secondSession
    $secondInput = @{
        hook_event_name = 'Stop'
        session_id = $secondSession
        turn_id = 'second-turn'
        transcript_path = $secondSource
    } | ConvertTo-Json -Compress
    [void](Invoke-Hook -InputJson $secondInput -OutRoot $outRoot)
    $current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
    Assert-True ($current.sessions.$sessionId.session_id -eq $sessionId) 'current.json should preserve existing sessions'
    Assert-True ($current.sessions.$secondSession.session_id -eq $secondSession) 'current.json should add new sessions'

    $nonStopInput = @{
        hook_event_name = 'UserPromptSubmit'
        session_id = $sessionId
        turn_id = 'ignored-turn'
        transcript_path = $source
    } | ConvertTo-Json -Compress
    $stdout = Invoke-Hook -InputJson $nonStopInput -OutRoot $outRoot
    Assert-True ((($stdout | ConvertFrom-Json).continue) -eq $true) 'Non-Stop hook should still continue'
    $eventsAfterNonStop = @(Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($eventsAfterNonStop.Count -eq 3) 'Non-Stop hook should not append token observations'

    $missingTranscriptInput = @{
        hook_event_name = 'Stop'
        session_id = 'missing-transcript-session'
        turn_id = 'missing-turn'
    } | ConvertTo-Json -Compress
    $stdout = Invoke-Hook -InputJson $missingTranscriptInput -OutRoot $outRoot
    Assert-True ((($stdout | ConvertFrom-Json).continue) -eq $true) 'Missing transcript should not block Codex'

    $badPathInput = @{
        hook_event_name = 'Stop'
        session_id = 'bad-path-session'
        turn_id = 'bad-path-turn'
        transcript_path = (Join-Path $root 'missing.jsonl')
    } | ConvertTo-Json -Compress
    $stdout = Invoke-Hook -InputJson $badPathInput -OutRoot $outRoot
    Assert-True ((($stdout | ConvertFrom-Json).continue) -eq $true) 'Unreadable transcript should not block Codex'

    $stdout = Invoke-Hook -InputJson '{not-json' -OutRoot $outRoot
    Assert-True ((($stdout | ConvertFrom-Json).continue) -eq $true) 'Malformed hook JSON should not block Codex'

    $errorsPath = Join-Path $outRoot 'hook-errors.jsonl'
    Assert-True (Test-Path -LiteralPath $errorsPath) 'Hook should write hook-errors.jsonl for failures'
    $errors = @(Get-Content -LiteralPath $errorsPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($errors.Count -ge 3) 'Hook should log missing path, bad path, and malformed JSON errors'

    'token-monitor-hook.tests.ps1 PASS'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
