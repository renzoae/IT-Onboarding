<#
    GRE IT Onboarding - Device information module (CIM/WMI inventory, read-only)
    Every section is collected independently: one failing query produces a
    warning and 'Unknown' values instead of aborting the whole inventory.
    Values are reported as detected - detection is NOT proof of physical health.
#>
Set-StrictMode -Version 2.0

function Invoke-DeviceInfoQuery {
    <# Runs one inventory query; on error records a warning and returns $null. #>
    param([string]$Name, [scriptblock]$Query, [System.Collections.Generic.List[string]]$Warnings)
    try { return (& $Query) }
    catch {
        $Warnings.Add(("{0}: {1}" -f $Name, $_.Exception.Message))
        return $null
    }
}

function Get-DeviceInfoValue {
    param($Object, [string]$Property, $Default = 'Unknown')
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Property]
    if ($null -eq $p -or $null -eq $p.Value -or ([string]$p.Value).Trim() -eq '') { return $Default }
    if ($p.Value -is [string]) { return $p.Value.Trim() }
    return $p.Value
}

function Get-OnboardingOsBuild {
    <# Returns the full OS build including the update revision, e.g. 26100.2314. #>
    [CmdletBinding()]
    param()
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $build = [string](Get-DeviceInfoValue $cv 'CurrentBuildNumber' '')
    $ubr = [string](Get-DeviceInfoValue $cv 'UBR' '')
    if ($build -and $ubr) { return "$build.$ubr" }
    if ($build) { return $build }
    return 'Unknown'
}

function Get-OnboardingDeviceInfo {
    <#
        Returns a hashtable (JSON-serialisable, no secrets) describing the device.
    #>
    [CmdletBinding()]
    param()
    $warnings = New-Object System.Collections.Generic.List[string]
    $info = [ordered]@{}

    $cs = Invoke-DeviceInfoQuery 'Computer system' { Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } $warnings
    $bios = Invoke-DeviceInfoQuery 'BIOS' { Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop } $warnings
    $os = Invoke-DeviceInfoQuery 'Operating system' { Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } $warnings
    $cv = Invoke-DeviceInfoQuery 'Windows version registry' { Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } $warnings

    $info['ComputerName'] = $env:COMPUTERNAME
    $info['Manufacturer'] = Get-DeviceInfoValue $cs 'Manufacturer'
    $info['Model'] = Get-DeviceInfoValue $cs 'Model'
    $info['SerialNumber'] = Get-DeviceInfoValue $bios 'SerialNumber'
    $info['BiosVersion'] = Get-DeviceInfoValue $bios 'SMBIOSBIOSVersion'
    $biosDate = Get-DeviceInfoValue $bios 'ReleaseDate' $null
    if ($biosDate -is [datetime]) { $info['BiosReleaseDate'] = $biosDate.ToString('yyyy-MM-dd') } else { $info['BiosReleaseDate'] = 'Unknown' }

    $info['WindowsEdition'] = Get-DeviceInfoValue $os 'Caption'
    $info['WindowsVersion'] = Get-DeviceInfoValue $cv 'DisplayVersion'
    $osBuild = Invoke-DeviceInfoQuery 'OS build' { Get-OnboardingOsBuild } $warnings
    if (-not $osBuild) { $osBuild = 'Unknown' }
    $info['OsBuild'] = $osBuild
    $info['OsArchitecture'] = Get-DeviceInfoValue $os 'OSArchitecture'

    # --- CPU ---
    $cpu = @(Invoke-DeviceInfoQuery 'Processor' { Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop } $warnings)
    if ($cpu.Count -gt 0 -and $null -ne $cpu[0]) {
        $info['Cpu'] = Get-DeviceInfoValue $cpu[0] 'Name'
        $info['CpuCores'] = [int](($cpu | Measure-Object -Property NumberOfCores -Sum).Sum)
        $info['LogicalProcessors'] = [int](($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
    }
    else { $info['Cpu'] = 'Unknown'; $info['CpuCores'] = 0; $info['LogicalProcessors'] = 0 }

    # --- RAM ---
    $ramBytes = Get-DeviceInfoValue $cs 'TotalPhysicalMemory' 0
    $info['RamGB'] = [math]::Round(([double]$ramBytes / 1GB), 1)

    # --- Storage ---
    $disks = @()
    $physical = Invoke-DeviceInfoQuery 'Physical disks' { @(Get-PhysicalDisk -ErrorAction Stop) } $warnings
    if ($physical) {
        foreach ($d in $physical) {
            $disks += @{
                Model        = [string](Get-DeviceInfoValue $d 'FriendlyName')
                MediaType    = [string](Get-DeviceInfoValue $d 'MediaType')
                BusType      = [string](Get-DeviceInfoValue $d 'BusType')
                SizeGB       = [math]::Round(([double](Get-DeviceInfoValue $d 'Size' 0) / 1GB), 1)
                HealthStatus = [string](Get-DeviceInfoValue $d 'HealthStatus')
            }
        }
    }
    else {
        $drives = Invoke-DeviceInfoQuery 'Disk drives' { @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop) } $warnings
        foreach ($d in @($drives)) {
            if ($null -eq $d) { continue }
            $disks += @{
                Model        = [string](Get-DeviceInfoValue $d 'Model')
                MediaType    = [string](Get-DeviceInfoValue $d 'MediaType')
                BusType      = [string](Get-DeviceInfoValue $d 'InterfaceType')
                SizeGB       = [math]::Round(([double](Get-DeviceInfoValue $d 'Size' 0) / 1GB), 1)
                HealthStatus = [string](Get-DeviceInfoValue $d 'Status')
            }
        }
    }
    $info['Storage'] = $disks
    $total = 0.0
    foreach ($d in $disks) { if ($d['BusType'] -ne 'USB') { $total += [double]$d['SizeGB'] } }
    $info['StorageTotalGB'] = [math]::Round($total, 1)

    # --- Battery ---
    $battery = @{ Present = $false; Name = 'Unknown'; DesignCapacity_mWh = $null; FullChargeCapacity_mWh = $null; HealthPercent = $null; ChargePercent = $null }
    $bat = @(Invoke-DeviceInfoQuery 'Battery' { Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop } $warnings)
    if ($bat.Count -gt 0 -and $null -ne $bat[0]) {
        $battery['Present'] = $true
        $battery['Name'] = [string](Get-DeviceInfoValue $bat[0] 'Name')
        $battery['ChargePercent'] = Get-DeviceInfoValue $bat[0] 'EstimatedChargeRemaining' $null
        # Capacity classes are optional (driver dependent); absence is not an error.
        try {
            $static = @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction Stop)
            $full = @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop)
            if ($static.Count -gt 0 -and $full.Count -gt 0) {
                $design = [double]$static[0].DesignedCapacity
                $fullCap = [double]$full[0].FullChargedCapacity
                $battery['DesignCapacity_mWh'] = $design
                $battery['FullChargeCapacity_mWh'] = $fullCap
                if ($design -gt 0) { $battery['HealthPercent'] = [math]::Round(($fullCap / $design) * 100, 1) }
            }
        }
        catch { $warnings.Add('Battery capacity details are not exposed by this device/driver.') }
    }
    $info['Battery'] = $battery

    # --- TPM ---
    $tpm = @{ Present = $false; Enabled = $null; Activated = $null; Owned = $null; SpecVersion = 'Unknown' }
    $t = Invoke-DeviceInfoQuery 'TPM' { Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop } $warnings
    $t = @($t)[0]
    if ($null -ne $t) {
        $tpm['Present'] = $true
        $tpm['Enabled'] = [bool](Get-DeviceInfoValue $t 'IsEnabled_InitialValue' $false)
        $tpm['Activated'] = [bool](Get-DeviceInfoValue $t 'IsActivated_InitialValue' $false)
        $tpm['Owned'] = [bool](Get-DeviceInfoValue $t 'IsOwned_InitialValue' $false)
        $tpm['SpecVersion'] = [string](Get-DeviceInfoValue $t 'SpecVersion')
    }
    $info['Tpm'] = $tpm

    # --- Secure Boot ---
    $secureBoot = 'Unknown'
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { $secureBoot = 'Enabled' } else { $secureBoot = 'Disabled' }
    }
    catch [System.PlatformNotSupportedException] { $secureBoot = 'Not supported (legacy BIOS)' }
    catch { $warnings.Add("Secure Boot: $($_.Exception.Message)") }
    $info['SecureBoot'] = $secureBoot

    # --- Network adapters ---
    $adapters = @()
    $net = Invoke-DeviceInfoQuery 'Network adapters' { @(Get-NetAdapter -Physical -ErrorAction Stop) } $warnings
    foreach ($a in @($net)) {
        if ($null -eq $a) { continue }
        $adapters += @{
            Name        = [string](Get-DeviceInfoValue $a 'Name')
            Description = [string](Get-DeviceInfoValue $a 'InterfaceDescription')
            MacAddress  = [string](Get-DeviceInfoValue $a 'MacAddress')
            Status      = [string](Get-DeviceInfoValue $a 'Status')
            LinkSpeed   = [string](Get-DeviceInfoValue $a 'LinkSpeed')
            MediaType   = [string](Get-DeviceInfoValue $a 'PhysicalMediaType')
        }
    }
    $info['NetworkAdapters'] = $adapters

    $info['CurrentUser'] = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $info['CollectedAt'] = (Get-Date).ToString('o')
    $info['Warnings'] = $warnings.ToArray()

    $result = @{}
    foreach ($k in $info.Keys) { $result[$k] = $info[$k] }
    return $result
}

Export-ModuleMember -Function Get-OnboardingDeviceInfo, Get-OnboardingOsBuild
