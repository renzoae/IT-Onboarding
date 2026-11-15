<#
    GRE IT Onboarding - Part 1 (Pre-Intune preparation)

    Steps
      1 LocalAdmin     interactive, on the UI thread (GUI\Components\LocalAdminDialog.ps1)
      2 DeviceInfo     hardware/OS inventory
      3 WindowsUpdate  scan / install / restart / resume / rescan
      4 AutopilotHash  hardware hash export + CSV validation
      5 Report         HTML + JSON report on the USB
      6 Cleanup        tracked temporary files only

    Part 1 stops after the report. It never enrolls the device and never runs Sysprep.

    Usage
      Part1.ps1 -AppRoot <path> [-Resume]     normal start (via Launcher.ps1)
      . Part1.ps1 -AppRoot <path> -DefineOnly load functions only (background runspace, tests)
#>
[CmdletBinding()]
param(
    [string]$AppRoot,
    [switch]$Resume,
    [switch]$DefineOnly
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
$AppRoot = [System.IO.Path]::GetFullPath($AppRoot)

foreach ($moduleName in @('Configuration', 'Logging', 'Resume', 'LocalAdmin', 'DeviceInfo', 'WindowsUpdate', 'Autopilot', 'Reporting', 'Cleanup')) {
    Import-Module (Join-Path (Join-Path $AppRoot 'Modules') "$moduleName.psm1") -Force -DisableNameChecking
}

# ---------------------------------------------------------------------------
# Step catalogue
# ---------------------------------------------------------------------------
function Get-Part1StepDefinition {
    <#
        Ordered list of Part 1 steps.
          Interactive    handled by the GUI thread, not by the background workflow
          AlwaysRun      cheap/refreshing step that runs again even when completed
          StopOnFailure  later steps cannot work without it
          RequiresAll    runs only when every earlier step is Completed
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ Name = 'LocalAdmin';    Title = '1. Local administrator account'; Interactive = $true;  AlwaysRun = $false; StopOnFailure = $true;  RequiresAll = $false }
        [pscustomobject]@{ Name = 'DeviceInfo';    Title = '2. Device information';          Interactive = $false; AlwaysRun = $true;  StopOnFailure = $true;  RequiresAll = $false }
        [pscustomobject]@{ Name = 'WindowsUpdate'; Title = '3. Windows Update';              Interactive = $false; AlwaysRun = $false; StopOnFailure = $false; RequiresAll = $false }
        [pscustomobject]@{ Name = 'AutopilotHash'; Title = '4. Autopilot hardware hash';     Interactive = $false; AlwaysRun = $false; StopOnFailure = $false; RequiresAll = $false }
        [pscustomobject]@{ Name = 'Report';        Title = '5. Part 1 report';               Interactive = $false; AlwaysRun = $true;  StopOnFailure = $false; RequiresAll = $false }
        [pscustomobject]@{ Name = 'Cleanup';       Title = '6. Cleanup';                     Interactive = $false; AlwaysRun = $true;  StopOnFailure = $false; RequiresAll = $true }
    )
}

function New-Part1StepResult {
    param([string]$Status, [string]$Message = '', [hashtable]$Data = @{})
    return @{ Status = $Status; Message = $Message; Data = $Data }
}

# ---------------------------------------------------------------------------
# Step implementations (background runspace). Each returns New-Part1StepResult.
# ---------------------------------------------------------------------------
function Invoke-Part1DeviceInfoStep {
    param([hashtable]$Context, [hashtable]$State, $Sync)
    $device = Get-OnboardingDeviceInfo
    foreach ($w in @($device['Warnings'])) { if ($w) { Write-OnboardingLog -Step 'DeviceInfo' -Level WARN -Message $w } }
    if ($null -ne $Sync) { $Sync.Queue.Enqueue(@{ Type = 'Device'; Data = $device }) }
    Write-OnboardingLog -Step 'DeviceInfo' -Message ("{0} {1}, serial {2}, {3} {4} build {5}" -f $device['Manufacturer'], $device['Model'], $device['SerialNumber'], $device['WindowsEdition'], $device['WindowsVersion'], $device['OsBuild'])
    $missing = @()
    foreach ($key in @('Manufacturer', 'Model', 'SerialNumber')) { if ($device[$key] -eq 'Unknown') { $missing += $key } }
    if ($missing.Count -gt 0) {
        return (New-Part1StepResult 'Failed' ("Could not detect: {0}. See the log for the underlying WMI error." -f ($missing -join ', ')) @{ Device = $device })
    }
    return (New-Part1StepResult 'Completed' 'Device information collected and saved to the session report.' @{ Device = $device })
}

function Invoke-Part1WindowsUpdateStep {
    param([hashtable]$Context, [hashtable]$State, $Sync)
    $settings = $Context.Settings['WindowsUpdate']
    $data = Get-OnboardingStepData -State $State -Name 'WindowsUpdate'
    foreach ($k in @('Installed', 'Failed', 'Excluded', 'Remaining')) { if (-not $data.ContainsKey($k) -or $null -eq $data[$k]) { $data[$k] = @() } }
    if (-not $data.ContainsKey('RestartCycles')) { $data['RestartCycles'] = 0 }
    if (-not $data.ContainsKey('BootTimeAtRestartRequest')) { $data['BootTimeAtRestartRequest'] = '' }

    # A restart was requested earlier: do nothing until Windows has actually restarted.
    $bootTime = ''
    try { $bootTime = Get-OnboardingLastBootTime } catch { }
    if ($data['BootTimeAtRestartRequest'] -and $bootTime -and ($data['BootTimeAtRestartRequest'] -eq $bootTime) -and (Test-WindowsUpdateRestartPending)) {
        return (New-Part1StepResult 'RestartRequired' 'Windows has not been restarted yet. Restart to continue installing updates.' $data)
    }

    Write-OnboardingLog -Step 'WindowsUpdate' -Message 'Checking internet connectivity.'
    $net = Test-OnboardingInternetConnectivity -ProbeUrls @($Context.Settings['Connectivity']['ProbeUrls']) -TimeoutSeconds ([int]$Context.Settings['Connectivity']['TimeoutSeconds'])
    foreach ($d in @($net.Details)) { Write-OnboardingLog -Step 'WindowsUpdate' -Level DEBUG -Message "Connectivity probe - $d" }
    if (-not $net.Connected) {
        return (New-Part1StepResult 'Failed' 'No internet connectivity. Connect the laptop to a network (Wi-Fi or Ethernet) and retry.' $data)
    }

    $progress = { param($pct, $text) if ($null -ne $Sync) { $Sync.Queue.Enqueue(@{ Type = 'Progress'; Percent = $pct; Text = $text }) } }
    $cycle = Invoke-WindowsUpdateCycle -IncludeDrivers ([bool]$settings['IncludeDrivers']) -IncludeFeatureUpgrades ([bool]$settings['IncludeFeatureUpgrades']) `
        -AcceptEulas ([bool]$settings['AcceptEulas']) -MaxPasses ([int]$settings['MaxPassesPerBoot']) -ProgressCallback $progress

    foreach ($i in @($cycle['Installed'])) { Write-OnboardingLog -Step 'WindowsUpdate' -Level SUCCESS -Message ("Installed: {0} {1}" -f $i['KB'], $i['Title']) }
    foreach ($i in @($cycle['Failed'])) { Write-OnboardingLog -Step 'WindowsUpdate' -Level ERROR -Message ("Failed: {0} {1} - {2}" -f $i['KB'], $i['Title'], $i['Message']) }
    foreach ($i in @($cycle['Excluded'])) { Write-OnboardingLog -Step 'WindowsUpdate' -Level WARN -Message ("Not installed: {0} {1} - {2}" -f $i['KB'], $i['Title'], $i['Reason']) }

    $data['Installed'] = @($data['Installed']) + @($cycle['Installed'])
    $data['Failed'] = @($cycle['Failed'])
    $data['Excluded'] = @($cycle['Excluded'])
    $data['Remaining'] = @($cycle['Remaining'])
    $data['LastScan'] = (Get-Date).ToString('o')
    $warnings = @()
    foreach ($i in @($cycle['Excluded'])) { $warnings += ("Not installed: {0} ({1})" -f $i['Title'], $i['Reason']) }
    $data['Warnings'] = $warnings

    switch ($cycle['Status']) {
        'UpToDate' {
            $data['FinalBuild'] = Get-OnboardingOsBuild
            $data['BootTimeAtRestartRequest'] = ''
            $message = "{0} Final OS build: {1}. Updates installed in this session: {2}." -f $cycle['Message'], $data['FinalBuild'], @($data['Installed']).Count
            if (@($cycle['Excluded']).Count -gt 0) { $message += " {0} update(s) were intentionally not installed (see warnings)." -f @($cycle['Excluded']).Count }
            return (New-Part1StepResult 'Completed' $message $data)
        }
        'RestartRequired' {
            if ([int]$data['RestartCycles'] -ge [int]$settings['MaxRestartCycles']) {
                return (New-Part1StepResult 'Failed' ("Windows still requests a restart after {0} restart cycles. Check Windows Update manually (Settings > Windows Update), then retry." -f $data['RestartCycles']) $data)
            }
            $data['RestartCycles'] = [int]$data['RestartCycles'] + 1
            $data['BootTimeAtRestartRequest'] = $bootTime
            return (New-Part1StepResult 'RestartRequired' ([string]$cycle['Message']) $data)
        }
        default {
            # ScanFailed / Failed / Incomplete: never reported as up to date.
            return (New-Part1StepResult 'Failed' ("Windows Update is NOT verified as up to date: {0}" -f $cycle['Message']) $data)
        }
    }
}

function Invoke-Part1AutopilotStep {
    param([hashtable]$Context, [hashtable]$State, $Sync)
    $settings = $Context.Settings['Autopilot']
    $hw = Get-AutopilotHardwareHash
    $path = $null
    try {
        $path = Export-AutopilotHardwareHashCsv -SerialNumber $hw['SerialNumber'] -HardwareHash $hw['HardwareHash'] `
            -Directory $Context.HardwareHashDir -GroupTag ([string]$settings['GroupTag'])
    }
    finally { $hw['HardwareHash'] = $null }

    $check = Test-AutopilotCsv -Path $path -ExpectedSerialNumber $hw['SerialNumber'] -MinimumHashLength ([int]$settings['MinimumHashLength'])
    if (-not $check.IsValid) {
        return (New-Part1StepResult 'Failed' ('The exported CSV failed validation: ' + ($check.Errors -join ' ')) @{ FileName = (Split-Path -Leaf $path) })
    }
    $protect = Protect-AutopilotExport -Path $path
    $data = @{ FileName = (Split-Path -Leaf $path); AccessRestricted = [bool]$protect['Protected']; Warnings = @() }
    if (-not $protect['Protected']) {
        $data['Warnings'] = @($protect['Message'])
        Write-OnboardingLog -Step 'AutopilotHash' -Level WARN -Message $protect['Message']
    }
    return (New-Part1StepResult 'Completed' ("Exported and validated: Reports\HardwareHash\{0}" -f $data['FileName']) $data)
}

function Invoke-Part1ReportStep {
    param([hashtable]$Context, [hashtable]$State, $Sync)
    $definitions = @(Get-Part1StepDefinition | Where-Object { $_.Name -notin @('Report', 'Cleanup') })
    $titles = @{}
    foreach ($d in $definitions) { $titles[$d.Name] = $d.Title }
    $device = @{}
    $deviceData = Get-OnboardingStepData -State $State -Name 'DeviceInfo'
    if ($deviceData.ContainsKey('Device') -and $deviceData['Device'] -is [hashtable]) { $device = $deviceData['Device'] }

    $model = New-Part1ReportModel -State $State -DeviceInfo $device -Settings $Context.Settings -StepOrder @($definitions | ForEach-Object { $_.Name }) -StepTitles $titles
    $files = Export-Part1Report -Model $model -Directory $Context.Part1ReportDir -Stamp $Context.SessionStamp
    return (New-Part1StepResult 'Completed' ("Report saved: Reports\Part1\{0} (overall: {1})" -f (Split-Path -Leaf $files['HtmlPath']), $model['OverallStatus']) @{ HtmlPath = $files['HtmlPath']; JsonPath = $files['JsonPath']; Overall = $model['OverallStatus'] })
}

function Invoke-Part1CleanupStep {
    param([hashtable]$Context, [hashtable]$State, $Sync)
    # Paths are rebuilt from the current application root: the USB drive letter may have changed.
    $csv = ''
    $csvName = [string](Get-OnboardingStepData -State $State -Name 'AutopilotHash')['FileName']
    if ($csvName) { $csv = Join-Path $Context.HardwareHashDir $csvName }
    $report = [string](Get-OnboardingStepData -State $State -Name 'Report')['HtmlPath']
    $result = Invoke-OnboardingPart1Cleanup -AppRoot $Context.AppRoot -HardwareHashPath $csv -ReportPath $report
    foreach ($r in @($result['Refused'])) { Write-OnboardingLog -Step 'Cleanup' -Level WARN -Message "Refused to delete: $r" }
    foreach ($e in @($result['Errors'])) { Write-OnboardingLog -Step 'Cleanup' -Level ERROR -Message $e }
    if (-not $result['Success']) { return (New-Part1StepResult 'Failed' ([string]$result['Message'])) }
    # The restart-resume mechanism is temporary: remove it now that Part 1 is done.
    Unregister-OnboardingResumeTask -Part 1
    return (New-Part1StepResult 'Completed' ([string]$result['Message']))
}

# ---------------------------------------------------------------------------
# Workflow engine (runs in the background runspace)
# ---------------------------------------------------------------------------
function Invoke-Part1Workflow {
    <#
        Runs every non-interactive Part 1 step in order, skipping work that is
        already verified as completed. Returns the overall status string:
        Completed | RestartRequired | Incomplete
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        $Sync
    )
    $queue = $null
    if ($null -ne $Sync) { $queue = $Sync.Queue }
    $post = { param($m) if ($null -ne $queue) { $queue.Enqueue($m) } }
    if ($Context.LogFile) {
        Initialize-OnboardingLog -PrimaryDirectory $Context.LogDirectory -FallbackDirectory $Context.LocalLogDirectory `
            -FileName (Split-Path -Leaf $Context.LogFile) -UiQueue $queue | Out-Null
    }

    $state = Get-OnboardingState -Part 1
    if ($null -eq $state) { throw 'No Part 1 session state was found. Start Part 1 from the application window.' }
    if (-not (Test-OnboardingStepCompleted -State $state -Name 'LocalAdmin')) {
        throw 'The local administrator step has not been completed and verified. Part 1 cannot continue.'
    }

    $definitions = @(Get-Part1StepDefinition)
    # Resolved by name at call time (keeps the steps individually replaceable/mocked in tests).
    $actions = @{
        DeviceInfo    = 'Invoke-Part1DeviceInfoStep'
        WindowsUpdate = 'Invoke-Part1WindowsUpdateStep'
        AutopilotHash = 'Invoke-Part1AutopilotStep'
        Report        = 'Invoke-Part1ReportStep'
        Cleanup       = 'Invoke-Part1CleanupStep'
    }
    $overall = 'Incomplete'
    $halt = $false

    for ($i = 0; $i -lt $definitions.Count; $i++) {
        $def = $definitions[$i]
        if ($def.Interactive) { continue }
        $name = $def.Name

        if ($halt) { continue }
        $rerun = $def.AlwaysRun
        if ($name -eq 'AutopilotHash' -and (Test-OnboardingStepCompleted -State $state -Name $name)) {
            # Re-verify the deliverable instead of trusting the checkpoint (USB swapped / file removed).
            $csvName = [string](Get-OnboardingStepData -State $state -Name $name)['FileName']
            if (-not $csvName -or -not (Test-Path -LiteralPath (Join-Path $Context.HardwareHashDir $csvName) -PathType Leaf)) {
                Write-OnboardingLog -Step $name -Level WARN -Message 'The hardware hash CSV recorded earlier is no longer on the USB drive; exporting it again.'
                $rerun = $true
            }
        }
        if ((Test-OnboardingStepCompleted -State $state -Name $name) -and -not $rerun) {
            Write-OnboardingLog -Step $name -Message 'Already completed in this session; skipping.'
            & $post @{ Type = 'Step'; Name = $name; Status = 'Completed'; Message = [string]$state['Steps'][$name]['Message'] }
            continue
        }
        if ($def.RequiresAll) {
            $blocked = @($definitions[0..($i - 1)] | Where-Object { -not (Test-OnboardingStepCompleted -State $state -Name $_.Name) } | ForEach-Object { $_.Title })
            if ($blocked.Count -gt 0) {
                $text = 'Not run: waiting for ' + ($blocked -join '; ') + '. Diagnostic files were preserved.'
                Set-OnboardingStepState -State $state -Name $name -Status 'Skipped' -Message $text
                & $post @{ Type = 'Step'; Name = $name; Status = 'Skipped'; Message = $text }
                Write-OnboardingLog -Step $name -Level WARN -Message $text
                continue
            }
        }

        Set-OnboardingStepState -State $state -Name $name -Status 'Running' -Message 'In progress...'
        & $post @{ Type = 'Step'; Name = $name; Status = 'Running'; Message = 'In progress...' }
        Write-OnboardingLog -Step $name -Message "Starting: $($def.Title)"

        $result = $null
        try {
            $result = & $actions[$name] -Context $Context -State $state -Sync $Sync
            if ($result -is [array]) { $result = $result[-1] }   # ignore stray pipeline output
            if ($null -eq $result -or -not ($result -is [hashtable]) -or -not $result.ContainsKey('Status')) { throw 'The task returned no result.' }
        }
        catch {
            $result = New-Part1StepResult 'Failed' ("{0}" -f $_.Exception.Message)
        }

        $data = $result['Data']
        if ($null -eq $data -or $data.Count -eq 0) { $data = $null }   # keep earlier data when the step returned none
        Set-OnboardingStepState -State $state -Name $name -Status $result['Status'] -Message $result['Message'] -Data $data
        & $post @{ Type = 'Step'; Name = $name; Status = $result['Status']; Message = $result['Message'] }
        & $post @{ Type = 'StepDone'; Name = $name }

        switch ($result['Status']) {
            'Completed' { Write-OnboardingLog -Step $name -Level SUCCESS -Message $result['Message'] }
            'RestartRequired' {
                Write-OnboardingLog -Step $name -Level WARN -Message $result['Message']
                $overall = 'RestartRequired'
                $halt = $true     # checkpoint is saved; nothing else runs until after the restart
            }
            default {
                Write-OnboardingLog -Step $name -Level ERROR -Message $result['Message']
                if ($def.StopOnFailure) { $halt = $true }
            }
        }
    }

    if ($overall -ne 'RestartRequired') {
        $allDone = $true
        foreach ($def in $definitions) { if (-not (Test-OnboardingStepCompleted -State $state -Name $def.Name)) { $allDone = $false } }
        if ($allDone) {
            $state['Completed'] = $true
            $state['CompletedAt'] = (Get-Date).ToString('o')
            Save-OnboardingState -State $state
            $overall = 'Completed'
            Write-OnboardingLog -Level SUCCESS -Message ("PART 1 COMPLETED {0} READY FOR INTUNE. The device was not enrolled and Sysprep was not run." -f [char]0x2014)
        }
        else {
            Write-OnboardingLog -Level WARN -Message 'Part 1 is INCOMPLETE. Review the failed tasks, fix the cause and choose Retry. Diagnostic information was preserved.'
        }
    }
    return $overall
}

if ($DefineOnly) { return }

# ---------------------------------------------------------------------------
# Interactive entry point (UI thread)
# ---------------------------------------------------------------------------
$exitCode = 1
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    $context = New-OnboardingContext -AppRoot $AppRoot -Part 1
    [void](Initialize-OnboardingLocalRoot)
    foreach ($dir in @($context.LogDirectory, $context.HardwareHashDir, $context.Part1ReportDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    $context.LogFile = Join-Path $context.LogDirectory ('Part1_{0}_{1}.log' -f $env:COMPUTERNAME, $context.SessionStamp)

    . (Join-Path $context.GuiRoot 'MainWindow.ps1')
    . (Join-Path (Join-Path $context.GuiRoot 'Components') 'LocalAdminDialog.ps1')

    $exitCode = [int]@(Show-OnboardingMainWindow -Context $context -StepDefinitions @(Get-Part1StepDefinition) `
            -WorkflowScriptPath $PSCommandPath -AutoStart:$Resume)[-1]
}
catch {
    $text = "GRE IT Onboarding (Part 1) stopped because of an unexpected error:`n`n$($_.Exception.Message)"
    try { Write-OnboardingLog -Level ERROR -Message ("{0} | {1}" -f $_.Exception.Message, $_.ScriptStackTrace) } catch { }
    Write-Host $text
    try { [void][System.Windows.MessageBox]::Show($text, 'GRE IT Onboarding', 'OK', 'Error') } catch { }
    $exitCode = 1
}
exit $exitCode
