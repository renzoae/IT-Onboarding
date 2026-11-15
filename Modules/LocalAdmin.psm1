<#
    GRE IT Onboarding - Local administrator module (business logic, no GUI)

    Security rules implemented here:
      * The password only ever exists as a SecureString. For policy checks it is
        copied to a char[] that is zeroed immediately afterwards (never a String).
      * Nothing in this module logs, returns or persists password material.
      * An existing account is never modified unless the caller passes the
        explicit -ResetPassword / -AddToAdministrators / -EnableAccount switches.
      * The Administrators group is addressed by its well-known SID (S-1-5-32-544)
        so the code works on non-English Windows.
#>
Set-StrictMode -Version 2.0

$script:AdministratorsSid = 'S-1-5-32-544'
$script:MaxUserNameLength = 20
$script:MaxPasswordLength = 127
$script:InvalidUserNameChars = [char[]]'"/\[]:;|=,+*?<>@'

# ---------------------------------------------------------------------------
# Thin wrappers around OS cmdlets (kept separate so Pester can mock them)
# ---------------------------------------------------------------------------
function Get-LAUser { param([string]$Name) return (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) }
function New-LAUser {
    param([string]$Name, [securestring]$Password, [string]$Description, [bool]$PasswordNeverExpires)
    $p = @{ Name = $Name; Password = $Password; AccountNeverExpires = $true; ErrorAction = 'Stop' }
    if ($Description) { $p['Description'] = $Description }
    if ($PasswordNeverExpires) { $p['PasswordNeverExpires'] = $true }
    return (New-LocalUser @p)
}
function Set-LAUserPassword { param([string]$Name, [securestring]$Password) Set-LocalUser -Name $Name -Password $Password -ErrorAction Stop }
function Enable-LAUser { param([string]$Name) Enable-LocalUser -Name $Name -ErrorAction Stop }
function Remove-LAUser { param([string]$Name) Remove-LocalUser -Name $Name -ErrorAction Stop }
function Add-LAAdministrator { param([string]$Name) Add-LocalGroupMember -SID $script:AdministratorsSid -Member $Name -ErrorAction Stop }
function Get-LAAdministratorSids {
    <# Returns the SID strings of all members of the local Administrators group. #>
    try {
        return @(Get-LocalGroupMember -SID $script:AdministratorsSid -ErrorAction Stop | ForEach-Object { [string]$_.SID })
    }
    catch {
        # Get-LocalGroupMember fails when the group contains orphaned (unresolvable) SIDs.
        # Fall back to ADSI, which tolerates them.
        $groupName = (Get-LocalGroup -SID $script:AdministratorsSid -ErrorAction Stop).Name
        $group = [ADSI]("WinNT://./{0},group" -f $groupName)
        $sids = @()
        foreach ($member in @($group.psbase.Invoke('Members'))) {
            $bytes = $member.GetType().InvokeMember('objectSid', 'GetProperty', $null, $member, $null)
            $sids += (New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value
        }
        return $sids
    }
}

# ---------------------------------------------------------------------------
# SecureString helpers
# ---------------------------------------------------------------------------
function ConvertTo-LACharArray {
    <# Copies a SecureString into a char[] via a zero-freed BSTR. Caller MUST clear the array. #>
    param([Parameter(Mandatory = $true)][securestring]$SecureString)
    $length = $SecureString.Length
    $chars = New-Object char[] $length
    if ($length -eq 0) { return , $chars }
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        [System.Runtime.InteropServices.Marshal]::Copy($bstr, $chars, 0, $length)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    return , $chars
}

function Clear-LACharArray {
    param([AllowNull()][char[]]$Chars)
    if ($null -ne $Chars -and $Chars.Length -gt 0) { [Array]::Clear($Chars, 0, $Chars.Length) }
}

function Test-LACharArrayContains {
    <# Case-insensitive search of a (non-secret) term inside a char[] without building a String. #>
    param([char[]]$Haystack, [string]$Needle)
    if ([string]::IsNullOrEmpty($Needle) -or $null -eq $Haystack) { return $false }
    $n = $Needle.ToLowerInvariant().ToCharArray()
    if ($n.Length -gt $Haystack.Length) { return $false }
    for ($i = 0; $i -le ($Haystack.Length - $n.Length); $i++) {
        $match = $true
        for ($j = 0; $j -lt $n.Length; $j++) {
            if ([char]::ToLowerInvariant($Haystack[$i + $j]) -ne $n[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

function Test-SecureStringEqual {
    <# Compares two SecureStrings without creating managed strings. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][securestring]$First,
        [Parameter(Mandatory = $true)][securestring]$Second
    )
    $a = $null; $b = $null
    try {
        $a = ConvertTo-LACharArray -SecureString $First
        $b = ConvertTo-LACharArray -SecureString $Second
        if ($a.Length -ne $b.Length) { return $false }
        $diff = 0
        for ($i = 0; $i -lt $a.Length; $i++) { $diff = $diff -bor ([int]$a[$i] -bxor [int]$b[$i]) }
        return ($diff -eq 0)
    }
    finally {
        Clear-LACharArray $a
        Clear-LACharArray $b
    }
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
function Test-LocalAdminUserName {
    <#
        Validates a name against Windows local account (SAM) naming rules.
        Returns: [pscustomobject] @{ IsValid; Errors (string[]) }
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$UserName,
        [string]$ComputerName = $env:COMPUTERNAME
    )
    $errors = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($UserName)) {
        $errors.Add('Username is required.')
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }
    if ($UserName -ne $UserName.Trim()) { $errors.Add('Username must not start or end with a space.') }
    if ($UserName.Length -gt $script:MaxUserNameLength) { $errors.Add("Username must be $($script:MaxUserNameLength) characters or fewer.") }
    if ($UserName.IndexOfAny($script:InvalidUserNameChars) -ge 0) {
        $errors.Add('Username contains a character Windows does not allow: " / \ [ ] : ; | = , + * ? < > @')
    }
    foreach ($c in $UserName.ToCharArray()) {
        if ([char]::IsControl($c)) { $errors.Add('Username must not contain control characters.'); break }
    }
    if ($UserName -match '^[\. ]+$') { $errors.Add('Username cannot consist only of periods or spaces.') }
    if ($UserName.EndsWith('.')) { $errors.Add('Username cannot end with a period.') }
    if ($ComputerName -and ($UserName -ieq $ComputerName)) { $errors.Add('Username cannot be the same as the computer name.') }
    return [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Test-LocalAdminPassword {
    <#
        Checks a SecureString password against the configured policy
        (Config\Settings.json -> LocalAdmin) and the Windows complexity rule
        (3 of 4 character classes, must not contain the account name).
        The machine's effective password policy is additionally enforced by
        Windows itself when the account is created.
        Returns: [pscustomobject] @{ IsValid; Errors (string[]) } - never any password content.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][securestring]$Password,
        [AllowEmptyString()][string]$UserName = '',
        [hashtable]$Policy = @{}
    )
    $minLength = 12
    if ($Policy.ContainsKey('MinimumPasswordLength')) { $minLength = [int]$Policy['MinimumPasswordLength'] }
    $requireComplexity = $true
    if ($Policy.ContainsKey('RequireComplexity')) { $requireComplexity = [bool]$Policy['RequireComplexity'] }
    $disallowName = $true
    if ($Policy.ContainsKey('DisallowUserNameInPassword')) { $disallowName = [bool]$Policy['DisallowUserNameInPassword'] }
    $forbidden = @()
    if ($Policy.ContainsKey('ForbiddenPasswordTerms') -and $null -ne $Policy['ForbiddenPasswordTerms']) { $forbidden = @($Policy['ForbiddenPasswordTerms']) }

    $errors = New-Object System.Collections.Generic.List[string]
    $chars = $null
    try {
        $chars = ConvertTo-LACharArray -SecureString $Password
        if ($chars.Length -eq 0) {
            $errors.Add('Password is required.')
            return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() }
        }
        if ($chars.Length -lt $minLength) { $errors.Add("Password must be at least $minLength characters long.") }
        if ($chars.Length -gt $script:MaxPasswordLength) { $errors.Add("Password must be $($script:MaxPasswordLength) characters or fewer.") }

        if ($requireComplexity) {
            $upper = $false; $lower = $false; $digit = $false; $other = $false
            foreach ($c in $chars) {
                if ([char]::IsUpper($c)) { $upper = $true }
                elseif ([char]::IsLower($c)) { $lower = $true }
                elseif ([char]::IsDigit($c)) { $digit = $true }
                else { $other = $true }
            }
            $classes = @($upper, $lower, $digit, $other | Where-Object { $_ }).Count
            if ($classes -lt 3) {
                $errors.Add('Password must contain at least three of: uppercase letters, lowercase letters, digits, symbols.')
            }
        }
        if ($disallowName -and $UserName -and $UserName.Length -ge 3) {
            if (Test-LACharArrayContains -Haystack $chars -Needle $UserName) { $errors.Add('Password must not contain the username.') }
        }
        foreach ($term in $forbidden) {
            if ($term -and (Test-LACharArrayContains -Haystack $chars -Needle ([string]$term))) {
                $errors.Add('Password contains a term that company policy forbids.')
                break
            }
        }
    }
    finally {
        Clear-LACharArray $chars
    }
    return [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

# ---------------------------------------------------------------------------
# Account state / creation / verification
# ---------------------------------------------------------------------------
function Get-LocalAdminAccountState {
    <# Read-only. Returns Exists / Enabled / IsAdministrator for a local account name. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UserName)
    $user = Get-LAUser -Name $UserName
    if ($null -eq $user) {
        return [pscustomobject]@{ UserName = $UserName; Exists = $false; Enabled = $false; IsAdministrator = $false; Sid = $null }
    }
    $sid = [string]$user.SID
    $adminSids = @(Get-LAAdministratorSids)
    return [pscustomobject]@{
        UserName        = [string]$user.Name
        Exists          = $true
        Enabled         = [bool]$user.Enabled
        IsAdministrator = ($adminSids -contains $sid)
        Sid             = $sid
    }
}

function Test-LocalAdminAccount {
    <# Verification gate: account exists, is enabled and is a member of Administrators. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UserName)
    $state = Get-LocalAdminAccountState -UserName $UserName
    $problems = @()
    if (-not $state.Exists) { $problems += "account '$UserName' does not exist" }
    else {
        if (-not $state.Enabled) { $problems += 'account is disabled' }
        if (-not $state.IsAdministrator) { $problems += 'account is not a member of the local Administrators group' }
    }
    $ok = ($problems.Count -eq 0)
    $message = 'Account exists, is enabled and is a member of the local Administrators group.'
    if (-not $ok) { $message = 'Verification failed: ' + ($problems -join '; ') + '.' }
    return [pscustomobject]@{
        Success         = $ok
        Exists          = $state.Exists
        Enabled         = $state.Enabled
        IsAdministrator = $state.IsAdministrator
        Message         = $message
    }
}

function New-LocalAdminAccount {
    <#
        Creates a NEW local account and adds it to Administrators.
        Throws if the account already exists (use Update-LocalAdminAccount with
        explicit switches for that). If the group change fails, the account that
        was just created by this call is removed again so no half-configured
        account is left behind.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][securestring]$Password,
        [string]$Description = '',
        [bool]$PasswordNeverExpires = $false
    )
    $check = Test-LocalAdminUserName -UserName $UserName
    if (-not $check.IsValid) { throw ('Invalid username: ' + ($check.Errors -join ' ')) }
    if ($null -ne (Get-LAUser -Name $UserName)) {
        throw "Account '$UserName' already exists. It was not modified."
    }
    if ($Description.Length -gt 48) { $Description = $Description.Substring(0, 48) }
    if (-not $PSCmdlet.ShouldProcess($UserName, 'Create local administrator account')) { return $null }

    New-LAUser -Name $UserName -Password $Password -Description $Description -PasswordNeverExpires $PasswordNeverExpires | Out-Null
    try {
        Add-LAAdministrator -Name $UserName
    }
    catch {
        $reason = $_.Exception.Message
        try { Remove-LAUser -Name $UserName } catch { }
        throw "The account was created but could not be added to the Administrators group ($reason). The new account was removed again."
    }
    return (Get-LocalAdminAccountState -UserName $UserName)
}

function Update-LocalAdminAccount {
    <#
        Modifies an EXISTING account. Does nothing unless at least one explicit
        switch is supplied - the GUI only passes a switch after the technician
        confirmed that specific change.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [securestring]$Password,
        [switch]$ResetPassword,
        [switch]$AddToAdministrators,
        [switch]$EnableAccount
    )
    $state = Get-LocalAdminAccountState -UserName $UserName
    if (-not $state.Exists) { throw "Account '$UserName' does not exist." }
    $changes = @()
    if ($ResetPassword) {
        if ($null -eq $Password) { throw 'A password is required to reset the account password.' }
        if ($PSCmdlet.ShouldProcess($UserName, 'Reset password')) {
            Set-LAUserPassword -Name $UserName -Password $Password
            $changes += 'PasswordReset'
        }
    }
    if ($EnableAccount -and -not $state.Enabled) {
        if ($PSCmdlet.ShouldProcess($UserName, 'Enable account')) {
            Enable-LAUser -Name $UserName
            $changes += 'Enabled'
        }
    }
    if ($AddToAdministrators -and -not $state.IsAdministrator) {
        if ($PSCmdlet.ShouldProcess($UserName, 'Add to local Administrators group')) {
            Add-LAAdministrator -Name $UserName
            $changes += 'AddedToAdministrators'
        }
    }
    return [pscustomobject]@{ UserName = $UserName; Changes = $changes }
}

Export-ModuleMember -Function Test-LocalAdminUserName, Test-LocalAdminPassword, Test-SecureStringEqual,
    Get-LocalAdminAccountState, Test-LocalAdminAccount, New-LocalAdminAccount, Update-LocalAdminAccount
