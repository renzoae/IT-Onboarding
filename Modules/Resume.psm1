<#
    GRE IT Onboarding - Resume / checkpoint module
    Stores NON-SENSITIVE task progress in a protected local folder and manages
    the temporary "resume after restart" scheduled task.
    No credentials are stored in the state file or in the scheduled task.
#>
Set-StrictMode -Version 2.0

$script:ValidStatuses = @('Pending', 'Running', 'Completed', 'Failed', 'RestartRequired', 'Skipped')

function Get-ResumeLocalRoot {
    if ($env:GRE_ONBOARDING_LOCALROOT) { return $env:GRE_ONBOARDING_LOCALROOT }
    $base = $env:ProgramData
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path $base 'GRE-IT-Onboarding')
}

function ConvertTo-ResumeHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [System.ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($InputObject.Keys)) { $h[[string]$k] = ConvertTo-ResumeHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($i in $InputObject) { $list += , (ConvertTo-ResumeHashtable $i) }
        return , $list
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-ResumeHashtable $p.Value }
        return $h
    }
    return $InputObject
}

function Initialize-OnboardingLocalRoot {
    <#
        Creates the local working root and restricts it to Administrators + SYSTEM,
        because an elevated resume task later executes a script stored there.
    #>
    [CmdletBinding()]
    param([switch]$SkipAcl)
    $root = Get-ResumeLocalRoot
    foreach ($d in @($root, (Join-Path $root 'State'), (Join-Path $root 'Work'), (Join-Path $root 'Logs'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    if (-not $SkipAcl -and -not $env:GRE_ONBOARDING_LOCALROOT) {
        try {
            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
            foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
                $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $inherit, 'None', 'Allow')
                $acl.AddAccessRule($rule)
            }
            $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
            Set-Acl -LiteralPath $root -AclObject $acl -ErrorAction Stop
        }
        catch {
            throw "Could not secure the local working folder '$root': $($_.Exception.Message)"
        }
    }
    return $root
}

function Get-OnboardingStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part)
    return (Join-Path (Join-Path (Get-ResumeLocalRoot) 'State') ("Part{0}.state.json" -f $Part))
}

function New-OnboardingState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part,
        [Parameter(Mandatory = $true)][string]$AppRoot
    )
    $full = [System.IO.Path]::GetFullPath($AppRoot)
    $rootOfDrive = [System.IO.Path]::GetPathRoot($full)
    return @{
        SchemaVersion   = 1
        Part            = $Part
        SessionId       = [guid]::NewGuid().ToString()
        ComputerName    = $env:COMPUTERNAME
        CreatedAt       = (Get-Date).ToString('o')
        UpdatedAt       = (Get-Date).ToString('o')
        # Path without the drive letter so the USB can come back under another letter.
        AppRelativePath = $full.Substring($rootOfDrive.Length)
        Technician      = ''
        Completed       = $false
        CompletedAt     = $null
        Steps           = @{}
    }
}

function Save-OnboardingState {
    <# Atomic write (temp file + replace) so a power loss cannot leave a half-written checkpoint. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$State)
    $path = Get-OnboardingStatePath -Part ([int]$State['Part'])
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $State['UpdatedAt'] = (Get-Date).ToString('o')
    $json = ConvertTo-Json -InputObject $State -Depth 12
    if ($json -match '(?i)"[^"]*(password|secret|token|recoverykey)[^"]*"\s*:') {
        throw 'Refusing to save onboarding state: it contains a credential-like field.'
    }
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-OnboardingState {
    <# Returns the saved state as a hashtable, or $null when none exists / it is unreadable. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part)
    $path = Get-OnboardingStatePath -Part $Part
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path)
        $state = ConvertTo-ResumeHashtable (ConvertFrom-Json -InputObject $raw)
        if ($null -eq $state -or -not $state.ContainsKey('Steps') -or [int]$state['Part'] -ne $Part) { throw 'Unexpected state format.' }
        if ($null -eq $state['Steps']) { $state['Steps'] = @{} }
        return $state
    }
    catch {
        # Keep the damaged file for troubleshooting but never trust it.
        $bad = '{0}.{1}.corrupt' -f $path, (Get-Date -Format 'yyyyMMddHHmmss')
        try { Move-Item -LiteralPath $path -Destination $bad -Force } catch { }
        return $null
    }
}

function Remove-OnboardingState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part)
    $path = Get-OnboardingStatePath -Part $Part
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Set-OnboardingStepState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Message = '',
        [hashtable]$Data,
        [switch]$NoSave
    )
    if ($script:ValidStatuses -notcontains $Status) { throw "Invalid step status '$Status'." }
    $existing = $null
    if ($State['Steps'].ContainsKey($Name)) { $existing = $State['Steps'][$Name] }
    $attempts = 0
    if ($existing -and $existing.ContainsKey('Attempts')) { $attempts = [int]$existing['Attempts'] }
    if ($Status -eq 'Running') { $attempts++ }
    if ($null -eq $Data) {
        if ($existing -and $existing.ContainsKey('Data') -and $null -ne $existing['Data']) { $Data = $existing['Data'] } else { $Data = @{} }
    }
    $State['Steps'][$Name] = @{
        Status    = $Status
        Message   = $Message
        Timestamp = (Get-Date).ToString('o')
        Attempts  = $attempts
        Data      = $Data
    }
    if (-not $NoSave) { Save-OnboardingState -State $State }
}

function Get-OnboardingStepStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)][string]$Name)
    if ($State['Steps'].ContainsKey($Name)) { return [string]$State['Steps'][$Name]['Status'] }
    return 'Pending'
}

function Get-OnboardingStepData {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)][string]$Name)
    if ($State['Steps'].ContainsKey($Name)) {
        $d = $State['Steps'][$Name]['Data']
        if ($d -is [hashtable]) { return $d }
    }
    return @{}
}

function Test-OnboardingStepCompleted {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)][string]$Name)
    return ((Get-OnboardingStepStatus -State $State -Name $Name) -eq 'Completed')
}

function Reset-OnboardingInterruptedSteps {
    <# A step left 'Running' means the process died mid-step (power loss/restart): it must run again. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$State)
    $changed = $false
    foreach ($name in @($State['Steps'].Keys)) {
        if ($State['Steps'][$name]['Status'] -eq 'Running') {
            $State['Steps'][$name]['Status'] = 'Pending'
            $State['Steps'][$name]['Message'] = 'Interrupted before completion; will run again.'
            $changed = $true
        }
    }
    if ($changed) { Save-OnboardingState -State $State }
    return $changed
}

# ---------------------------------------------------------------------------
# Resume-after-restart scheduled task
# ---------------------------------------------------------------------------

function Get-OnboardingResumeTaskName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part)
    return ('GRE-IT-Onboarding-Resume-Part{0}' -f $Part)
}

function Get-OnboardingResumeStubPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part)
    return (Join-Path (Get-ResumeLocalRoot) ('Resume-Part{0}.ps1' -f $Part))
}

function New-OnboardingResumeStubContent {
    <#
        Builds the small local script the scheduled task runs after a restart.
        It finds the USB again under ANY drive letter, verifies that the launcher is
        byte-identical to the one that scheduled the resume (SHA-256) and starts it.
        It contains no credentials.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AppRelativePath,
        [Parameter(Mandatory = $true)][string]$LauncherHash
    )
    $rel = $AppRelativePath.Replace("'", "''")
    $template = @'
# Auto-generated by GRE IT Onboarding. Temporary - removed by cleanup. Contains no credentials.
$ErrorActionPreference = 'Stop'
$relative = '__REL__'
$expectedHash = '__HASH__'
$part = '__PART__'
Add-Type -AssemblyName System.Windows.Forms
function Find-Launcher {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        $candidate = Join-Path (Join-Path $drive.RootDirectory.FullName $relative) 'Scripts\Launcher.ps1'
        if (Test-Path -LiteralPath $candidate) {
            try {
                if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -eq $expectedHash) { return $candidate }
            } catch { }
        }
    }
    return $null
}
$launcher = Find-Launcher
while (-not $launcher) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "GRE IT Onboarding needs to resume Part $part after the restart, but the onboarding USB drive was not found.`n`nInsert the USB drive and choose Retry, or Cancel to resume later by running Start-Part$($part).cmd from the USB.",
        'GRE IT Onboarding', 'RetryCancel', 'Warning')
    if ($answer -ne 'Retry') { exit 4 }
    $launcher = Find-Launcher
}
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -ExecutionPolicy RemoteSigned -STA -File "{0}" -Part {1} -Resume' -f $launcher, $part
Start-Process -FilePath $ps -ArgumentList $arguments
'@
    return $template.Replace('__REL__', $rel).Replace('__HASH__', $LauncherHash).Replace('__PART__', [string]$Part)
}

function Register-OnboardingResumeTask {
    <#
        Registers a logon-triggered task that runs elevated for any member of the
        local Administrators group in THEIR interactive session. Group principal =
        no stored password.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part,
        [Parameter(Mandatory = $true)][string]$AppRoot
    )
    $full = [System.IO.Path]::GetFullPath($AppRoot)
    $launcher = Join-Path $full 'Scripts\Launcher.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) { throw "Launcher not found at '$launcher'." }
    $hash = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
    $relative = $full.Substring([System.IO.Path]::GetPathRoot($full).Length)

    $stub = Get-OnboardingResumeStubPath -Part $Part
    $content = New-OnboardingResumeStubContent -Part $Part -AppRelativePath $relative -LauncherHash $hash
    [System.IO.File]::WriteAllText($stub, $content, [System.Text.Encoding]::ASCII)

    $adminGroup = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Hidden -File "{0}"' -f $stub)
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId $adminGroup -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 12)
    $name = Get-OnboardingResumeTaskName -Part $Part
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Temporary: resumes GRE IT Onboarding after a restart. Removed automatically on completion.' -Force | Out-Null
    return $name
}

function Test-OnboardingResumeTask {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part)
    $name = Get-OnboardingResumeTaskName -Part $Part
    return ($null -ne (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue))
}

function Unregister-OnboardingResumeTask {
    <# Removes the temporary task and its stub. Safe to call when nothing exists. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$Part)
    $name = Get-OnboardingResumeTaskName -Part $Part
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
    }
    $stub = Get-OnboardingResumeStubPath -Part $Part
    if (Test-Path -LiteralPath $stub) { Remove-Item -LiteralPath $stub -Force }
}

Export-ModuleMember -Function Initialize-OnboardingLocalRoot, Get-OnboardingStatePath, New-OnboardingState, Save-OnboardingState,
    Get-OnboardingState, Remove-OnboardingState, Set-OnboardingStepState, Get-OnboardingStepStatus, Get-OnboardingStepData,
    Test-OnboardingStepCompleted, Reset-OnboardingInterruptedSteps, Get-OnboardingResumeTaskName, Get-OnboardingResumeStubPath,
    New-OnboardingResumeStubContent, Register-OnboardingResumeTask, Test-OnboardingResumeTask, Unregister-OnboardingResumeTask
