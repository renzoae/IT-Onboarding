<#
    GRE IT Onboarding - Windows Update module
    Uses the built-in Windows Update Agent (WUA) COM API. The default search
    honours the update source configured by the organization (WSUS / Windows
    Update for Business / Microsoft Update) - this module does not change it.

    Honesty rules:
      * 'UpToDate' is returned ONLY after a successful scan that found no
        applicable updates and with no restart pending.
      * Feature upgrades are excluded unless explicitly enabled in Settings.json.
      * Excluded/failed/remaining updates are always reported.
#>
Set-StrictMode -Version 2.0

$script:UpgradeCategoryId = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'   # WUA "Upgrades" classification
$script:ResultCodeText = @{ 0 = 'NotStarted'; 1 = 'InProgress'; 2 = 'Succeeded'; 3 = 'SucceededWithErrors'; 4 = 'Failed'; 5 = 'Aborted' }

function Test-OnboardingInternetConnectivity {
    <# Probes the configured URLs. Connected = at least one probe answered. #>
    [CmdletBinding()]
    param(
        [string[]]$ProbeUrls = @('http://www.msftconnecttest.com/connecttest.txt'),
        [int]$TimeoutSeconds = 10
    )
    $details = @()
    $connected = $false
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
    foreach ($url in $ProbeUrls) {
        if (-not $url) { continue }
        $response = $null
        try {
            $request = [System.Net.WebRequest]::Create($url)
            $request.Timeout = $TimeoutSeconds * 1000
            $request.Method = 'GET'
            $response = $request.GetResponse()
            $details += ('{0}: reachable' -f $url)
            $connected = $true
        }
        catch [System.Net.WebException] {
            # An HTTP error status still proves the network path works.
            if ($null -ne $_.Exception.Response) {
                $details += ('{0}: reachable (HTTP error status)' -f $url)
                $connected = $true
            }
            else { $details += ('{0}: {1}' -f $url, $_.Exception.Message) }
        }
        catch { $details += ('{0}: {1}' -f $url, $_.Exception.Message) }
        finally { if ($null -ne $response) { $response.Close() } }
        if ($connected) { break }
    }
    return [pscustomobject]@{ Connected = $connected; Details = $details }
}

function Test-WindowsUpdateRestartPending {
    <# True when Windows Update / servicing reports that a restart is required. #>
    [CmdletBinding()]
    param()
    $pending = $false
    try {
        $sys = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($sys.RebootRequired) { $pending = $true }
    }
    catch { }
    foreach ($key in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        if (Test-Path -LiteralPath $key) { $pending = $true }
    }
    return $pending
}

function Get-OnboardingLastBootTime {
    [CmdletBinding()]
    param()
    return (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToString('o')
}

function Get-PendingWindowsUpdate {
    <#
        Scans for applicable, not-installed updates.
        Returns @{ Success; Message; Applicable = @(items); Excluded = @(items) }
        where each item is @{ Title; KB; Reason; Update (COM object, Applicable only) }.
    #>
    [CmdletBinding()]
    param([bool]$IncludeDrivers = $false, [bool]$IncludeFeatureUpgrades = $false)
    $result = @{ Success = $false; Message = ''; Applicable = @(); Excluded = @() }
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'GRE IT Onboarding'
        $searcher = $session.CreateUpdateSearcher()
        $criteria = 'IsInstalled=0 and IsHidden=0'
        if (-not $IncludeDrivers) { $criteria += " and Type='Software'" }
        $search = $searcher.Search($criteria)
        $code = [int]$search.ResultCode
        if ($code -ne 2 -and $code -ne 3) {
            $result.Message = "Windows Update scan did not succeed (result: $($script:ResultCodeText[$code]))."
            return $result
        }
        foreach ($u in $search.Updates) {
            $kb = ''
            try { if ($u.KBArticleIDs.Count -gt 0) { $kb = 'KB' + $u.KBArticleIDs.Item(0) } } catch { }
            $isUpgrade = $false
            try { foreach ($c in $u.Categories) { if ($c.CategoryID -eq $script:UpgradeCategoryId) { $isUpgrade = $true } } } catch { }
            $needsInput = $false
            try { $needsInput = [bool]$u.InstallationBehavior.CanRequestUserInput } catch { }

            if ($isUpgrade -and -not $IncludeFeatureUpgrades) {
                $result.Excluded += @{ Title = [string]$u.Title; KB = $kb; Reason = 'Feature upgrade (excluded by onboarding policy)' }
            }
            elseif ($needsInput) {
                $result.Excluded += @{ Title = [string]$u.Title; KB = $kb; Reason = 'Requires user interaction - install manually' }
            }
            else {
                $result.Applicable += @{ Title = [string]$u.Title; KB = $kb; Reason = ''; Update = $u }
            }
        }
        $result.Success = $true
        if ($code -eq 3) { $result.Message = 'Scan succeeded with warnings.' }
    }
    catch {
        $result.Message = "Windows Update scan failed: $($_.Exception.Message)"
    }
    return $result
}

function Install-WindowsUpdateItem {
    <#
        Downloads and installs ONE update. Returns
        @{ Title; KB; Success; RebootRequired; Message }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Item, [bool]$AcceptEulas = $true)
    $out = @{ Title = $Item['Title']; KB = $Item['KB']; Success = $false; RebootRequired = $false; Message = '' }
    try {
        $u = $Item['Update']
        if (-not $u.EulaAccepted) {
            if ($AcceptEulas) { $u.AcceptEula() }
            else { $out.Message = 'License terms not accepted (AcceptEulas is disabled in Settings.json).'; return $out }
        }
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'GRE IT Onboarding'
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$coll.Add($u)

        if (-not $u.IsDownloaded) {
            $downloadOk = $false
            $lastCode = 0
            for ($attempt = 1; $attempt -le 2 -and -not $downloadOk; $attempt++) {   # one retry for transient failures
                $downloader = $session.CreateUpdateDownloader()
                $downloader.Updates = $coll
                $dl = $downloader.Download()
                $lastCode = [int]$dl.ResultCode
                if ($lastCode -eq 2 -or $lastCode -eq 3) { $downloadOk = $true } else { Start-Sleep -Seconds 5 }
            }
            if (-not $downloadOk) { $out.Message = "Download failed (result: $($script:ResultCodeText[$lastCode]))."; return $out }
        }

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $coll
        $ir = $installer.Install()
        $code = [int]$ir.ResultCode
        $out.RebootRequired = [bool]$ir.RebootRequired
        if ($code -eq 2 -or $code -eq 3) {
            $out.Success = $true
            $out.Message = $script:ResultCodeText[$code]
        }
        else {
            $out.Message = 'Install failed (result: {0}, HRESULT: 0x{1:X8}).' -f $script:ResultCodeText[$code], [int]$ir.HResult
        }
    }
    catch {
        $out.Message = "Install error: $($_.Exception.Message)"
    }
    return $out
}

function Invoke-WindowsUpdateCycle {
    <#
        Scan -> install -> rescan loop for the current boot.
        Status values:
          UpToDate        verified by a clean rescan, no restart pending
          RestartRequired a restart is needed before updating can continue/finish
          ScanFailed      Windows Update could not be scanned (nothing is claimed)
          Failed          every applicable update in a pass failed to install
          Incomplete      updates still remain after MaxPasses
    #>
    [CmdletBinding()]
    param(
        [bool]$IncludeDrivers = $false,
        [bool]$IncludeFeatureUpgrades = $false,
        [bool]$AcceptEulas = $true,
        [ValidateRange(1, 10)][int]$MaxPasses = 3,
        [scriptblock]$ProgressCallback
    )
    $installed = @(); $failed = @(); $excluded = @(); $remaining = @()
    $report = { param($pct, $text) if ($ProgressCallback) { try { & $ProgressCallback $pct $text } catch { } } }
    $finish = {
        param($status, $message)
        return @{
            Status = $status; Message = $message; Installed = $installed; Failed = $failed
            Excluded = $excluded; Remaining = $remaining
        }
    }

    if (Test-WindowsUpdateRestartPending) {
        return (& $finish 'RestartRequired' 'A restart is already pending. Restart before installing updates.')
    }

    for ($pass = 1; $pass -le $MaxPasses; $pass++) {
        & $report 5 "Scanning Windows Update (pass $pass of $MaxPasses)..."
        $scan = Get-PendingWindowsUpdate -IncludeDrivers $IncludeDrivers -IncludeFeatureUpgrades $IncludeFeatureUpgrades
        if (-not $scan['Success']) { return (& $finish 'ScanFailed' $scan['Message']) }
        $excluded = @($scan['Excluded'] | ForEach-Object { @{ Title = $_['Title']; KB = $_['KB']; Reason = $_['Reason'] } })
        $applicable = @($scan['Applicable'])
        $remaining = @($applicable | ForEach-Object { @{ Title = $_['Title']; KB = $_['KB'] } })

        if ($applicable.Count -eq 0) {
            if (Test-WindowsUpdateRestartPending) {
                return (& $finish 'RestartRequired' 'Updates were installed; a restart is required to finish.')
            }
            return (& $finish 'UpToDate' 'Verified: a Windows Update scan found no applicable updates and no restart is pending.')
        }

        $restart = $false
        $successThisPass = 0
        $index = 0
        foreach ($item in $applicable) {
            $index++
            & $report ([int](10 + (80 * $index / $applicable.Count))) ("Installing update {0} of {1}: {2}" -f $index, $applicable.Count, $item['Title'])
            $r = Install-WindowsUpdateItem -Item $item -AcceptEulas $AcceptEulas
            $entry = @{ Title = $r['Title']; KB = $r['KB']; Message = $r['Message'] }
            if ($r['Success']) { $installed += $entry; $successThisPass++ } else { $failed += $entry }
            if ($r['RebootRequired']) { $restart = $true }
        }
        $remaining = @()

        if ($restart -or (Test-WindowsUpdateRestartPending)) {
            return (& $finish 'RestartRequired' 'Updates were installed; a restart is required to continue.')
        }
        if ($successThisPass -eq 0) {
            $remaining = @($applicable | ForEach-Object { @{ Title = $_['Title']; KB = $_['KB'] } })
            return (& $finish 'Failed' ("{0} applicable update(s) failed to install. See the log for each result." -f $applicable.Count))
        }
    }

    # MaxPasses reached without a clean scan: say so, do not claim success.
    $scan = Get-PendingWindowsUpdate -IncludeDrivers $IncludeDrivers -IncludeFeatureUpgrades $IncludeFeatureUpgrades
    if ($scan['Success']) {
        $remaining = @($scan['Applicable'] | ForEach-Object { @{ Title = $_['Title']; KB = $_['KB'] } })
        if ($remaining.Count -eq 0 -and -not (Test-WindowsUpdateRestartPending)) {
            return (& $finish 'UpToDate' 'Verified: a Windows Update scan found no applicable updates and no restart is pending.')
        }
    }
    return (& $finish 'Incomplete' ("Updates still remain after {0} passes. Run the Windows Update task again." -f $MaxPasses))
}

Export-ModuleMember -Function Test-OnboardingInternetConnectivity, Test-WindowsUpdateRestartPending, Get-OnboardingLastBootTime,
    Get-PendingWindowsUpdate, Install-WindowsUpdateItem, Invoke-WindowsUpdateCycle
