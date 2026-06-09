param(
    [string]$EnvPath = '.env',
    [switch]$IncludeSecrets
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Truth {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -match '^(?i:true|1|yes|y|on)$')
}

function Get-EnvValue {
    param(
        [hashtable]$Map,
        [string]$Name,
        [string]$Default = ''
    )
    $processValue = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
        return [string]$processValue
    }
    if ($Map.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$Map[$Name])) {
        return [string]$Map[$Name]
    }
    return $Default
}

$values = @{}
$loaded = $false

if (Test-Path -LiteralPath $EnvPath) {
    $loaded = $true
    foreach ($line in Get-Content -LiteralPath $EnvPath) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^\s*([^=\s]+)\s*=\s*(.*)\s*$') { continue }

        $name = $matches[1].Trim()
        $value = $matches[2].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            if ($value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $values[$name] = $value
    }
}

$minimaxKey = Get-EnvValue -Map $values -Name 'MINIMAX_API_KEY'
$minimaxKeyPresent = -not [string]::IsNullOrWhiteSpace($minimaxKey)
$mimoKeyName = $null
$mimoKey = ''
if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -Map $values -Name 'MIMO_API_KEY'))) {
    $mimoKeyName = 'MIMO_API_KEY'
    $mimoKey = Get-EnvValue -Map $values -Name 'MIMO_API_KEY'
} elseif (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -Map $values -Name 'mimo_api_key'))) {
    $mimoKeyName = 'mimo_api_key'
    $mimoKey = Get-EnvValue -Map $values -Name 'mimo_api_key'
}
$glmKeyName = $null
$glmKey = ''
if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -Map $values -Name 'Z_GLM_API_KEY'))) {
    $glmKeyName = 'Z_GLM_API_KEY'
    $glmKey = Get-EnvValue -Map $values -Name 'Z_GLM_API_KEY'
} elseif (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -Map $values -Name 'ZAI_API_KEY'))) {
    $glmKeyName = 'ZAI_API_KEY'
    $glmKey = Get-EnvValue -Map $values -Name 'ZAI_API_KEY'
}

$glmEnabled = ConvertTo-Truth (Get-EnvValue -Map $values -Name 'GLM_VALIDATION_ENABLED' -Default 'false')
$glmPolicySafe = ConvertTo-Truth (Get-EnvValue -Map $values -Name 'GLM_VALIDATION_POLICY_SAFE' -Default 'false')

$result = [ordered]@{
    env_path = $EnvPath
    loaded = $loaded
    providers = [ordered]@{
        minimax = [ordered]@{
            api_key_present = $minimaxKeyPresent
            key_name = 'MINIMAX_API_KEY'
            base_url = Get-EnvValue -Map $values -Name 'MINIMAX_BASE_URL' -Default 'https://api.minimax.io/v1'
            model = Get-EnvValue -Map $values -Name 'MINIMAX_MODEL' -Default 'MiniMax-M3'
            endpoint_kind = Get-EnvValue -Map $values -Name 'MINIMAX_ENDPOINT_KIND' -Default 'chat_completions'
        }
        mimo = [ordered]@{
            api_key_present = ($null -ne $mimoKeyName)
            key_name = $mimoKeyName
            base_url = Get-EnvValue -Map $values -Name 'MIMO_BASE_URL' -Default 'https://api.xiaomimimo.com/v1'
            model = Get-EnvValue -Map $values -Name 'MIMO_MODEL' -Default 'mimo-v2.5-pro'
            endpoint_kind = Get-EnvValue -Map $values -Name 'MIMO_ENDPOINT_KIND' -Default 'chat_completions'
            context_window = 1048576
            max_output = 131072
        }
        glm = [ordered]@{
            api_key_present = ($null -ne $glmKeyName)
            key_name = $glmKeyName
            coding_base_url = Get-EnvValue -Map $values -Name 'ZAI_CODING_BASE_URL' -Default 'https://api.z.ai/api/coding/paas/v4'
            general_base_url = Get-EnvValue -Map $values -Name 'ZAI_GENERAL_BASE_URL' -Default 'https://api.z.ai/api/paas/v4'
            model = Get-EnvValue -Map $values -Name 'ZAI_MODEL' -Default (Get-EnvValue -Map $values -Name 'GLM_MODEL' -Default 'GLM-5.1')
            validation_enabled = $glmEnabled
            policy_safe = $glmPolicySafe
            usable_for_validation = (($null -ne $glmKeyName) -and $glmEnabled -and $glmPolicySafe)
        }
    }
}

if ($IncludeSecrets) {
    $secrets = [ordered]@{
        minimax_api_key = if ($minimaxKeyPresent) { [string]$minimaxKey } else { '' }
        mimo_api_key = if ($mimoKeyName) { [string]$mimoKey } else { '' }
        glm_api_key = if ($glmKeyName) { [string]$glmKey } else { '' }
    }
    $result.secrets = $secrets
}

[pscustomobject]$result
