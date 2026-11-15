<#
    GRE IT Onboarding - Configuration module
    Loads Config\Settings.json, merges it over safe defaults and builds the
    run-time context (paths). No secrets are ever read from or written to config.
#>
Set-StrictMode -Version 2.0

function ConvertTo-OnboardingHashtable {
    <# Recursively converts PSCustomObject / arrays (ConvertFrom-Json output) to hashtables. #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)][AllowNull()]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $h = @{}
            foreach ($k in @($InputObject.Keys)) { $h[[string]$k] = ConvertTo-OnboardingHashtable -InputObject $InputObject[$k] }
            return $h
        }
        if ($InputObject -is [string] -or $InputObject -is [System.ValueType]) { return $InputObject }
        if ($InputObject -is [System.Collections.IEnumerable]) {
            $list = @()
            foreach ($item in $InputObject) { $list += , (ConvertTo-OnboardingHashtable -InputObject $item) }
            return , $list
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $h = @{}
            foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-OnboardingHashtable -InputObject $p.Value }
            return $h
        }
        return $InputObject
    }
}

function Get-OnboardingDefaultSettings {
    [CmdletBinding()]
    param()
    return @{
        LocalAdmin    = @{
            MinimumPasswordLength      = 12
            RequireComplexity          = $true
            DisallowUserNameInPassword = $true
            ForbiddenPasswordTerms     = @()
            PasswordNeverExpires       = $false
            AccountDescription         = 'Local administrator (IT onboarding)'
        }
        Connectivity  = @{
            ProbeUrls      = @('http://www.msftconnecttest.com/connecttest.txt', 'https://www.microsoft.com')
            TimeoutSeconds = 10
        }
        WindowsUpdate = @{
            IncludeDrivers         = $false
            IncludeFeatureUpgrades = $false
            AcceptEulas            = $true
            MaxPassesPerBoot       = 3
            MaxRestartCycles       = 5
        }
        Autopilot     = @{ GroupTag = ''; MinimumHashLength = 1000 }
        Reporting     = @{ OrganizationName = ''; DefaultTechnicianName = '' }
    }
}

function Merge-OnboardingSettings {
    <# Returns Defaults overlaid with Override (recursive for nested hashtables). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Defaults, [hashtable]$Override)
    $result = @{}
    foreach ($k in $Defaults.Keys) { $result[$k] = $Defaults[$k] }
    if ($null -eq $Override) { return $result }
    foreach ($k in $Override.Keys) {
        if ($result.ContainsKey($k) -and ($result[$k] -is [hashtable]) -and ($Override[$k] -is [hashtable])) {
            $result[$k] = Merge-OnboardingSettings -Defaults $result[$k] -Override $Override[$k]
        }
        elseif ($null -ne $Override[$k]) {
            $result[$k] = $Override[$k]
        }
    }
    return $result
}

function Get-OnboardingSettings {
    <# Reads Settings.json. A missing file yields defaults; an unreadable file is an error. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AppRoot)
    $defaults = Get-OnboardingDefaultSettings
    $path = Join-Path (Join-Path $AppRoot 'Config') 'Settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return $defaults }
    try {
        $raw = [System.IO.File]::ReadAllText($path)
        $parsed = ConvertTo-OnboardingHashtable -InputObject (ConvertFrom-Json -InputObject $raw)
    }
    catch {
        throw "Config\Settings.json could not be parsed: $($_.Exception.Message)"
    }
    $settings = Merge-OnboardingSettings -Defaults $defaults -Override $parsed

    $min = 0
    if (-not [int]::TryParse([string]$settings.LocalAdmin['MinimumPasswordLength'], [ref]$min) -or $min -lt 1 -or $min -gt 127) {
        throw 'Settings.json: LocalAdmin.MinimumPasswordLength must be a number between 1 and 127.'
    }
    $settings.LocalAdmin['MinimumPasswordLength'] = $min
    $settings.LocalAdmin['ForbiddenPasswordTerms'] = @($settings.LocalAdmin['ForbiddenPasswordTerms'] | Where-Object { $_ })
    $settings.Connectivity['ProbeUrls'] = @($settings.Connectivity['ProbeUrls'] | Where-Object { $_ })
    return $settings
}

function Get-OnboardingLocalRoot {
    <#
        Local (non-USB) working root used for checkpoints and temp files.
        GRE_ONBOARDING_LOCALROOT overrides it (used by automated tests only).
    #>
    [CmdletBinding()]
    param()
    if ($env:GRE_ONBOARDING_LOCALROOT) { return $env:GRE_ONBOARDING_LOCALROOT }
    $base = $env:ProgramData
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path $base 'GRE-IT-Onboarding')
}

function New-OnboardingContext {
    <# Builds the path/settings context shared by GUI and workflow. All paths derive from AppRoot (USB letter independent). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part
    )
    $AppRoot = [System.IO.Path]::GetFullPath($AppRoot)
    $localRoot = Get-OnboardingLocalRoot
    $reports = Join-Path $AppRoot 'Reports'
    return @{
        AppRoot           = $AppRoot
        Part              = $Part
        Settings          = (Get-OnboardingSettings -AppRoot $AppRoot)
        LocalRoot         = $localRoot
        WorkDirectory     = (Join-Path $localRoot 'Work')
        LocalLogDirectory = (Join-Path $localRoot 'Logs')
        LogDirectory      = (Join-Path $AppRoot 'Logs')
        ReportsRoot       = $reports
        HardwareHashDir   = (Join-Path $reports 'HardwareHash')
        Part1ReportDir    = (Join-Path $reports 'Part1')
        Part2ReportDir    = (Join-Path $reports 'Part2')
        InventoryDir      = (Join-Path $reports 'Inventory')
        GuiRoot           = (Join-Path $AppRoot 'GUI')
        ScriptsRoot       = (Join-Path $AppRoot 'Scripts')
        SessionStamp      = (Get-Date -Format 'yyyyMMdd_HHmmss')
        LogFile           = $null
    }
}

Export-ModuleMember -Function ConvertTo-OnboardingHashtable, Get-OnboardingDefaultSettings, Merge-OnboardingSettings,
    Get-OnboardingSettings, Get-OnboardingLocalRoot, New-OnboardingContext
