BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\LocalAdmin.psm1') -Force
    function New-TestSecureString([string]$Text) { ConvertTo-SecureString $Text -AsPlainText -Force }   # test-only literals
}

Describe 'Test-LocalAdminUserName' {
    It 'accepts <Name>' -ForEach @(
        @{ Name = 'itadmin' }, @{ Name = 'GRE-Admin_01' }, @{ Name = 'local.admin' }, @{ Name = 'a' }, @{ Name = ('x' * 20) }
    ) {
        (Test-LocalAdminUserName -UserName $Name -ComputerName 'PC01').IsValid | Should -BeTrue
    }
    It 'rejects <Name> (<Why>)' -ForEach @(
        @{ Name = ''; Why = 'empty' }
        @{ Name = ('x' * 21); Why = 'longer than 20' }
        @{ Name = 'ad/min'; Why = 'slash' }
        @{ Name = 'ad\min'; Why = 'backslash' }
        @{ Name = 'ad:min'; Why = 'colon' }
        @{ Name = 'admin@corp'; Why = 'at sign' }
        @{ Name = 'ad"min'; Why = 'quote' }
        @{ Name = 'a[b]'; Why = 'brackets' }
        @{ Name = 'a*b'; Why = 'asterisk' }
        @{ Name = 'a?b'; Why = 'question mark' }
        @{ Name = 'a<b>'; Why = 'angle brackets' }
        @{ Name = 'a,b'; Why = 'comma' }
        @{ Name = 'a;b=c+d|e'; Why = 'punctuation' }
        @{ Name = '...'; Why = 'only periods' }
        @{ Name = '. .'; Why = 'periods and spaces' }
        @{ Name = 'admin.'; Why = 'trailing period' }
        @{ Name = ' admin'; Why = 'leading space' }
        @{ Name = 'admin '; Why = 'trailing space' }
        @{ Name = "ad`tmin"; Why = 'control character' }
        @{ Name = 'pc01'; Why = 'same as computer name' }
    ) {
        $r = Test-LocalAdminUserName -UserName $Name -ComputerName 'PC01'
        $r.IsValid | Should -BeFalse
        $r.Errors.Count | Should -BeGreaterThan 0
    }
    It 'rejects $null' { (Test-LocalAdminUserName -UserName $null).IsValid | Should -BeFalse }
}

Describe 'Test-LocalAdminPassword' {
    BeforeAll { $policy = @{ MinimumPasswordLength = 12; RequireComplexity = $true; DisallowUserNameInPassword = $true; ForbiddenPasswordTerms = @('acme') } }

    It 'accepts a compliant password' {
        (Test-LocalAdminPassword -Password (New-TestSecureString 'Tr1cky-Horse-Battery') -UserName 'itadmin' -Policy $policy).IsValid | Should -BeTrue
    }
    It 'rejects a short password' {
        (Test-LocalAdminPassword -Password (New-TestSecureString 'Ab1!xyz') -UserName 'itadmin' -Policy $policy).IsValid | Should -BeFalse
    }
    It 'rejects fewer than three character classes' {
        (Test-LocalAdminPassword -Password (New-TestSecureString 'alllowercaseletters') -UserName 'itadmin' -Policy $policy).IsValid | Should -BeFalse
    }
    It 'rejects a password containing the username (case-insensitive)' {
        (Test-LocalAdminPassword -Password (New-TestSecureString 'Xx-ITADMIN-2024!') -UserName 'itadmin' -Policy $policy).IsValid | Should -BeFalse
    }
    It 'rejects a forbidden company term' {
        (Test-LocalAdminPassword -Password (New-TestSecureString 'Welcome-Acme-2024!') -UserName 'itadmin' -Policy $policy).IsValid | Should -BeFalse
    }
    It 'rejects an empty password' {
        (Test-LocalAdminPassword -Password (New-Object System.Security.SecureString) -UserName 'itadmin' -Policy $policy).IsValid | Should -BeFalse
    }
    It 'never echoes the password in its error messages' {
        $secret = 'zzSecretValue'
        $r = Test-LocalAdminPassword -Password (New-TestSecureString $secret) -UserName 'itadmin' -Policy $policy
        ($r.Errors -join ' ') | Should -Not -Match $secret
    }
}

Describe 'Test-SecureStringEqual' {
    It 'is true for equal values' { Test-SecureStringEqual (New-TestSecureString 'Same#Value1') (New-TestSecureString 'Same#Value1') | Should -BeTrue }
    It 'is false for different values' { Test-SecureStringEqual (New-TestSecureString 'Same#Value1') (New-TestSecureString 'Same#Value2') | Should -BeFalse }
    It 'is false for different lengths' { Test-SecureStringEqual (New-TestSecureString 'abc') (New-TestSecureString 'abcd') | Should -BeFalse }
}

Describe 'Account operations (mocked OS calls)' {
    BeforeAll { $pw = New-TestSecureString 'Tr1cky-Horse-Battery' }

    Context 'new account' {
        BeforeEach {
            $script:created = $false
            Mock -ModuleName LocalAdmin Get-LAUser { if ($script:created) { [pscustomobject]@{ Name = 'itadmin'; Enabled = $true; SID = 'S-1-5-21-1-2-3-1001' } } }
            Mock -ModuleName LocalAdmin New-LAUser { $script:created = $true }
            Mock -ModuleName LocalAdmin Add-LAAdministrator { }
            Mock -ModuleName LocalAdmin Remove-LAUser { $script:created = $false }
            Mock -ModuleName LocalAdmin Get-LAAdministratorSids { @('S-1-5-21-1-2-3-500', 'S-1-5-21-1-2-3-1001') }
        }
        It 'creates the account, adds it to Administrators and verifies' {
            $state = New-LocalAdminAccount -UserName 'itadmin' -Password $pw
            $state.IsAdministrator | Should -BeTrue
            Should -Invoke -ModuleName LocalAdmin New-LAUser -Times 1 -Exactly
            Should -Invoke -ModuleName LocalAdmin Add-LAAdministrator -Times 1 -Exactly
            (Test-LocalAdminAccount -UserName 'itadmin').Success | Should -BeTrue
        }
        It 'removes the new account again when the group change fails' {
            Mock -ModuleName LocalAdmin Add-LAAdministrator { throw 'access denied' }
            { New-LocalAdminAccount -UserName 'itadmin' -Password $pw } | Should -Throw
            Should -Invoke -ModuleName LocalAdmin Remove-LAUser -Times 1 -Exactly
        }
        It 'rejects an invalid username before touching the system' {
            { New-LocalAdminAccount -UserName 'bad/name' -Password $pw } | Should -Throw
            Should -Invoke -ModuleName LocalAdmin New-LAUser -Times 0 -Exactly
        }
    }

    Context 'existing account' {
        BeforeEach {
            Mock -ModuleName LocalAdmin Get-LAUser { [pscustomobject]@{ Name = 'existing'; Enabled = $true; SID = 'S-1-5-21-1-2-3-1002' } }
            Mock -ModuleName LocalAdmin Get-LAAdministratorSids { @('S-1-5-21-1-2-3-500') }
            Mock -ModuleName LocalAdmin New-LAUser { }
            Mock -ModuleName LocalAdmin Set-LAUserPassword { }
            Mock -ModuleName LocalAdmin Add-LAAdministrator { }
            Mock -ModuleName LocalAdmin Enable-LAUser { }
        }
        It 'New-LocalAdminAccount refuses and changes nothing' {
            { New-LocalAdminAccount -UserName 'existing' -Password $pw } | Should -Throw '*already exists*'
            Should -Invoke -ModuleName LocalAdmin New-LAUser -Times 0 -Exactly
            Should -Invoke -ModuleName LocalAdmin Set-LAUserPassword -Times 0 -Exactly
            Should -Invoke -ModuleName LocalAdmin Add-LAAdministrator -Times 0 -Exactly
        }
        It 'Update-LocalAdminAccount without switches changes nothing' {
            $r = Update-LocalAdminAccount -UserName 'existing' -Password $pw
            @($r.Changes).Count | Should -Be 0
            Should -Invoke -ModuleName LocalAdmin Set-LAUserPassword -Times 0 -Exactly
            Should -Invoke -ModuleName LocalAdmin Add-LAAdministrator -Times 0 -Exactly
        }
        It 'resets the password only with -ResetPassword' {
            Update-LocalAdminAccount -UserName 'existing' -Password $pw -ResetPassword | Out-Null
            Should -Invoke -ModuleName LocalAdmin Set-LAUserPassword -Times 1 -Exactly
            Should -Invoke -ModuleName LocalAdmin Add-LAAdministrator -Times 0 -Exactly
        }
        It 'changes group membership only with -AddToAdministrators' {
            Update-LocalAdminAccount -UserName 'existing' -AddToAdministrators | Out-Null
            Should -Invoke -ModuleName LocalAdmin Add-LAAdministrator -Times 1 -Exactly
            Should -Invoke -ModuleName LocalAdmin Set-LAUserPassword -Times 0 -Exactly
        }
        It 'verification fails when the account is not an administrator' {
            $v = Test-LocalAdminAccount -UserName 'existing'
            $v.Success | Should -BeFalse
            $v.Message | Should -Match 'Administrators'
        }
    }

    It 'verification fails for a missing account' {
        Mock -ModuleName LocalAdmin Get-LAUser { $null }
        (Test-LocalAdminAccount -UserName 'ghost').Success | Should -BeFalse
    }
}
