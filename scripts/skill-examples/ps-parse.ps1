# Syntax check for the powershell blocks of SKILL.md files whose runner is 'parse' (see skill_examples.py):
# every block goes through the PowerShell parser; nothing is executed.
# Arguments: input JSON file ([{ "id": "...", "text": "..." }]), output JSON file ({ "<id>": [{ line, column, message }] }).
param(
    [Parameter(Mandatory)] [string] $InputFile,
    [Parameter(Mandatory)] [string] $OutputFile
)
$ErrorActionPreference = 'Stop'

$result = [ordered]@{}
foreach ($block in @(Get-Content -Raw -Encoding utf8 -LiteralPath $InputFile | ConvertFrom-Json)) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput([string] $block.text, [ref] $tokens, [ref] $errors)
    $result[[string] $block.id] = @($errors | ForEach-Object {
            [ordered]@{ line = $_.Extent.StartLineNumber; column = $_.Extent.StartColumnNumber; message = $_.Message }
        })
}
[System.IO.File]::WriteAllText($OutputFile, (ConvertTo-Json -InputObject $result -Depth 5))
