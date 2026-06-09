param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [object]$InputObject,
    [string]$Text,
    [int]$Depth = 50,
    [switch]$CompressJson,
    [switch]$NoNewline
)

$ErrorActionPreference = 'Stop'

$parent = Split-Path -Parent $Path
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

if ($PSBoundParameters.ContainsKey('InputObject')) {
    $json = if ($CompressJson) {
        $InputObject | ConvertTo-Json -Depth $Depth -Compress
    } else {
        $InputObject | ConvertTo-Json -Depth $Depth
    }
    $Text = [string]$json
}

if ($null -eq $Text) {
    $Text = ''
}

if (-not $NoNewline) {
    $Text = $Text + [Environment]::NewLine
}

$encoding = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($Path, $Text, $encoding)

[pscustomobject]@{
    path = $Path
    bytes = (Get-Item -LiteralPath $Path).Length
    utf8_bom = $false
}
