function Get-UserInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Username)
    Get-ADUser -Identity $Username
}
