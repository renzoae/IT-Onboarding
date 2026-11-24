<#
    GRE IT Onboarding - Part 2 (after Intune)

    Run it AFTER the laptop is provisioned and the EMPLOYEE is signed in with
    the company account. Start it with Start-Part2.cmd (plain double-click).

    It runs in two stages:
      A) as the employee (no admin rights): Entra/Intune join status, company
         wallpaper, OneDrive sign-in. These belong to the employee's profile.
      B) as administrator (UAC prompt): applications, security checks, report.

    Result: Reports\Part2_<serial>.html with READY / NOT READY / MANUAL REVIEW REQUIRED.
    Nothing is disabled, no Intune policy is changed, no recovery key is exported.
#>
param([string]$UserData)
$ErrorActionPreference = 'Stop'

# ============================ SETTINGS ============================
# Installed with WinGet when missing (exact IDs from the "winget" source):
$WinGetApps = @(
    @{ Name = 'Adobe Acrobat Reader'; Match = 'Adobe Acrobat*';    Id = 'Adobe.Acrobat.Reader.64-bit' }
    @{ Name = '7-Zip';                Match = '7-Zip*';            Id = '7zip.7zip' }
    @{ Name = 'Google Earth Pro';     Match = 'Google Earth Pro*'; Id = 'Google.EarthPro' }
)
# Microsoft 365 Apps: installed from Microsoft when missing. Must match the licence:
#   'Business'   = Microsoft 365 Business Standard / Premium
#   'Enterprise' = Microsoft 365 E3 / E5
#   ''           = do not install, only check
$Microsoft365Edition = 'Business'
# Teams, OneDrive and Sophos are only VERIFIED here; they are expected to be
# installed by Intune or the company installer.
$WallpaperFile = 'Assets\CompanyWallpaper.jpg'   # relative to this folder
# ==================================================================

$Root    = $PSScriptRoot
$Reports = Join-Path $Root 'Reports'
$Title   = 'GRE IT Onboarding'
$Checks  = New-Object System.Collections.ArrayList

function Write-Line {
    param([string]$Text, [string]$Level = 'INFO')
    $color = 'Gray'
    switch ($Level) { 'OK' { $color = 'Green' } 'REVIEW' { $color = 'Yellow' } 'FAIL' { $color = 'Red' } 'STEP' { $color = 'Cyan' } }
    Write-Host $Text -ForegroundColor $color
}

function Add-Check {
    # Status: OK | FAIL | REVIEW
    param([string]$Name, [string]$Status, [string]$Message)
    [void]$Checks.Add(@{ Name = $Name; Status = $Status; Message = $Message })
    Write-Line ('  [{0,-6}] {1}: {2}' -f $Status, $Name, $Message) $Status
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =================================================================
# STAGE A - runs as the EMPLOYEE (not elevated)
# =================================================================
function Invoke-EmployeeStage {
    $employee = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Line "`nSTAGE A - employee profile ($employee)" 'STEP'

    # --- Entra ID join status (dsregcmd is the supported tool) ---
    $ds = @{}
    foreach ($line in (& dsregcmd.exe /status)) {
        if ($line -match '^\s*(\w+)\s*:\s*(.*)$') { $ds[$Matches[1]] = $Matches[2].Trim() }
    }
    if ($ds['AzureAdJoined'] -eq 'YES') { Add-Check 'Entra ID join' 'OK' "Joined to tenant '$($ds['TenantName'])'." }
    else { Add-Check 'Entra ID join' 'FAIL' 'Device is not Microsoft Entra joined (dsregcmd).' }
    if ($ds['AzureAdPrt'] -eq 'YES') { Add-Check 'Employee sign-in' 'OK' "$employee is signed in with a company account." }
    else { Add-Check 'Employee sign-in' 'REVIEW' "$employee has no company sign-in token. Is this the employee's company account?" }

    # --- Wallpaper (employee profile) ---
    try {
        $policy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).Wallpaper
        if (-not $policy) { $policy = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -ErrorAction SilentlyContinue).DesktopImagePath }
        $source = Join-Path $Root $WallpaperFile
        if ($policy) { Add-Check 'Wallpaper' 'OK' 'Managed by company policy - not changed.' }
        elseif (-not (Test-Path -LiteralPath $source)) { Add-Check 'Wallpaper' 'REVIEW' "$WallpaperFile was not found. Add the company wallpaper and run again." }
        else {
            $folder = Join-Path $env:LOCALAPPDATA 'GRE'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $target = Join-Path $folder 'CompanyWallpaper.jpg'
            Copy-Item -LiteralPath $source -Destination $target -Force
            Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'   # 10 = Fill
            Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
            Add-Type -Namespace Gre -Name Desktop -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SystemParametersInfo(uint action, uint param, string value, uint flags);'
            [void][Gre.Desktop]::SystemParametersInfo(0x0014, 0, $target, 3)                  # set + save + refresh
            $now = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper
            if ($now -eq $target) { Add-Check 'Wallpaper' 'OK' "Applied to $employee and verified." }
            else { Add-Check 'Wallpaper' 'FAIL' 'Windows did not accept the wallpaper setting.' }
        }
    }
    catch { Add-Check 'Wallpaper' 'FAIL' $_.Exception.Message }

    # --- OneDrive (employee profile) ---
    $exe = @("$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $account = Get-ItemProperty 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1' -ErrorAction SilentlyContinue
    if (-not $exe) { Add-Check 'OneDrive' 'FAIL' 'OneDrive is not installed.' }
    elseif (-not $account -or -not $account.UserEmail) { Add-Check 'OneDrive' 'REVIEW' 'Installed, but the employee is not signed in to OneDrive yet.' }
    else {
        $folders = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $backedUp = @()
        if ($account.UserFolder -and "$($folders.Desktop)" -like "$($account.UserFolder)*") { $backedUp += 'Desktop' }
        if ($account.UserFolder -and "$($folders.Personal)" -like "$($account.UserFolder)*") { $backedUp += 'Documents' }
        if ($backedUp.Count -eq 2) { Add-Check 'OneDrive' 'OK' "Signed in as $($account.UserEmail); Desktop and Documents are redirected to OneDrive." }
        else { Add-Check 'OneDrive' 'REVIEW' "Signed in as $($account.UserEmail), but folder backup is not complete (redirected: $($backedUp -join ', ')). Sync status must be checked in OneDrive." }
    }

    return @{ Employee = $employee; Tenant = $ds['TenantName']; Checks = @($Checks) }
}

# =================================================================
# STAGE B - runs as ADMINISTRATOR
# =================================================================
function Get-InstalledApp {
    # Looks in the machine-wide uninstall registry (64 and 32 bit). Returns the first match.
    param([string]$Match)
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    return (Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $Match } | Select-Object -First 1)
}

function Get-WinGetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # An admin account that never signed in has no winget alias; use the installed package directly.
    $found = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Install-Microsoft365 {
    # Uses Microsoft's own Office Deployment Tool, downloaded from Microsoft and
    # checked for a valid Microsoft signature before it is run. Returns nothing;
    # the caller verifies the result. Typically takes 10-30 minutes.
    $product = 'O365BusinessRetail'
    if ($Microsoft365Edition -eq 'Enterprise') { $product = 'O365ProPlusRetail' }
    $work = Join-Path $env:TEMP 'GRE-Office-Setup'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $setup = Join-Path $work 'setup.exe'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Line '  Downloading the Office Deployment Tool from Microsoft...'
        Invoke-WebRequest -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $setup -UseBasicParsing
        $sig = Get-AuthenticodeSignature -LiteralPath $setup
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*O=Microsoft Corporation*') {
            throw 'The downloaded Office setup file is not signed by Microsoft. It was not run.'
        }
        $config = Join-Path $work 'configuration.xml'
        $xml = @(
            '<Configuration>',
            '  <Add OfficeClientEdition="64" Channel="Current">',
            ('    <Product ID="{0}">' -f $product),
            '      <Language ID="MatchOS" />',
            '      <ExcludeApp ID="Groove" />',
            '      <ExcludeApp ID="Lync" />',
            '    </Product>',
            '  </Add>',
            '  <Display Level="None" AcceptEULA="TRUE" />',
            '  <Updates Enabled="TRUE" />',
            '</Configuration>')
        [IO.File]::WriteAllLines($config, [string[]]$xml)
        Write-Line "  Installing Microsoft 365 Apps ($Microsoft365Edition). This takes 10-30 minutes - do not close this window..."
        $run = Start-Process -FilePath $setup -ArgumentList ('/configure "{0}"' -f $config) -Wait -PassThru
        if ($run.ExitCode -ne 0) { throw "Office setup ended with exit code $($run.ExitCode)." }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue   # only our own temp folder
    }
}

function Invoke-ApplicationChecks {
    Write-Line "`nApplications" 'STEP'
    $winget = Get-WinGetPath
    foreach ($app in $WinGetApps) {
        $installed = Get-InstalledApp $app.Match
        if ($installed) { Add-Check $app.Name 'OK' "Already installed (version $($installed.DisplayVersion))."; continue }
        if (-not $winget) { Add-Check $app.Name 'FAIL' 'Not installed, and WinGet is not available on this device.'; continue }
        foreach ($attempt in 1, 2) {     # one retry for temporary download problems
            Write-Line "  Installing $($app.Name) (attempt $attempt)..."
            & $winget install --id $app.Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Null
            $code = $LASTEXITCODE
            $installed = Get-InstalledApp $app.Match
            if ($installed) { break }
            Start-Sleep -Seconds 10
        }
        # The exit code alone is not trusted: the app must actually be found afterwards.
        if ($installed) { Add-Check $app.Name 'OK' "Installed (version $($installed.DisplayVersion))." }
        else { Add-Check $app.Name 'FAIL' "Installation failed (WinGet exit code $code)." }
    }

    $office = Get-InstalledApp 'Microsoft 365 Apps*'
    if ($office) { Add-Check 'Microsoft 365 Apps' 'OK' "Installed (version $($office.DisplayVersion))." }
    elseif (-not $Microsoft365Edition) { Add-Check 'Microsoft 365 Apps' 'FAIL' 'Not installed (installing is switched off in the settings).' }
    else {
        $problem = ''
        try { Install-Microsoft365 } catch { $problem = $_.Exception.Message }
        $office = Get-InstalledApp 'Microsoft 365 Apps*'     # verify, do not trust the exit code alone
        if ($office) { Add-Check 'Microsoft 365 Apps' 'OK' "Installed ($Microsoft365Edition, version $($office.DisplayVersion)). The employee activates it by signing in." }
        else { Add-Check 'Microsoft 365 Apps' 'FAIL' "Installation failed. $problem" }
    }

    $teams = Get-AppxPackage -AllUsers -Name MSTeams -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($teams) { Add-Check 'Microsoft Teams' 'OK' "Installed (version $($teams.Version))." }
    else { Add-Check 'Microsoft Teams' 'FAIL' 'Not installed. It is deployed by Intune / with Microsoft 365.' }

    $sophos = @(Get-Service -Name 'Sophos*' -ErrorAction SilentlyContinue)
    $running = @($sophos | Where-Object Status -eq 'Running')
    if ($running.Count -gt 0) { Add-Check 'Sophos Endpoint' 'OK' "$($running.Count) Sophos service(s) running." }
    elseif ($sophos.Count -gt 0) { Add-Check 'Sophos Endpoint' 'FAIL' 'Installed, but no Sophos service is running.' }
    else { Add-Check 'Sophos Endpoint' 'FAIL' 'Not installed. Install it with the company installer or Intune.' }
}

function Invoke-SecurityChecks {
    Write-Line "`nSecurity" 'STEP'

    # Intune (MDM) enrollment indicator. Local data cannot prove COMPLIANCE.
    $mdm = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.ProviderID -eq 'MS DM Server' } | Select-Object -First 1
    if ($mdm) { Add-Check 'Intune enrollment' 'OK' "Enrolled ($($mdm.UPN)). Compliance must be confirmed in the Intune portal." }
    else { Add-Check 'Intune enrollment' 'FAIL' 'No Intune (MDM) enrollment was found on this device.' }

    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive
        if ($bl.ProtectionStatus -eq 'On') {
            Add-Check 'BitLocker' 'OK' "Protection is on ($($bl.EncryptionPercentage)% encrypted)."
            # Event 845 = recovery key was backed up to Entra ID. The key itself is never read.
            $escrow = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-BitLocker/BitLocker Management'; Id = 845 } -MaxEvents 1 -ErrorAction SilentlyContinue
            if ($escrow) { Add-Check 'Recovery key escrow' 'OK' "Backup to Entra ID recorded on $($escrow.TimeCreated.ToString('yyyy-MM-dd'))." }
            else { Add-Check 'Recovery key escrow' 'REVIEW' 'No backup event found. Confirm in Entra/Intune that the recovery key is stored.' }
        }
        elseif ($bl.VolumeStatus -like '*InProgress*') { Add-Check 'BitLocker' 'REVIEW' "Encryption in progress ($($bl.EncryptionPercentage)%). Check again when it finishes." }
        else { Add-Check 'BitLocker' 'FAIL' "Protection is off (status: $($bl.VolumeStatus))." }
    }
    catch { Add-Check 'BitLocker' 'REVIEW' "Could not be read: $($_.Exception.Message)" }

    try { $tpm = Get-Tpm; if ($tpm.TpmReady) { Add-Check 'TPM' 'OK' 'Present and ready.' } else { Add-Check 'TPM' 'FAIL' "Present: $($tpm.TpmPresent), ready: $($tpm.TpmReady)." } }
    catch { Add-Check 'TPM' 'REVIEW' "Could not be read: $($_.Exception.Message)" }

    try { if (Confirm-SecureBootUEFI) { Add-Check 'Secure Boot' 'OK' 'Enabled.' } else { Add-Check 'Secure Boot' 'FAIL' 'Disabled.' } }
    catch { Add-Check 'Secure Boot' 'REVIEW' 'Could not be read (legacy BIOS?).' }

    try {
        $off = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        if ($off.Count -eq 0) { Add-Check 'Windows Firewall' 'OK' 'Enabled for all profiles.' } else { Add-Check 'Windows Firewall' 'FAIL' "Disabled for: $($off -join ', ')." }
    }
    catch { Add-Check 'Windows Firewall' 'REVIEW' "Could not be read: $($_.Exception.Message)" }

    try {
        $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct | ForEach-Object { $_.displayName } | Sort-Object -Unique)
        if ($av.Count -gt 0) { Add-Check 'Antivirus' 'OK' "Registered with Windows Security: $($av -join ', ')." } else { Add-Check 'Antivirus' 'FAIL' 'No antivirus product is registered with Windows Security.' }
    }
    catch { Add-Check 'Antivirus' 'REVIEW' "Could not be read: $($_.Exception.Message)" }
}

function Save-Report {
    param([string]$Overall, [string]$Employee)
    $enc = { param($v) [Net.WebUtility]::HtmlEncode([string]$v) }
    $cs = Get-CimInstance Win32_ComputerSystem
    $serial = [string](Get-CimInstance Win32_BIOS).SerialNumber
    $fileSerial = $serial
    foreach ($c in [IO.Path]::GetInvalidFileNameChars() + ' ') { $fileSerial = $fileSerial.Replace([string]$c, '_') }
    New-Item -ItemType Directory -Path $Reports -Force | Out-Null
    $path = Join-Path $Reports "Part2_$fileSerial.html"
    $colors = @{ OK = '#1e9e57'; FAIL = '#d64545'; REVIEW = '#b97a00' }
    $top = '#d64545'; if ($Overall -eq 'READY') { $top = '#1e9e57' } elseif ($Overall -like 'MANUAL*') { $top = '#b97a00' }
    $html = @('<html><head><meta charset="utf-8"><title>GRE IT Onboarding - Part 2</title>',
        '<style>body{font-family:Segoe UI,Arial;margin:30px;color:#1b2733}h1{color:#0b2a4a}table{border-collapse:collapse;margin-bottom:24px}td,th{border:1px solid #d5dde8;padding:6px 12px;text-align:left;vertical-align:top}th{background:#eef2f7}</style></head><body>',
        '<h1>GRE IT Onboarding - Part 2 Report</h1>',
        ('<p style="font-size:20px"><b style="color:{0}">{1}</b></p>' -f $top, (& $enc $Overall)),
        '<table>',
        ('<tr><th>Employee</th><td>{0}</td></tr><tr><th>Device</th><td>{1}</td></tr><tr><th>Model</th><td>{2} {3}</td></tr><tr><th>Serial number</th><td>{4}</td></tr><tr><th>Generated</th><td>{5}</td></tr>' -f
            (& $enc $Employee), (& $enc $env:COMPUTERNAME), (& $enc $cs.Manufacturer), (& $enc $cs.Model), (& $enc $serial), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        '</table><h2>Checks</h2><table><tr><th>Check</th><th>Result</th><th>Details</th></tr>')
    foreach ($c in $Checks) {
        $html += '<tr><td>{0}</td><td><b style="color:{1}">{2}</b></td><td>{3}</td></tr>' -f (& $enc $c.Name), $colors[$c.Status], $c.Status, (& $enc $c.Message)
    }
    $html += '</table><p>READY = every check passed. NOT READY = at least one check failed. MANUAL REVIEW REQUIRED = nothing failed, but something could not be confirmed.<br>Intune compliance is not decided by this tool. This report contains no passwords and no BitLocker recovery keys.</p></body></html>'
    [IO.File]::WriteAllLines($path, [string[]]$html, (New-Object Text.UTF8Encoding($false)))
    return $path
}

# =================================================================
# MAIN
# =================================================================
$exitCode = 1
try {
    if (-not $UserData) {
        # ---------- first start: must be the employee's own session ----------
        Write-Line '=== GRE IT Onboarding - Part 2 ===' 'STEP'
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $signedIn = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($signedIn -and ($signedIn -ne $me)) {
            Write-Line "This window runs as '$me', but the signed-in user is '$signedIn'." 'FAIL'
            Write-Line 'Start Part 2 with a normal double-click on Start-Part2.cmd (not "Run as administrator"), so the employee profile is configured.' 'FAIL'
            Read-Host 'Press Enter to close'; exit 2
        }
        $data = Invoke-EmployeeStage
        if (-not (Test-IsAdmin)) {
            # Hand the employee results to the elevated stage (no secrets in here).
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $data -Depth 5 -Compress)))
            Write-Line "`nAdministrator rights are needed for the remaining checks - approve the prompt." 'STEP'
            try { Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -UserData {1}' -f $PSCommandPath, $encoded) }
            catch { Write-Line 'The administrator prompt was declined. Part 2 did not finish.' 'FAIL'; Read-Host 'Press Enter to close'; exit 2 }
            exit 0
        }
        $employee = $data.Employee
    }
    else {
        # ---------- elevated stage: load what the employee stage found ----------
        $data = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($UserData)))
        $employee = $data.Employee
        Write-Line "=== GRE IT Onboarding - Part 2 (administrator stage, employee: $employee) ===" 'STEP'
        foreach ($c in $data.Checks) { Add-Check $c.Name $c.Status $c.Message }
    }

    if (-not (Test-IsAdmin)) { throw 'Administrator rights are required for this stage.' }
    Add-Type -AssemblyName PresentationFramework
    Invoke-ApplicationChecks
    Invoke-SecurityChecks

    # A single failure always wins - there is no score that can hide it.
    $failed = @($Checks | Where-Object { $_.Status -eq 'FAIL' }).Count
    $review = @($Checks | Where-Object { $_.Status -eq 'REVIEW' }).Count
    if ($failed -gt 0) { $overall = 'NOT READY'; $level = 'FAIL'; $exitCode = 3 }
    elseif ($review -gt 0) { $overall = 'MANUAL REVIEW REQUIRED'; $level = 'REVIEW'; $exitCode = 5 }
    else { $overall = 'READY'; $level = 'OK'; $exitCode = 0 }

    $report = Save-Report $overall $employee
    Write-Line "`n$overall  ($failed failed, $review to review)" $level
    Write-Line "Report: $report"
    [void][Windows.MessageBox]::Show("$overall`n`n$failed check(s) failed, $review need manual review.`nSee the report in the Reports folder.", $Title, 'OK', 'Information')
}
catch {
    Write-Line "Unexpected error: $($_.Exception.Message)" 'FAIL'
    Write-Line $_.ScriptStackTrace 'FAIL'
}
Read-Host "`nPress Enter to close"
exit $exitCode
