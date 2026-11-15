<#
    GRE IT Onboarding - UserConfiguration module
    Purpose : Outlook and OneDrive employee profile configuration
    Status  : NOT IMPLEMENTED YET - scheduled for Phase 5.
    This placeholder exists so the repository structure is complete. It exports
    one function that reports its status; nothing in Part 1 depends on it.
#>
Set-StrictMode -Version 2.0

function Get-UserConfigurationModuleStatus {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{ Module = 'UserConfiguration'; Implemented = $false; PlannedPhase = 5 }
}

Export-ModuleMember -Function Get-UserConfigurationModuleStatus
