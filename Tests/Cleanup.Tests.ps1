BeforeAll {
    $script:previousRoot = $env:GRE_ONBOARDING_LOCALROOT
    $env:GRE_ONBOARDING_LOCALROOT = Join-Path $TestDrive 'local'
    Import-Module (Join-Path $PSScriptRoot '..\Modules\Cleanup.psm1') -Force
    $script:work = Join-Path $env:GRE_ONBOARDING_LOCALROOT 'Work'
    $script:usb = Join-Path $TestDrive 'usb'
    New-Item -ItemType Directory -Path $script:work, $script:usb -Force | Out-Null
}
AfterAll { $env:GRE_ONBOARDING_LOCALROOT = $script:previousRoot }

Describe 'Cleanup safety' {
    It 'allows a file inside the application working folder' {
        (Test-OnboardingCleanupPathSafe -Path (Join-Path $script:work 'download.tmp') -AllowedRoots $script:work).IsSafe | Should -BeTrue
    }
    It 'refuses <Case>' -ForEach @(
        @{ Case = 'an empty path'; Path = '' }
        @{ Case = 'a relative path'; Path = 'Work\file.tmp' }
        @{ Case = 'wildcards'; Path = 'C:\ProgramData\GRE-IT-Onboarding\Work\*' }
    ) {
        (Test-OnboardingCleanupPathSafe -Path $Path -AllowedRoots $script:work).IsSafe | Should -BeFalse
    }
    It 'refuses the working root itself' {
        (Test-OnboardingCleanupPathSafe -Path $script:work -AllowedRoots $script:work).IsSafe | Should -BeFalse
    }
    It 'refuses a path outside the working folder' {
        (Test-OnboardingCleanupPathSafe -Path (Join-Path $TestDrive 'elsewhere.txt') -AllowedRoots $script:work).IsSafe | Should -BeFalse
    }
    It 'refuses a sibling folder that merely shares the prefix' {
        (Test-OnboardingCleanupPathSafe -Path ($script:work + 'Other' + [IO.Path]::DirectorySeparatorChar + 'x.tmp') -AllowedRoots $script:work).IsSafe | Should -BeFalse
    }
    It 'refuses path traversal out of the working folder' {
        $p = Join-Path (Join-Path $script:work '..') 'State'
        (Test-OnboardingCleanupPathSafe -Path $p -AllowedRoots $script:work).IsSafe | Should -BeFalse
    }
    It 'refuses anything inside a protected root (the USB application)' {
        $inside = Join-Path $script:usb 'Reports'
        (Test-OnboardingCleanupPathSafe -Path $inside -AllowedRoots $script:usb -ProtectedRoots $script:usb).IsSafe | Should -BeFalse
    }
    It 'will not even track an unsafe path' {
        { Register-OnboardingCleanupItem -Path (Join-Path $script:usb 'Reports') } | Should -Throw
    }
}

Describe 'Part 1 cleanup' {
    BeforeEach {
        $script:csv = Join-Path $script:usb 'Autopilot_SN1.csv'; Set-Content -LiteralPath $script:csv -Value 'x'
        $script:report = Join-Path $script:usb 'Part1.html'; Set-Content -LiteralPath $script:report -Value 'x'
        $script:tmp = Join-Path $script:work 'payload.tmp'; Set-Content -LiteralPath $script:tmp -Value 'x'
        Register-OnboardingCleanupItem -Path $script:tmp
    }
    It 'removes tracked temp files and preserves deliverables' {
        $r = Invoke-OnboardingPart1Cleanup -AppRoot $script:usb -HardwareHashPath $script:csv -ReportPath $script:report
        $r['Success'] | Should -BeTrue
        Test-Path -LiteralPath $script:tmp | Should -BeFalse
        Test-Path -LiteralPath $script:csv | Should -BeTrue
        Test-Path -LiteralPath $script:report | Should -BeTrue
    }
    It 'does nothing when the hardware hash CSV is missing' {
        Remove-Item -LiteralPath $script:csv
        $r = Invoke-OnboardingPart1Cleanup -AppRoot $script:usb -HardwareHashPath $script:csv -ReportPath $script:report
        $r['Success'] | Should -BeFalse
        Test-Path -LiteralPath $script:tmp | Should -BeTrue
    }
    It 'does nothing when the report is missing' {
        $r = Invoke-OnboardingPart1Cleanup -AppRoot $script:usb -HardwareHashPath $script:csv -ReportPath ''
        $r['Success'] | Should -BeFalse
        Test-Path -LiteralPath $script:tmp | Should -BeTrue
    }
    It 'refuses a manifest entry that was tampered with' {
        $victim = Join-Path $TestDrive 'victim.txt'; Set-Content -LiteralPath $victim -Value 'keep me'
        $manifest = Get-OnboardingCleanupManifestPath
        Set-Content -LiteralPath $manifest -Value (ConvertTo-Json -InputObject @($victim, $script:tmp))
        $r = Invoke-OnboardingPart1Cleanup -AppRoot $script:usb -HardwareHashPath $script:csv -ReportPath $script:report
        Test-Path -LiteralPath $victim | Should -BeTrue
        @($r['Refused']).Count | Should -Be 1
    }
}
