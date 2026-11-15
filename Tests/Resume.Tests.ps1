BeforeAll {
    $script:previousRoot = $env:GRE_ONBOARDING_LOCALROOT
    $env:GRE_ONBOARDING_LOCALROOT = Join-Path $TestDrive 'local'
    Import-Module (Join-Path $PSScriptRoot '..\Modules\Resume.psm1') -Force
}
AfterAll { $env:GRE_ONBOARDING_LOCALROOT = $script:previousRoot }

Describe 'Task checkpoint logic' {
    BeforeEach { Remove-OnboardingState -Part 1 }

    It 'returns $null when no state exists' { Get-OnboardingState -Part 1 | Should -BeNullOrEmpty }

    It 'round-trips state and step data through disk' {
        $s = New-OnboardingState -Part 1 -AppRoot $TestDrive
        Set-OnboardingStepState -State $s -Name 'DeviceInfo' -Status 'Completed' -Message 'ok' -Data @{ Device = @{ SerialNumber = 'SN1'; Storage = @(@{ Model = 'Disk A' }) } }
        $loaded = Get-OnboardingState -Part 1
        $loaded | Should -BeOfType [hashtable]
        $loaded['SessionId'] | Should -Be $s['SessionId']
        Test-OnboardingStepCompleted -State $loaded -Name 'DeviceInfo' | Should -BeTrue
        (Get-OnboardingStepData -State $loaded -Name 'DeviceInfo')['Device']['SerialNumber'] | Should -Be 'SN1'
        @((Get-OnboardingStepData -State $loaded -Name 'DeviceInfo')['Device']['Storage'])[0]['Model'] | Should -Be 'Disk A'
    }
    It 'treats unknown steps as Pending' {
        $s = New-OnboardingState -Part 1 -AppRoot $TestDrive
        Get-OnboardingStepStatus -State $s -Name 'Nope' | Should -Be 'Pending'
        Test-OnboardingStepCompleted -State $s -Name 'Nope' | Should -BeFalse
    }
    It 'counts attempts and keeps earlier data when none is supplied' {
        $s = New-OnboardingState -Part 1 -AppRoot $TestDrive
        Set-OnboardingStepState -State $s -Name 'WindowsUpdate' -Status 'Running'
        Set-OnboardingStepState -State $s -Name 'WindowsUpdate' -Status 'Failed' -Message 'x' -Data @{ RestartCycles = 2 }
        Set-OnboardingStepState -State $s -Name 'WindowsUpdate' -Status 'Running'
        $s['Steps']['WindowsUpdate']['Attempts'] | Should -Be 2
        (Get-OnboardingStepData -State $s -Name 'WindowsUpdate')['RestartCycles'] | Should -Be 2
    }
    It 'rejects an invalid status' {
        $s = New-OnboardingState -Part 1 -AppRoot $TestDrive
        { Set-OnboardingStepState -State $s -Name 'X' -Status 'Done' } | Should -Throw
    }
    It 'resets steps that were interrupted while Running' {
        $s = New-OnboardingState -Part 1 -AppRoot $TestDrive
        Set-OnboardingStepState -State $s -Name 'WindowsUpdate' -Status 'Running'
        Reset-OnboardingInterruptedSteps -State $s | Should -BeTrue
        Get-OnboardingStepStatus -State (Get-OnboardingState -Part 1) -Name 'WindowsUpdate' | Should -Be 'Pending'
    }
    It 'refuses to persist credential-like fields' {
        $s = New-OnboardingState -Part 1 -AppRoot $TestDrive
        { Set-OnboardingStepState -State $s -Name 'LocalAdmin' -Status 'Completed' -Data @{ Password = 'x' } } | Should -Throw '*credential*'
        Get-OnboardingState -Part 1 | Should -BeNullOrEmpty
    }
    It 'quarantines a corrupt state file instead of trusting it' {
        $path = Get-OnboardingStatePath -Part 1
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value '{ this is not json'
        Get-OnboardingState -Part 1 | Should -BeNullOrEmpty
        Test-Path -LiteralPath $path | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '*.corrupt').Count | Should -BeGreaterThan 0
    }
    It 'keeps Part 1 and Part 2 state independent' {
        $s1 = New-OnboardingState -Part 1 -AppRoot $TestDrive; Save-OnboardingState -State $s1
        Get-OnboardingState -Part 2 | Should -BeNullOrEmpty
        (Get-OnboardingStatePath -Part 1) | Should -Not -Be (Get-OnboardingStatePath -Part 2)
    }
}

Describe 'Resume stub' {
    It 'contains the launcher hash and relative path but no credentials' {
        $text = New-OnboardingResumeStubContent -Part 1 -AppRelativePath 'GRE-IT-Onboarding' -LauncherHash 'ABC123'
        $text | Should -Match 'ABC123'
        $text | Should -Match "GRE-IT-Onboarding"
        $text | Should -Match '-Resume'
        $text | Should -Not -Match '(?i)password\s*='
        $text | Should -Not -Match '(?i)-Credential'
    }
}
