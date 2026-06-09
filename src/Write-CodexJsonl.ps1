param(
    [string]$InputFile,
    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'

$content = Get-Content $InputFile -Raw
& (Join-Path $PSScriptRoot 'Write-Utf8NoBom.ps1') -Path $OutputFile -Text $content -NoNewline | Out-Null
Write-Host "Written $OutputFile ($(Get-Item $OutputFile).Length bytes, no BOM)"
