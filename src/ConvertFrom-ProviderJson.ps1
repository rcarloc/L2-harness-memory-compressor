param(
    [Parameter(Mandatory = $true)]
    [string]$Text,

    [string]$AnchorProperty = 'artifact_type'
)

$ErrorActionPreference = 'Stop'

function ConvertTo-JsonSafeString {
    param([string]$JsonText)

    $out = New-Object System.Text.StringBuilder
    $inString = $false
    $escape = $false

    for ($i = 0; $i -lt $JsonText.Length; $i++) {
        $ch = $JsonText[$i]
        if ($escape) {
            [void]$out.Append($ch)
            $escape = $false
            continue
        }
        if ($ch -eq '\') {
            [void]$out.Append($ch)
            $escape = $true
            continue
        }
        if ($ch -eq '"') {
            [void]$out.Append($ch)
            $inString = -not $inString
            continue
        }
        if ($inString -and ($ch -eq "`r" -or $ch -eq "`n" -or $ch -eq "`t")) {
            [void]$out.Append(' ')
            continue
        }
        [void]$out.Append($ch)
    }

    $out.ToString()
}

function Get-BalancedObjectFrom {
    param([string]$Source, [int]$Start)

    $depth = 0
    $inString = $false
    $escape = $false

    for ($i = $Start; $i -lt $Source.Length; $i++) {
        $ch = $Source[$i]
        if ($escape) {
            $escape = $false
            continue
        }
        if ($ch -eq '\') {
            $escape = $true
            continue
        }
        if ($ch -eq '"') {
            $inString = -not $inString
            continue
        }
        if ($inString) { continue }

        if ($ch -eq '{') {
            $depth++
        }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Source.Substring($Start, $i - $Start + 1)
            }
        }
    }

    $null
}

function Convert-Candidate {
    param([string]$Candidate)

    try {
        return $Candidate | ConvertFrom-Json
    }
    catch {
        return (ConvertTo-JsonSafeString -JsonText $Candidate) | ConvertFrom-Json
    }
}

if ([string]::IsNullOrWhiteSpace($Text)) {
    throw 'Provider output was empty.'
}

$fenceMatches = [regex]::Matches($Text, '(?s)```(?:json)?\s*(\{[\s\S]*?\})\s*```')
foreach ($match in $fenceMatches) {
    try {
        $obj = Convert-Candidate -Candidate $match.Groups[1].Value
        if ($obj) { return $obj }
    }
    catch {}
}

$anchorIndex = $Text.IndexOf('"' + $AnchorProperty + '"')
if ($anchorIndex -lt 0) {
    $anchorIndex = $Text.IndexOf($AnchorProperty)
}

if ($anchorIndex -ge 0) {
    $start = $Text.LastIndexOf('{', $anchorIndex)
    while ($start -ge 0) {
        $candidate = Get-BalancedObjectFrom -Source $Text -Start $start
        if ($candidate) {
            try { return Convert-Candidate -Candidate $candidate } catch {}
        }
        if ($start -eq 0) { break }
        $start = $Text.LastIndexOf('{', $start - 1)
    }
}

$idx = -1
while ($true) {
    $idx = $Text.IndexOf('{', $idx + 1)
    if ($idx -lt 0) { break }
    $candidate = Get-BalancedObjectFrom -Source $Text -Start $idx
    if ($candidate) {
        try { return Convert-Candidate -Candidate $candidate } catch {}
    }
}

throw 'Could not extract a valid JSON object from provider output.'
