<#
    Runs the Pester test suite. Requires Pester 5.x (development machine only -
    Pester is not needed on the USB drive or on onboarded laptops):

        Install-Module Pester -MinimumVersion 5.3 -Scope CurrentUser -Force -SkipPublisherCheck

    All tests use mocks / temporary folders. They do NOT create accounts, install
    updates or read a real hardware hash, and therefore prove nothing about
    hardware- or Intune-dependent behaviour. See Documentation\Testing.md.
#>
[CmdletBinding()]
param([string]$OutputFile)
$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester -or $pester.Version.Major -lt 5) {
    Write-Error 'Pester 5.x is required. Windows ships Pester 3.4, which cannot run these tests. See the header of this script.'
    exit 1
}
Import-Module Pester -MinimumVersion 5.0
$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
if ($OutputFile) { $config.TestResult.Enabled = $true; $config.TestResult.OutputPath = $OutputFile }
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
