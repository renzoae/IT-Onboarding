<#
    GRE IT Onboarding - Launcher
    Started by Start-Part1.cmd / Start-Part2.cmd (and by the resume task).

      * Verifies Windows PowerShell 5.1 (Desktop edition) on Windows.
      * Requests elevation through the normal UAC prompt - it never bypasses UAC.
      * Resolves the application root from its own location, so the USB drive
        letter does not matter.

    Execution policy: the launchers pass "-ExecutionPolicy RemoteSigned" for this
    process only. A policy enforced by Group Policy/Intune takes precedence over
    that parameter and is NOT overridden.

    Exit codes
      0  success (or handed over to the elevated instance)
      1  unexpected error            2  elevation declined / not available
      3  Part 1 incomplete           4  cancelled by the technician
      5  unsupported environment     10 restart pending
      20 requested part is not implemented in this build
#>
[CmdletBinding()]
param(
    [ValidateSet('1', '2')][string]$Part = '1',
    [switch]$Resume
)
$ErrorActionPreference = 'Stop'

function Show-LauncherMessage {
    param([string]$Text, [string]$Icon = 'Error')
    Write-Host $Text
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [void][System.Windows.Forms.MessageBox]::Show($Text, 'GRE IT Onboarding', 'OK', $Icon)
    }
    catch { }
}

try {
    # ---- environment checks ------------------------------------------------
    if ($PSVersionTable.PSVersion.Major -ne 5 -or ($PSVersionTable.ContainsKey('PSEdition') -and $PSVersionTable.PSEdition -ne 'Desktop')) {
        Show-LauncherMessage 'GRE IT Onboarding requires Windows PowerShell 5.1. Start it with Start-Part1.cmd or Start-Part2.cmd.'
        exit 5
    }
    if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or [Environment]::OSVersion.Version.Major -lt 10) {
        Show-LauncherMessage 'GRE IT Onboarding requires Windows 10/11.'
        exit 5
    }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Show-LauncherMessage "PowerShell is running in $($ExecutionContext.SessionState.LanguageMode) mode because of an application control policy. The onboarding tool cannot run and will not try to bypass that policy. Contact the security team."
        exit 5
    }

    $appRoot = Split-Path -Parent $PSScriptRoot
    $partScript = Join-Path $PSScriptRoot ('Part{0}.ps1' -f $Part)
    if (-not (Test-Path -LiteralPath $partScript)) {
        Show-LauncherMessage "Required file is missing: $partScript"
        exit 1
    }

    # ---- elevation (standard UAC) -----------------------------------------
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    $isSta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)

    if (-not $isAdmin -or -not $isSta) {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -ExecutionPolicy RemoteSigned -STA -File "{0}" -Part {1}' -f $PSCommandPath, $Part
        if ($Resume) { $arguments += ' -Resume' }
        try {
            if ($isAdmin) { Start-Process -FilePath $powershell -ArgumentList $arguments }
            else { Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs }
            exit 0
        }
        catch {
            Show-LauncherMessage 'Administrator rights are required. The UAC prompt was declined or elevation is not available for this account.' 'Warning'
            exit 2
        }
    }

    # ---- run the selected part ---------------------------------------------
    & $partScript -AppRoot $appRoot -Resume:$Resume
    exit $LASTEXITCODE
}
catch {
    Show-LauncherMessage ("GRE IT Onboarding stopped because of an unexpected error:`n`n{0}`n`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    exit 1
}
