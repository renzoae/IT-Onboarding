<#
    Workflow engine tests: step ordering, checkpoint skipping, failure handling
    and restart handling. Every step implementation is mocked - nothing here
    touches accounts, Windows Update or the hardware hash.
#>
BeforeAll {
    $script:previousRoot = $env:GRE_ONBOARDING_LOCALROOT
    $env:GRE_ONBOARDING_LOCALROOT = Join-Path $TestDrive 'local'
    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    . (Join-Path $script:repo 'Scripts\Part1.ps1') -AppRoot $script:repo -DefineOnly
    $script:context = New-OnboardingContext -AppRoot $script:repo -Part 1

    function New-ReadyState {
        Remove-OnboardingState -Part 1
        $s = New-OnboardingState -Part 1 -AppRoot $script:repo
        Set-OnboardingStepState -State $s -Name 'LocalAdmin' -Status 'Completed' -Message 'Verified' -Data @{ UserName = 'itadmin'; Action = 'Created' }
    }
    function Set-HappyMocks {
        Mock Invoke-Part1DeviceInfoStep { New-Part1StepResult 'Completed' 'ok' @{ Device = @{ SerialNumber = 'SN1' } } }
        Mock Invoke-Part1WindowsUpdateStep { New-Part1StepResult 'Completed' 'verified' @{ FinalBuild = '1.2' } }
        Mock Invoke-Part1AutopilotStep { New-Part1StepResult 'Completed' 'exported' @{ FileName = 'missing-on-purpose.csv' } }
        Mock Invoke-Part1ReportStep { New-Part1StepResult 'Completed' 'saved' @{ HtmlPath = 'x' } }
        Mock Invoke-Part1CleanupStep { New-Part1StepResult 'Completed' 'clean' }
    }
}
AfterAll { $env:GRE_ONBOARDING_LOCALROOT = $script:previousRoot }

Describe 'Invoke-Part1Workflow' {
    BeforeEach { New-ReadyState; Set-HappyMocks }

    It 'refuses to run before the local administrator step is verified' {
        Remove-OnboardingState -Part 1
        Save-OnboardingState -State (New-OnboardingState -Part 1 -AppRoot $script:repo)
        { Invoke-Part1Workflow -Context $script:context } | Should -Throw '*local administrator*'
        Should -Invoke Invoke-Part1DeviceInfoStep -Times 0 -Exactly
    }
    It 'completes when every step succeeds' {
        Invoke-Part1Workflow -Context $script:context | Should -Be 'Completed'
        (Get-OnboardingState -Part 1)['Completed'] | Should -BeTrue
    }
    It 'continues to the hash export and report when Windows Update fails, but does not complete or clean up' {
        Mock Invoke-Part1WindowsUpdateStep { New-Part1StepResult 'Failed' 'no internet' }
        Invoke-Part1Workflow -Context $script:context | Should -Be 'Incomplete'
        Should -Invoke Invoke-Part1AutopilotStep -Times 1 -Exactly
        Should -Invoke Invoke-Part1ReportStep -Times 1 -Exactly
        Should -Invoke Invoke-Part1CleanupStep -Times 0 -Exactly
        $s = Get-OnboardingState -Part 1
        $s['Completed'] | Should -BeFalse
        Get-OnboardingStepStatus -State $s -Name 'Cleanup' | Should -Be 'Skipped'
    }
    It 'records an exception thrown by a step as a failure' {
        Mock Invoke-Part1AutopilotStep { throw 'WMI provider unavailable' }
        Invoke-Part1Workflow -Context $script:context | Should -Be 'Incomplete'
        $s = Get-OnboardingState -Part 1
        Get-OnboardingStepStatus -State $s -Name 'AutopilotHash' | Should -Be 'Failed'
        $s['Steps']['AutopilotHash']['Message'] | Should -Match 'WMI provider unavailable'
    }
    It 'stops everything when device information cannot be collected' {
        Mock Invoke-Part1DeviceInfoStep { New-Part1StepResult 'Failed' 'no serial' }
        Invoke-Part1Workflow -Context $script:context | Should -Be 'Incomplete'
        Should -Invoke Invoke-Part1WindowsUpdateStep -Times 0 -Exactly
        Should -Invoke Invoke-Part1AutopilotStep -Times 0 -Exactly
    }
    It 'halts at a required restart and resumes without repeating completed work' {
        Mock Invoke-Part1WindowsUpdateStep { New-Part1StepResult 'RestartRequired' 'restart' @{ RestartCycles = 1 } }
        Invoke-Part1Workflow -Context $script:context | Should -Be 'RestartRequired'
        Should -Invoke Invoke-Part1AutopilotStep -Times 0 -Exactly
        Should -Invoke Invoke-Part1ReportStep -Times 0 -Exactly

        # "after the restart"
        Mock Invoke-Part1WindowsUpdateStep { New-Part1StepResult 'Completed' 'verified' }
        Invoke-Part1Workflow -Context $script:context | Should -Be 'Completed'
        Should -Invoke Invoke-Part1AutopilotStep -Times 1 -Exactly
    }
    It 'retries only the failed step on the next run' {
        Mock Invoke-Part1WindowsUpdateStep { New-Part1StepResult 'Failed' 'transient' }
        Invoke-Part1Workflow -Context $script:context | Out-Null
        Mock Invoke-Part1WindowsUpdateStep { New-Part1StepResult 'Completed' 'verified' }
        # the hash file from the first run exists on the "USB" this time
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*missing-on-purpose.csv' }
        Invoke-Part1Workflow -Context $script:context | Should -Be 'Completed'
        Should -Invoke Invoke-Part1AutopilotStep -Times 1 -Exactly     # not exported a second time
        Should -Invoke Invoke-Part1WindowsUpdateStep -Times 2 -Exactly
    }
    It 're-exports the hash when the recorded CSV is no longer on the USB' {
        Invoke-Part1Workflow -Context $script:context | Out-Null
        Invoke-Part1Workflow -Context $script:context | Out-Null
        Should -Invoke Invoke-Part1AutopilotStep -Times 2 -Exactly
    }
}
