<#
    GRE IT Onboarding - Part 2 (Post-Intune employee setup)
    NOT IMPLEMENTED IN THIS BUILD (Phases 3-7).
    The launcher is wired up so the structure is complete, but Part 2 performs
    no action yet and says so explicitly instead of pretending to work.
#>
[CmdletBinding()]
param(
    [string]$AppRoot,
    [switch]$Resume
)
$message = "Part 2 (Post-Intune employee setup) is not available in this build.`n`nIt is delivered in later phases. No changes were made to this device."
Write-Host $message
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    [void][System.Windows.Forms.MessageBox]::Show($message, 'GRE IT Onboarding', 'OK', 'Information')
}
catch { }
exit 20
