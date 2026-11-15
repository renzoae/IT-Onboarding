<#
    GRE IT Onboarding - SoftwareInstaller module
    Purpose : Application detection and installation (WinGet, ODT, Sophos, OneDrive)
    Status  : NOT IMPLEMENTED YET - scheduled for Phase 3.
    This placeholder exists so the repository structure is complete. It exports
    one function that reports its status; nothing in Part 1 depends on it.
#>
Set-StrictMode -Version 2.0

function Get-SoftwareInstallerModuleStatus {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{ Module = 'SoftwareInstaller'; Implemented = $false; PlannedPhase = 3 }
}

Export-ModuleMember -Function Get-SoftwareInstallerModuleStatus
