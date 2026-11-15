<#
    GRE IT Onboarding - Main window (GUI layer)
    Dot-sourced by Scripts\Part1.ps1.

    Threading model
      * The WPF window lives on the STA UI thread.
      * Long-running work (device inventory, Windows Update, Autopilot export,
        reporting, cleanup) runs in a background runspace.
      * The background runspace never touches WPF objects. It posts messages to
        a ConcurrentQueue; a DispatcherTimer on the UI thread drains the queue
        and updates the controls. That keeps every UI update thread-safe.
      * The local administrator dialog runs on the UI thread BEFORE the
        background workflow starts, so the SecureString never leaves it.
#>

function Import-OnboardingXaml {
    <# Loads a XAML file into a WPF object (works for Window roots without x:Class). #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "GUI file not found: $Path" }
    $reader = [System.Xml.XmlReader]::Create($Path)
    try { return [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
}

function Get-OnboardingStatusBrush {
    param([string]$Status)
    $color = '#9AA5B1'
    switch ($Status) {
        'Running' { $color = '#1E6FD9' }
        'Completed' { $color = '#1E9E57' }
        'Failed' { $color = '#D64545' }
        'RestartRequired' { $color = '#E0A100' }
        'Skipped' { $color = '#9AA5B1' }
    }
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
}

function Show-OnboardingMainWindow {
    <#
        Shows the main window for Part 1 and returns a process exit code:
          0  Part 1 completed          3  closed with Part 1 incomplete
          10 restart initiated/pending 1  unexpected GUI error
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][object[]]$StepDefinitions,
        [Parameter(Mandatory = $true)][string]$WorkflowScriptPath,
        [switch]$AutoStart
    )
    $window = Import-OnboardingXaml -Path (Join-Path $Context.GuiRoot 'MainWindow.xaml')
    $find = { param($n) $window.FindName($n) }
    $dash = [string][char]0x2014

    $ui = @{
        Running      = $false
        ExitCode     = 3
        Sync         = @{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') }
        PowerShell   = $null
        Runspace     = $null
        Handle       = $null
        StepRows     = @{}
        ReportPath   = $null
        StepPercent  = 0
    }
    $ui.Sync = [hashtable]::Synchronized($ui.Sync)

    # ---- navigation -------------------------------------------------------
    $pages = @{
        NavDashboard = 'PageDashboard'; NavPart1 = 'PagePart1'; NavPart2 = 'PagePart2'; NavSoftware = 'PageSoftware'
        NavHardware = 'PageHardware'; NavSecurity = 'PageSecurity'; NavReports = 'PageReports'; NavSettings = 'PageSettings'
    }
    $showPage = {
        param($pageName)
        foreach ($p in $pages.Values) {
            $element = & $find $p
            if ($p -eq $pageName) { $element.Visibility = 'Visible' } else { $element.Visibility = 'Collapsed' }
        }
    }
    foreach ($navName in @($pages.Keys)) {
        $nav = & $find $navName
        $nav.Tag = $pages[$navName]
        $nav.Add_Checked({ param($source, $eventArgs) & $showPage ([string]$source.Tag) })
    }

    # ---- static texts -----------------------------------------------------
    (& $find 'SidebarFooter').Text = "Running from: $($Context.AppRoot)"
    (& $find 'ReportsPathText').Text = "Reports are saved on the USB drive under:`n$($Context.ReportsRoot)`n`nHardware hash CSV files: Reports\HardwareHash (sensitive - hand over to the Intune administrator only)."
    (& $find 'SettingsText').Text = (ConvertTo-Json -InputObject $Context.Settings -Depth 6)
    (& $find 'OpenReportsFolderButton').Add_Click({ if (Test-Path -LiteralPath $Context.ReportsRoot) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Context.ReportsRoot) } })
    (& $find 'OpenLogsFolderButton').Add_Click({ if (Test-Path -LiteralPath $Context.LogDirectory) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Context.LogDirectory) } })

    $startButton = & $find 'Part1StartButton'
    $newSessionButton = & $find 'Part1NewSessionButton'
    $openReportButton = & $find 'Part1OpenReportButton'
    $technicianBox = & $find 'TechnicianBox'
    $logList = & $find 'Part1Log'
    $banner = & $find 'Part1Banner'
    $bannerText = & $find 'Part1BannerText'
    $progress = & $find 'Part1Progress'
    $progressText = & $find 'Part1ProgressText'
    $technicianBox.Text = [string]$Context.Settings['Reporting']['DefaultTechnicianName']

    # ---- step rows --------------------------------------------------------
    $stepsPanel = & $find 'Part1Steps'
    foreach ($def in $StepDefinitions) {
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = '0,3,0,3'
        foreach ($w in @('26', '230', '130', '*', 'Auto')) {
            $col = New-Object System.Windows.Controls.ColumnDefinition
            if ($w -eq '*') { $col.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
            elseif ($w -eq 'Auto') { $col.Width = [System.Windows.GridLength]::Auto }
            else { $col.Width = [System.Windows.GridLength]::new([double]$w) }
            $grid.ColumnDefinitions.Add($col)
        }
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 14; $dot.Height = 14; $dot.VerticalAlignment = 'Center'; $dot.HorizontalAlignment = 'Left'
        $dot.Fill = Get-OnboardingStatusBrush 'Pending'
        $titleBlock = New-Object System.Windows.Controls.TextBlock
        $titleBlock.Text = [string]$def.Title; $titleBlock.FontWeight = 'SemiBold'; $titleBlock.VerticalAlignment = 'Center'
        $statusBlock = New-Object System.Windows.Controls.TextBlock
        $statusBlock.Text = 'Pending'; $statusBlock.VerticalAlignment = 'Center'
        $messageBlock = New-Object System.Windows.Controls.TextBlock
        $messageBlock.TextTrimming = 'CharacterEllipsis'; $messageBlock.VerticalAlignment = 'Center'
        $messageBlock.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#5B6B7F')
        $retry = New-Object System.Windows.Controls.Button
        $retry.Content = 'Retry'; $retry.Padding = '10,2'; $retry.Margin = '8,0,0,0'; $retry.Visibility = 'Collapsed'
        $i = 0
        foreach ($child in @($dot, $titleBlock, $statusBlock, $messageBlock, $retry)) {
            [System.Windows.Controls.Grid]::SetColumn($child, $i); $i++
            [void]$grid.Children.Add($child)
        }
        [void]$stepsPanel.Children.Add($grid)
        $ui.StepRows[[string]$def.Name] = @{ Dot = $dot; Status = $statusBlock; Message = $messageBlock; Retry = $retry }
    }

    $setStep = {
        param([string]$name, [string]$status, [string]$message)
        if (-not $ui.StepRows.ContainsKey($name)) { return }
        $row = $ui.StepRows[$name]
        $row.Dot.Fill = Get-OnboardingStatusBrush $status
        $label = $status
        if ($status -eq 'RestartRequired') { $label = 'Restart required' }
        $row.Status.Text = $label
        $row.Message.Text = $message
        $row.Message.ToolTip = $message
        if ($status -eq 'Failed' -and -not $ui.Running) { $row.Retry.Visibility = 'Visible' } else { $row.Retry.Visibility = 'Collapsed' }
    }

    $addLog = {
        param([string]$text, [string]$level)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $color = '#C9D6E5'
        switch ($level) { 'ERROR' { $color = '#FF8A8A' } 'WARN' { $color = '#FFD479' } 'SUCCESS' { $color = '#7DE3A8' } }
        $tb.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
        [void]$logList.Items.Add($tb)
        while ($logList.Items.Count -gt 3000) { $logList.Items.RemoveAt(0) }
        $logList.ScrollIntoView($tb)
    }

    $showBanner = {
        param([string]$text, [string]$kind)
        $color = '#1E9E57'
        if ($kind -eq 'warn') { $color = '#E0A100' } elseif ($kind -eq 'error') { $color = '#D64545' }
        $banner.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
        $bannerText.Text = $text
        $banner.Visibility = 'Visible'
    }

    $updateOverallProgress = {
        param($state)
        $done = 0
        foreach ($def in $StepDefinitions) { if ($null -ne $state -and (Test-OnboardingStepCompleted -State $state -Name $def.Name)) { $done++ } }
        $pct = [int](100 * $done / $StepDefinitions.Count)
        $ui.StepPercent = $pct
        (& $find 'DashboardProgress').Value = $pct
        (& $find 'DashboardProgressText').Text = "Part 1: $done of $($StepDefinitions.Count) tasks completed"
        $progress.Value = $pct
        $readiness = & $find 'ReadinessText'
        if ($null -ne $state -and $state['Completed']) { $readiness.Text = "PART 1 COMPLETED $dash READY FOR INTUNE (Part 2 pending)" }
        elseif ($done -gt 0) { $readiness.Text = 'Part 1 in progress - not ready' }
        else { $readiness.Text = 'Not evaluated' }
    }

    $showDevice = {
        param($d)
        if ($null -eq $d) { return }
        $get = { param($k) if ($d.ContainsKey($k) -and $null -ne $d[$k]) { [string]$d[$k] } else { 'Unknown' } }
        (& $find 'CardDeviceName').Text = & $get 'ComputerName'
        (& $find 'CardManufacturer').Text = & $get 'Manufacturer'
        (& $find 'CardModel').Text = & $get 'Model'
        (& $find 'CardSerial').Text = & $get 'SerialNumber'
        (& $find 'CardWindows').Text = '{0} {1} (build {2})' -f (& $get 'WindowsEdition'), (& $get 'WindowsVersion'), (& $get 'OsBuild')
        (& $find 'CardUser').Text = & $get 'CurrentUser'
        $tpmText = 'TPM: not detected'
        if ($d.ContainsKey('Tpm') -and $d['Tpm'] -and $d['Tpm']['Present']) { $tpmText = 'TPM {0} (enabled: {1})' -f $d['Tpm']['SpecVersion'], $d['Tpm']['Enabled'] }
        (& $find 'CardSecurity').Text = "$tpmText`nSecure Boot: $(& $get 'SecureBoot')"
        (& $find 'CardHardware').Text = "{0}`nRAM: {1} GB   Storage: {2} GB" -f (& $get 'Cpu'), (& $get 'RamGB'), (& $get 'StorageTotalGB')
    }

    $refreshFromState = {
        $state = Get-OnboardingState -Part 1
        foreach ($def in $StepDefinitions) {
            $status = 'Pending'; $message = ''
            if ($null -ne $state -and $state['Steps'].ContainsKey($def.Name)) {
                $status = [string]$state['Steps'][$def.Name]['Status']; $message = [string]$state['Steps'][$def.Name]['Message']
            }
            & $setStep $def.Name $status $message
        }
        & $updateOverallProgress $state
        if ($null -ne $state) {
            if ($state['Technician'] -and -not $technicianBox.Text) { $technicianBox.Text = [string]$state['Technician'] }
            $data = Get-OnboardingStepData -State $state -Name 'DeviceInfo'
            if ($data.ContainsKey('Device')) { & $showDevice $data['Device'] }
            $reportData = Get-OnboardingStepData -State $state -Name 'Report'
            if ($reportData.ContainsKey('HtmlPath')) { $ui.ReportPath = [string]$reportData['HtmlPath'] }
            if ($state['Completed']) { & $showBanner "PART 1 COMPLETED $dash READY FOR INTUNE" 'ok'; $startButton.Content = 'Run Again (skips completed tasks)' }
            elseif (@($state['Steps'].Keys).Count -gt 0) { $startButton.Content = 'Resume Part 1' }
        }
        $openReportButton.IsEnabled = [bool]($ui.ReportPath -and (Test-Path -LiteralPath $ui.ReportPath))
        return $state
    }

    $setRunning = {
        param([bool]$running)
        $ui.Running = $running
        $startButton.IsEnabled = -not $running
        $newSessionButton.IsEnabled = -not $running
        $technicianBox.IsEnabled = -not $running
        if ($running) { foreach ($row in $ui.StepRows.Values) { $row.Retry.Visibility = 'Collapsed' } }
    }

    $disposeWorker = {
        if ($null -ne $ui.PowerShell) {
            try { if ($null -ne $ui.Handle -and $ui.Handle.IsCompleted) { [void]$ui.PowerShell.EndInvoke($ui.Handle) } } catch { }
            try { $ui.PowerShell.Dispose() } catch { }
            $ui.PowerShell = $null; $ui.Handle = $null
        }
        if ($null -ne $ui.Runspace) { try { $ui.Runspace.Dispose() } catch { }; $ui.Runspace = $null }
    }

    $startWorker = {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript({
                param($ScriptPath, $Context, $Sync)
                try {
                    . $ScriptPath -AppRoot $Context.AppRoot -DefineOnly
                    Invoke-Part1Workflow -Context $Context -Sync $Sync
                }
                catch {
                    $Sync.Queue.Enqueue(@{ Type = 'Log'; Level = 'ERROR'; Text = "Unexpected workflow error: $($_.Exception.Message)" })
                }
                finally {
                    $Sync.Queue.Enqueue(@{ Type = 'WorkflowEnded' })
                }
            }).AddArgument($WorkflowScriptPath).AddArgument($Context).AddArgument($ui.Sync)
        $ui.Runspace = $runspace
        $ui.PowerShell = $ps
        $ui.Handle = $ps.BeginInvoke()
    }

    $promptRestart = {
        param([string]$message)
        try { [void](Register-OnboardingResumeTask -Part 1 -AppRoot $Context.AppRoot) }
        catch { Write-OnboardingLog -Level WARN -Message "The automatic resume task could not be registered: $($_.Exception.Message). After restarting, run Start-Part1.cmd manually." }
        & $showBanner 'RESTART REQUIRED - Part 1 will resume after the restart' 'warn'
        $answer = [System.Windows.MessageBox]::Show($window,
            "$message`n`nWindows must restart to continue Part 1.`n`nRestart now? Part 1 resumes automatically when an administrator signs in again (keep the USB drive inserted).",
            'GRE IT Onboarding', 'YesNo', 'Question', 'Yes')
        $ui.ExitCode = 10
        if ($answer -eq 'Yes') {
            Write-OnboardingLog -Message 'Technician approved the restart. Restarting Windows in 15 seconds.'
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/r /t 15 /c "GRE IT Onboarding: restarting to continue Windows updates."' -WindowStyle Hidden
            $window.Close()
        }
        else {
            Write-OnboardingLog -Level WARN -Message 'Restart postponed by the technician. Part 1 cannot finish until Windows restarts.'
        }
    }

    $onWorkflowEnded = {
        & $disposeWorker
        & $setRunning $false
        $state = & $refreshFromState
        $progressText.Text = ''
        if ($null -eq $state) { return }
        if ($state['Completed']) {
            $ui.ExitCode = 0
            [System.Windows.MessageBox]::Show($window, "PART 1 COMPLETED $dash READY FOR INTUNE`n`nThe hardware hash CSV and the Part 1 report are on the USB drive.`nThe device was NOT enrolled and Sysprep was NOT run - hand the CSV to the Intune administrator.",
                'GRE IT Onboarding', 'OK', 'Information') | Out-Null
            return
        }
        if ((Get-OnboardingStepStatus -State $state -Name 'WindowsUpdate') -eq 'RestartRequired') {
            & $promptRestart ([string]$state['Steps']['WindowsUpdate']['Message'])
            return
        }
        $ui.ExitCode = 3
        & $showBanner 'PART 1 INCOMPLETE - review the failed tasks and choose Retry' 'error'
        $startButton.Content = 'Retry Failed Tasks'
    }

    $startPart1 = {
        if ($ui.Running) { return }
        try {
            $state = Get-OnboardingState -Part 1
            if ($null -eq $state) { $state = New-OnboardingState -Part 1 -AppRoot $Context.AppRoot }
            [void](Reset-OnboardingInterruptedSteps -State $state)
            $state['Technician'] = $technicianBox.Text.Trim()
            if ($state['Completed']) { $state['Completed'] = $false }
            Save-OnboardingState -State $state

            # STEP 1 - local administrator (UI thread, before anything else)
            $needAdmin = $true
            if (Test-OnboardingStepCompleted -State $state -Name 'LocalAdmin') {
                $known = [string](Get-OnboardingStepData -State $state -Name 'LocalAdmin')['UserName']
                if ($known -and (Test-LocalAdminAccount -UserName $known).Success) {
                    $needAdmin = $false
                    Write-OnboardingLog -Step 'LocalAdmin' -Message "Local administrator '$known' was created earlier and re-verified; skipping."
                }
                else {
                    Write-OnboardingLog -Step 'LocalAdmin' -Level WARN -Message 'The previously recorded local administrator could not be re-verified; asking again.'
                }
            }
            if ($needAdmin) {
                & $setStep 'LocalAdmin' 'Running' 'Waiting for technician input...'
                $admin = Invoke-LocalAdminSetupInteractive -Owner $window -Context $Context
                if (-not $admin.Success) {
                    Set-OnboardingStepState -State $state -Name 'LocalAdmin' -Status 'Pending' -Message 'Not completed - cancelled by the technician.'
                    & $refreshFromState | Out-Null
                    Write-OnboardingLog -Step 'LocalAdmin' -Level WARN -Message 'Local administrator setup was cancelled. Part 1 did not continue.'
                    return
                }
                $text = 'Verified: account exists and is a member of Administrators.'
                Set-OnboardingStepState -State $state -Name 'LocalAdmin' -Status 'Completed' -Message $text -Data @{ UserName = $admin.UserName; Action = $admin.Action }
                & $setStep 'LocalAdmin' 'Completed' $text
                if ($admin.Action -eq 'Created') { & $showBanner 'LOCAL ADMINISTRATOR CREATED SUCCESSFULLY' 'ok' }
                else { & $showBanner 'LOCAL ADMINISTRATOR VERIFIED (existing account)' 'ok' }
            }

            & $setRunning $true
            & $startWorker
        }
        catch {
            & $setRunning $false
            Write-OnboardingLog -Level ERROR -Message "Part 1 could not be started: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($window, "Part 1 could not be started:`n`n$($_.Exception.Message)", 'GRE IT Onboarding', 'OK', 'Error') | Out-Null
        }
    }

    $startButton.Add_Click({ & $startPart1 })
    foreach ($row in $ui.StepRows.Values) { $row.Retry.Add_Click({ & $startPart1 }) }

    $newSessionButton.Add_Click({
            if ($ui.Running) { return }
            $answer = [System.Windows.MessageBox]::Show($window,
                "Start a new Part 1 session?`n`nThe saved progress for this device is discarded and every task runs again. Existing reports, hardware hash files and accounts are not deleted.",
                'GRE IT Onboarding', 'YesNo', 'Warning', 'No')
            if ($answer -ne 'Yes') { return }
            try {
                Unregister-OnboardingResumeTask -Part 1
                Remove-OnboardingState -Part 1
                $ui.ReportPath = $null
                $banner.Visibility = 'Collapsed'
                $startButton.Content = 'Start Part 1'
                & $refreshFromState | Out-Null
                Write-OnboardingLog -Level WARN -Message 'Saved Part 1 progress was discarded by the technician. A new session will start.'
            }
            catch { [System.Windows.MessageBox]::Show($window, "The session could not be reset: $($_.Exception.Message)", 'GRE IT Onboarding', 'OK', 'Error') | Out-Null }
        })

    $openReportButton.Add_Click({ if ($ui.ReportPath -and (Test-Path -LiteralPath $ui.ReportPath)) { Start-Process -FilePath $ui.ReportPath } })

    # ---- queue pump (UI thread) --------------------------------------------
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
            $msg = $null
            $count = 0
            while ($count -lt 200 -and $ui.Sync.Queue.TryDequeue([ref]$msg)) {
                $count++
                try {
                    switch ([string]$msg['Type']) {
                        'Log' { & $addLog ([string]$msg['Text']) ([string]$msg['Level']) }
                        'Step' { & $setStep ([string]$msg['Name']) ([string]$msg['Status']) ([string]$msg['Message']) }
                        'Progress' {
                            $progressText.Text = [string]$msg['Text']
                            # blend the running step's own progress into the overall bar
                            $progress.Value = [math]::Min(100, $ui.StepPercent + ([double]$msg['Percent'] / $StepDefinitions.Count))
                        }
                        'Device' { & $showDevice $msg['Data'] }
                        'StepDone' { & $updateOverallProgress (Get-OnboardingState -Part 1) }
                        'WorkflowEnded' { & $onWorkflowEnded }
                    }
                }
                catch { & $addLog ("UI update error: $($_.Exception.Message)") 'ERROR' }
            }
        })

    $window.Add_Closing({
            param($source, $eventArgs)
            if ($ui.Running) {
                $answer = [System.Windows.MessageBox]::Show($window,
                    "A task is still running. Closing now can interrupt an update or export.`n`nProgress is saved and the interrupted task runs again next time. Close anyway?",
                    'GRE IT Onboarding', 'YesNo', 'Warning', 'No')
                if ($answer -ne 'Yes') { $eventArgs.Cancel = $true }
            }
        })
    $window.Add_Closed({
            $timer.Stop()
            if ($null -ne $ui.PowerShell -and $ui.Running) { try { [void]$ui.PowerShell.BeginStop($null, $null) } catch { } }
        })

    $window.Add_ContentRendered({
            Write-OnboardingLog -Message "GRE IT Onboarding started (Part 1). Application root: $($Context.AppRoot)"
            $state = & $refreshFromState
            (& $find 'NavPart1').IsChecked = $true
            if ($AutoStart -and $null -ne $state -and -not $state['Completed']) {
                Write-OnboardingLog -Message 'Resuming Part 1 after restart.'
                & $startPart1
            }
        })

    # The UI queue is also the log sink for messages written on the UI thread.
    Initialize-OnboardingLog -PrimaryDirectory $Context.LogDirectory -FallbackDirectory $Context.LocalLogDirectory `
        -FileName (Split-Path -Leaf $Context.LogFile) -UiQueue $ui.Sync.Queue | Out-Null

    $timer.Start()
    [void]$window.ShowDialog()
    return [int]$ui.ExitCode
}
