param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('minimax', 'mimo', 'glm')]
    [string]$Provider,

    [Parameter(Mandatory = $true)]
    [string]$Model,

    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [Parameter(Mandatory = $true)]
    [object[]]$Messages,

    [string]$EndpointKind = 'chat_completions',
    [int]$MaxTokens = 4096,
    [double]$Temperature = 0.1,
    [string]$RunDir,
    [string]$RunLabel = 'provider-call',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $RunDir) {
    $RunDir = Join-Path (Get-Location).Path 'provider_runs'
}
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null

$safeLabel = ($RunLabel -replace '[^A-Za-z0-9_.-]', '_')
$stamp = Get-Date -Format 'yyyyMMddTHHmmssfffZ'
$runPath = Join-Path $RunDir "$stamp-$safeLabel.json"

$trimmedBaseUrl = $BaseUrl.TrimEnd('/')
$uri = switch ($EndpointKind) {
    'responses' { "$trimmedBaseUrl/responses" }
    default { "$trimmedBaseUrl/chat/completions" }
}

if ($EndpointKind -eq 'responses') {
    $body = [ordered]@{
        model = $Model
        input = $Messages
        max_output_tokens = $MaxTokens
        temperature = $Temperature
    }
} else {
    if ($Provider -eq 'mimo') {
        $body = [ordered]@{
            model = $Model
            messages = $Messages
            max_completion_tokens = $MaxTokens
            temperature = $Temperature
        }
    } else {
        $body = [ordered]@{
            model = $Model
            messages = $Messages
            max_tokens = $MaxTokens
            temperature = $Temperature
        }
    }
}

$run = [ordered]@{
    provider = $Provider
    model = $Model
    endpoint_kind = $EndpointKind
    uri = $uri
    dry_run = [bool]$DryRun
    authorization_header_written = $false
    api_key_present = (-not [string]::IsNullOrWhiteSpace($ApiKey))
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    request = $body
    response = $null
    output_text = ''
    error = $null
}

if ($DryRun) {
    $run.output_text = ''
    $run.completed_at = (Get-Date).ToUniversalTime().ToString('o')
    $run | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $runPath -Encoding UTF8
    return [pscustomobject]@{
        provider = $Provider
        model = $Model
        dry_run = $true
        run_path = $runPath
        output_text = ''
    }
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw "Missing API key for provider $Provider"
}

if ($Provider -eq 'mimo') {
    $headers = @{
        'api-key' = $ApiKey
        'Content-Type' = 'application/json'
    }
} else {
    $headers = @{
        Authorization = "Bearer $ApiKey"
        'Content-Type' = 'application/json'
    }
}

try {
    $jsonBody = $body | ConvertTo-Json -Depth 50
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $bodyBytes -ContentType 'application/json; charset=utf-8'
    $run.response = $response

    $text = ''
    if ($response.choices -and $response.choices.Count -gt 0 -and $response.choices[0].message.content) {
        $text = [string]$response.choices[0].message.content
    } elseif ($response.output_text) {
        $text = [string]$response.output_text
    } elseif ($response.output -and $response.output.Count -gt 0) {
        $parts = @()
        foreach ($item in @($response.output)) {
            foreach ($content in @($item.content)) {
                if ($content.text) { $parts += [string]$content.text }
            }
        }
        $text = ($parts -join "`n")
    }

    $run.output_text = $text
    $finishReason = $null
    if ($response.choices -and $response.choices.Count -gt 0 -and $response.choices[0].finish_reason) {
        $finishReason = [string]$response.choices[0].finish_reason
    }
    $run.finish_reason = $finishReason
    $run.completed_at = (Get-Date).ToUniversalTime().ToString('o')
    $run | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $runPath -Encoding UTF8

    [pscustomobject]@{
        provider = $Provider
        model = $Model
        dry_run = $false
        run_path = $runPath
        output_text = $text
        finish_reason = $finishReason
    }
}
catch {
    $run.error = [ordered]@{
        message = $_.Exception.Message
        type = $_.Exception.GetType().FullName
    }
    $run.completed_at = (Get-Date).ToUniversalTime().ToString('o')
    $run | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $runPath -Encoding UTF8
    throw
}
