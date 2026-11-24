<#
    GRE IT Onboarding - Part 1 (before Intune)

    Start it with Start-Part1.cmd. Steps, in order:
      1. Local administrator account (secure dialog)
      2. Device information
      3. Autopilot hardware hash  -> Reports\HardwareHash\Autopilot_<serial>.csv
      4. Windows Update (last)    -> restart and run Start-Part1.cmd again if asked

    A report is saved to Reports\Part1_<serial>.html.
    Finished steps are skipped when you run it again.
    The password is never written to any file. The device is NOT enrolled and
    Sysprep is NOT run.
#>
param()
$ErrorActionPreference = 'Stop'

# ============================ SETTINGS ============================
$IncludeDriverUpdates = $false  # $true = also install driver updates
$AutopilotGroupTag    = ''      # optional Autopilot Group Tag, '' = none
# ==================================================================

# ---------- run as administrator (normal UAC prompt) ----------
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -STA -File "{0}"' -f $PSCommandPath)
        exit 0
    }
    catch {
        Write-Host 'Administrator rights are required (the UAC prompt was declined).' -ForegroundColor Red
        Read-Host 'Press Enter to close'
        exit 2
    }
}

$Root      = $PSScriptRoot
$Reports   = Join-Path $Root 'Reports'
$HashDir   = Join-Path $Reports 'HardwareHash'
$StateDir  = Join-Path $env:ProgramData 'GRE-IT-Onboarding'
$StateFile = Join-Path $StateDir 'Part1.json'       # remembers only the admin USERNAME
$LogFile   = Join-Path $Reports ('Part1_{0}.log' -f $env:COMPUTERNAME)
$Title     = 'GRE IT Onboarding'
$AdminSid  = 'S-1-5-32-544'                         # local Administrators group (any language)

function Write-Log {
    param([string]$Text, [string]$Level = 'INFO')
    $color = 'Gray'
    switch ($Level) { 'OK' { $color = 'Green' } 'WARN' { $color = 'Yellow' } 'ERROR' { $color = 'Red' } 'STEP' { $color = 'Cyan' } }
    Write-Host $Text -ForegroundColor $color
    try { Add-Content -LiteralPath $LogFile -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Text) } catch { }
}

# =================================================================
# STEP 1 - LOCAL ADMINISTRATOR
# =================================================================
function Get-UserNameProblems {
    param([string]$Name)
    $p = @()
    if ([string]::IsNullOrEmpty($Name)) { return @('Username is required.') }
    if ($Name -ne $Name.Trim()) { $p += 'Username must not start or end with a space.' }
    if ($Name.Length -gt 20) { $p += 'Username must be 20 characters or fewer.' }
    if ($Name.IndexOfAny([char[]]'"/\[]:;|=,+*?<>@') -ge 0) { $p += 'Username contains a character Windows does not allow: " / \ [ ] : ; | = , + * ? < > @' }
    if ($Name -match '[\x00-\x1F]') { $p += 'Username must not contain control characters.' }
    if ($Name -match '^[\. ]+$') { $p += 'Username cannot be only periods or spaces.' }
    if ($Name.EndsWith('.')) { $p += 'Username cannot end with a period.' }
    if ($Name -ieq $env:COMPUTERNAME) { $p += 'Username cannot be the same as the computer name.' }
    return $p
}

function Get-SecureChars {
    # Copies a SecureString to a char[] (never a String). The caller clears the array.
    param([securestring]$Secure)
    $chars = New-Object char[] $Secure.Length
    if ($Secure.Length -eq 0) { return , $chars }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::Copy($ptr, $chars, 0, $Secure.Length) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    return , $chars
}

function Get-PasswordProblems {
    # Only checks that a password was typed and both boxes match (no other rules),
    # without ever turning the password into text.
    param([securestring]$Password, [securestring]$Confirm, [string]$UserName)
    $a = Get-SecureChars $Password
    $b = Get-SecureChars $Confirm
    try {
        if ($a.Length -eq 0) { return @('Password is required.') }
        $same = ($a.Length -eq $b.Length)
        if ($same) { for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $same = $false; break } } }
        if (-not $same) { return @('Password and Confirm Password do not match.') }

        return @()
    }
    finally {
        [Array]::Clear($a, 0, $a.Length)
        [Array]::Clear($b, 0, $b.Length)
    }
}

function Test-LocalAdmin {
    # True only if the account exists, is enabled and is in the Administrators group.
    param([string]$Name)
    $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if (-not $user -or -not $user.Enabled) { return $false }
    try { $sids = @(Get-LocalGroupMember -SID $AdminSid -ErrorAction Stop | ForEach-Object { $_.SID.Value }) }
    catch {
        # Get-LocalGroupMember fails if the group holds an orphaned account; ADSI does not.
        $group = [ADSI]('WinNT://./{0},group' -f (Get-LocalGroup -SID $AdminSid).Name)
        $sids = @($group.psbase.Invoke('Members') | ForEach-Object {
                (New-Object Security.Principal.SecurityIdentifier($_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null), 0)).Value })
    }
    return ($sids -contains $user.SID.Value)
}

function Show-AdminDialog {
    # Returns @{ UserName; Password (SecureString) } or $null when cancelled.
    param([string]$UserName = '', [string]$ErrorText = '')
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="GRE IT Onboarding - Local Administrator" Width="480" SizeToContent="Height"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Topmost="True"
        Background="#F3F6FA" FontFamily="Segoe UI" FontSize="13">
  <Border Margin="16" Padding="20" Background="White" CornerRadius="8" BorderBrush="#D5DDE8" BorderThickness="1">
    <StackPanel>
      <TextBlock Text="Local Administrator Account" FontSize="18" FontWeight="SemiBold" Foreground="#0B2A4A" Margin="0,0,0,12"/>
      <TextBlock Text="Local Administrator Username" FontWeight="SemiBold"/>
      <TextBox Name="UserBox" Margin="0,4,0,10" Padding="5" MaxLength="20"/>
      <TextBlock Text="Password" FontWeight="SemiBold"/>
      <PasswordBox Name="Pw1" Margin="0,4,0,10" Padding="5" MaxLength="127"/>
      <TextBlock Text="Confirm Password" FontWeight="SemiBold"/>
      <PasswordBox Name="Pw2" Margin="0,4,0,10" Padding="5" MaxLength="127"/>
      <TextBlock Name="Hint" TextWrapping="Wrap" Foreground="#5B6B7F" FontSize="12"/>
      <TextBlock Name="Err" TextWrapping="Wrap" Foreground="#C0392B" Margin="0,8,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button Name="CancelBtn" Content="Cancel" Width="90" Height="30" Margin="0,0,8,0" IsCancel="True"/>
        <Button Name="OkBtn" Content="Create Account" Width="130" Height="30" IsDefault="True" Background="#0B2A4A" Foreground="White"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    $userBox = $win.FindName('UserBox'); $pw1 = $win.FindName('Pw1'); $pw2 = $win.FindName('Pw2'); $err = $win.FindName('Err')
    $win.FindName('Hint').Text = 'Any password is accepted. It is not saved anywhere.'
    $userBox.Text = $UserName
    $err.Text = $ErrorText
    $result = @{ UserName = $null; Password = $null }

    $win.FindName('OkBtn').Add_Click({
            $s1 = $pw1.SecurePassword; $s2 = $pw2.SecurePassword
            $problems = @(Get-UserNameProblems $userBox.Text) + @(Get-PasswordProblems $s1 $s2 $userBox.Text)
            $s2.Dispose()
            if ($problems.Count -gt 0) { $s1.Dispose(); $err.Text = ($problems -join "`n"); return }
            $result.UserName = $userBox.Text
            $result.Password = $s1
            $pw1.Clear(); $pw2.Clear()
            $win.DialogResult = $true
        })
    [void]$userBox.Focus()
    [void]$win.ShowDialog()
    $pw1.Clear(); $pw2.Clear()
    if ($result.Password) { return $result }
    return $null
}

function Invoke-LocalAdminStep {
    # Returns the verified username, or $null if the technician cancelled.
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $known = (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).AdminUser
            if ($known -and (Test-LocalAdmin $known)) { Write-Log "Local administrator '$known' already created and verified - skipping." 'OK'; return $known }
        }
        catch { }
    }

    $name = ''; $message = ''
    while ($true) {
        $entry = Show-AdminDialog -UserName $name -ErrorText $message
        if (-not $entry) { return $null }
        $name = $entry.UserName
        $password = $entry.Password
        try {
            $existing = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
            if (-not $existing) {
                New-LocalUser -Name $name -Password $password -Description 'Local administrator (IT onboarding)' -AccountNeverExpires | Out-Null
                try { Add-LocalGroupMember -SID $AdminSid -Member $name }
                catch { Remove-LocalUser -Name $name -ErrorAction SilentlyContinue; throw "Could not add the account to Administrators: $($_.Exception.Message)" }
                Write-Log "Created local account '$name' and added it to Administrators."
            }
            else {
                # Existing account: nothing is changed without an explicit Yes.
                $answer = [Windows.MessageBox]::Show("The account '$name' already exists.`n`nYes = reset its password to the one you entered`nNo = keep its current password`nCancel = choose another username", $Title, 'YesNoCancel', 'Warning')
                if ($answer -eq 'Cancel') { $message = "Account '$name' was not changed. Choose another username."; continue }
                if ($answer -eq 'Yes') { Set-LocalUser -Name $name -Password $password; Write-Log "Password of existing account '$name' reset (approved by technician)." 'WARN' }
                if (-not (Test-LocalAdmin $name)) {
                    $answer = [Windows.MessageBox]::Show("'$name' is disabled or not a member of Administrators.`n`nEnable it and add it to the Administrators group?", $Title, 'YesNo', 'Warning')
                    if ($answer -ne 'Yes') { $message = "Account '$name' was not changed. Choose another username."; continue }
                    Enable-LocalUser -Name $name
                    if (-not (Test-LocalAdmin $name)) { Add-LocalGroupMember -SID $AdminSid -Member $name }
                    Write-Log "Existing account '$name' enabled / added to Administrators (approved by technician)." 'WARN'
                }
            }
            if (Test-LocalAdmin $name) {
                @{ AdminUser = $name } | ConvertTo-Json | Set-Content -LiteralPath $StateFile
                return $name
            }
            $message = 'Verification failed: the account is not an enabled member of Administrators.'
        }
        catch { $message = "The account could not be created: $($_.Exception.Message)" }
        finally { $password.Dispose(); $entry.Password = $null; [GC]::Collect() }
        Write-Log $message 'ERROR'
    }
}

# =================================================================
# STEP 2 - DEVICE INFORMATION
# =================================================================
function Get-Value {
    # Runs a query; returns 'Unknown' instead of failing.
    param([scriptblock]$Query)
    try { $v = & $Query; if ($null -eq $v -or "$v".Trim() -eq '') { 'Unknown' } else { "$v".Trim() } }
    catch { 'Unknown' }
}

function Get-DeviceInfo {
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $d = [ordered]@{}
    $d['Device name']     = $env:COMPUTERNAME
    $d['Manufacturer']    = Get-Value { $cs.Manufacturer }
    $d['Model']           = Get-Value { $cs.Model }
    $d['Serial number']   = Get-Value { $bios.SerialNumber }
    $d['BIOS version']    = Get-Value { $bios.SMBIOSBIOSVersion }
    $d['Windows edition'] = Get-Value { $os.Caption }
    $d['Windows version'] = Get-Value { $cv.DisplayVersion }
    $d['OS build']        = Get-Value { '{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR }
    $d['CPU']             = Get-Value { (Get-CimInstance Win32_Processor | Select-Object -First 1).Name }
    $d['RAM']             = Get-Value { '{0} GB' -f [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) }
    $d['Storage']         = Get-Value { (Get-PhysicalDisk | Where-Object BusType -ne 'USB' | ForEach-Object { '{0} ({1}, {2} GB, {3})' -f $_.FriendlyName, $_.MediaType, [math]::Round($_.Size / 1GB), $_.HealthStatus }) -join '; ' }
    $d['Battery']         = Get-Value {
        $b = Get-CimInstance Win32_Battery | Select-Object -First 1
        if (-not $b) { return 'No battery detected' }
        $text = '{0}, charge {1}%' -f $b.Name, $b.EstimatedChargeRemaining
        try {
            $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
            $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
            if ($design -gt 0) { $text += ', design {0} mWh, full {1} mWh, health {2}%' -f $design, $full, [math]::Round(100 * $full / $design) }
        }
        catch { }
        $text
    }
    $d['TPM']             = Get-Value { $t = Get-Tpm; 'Present: {0}, Ready: {1}' -f $t.TpmPresent, $t.TpmReady }
    $d['Secure Boot']     = Get-Value { if (Confirm-SecureBootUEFI) { 'Enabled' } else { 'Disabled' } }
    $d['Network adapters'] = Get-Value { (Get-NetAdapter -Physical | ForEach-Object { '{0}: {1} [{2}] {3}' -f $_.Name, $_.InterfaceDescription, $_.MacAddress, $_.Status }) -join '; ' }
    return $d
}

# =================================================================
# STEP 3 - AUTOPILOT HARDWARE HASH
# =================================================================
function Test-HashCsv {
    param([string]$Path, [string]$Serial)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() })
    if ($lines.Count -ne 2 -or $lines[0] -notlike 'Device Serial Number,Windows Product ID,Hardware Hash*') { return $false }
    $f = $lines[1].Split(',')
    return ($f.Count -ge 3 -and $f[0] -eq $Serial -and $f[2].Length -ge 1000 -and $f[2] -match '^[A-Za-z0-9+/]+={0,2}$')
}

function Export-HardwareHash {
    # Returns the CSV path. Uses the Microsoft MDM WMI provider (same source as Get-WindowsAutopilotInfo).
    param([string]$Serial)
    if (-not $Serial -or $Serial -eq 'Unknown' -or $Serial -match '[,"]') { throw 'The device has no usable serial number.' }
    $fileSerial = $Serial
    foreach ($c in [IO.Path]::GetInvalidFileNameChars() + ' ') { $fileSerial = $fileSerial.Replace([string]$c, '_') }
    $path = Join-Path $HashDir "Autopilot_$fileSerial.csv"
    if (Test-HashCsv $path $Serial) { Write-Log 'Hardware hash CSV already exported and valid - skipping.' 'OK'; return $path }

    $hash = (Get-CimInstance -Namespace root/cimv2/mdm/dmmap -ClassName MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'").DeviceHardwareData
    if (-not $hash) { throw 'Windows returned an empty hardware hash (normal in a virtual machine).' }
    if ($AutopilotGroupTag) { $lines = 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag', "$Serial,,$hash,$AutopilotGroupTag" }
    else { $lines = 'Device Serial Number,Windows Product ID,Hardware Hash', "$Serial,,$hash" }
    [IO.File]::WriteAllLines($path, [string[]]$lines, [Text.Encoding]::ASCII)
    if (-not (Test-HashCsv $path $Serial)) { throw 'The exported CSV failed validation.' }

    # Sensitive file: restrict to Administrators + SYSTEM where the drive supports it (NTFS).
    if ((New-Object IO.DriveInfo([IO.Path]::GetPathRoot($path))).DriveFormat -eq 'NTFS') {
        & icacls.exe $path /inheritance:r /grant '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
    }
    else { Write-Log 'This drive cannot restrict file permissions (not NTFS). Keep it physically secure.' 'WARN' }
    return $path
}

# =================================================================
# STEP 4 - WINDOWS UPDATE (last step)
# =================================================================
function Test-RestartPending {
    try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { return $true } } catch { }
    return ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'))
}

function Invoke-WindowsUpdateStep {
    # Returns @{ Status = 'OK' | 'RESTART' | 'FAILED'; Message }.
    # 'OK' is returned ONLY after a scan that finds nothing left to install.
    try { [void](Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 15) }
    catch { return @{ Status = 'FAILED'; Message = 'No internet connection. Connect to a network and run Start-Part1.cmd again.' } }
    if (Test-RestartPending) { return @{ Status = 'RESTART'; Message = 'A restart is pending. Restart, then run Start-Part1.cmd again.' } }

    $session = New-Object -ComObject Microsoft.Update.Session
    $criteria = 'IsInstalled=0 and IsHidden=0'
    if (-not $IncludeDriverUpdates) { $criteria += " and Type='Software'" }
    $installed = 0

    foreach ($pass in 1..3) {
        Write-Log "Scanning for updates (pass $pass)... this can take several minutes."
        try { $found = $session.CreateUpdateSearcher().Search($criteria) }
        catch { return @{ Status = 'FAILED'; Message = "Windows Update scan failed: $($_.Exception.Message)" } }

        $todo = @()
        foreach ($u in $found.Updates) {
            $isUpgrade = @($u.Categories | Where-Object { $_.CategoryID -eq '3689bdc8-b205-4af4-8d4a-a63924c5e9d5' }).Count -gt 0
            if ($isUpgrade) { Write-Log "Skipped (feature upgrade): $($u.Title)" 'WARN' }
            elseif ($u.InstallationBehavior.CanRequestUserInput) { Write-Log "Skipped (needs user input, install manually): $($u.Title)" 'WARN' }
            else { $todo += $u }
        }
        if ($todo.Count -eq 0) {
            if (Test-RestartPending) { return @{ Status = 'RESTART'; Message = "$installed update(s) installed. Restart, then run Start-Part1.cmd again." } }
            $build = Get-Value { $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; '{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR }
            return @{ Status = 'OK'; Message = "Up to date (verified by scan). Final OS build $build." }
        }

        $ok = 0; $n = 0; $restart = $false
        foreach ($u in $todo) {
            $n++
            Write-Log ("Installing {0} of {1}: {2}" -f $n, $todo.Count, $u.Title)
            try {
                if (-not $u.EulaAccepted) { $u.AcceptEula() }
                $list = New-Object -ComObject Microsoft.Update.UpdateColl
                [void]$list.Add($u)
                if (-not $u.IsDownloaded) {
                    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $list
                    if ($dl.Download().ResultCode -notin 2, 3) { throw 'download failed' }
                }
                $inst = $session.CreateUpdateInstaller(); $inst.Updates = $list
                $r = $inst.Install()
                if ($r.RebootRequired) { $restart = $true }
                if ($r.ResultCode -in 2, 3) { $ok++; $installed++; Write-Log '   installed' 'OK' } else { throw ('install failed (0x{0:X8})' -f $r.HResult) }
            }
            catch { Write-Log "   FAILED: $($_.Exception.Message)" 'ERROR' }
        }
        if ($restart -or (Test-RestartPending)) { return @{ Status = 'RESTART'; Message = "$installed update(s) installed. Restart, then run Start-Part1.cmd again." } }
        if ($ok -eq 0) { return @{ Status = 'FAILED'; Message = "$($todo.Count) update(s) could not be installed. See the log." } }
    }
    return @{ Status = 'FAILED'; Message = 'Updates still remain after 3 passes. Run Start-Part1.cmd again.' }
}

# =================================================================
# REPORT
# =================================================================
function Save-Report {
    param($Device, $Results, [string]$Overall)
    $enc = { param($v) [Net.WebUtility]::HtmlEncode([string]$v) }
    $serial = [string]$Device['Serial number']
    foreach ($c in [IO.Path]::GetInvalidFileNameChars() + ' ') { $serial = $serial.Replace([string]$c, '_') }
    $path = Join-Path $Reports "Part1_$serial.html"
    $color = '#d64545'; if ($Overall -like 'PART 1 COMPLETED*') { $color = '#1e9e57' }
    $html = @('<html><head><meta charset="utf-8"><title>GRE IT Onboarding - Part 1</title>',
        '<style>body{font-family:Segoe UI,Arial;margin:30px;color:#1b2733}h1{color:#0b2a4a}table{border-collapse:collapse;margin-bottom:24px}td,th{border:1px solid #d5dde8;padding:6px 12px;text-align:left;vertical-align:top}th{background:#eef2f7}</style></head><body>',
        '<h1>GRE IT Onboarding - Part 1 Report</h1>',
        ('<p><b style="color:{0}">{1}</b><br>Generated: {2}</p>' -f $color, (& $enc $Overall), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        '<h2>Tasks</h2><table><tr><th>Task</th><th>Status</th><th>Details</th></tr>')
    foreach ($k in $Results.Keys) { $html += '<tr><td>{0}</td><td>{1}</td><td>{2}</td></tr>' -f (& $enc $k), (& $enc $Results[$k].Status), (& $enc $Results[$k].Message) }
    $html += '</table><h2>Device information</h2><table>'
    foreach ($k in $Device.Keys) { $html += '<tr><th>{0}</th><td>{1}</td></tr>' -f (& $enc $k), (& $enc $Device[$k]) }
    $html += '</table><p>This report contains no passwords and no hardware hash. The device was not enrolled and Sysprep was not run.</p></body></html>'
    [IO.File]::WriteAllLines($path, [string[]]$html, (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Get-Overall {
    param($Results)
    foreach ($k in $Results.Keys) { if ($Results[$k].Status -ne 'OK') { return 'PART 1 NOT COMPLETED' } }
    return ('PART 1 COMPLETED {0} READY FOR INTUNE' -f [char]0x2014)
}

# =================================================================
# MAIN
# =================================================================
$exitCode = 1
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    New-Item -ItemType Directory -Path $Reports, $HashDir, $StateDir -Force | Out-Null
    Write-Log '=== GRE IT Onboarding - Part 1 ===' 'STEP'
    $results = [ordered]@{
        '1. Local administrator'     = @{ Status = 'NOT DONE'; Message = '' }
        '2. Device information'      = @{ Status = 'NOT DONE'; Message = '' }
        '3. Autopilot hardware hash' = @{ Status = 'NOT DONE'; Message = '' }
        '4. Windows Update'          = @{ Status = 'NOT DONE'; Message = 'Not finished yet.' }
    }

    Write-Log "`nSTEP 1 - Local administrator account" 'STEP'
    $admin = Invoke-LocalAdminStep
    if (-not $admin) { Write-Log 'Cancelled. Nothing else was done.' 'WARN'; Read-Host 'Press Enter to close'; exit 4 }
    $results['1. Local administrator'] = @{ Status = 'OK'; Message = "Account '$admin' exists and is a member of Administrators (verified)." }
    Write-Log 'LOCAL ADMINISTRATOR CREATED SUCCESSFULLY' 'OK'

    Write-Log "`nSTEP 2 - Device information" 'STEP'
    $device = Get-DeviceInfo
    foreach ($k in $device.Keys) { Write-Log ('  {0,-17}: {1}' -f $k, $device[$k]) }
    $results['2. Device information'] = @{ Status = 'OK'; Message = 'Collected.' }

    Write-Log "`nSTEP 3 - Autopilot hardware hash" 'STEP'
    try {
        $csv = Export-HardwareHash $device['Serial number']
        $results['3. Autopilot hardware hash'] = @{ Status = 'OK'; Message = 'Saved and validated: Reports\HardwareHash\' + (Split-Path -Leaf $csv) }
        Write-Log $results['3. Autopilot hardware hash'].Message 'OK'
    }
    catch {
        $results['3. Autopilot hardware hash'] = @{ Status = 'FAILED'; Message = $_.Exception.Message }
        Write-Log "Hardware hash export failed: $($_.Exception.Message)" 'ERROR'
    }

    # Save the report now, so it exists even if updates take long or need a restart.
    [void](Save-Report $device $results (Get-Overall $results))

    Write-Log "`nSTEP 4 - Windows Update" 'STEP'
    try { $wu = Invoke-WindowsUpdateStep }
    catch { $wu = @{ Status = 'FAILED'; Message = "Windows Update error: $($_.Exception.Message)" } }
    $results['4. Windows Update'] = $wu
    $level = 'ERROR'; if ($wu.Status -eq 'OK') { $level = 'OK' } elseif ($wu.Status -eq 'RESTART') { $level = 'WARN' }
    Write-Log $wu.Message $level

    $overall = Get-Overall $results
    $report = Save-Report $device $results $overall
    Write-Log "`nReport: $report"

    if ($wu.Status -eq 'RESTART') {
        $exitCode = 10
        $answer = [Windows.MessageBox]::Show("Windows must restart to finish the updates.`n`nAfter the restart, run Start-Part1.cmd again. Finished steps are skipped.`n`nRestart now?", $Title, 'YesNo', 'Question')
        if ($answer -eq 'Yes') { & shutdown.exe /r /t 15 /c 'GRE IT Onboarding: restarting to finish Windows updates.'; exit 10 }
        Write-Log 'Restart postponed. Part 1 is NOT finished until you restart and run Start-Part1.cmd again.' 'WARN'
    }
    elseif ($overall -like 'PART 1 COMPLETED*') {
        $exitCode = 0
        Write-Log "`n$overall" 'OK'
        [void][Windows.MessageBox]::Show("$overall`n`nGive the file in Reports\HardwareHash to the Intune administrator.`nThe device was not enrolled and Sysprep was not run.", $Title, 'OK', 'Information')
    }
    else {
        $exitCode = 3
        Write-Log "`n$overall - fix the failed step shown above and run Start-Part1.cmd again." 'ERROR'
    }
}
catch {
    Write-Host "Unexpected error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    try { Write-Log "Unexpected error: $($_.Exception.Message)" 'ERROR' } catch { }
}
Read-Host "`nPress Enter to close"
exit $exitCode
