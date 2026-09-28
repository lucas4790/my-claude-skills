# Stubs for the powershell examples of plugins/powershell/skills/pester/SKILL.md (tests/skill-examples.json).
# Dot-sourced by pester-driver.ps1 before the run. Every stub is a global function: Pester only mocks commands
# that exist, and the examples run from a separate module that sees only the global scope.

function global:Get-ADUser {
    [CmdletBinding()]
    param([Parameter(Position = 0)] $Identity, $Filter, $Properties)
    throw 'Get-ADUser stub: the example should have mocked this command.'
}

function global:Get-Service {
    [CmdletBinding()]
    param([Parameter(Position = 0)] [string[]] $Name)
    throw 'Get-Service stub: the example should have mocked this command.'
}

function global:Get-Function {
    param([Parameter(Position = 0)] $Value)
    $map = @{ value1 = 'result1'; value2 = 'result2'; test1 = 'result1'; test2 = 'result2' }
    # "$Value" turns anything unexpected (such as the $Input enumerator) into a key the map lacks.
    $map["$Value"]
}

function global:Get-Collection { 'item1', 'item2' }
