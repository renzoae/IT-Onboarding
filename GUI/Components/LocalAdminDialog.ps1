<#
    GRE IT Onboarding - Local administrator dialog (GUI layer)
    Dot-sourced by Scripts\Part1.ps1 after GUI\MainWindow.ps1.

    * WPF PasswordBox masks input and exposes SecurePassword (a SecureString);
      the .Password string property is never read.
    * SecureStrings are disposed and the PasswordBoxes cleared as soon as the
      account operation finishes, whatever the outcome.
#>

function Show-LocalAdminDialog {
    <#
        Shows the credential dialog. Returns
        @{ Confirmed; UserName; Password (read-only SecureString - caller must Dispose) }.
    #>
    param(
        $Owner,
        [Parameter(Mandatory = $true)][string]$XamlPath,
        [hashtable]$Policy = @{},
        [string]$InitialUserName = '',
        [string]$InitialError = ''
    )
    $dialog = Import-OnboardingXaml -Path $XamlPath
    if ($null -ne $Owner) { $dialog.Owner = $Owner }
    $userBox = $dialog.FindName('UserNameBox')
    $pw1 = $dialog.FindName('PasswordBox1')
    $pw2 = $dialog.FindName('PasswordBox2')
    $errorPanel = $dialog.FindName('ErrorPanel')
    $errorText = $dialog.FindName('ErrorText')
    $policyText = $dialog.FindName('PolicyText')
    $okButton = $dialog.FindName('OkButton')

    $minLength = 12
    if ($Policy.ContainsKey('MinimumPasswordLength')) { $minLength = [int]$Policy['MinimumPasswordLength'] }
    $policyText.Text = "Password policy: at least $minLength characters, with three of uppercase / lowercase / digits / symbols, and not containing the username. Windows may enforce additional rules when the account is created."
    $userBox.Text = $InitialUserName
    if ($InitialError) { $errorText.Text = $InitialError; $errorPanel.Visibility = 'Visible' }

    $result = @{ Confirmed = $false; UserName = $null; Password = $null }

    $okButton.Add_Click({
            $messages = New-Object System.Collections.Generic.List[string]
            $name = $userBox.Text
            $nameCheck = Test-LocalAdminUserName -UserName $name
            foreach ($m in $nameCheck.Errors) { $messages.Add($m) }

            $first = $pw1.SecurePassword      # copies; disposed below unless handed to the caller
            $second = $pw2.SecurePassword
            $handedOver = $false
            try {
                if ($first.Length -eq 0) { $messages.Add('Password is required.') }
                elseif (-not (Test-SecureStringEqual -First $first -Second $second)) { $messages.Add('Password and Confirm Password do not match.') }
                else {
                    $pwCheck = Test-LocalAdminPassword -Password $first -UserName $name -Policy $Policy
                    foreach ($m in $pwCheck.Errors) { $messages.Add($m) }
                }
                if ($messages.Count -eq 0) {
                    $first.MakeReadOnly()
                    $result.UserName = $name
                    $result.Password = $first
                    $result.Confirmed = $true
                    $handedOver = $true
                    $pw1.Clear(); $pw2.Clear()
                    $dialog.DialogResult = $true
                }
                else {
                    $errorText.Text = ($messages -join [Environment]::NewLine)
                    $errorPanel.Visibility = 'Visible'
                }
            }
            finally {
                if (-not $handedOver) { $first.Dispose() }
                $second.Dispose()
            }
        })

    $dialog.Add_Closed({ $pw1.Clear(); $pw2.Clear() })
    [void]$userBox.Focus()
    [void]$dialog.ShowDialog()
    return $result
}

function Invoke-LocalAdminSetupInteractive {
    <#
        Full interactive flow: prompt -> (confirm if account exists) -> create/update -> verify.
        Loops until verification succeeds or the technician cancels.
        Returns @{ Success; Cancelled; UserName; Action; Message }.
        Action: Created | ExistingUnchanged | ExistingUpdated
    #>
    param(
        $Owner,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )
    $policy = $Context.Settings['LocalAdmin']
    $xaml = Join-Path (Join-Path $Context.GuiRoot 'Components') 'LocalAdminDialog.xaml'
    $title = 'GRE IT Onboarding'
    $lastName = ''
    $lastError = ''

    while ($true) {
        $entry = Show-LocalAdminDialog -Owner $Owner -XamlPath $xaml -Policy $policy -InitialUserName $lastName -InitialError $lastError
        if (-not $entry.Confirmed) {
            return @{ Success = $false; Cancelled = $true; UserName = $null; Action = $null; Message = 'Cancelled by the technician.' }
        }
        $userName = [string]$entry.UserName
        $securePassword = $entry.Password
        $lastName = $userName
        $lastError = ''
        $action = $null
        try {
            $account = Get-LocalAdminAccountState -UserName $userName
            if (-not $account.Exists) {
                Write-OnboardingLog -Step 'LocalAdmin' -Message "Creating local account '$userName' and adding it to the Administrators group."
                New-LocalAdminAccount -UserName $userName -Password $securePassword `
                    -Description ([string]$policy['AccountDescription']) -PasswordNeverExpires ([bool]$policy['PasswordNeverExpires']) | Out-Null
                $action = 'Created'
            }
            else {
                Write-OnboardingLog -Step 'LocalAdmin' -Level WARN -Message "Account '$userName' already exists (enabled: $($account.Enabled), administrator: $($account.IsAdministrator)). Asking for explicit confirmation."
                $answer = [System.Windows.MessageBox]::Show($Owner,
                    "The local account '$userName' already exists.`n`nDo you want to RESET its password to the one you just entered?`n`nYes = reset the password`nNo = keep the existing password unchanged`nCancel = choose a different username",
                    $title, 'YesNoCancel', 'Warning', 'Cancel')
                if ($answer -eq 'Cancel') { $lastError = "Account '$userName' was not modified. Choose a different username."; continue }
                $reset = ($answer -eq 'Yes')

                $needsPrivilegeChange = (-not $account.IsAdministrator) -or (-not $account.Enabled)
                if ($needsPrivilegeChange) {
                    $what = @()
                    if (-not $account.Enabled) { $what += 'enable the account' }
                    if (-not $account.IsAdministrator) { $what += 'add it to the local Administrators group' }
                    $answer2 = [System.Windows.MessageBox]::Show($Owner,
                        "To use '$userName' as the local administrator, the tool must $($what -join ' and ').`n`nDo you approve this change to the existing account?",
                        $title, 'YesNo', 'Warning', 'No')
                    if ($answer2 -ne 'Yes') {
                        $lastError = "Account '$userName' was not modified. It cannot be used as the local administrator without that change - choose a different username."
                        continue
                    }
                }
                if ($reset -or $needsPrivilegeChange) {
                    $update = Update-LocalAdminAccount -UserName $userName -Password $securePassword -ResetPassword:$reset `
                        -AddToAdministrators:$needsPrivilegeChange -EnableAccount:$needsPrivilegeChange
                    Write-OnboardingLog -Step 'LocalAdmin' -Message "Existing account '$userName' updated with technician approval: $(@($update.Changes) -join ', ')."
                    $action = 'ExistingUpdated'
                }
                else {
                    Write-OnboardingLog -Step 'LocalAdmin' -Message "Existing account '$userName' left unchanged at the technician's request."
                    $action = 'ExistingUnchanged'
                }
            }

            $verify = Test-LocalAdminAccount -UserName $userName
            if ($verify.Success) {
                Write-OnboardingLog -Step 'LocalAdmin' -Level SUCCESS -Message "Verified: '$userName' exists, is enabled and is a member of the local Administrators group."
                return @{ Success = $true; Cancelled = $false; UserName = $userName; Action = $action; Message = $verify.Message }
            }
            $lastError = $verify.Message
            Write-OnboardingLog -Step 'LocalAdmin' -Level ERROR -Message $verify.Message
        }
        catch {
            # Exception text from the account cmdlets never contains the password.
            $lastError = "The account operation failed: $($_.Exception.Message)"
            Write-OnboardingLog -Step 'LocalAdmin' -Level ERROR -Message $lastError
        }
        finally {
            if ($null -ne $securePassword) { $securePassword.Dispose() }
            $securePassword = $null
            $entry.Password = $null
            [System.GC]::Collect()
        }
    }
}
