function Invoke-Thing {
    [CmdletBinding()]
    # Mandatory, so a $null name (the vacuous-$Name bug) fails instead of passing.
    param([Parameter(Mandatory, Position = 0)] [string] $Name)
    'ok'
}
Export-ModuleMember -Function Invoke-Thing
