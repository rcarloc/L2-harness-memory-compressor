$ErrorActionPreference = 'Stop'
$Parser = Join-Path $PSScriptRoot '..\src\ConvertFrom-ProviderJson.ps1'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

$thinkPreamble = @'
<think>
I will reason first {not json}.
</think>
{"artifact_type":"chunk_summary","chunk_index":2}
'@

$earlierBrace = @'
notes {id}/content then {"artifact_type":"context","current_state":{"summary":"done"}}
'@

$rawNewline = @'
{"artifact_type":"chunk_summary","text":"line one
line two"}
'@

$fencedObject = @'
```json
{"artifact_type":"context","source_session_id":"abc"}
```
'@

$cases = @(
    @{
        name = 'clean object'
        text = '{"artifact_type":"chunk_summary","chunk_index":1}'
        expected = 'chunk_summary'
    },
    @{
        name = 'fenced object'
        text = $fencedObject
        expected = 'context'
    },
    @{
        name = 'think preamble'
        text = $thinkPreamble
        expected = 'chunk_summary'
    },
    @{
        name = 'earlier brace before artifact'
        text = $earlierBrace
        expected = 'context'
    },
    @{
        name = 'raw newline inside string'
        text = $rawNewline
        expected = 'chunk_summary'
    }
)

foreach ($case in $cases) {
    $obj = & $Parser -Text $case.text
    Assert-Equal $obj.artifact_type $case.expected $case.name
}

'provider-json-parser.tests.ps1 PASS'
