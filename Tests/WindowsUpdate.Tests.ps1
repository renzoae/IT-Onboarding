BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\WindowsUpdate.psm1') -Force
}

Describe 'Invoke-WindowsUpdateCycle (mocked Windows Update Agent)' {
    It 'reports UpToDate only after a clean scan with no restart pending' {
        Mock -ModuleName WindowsUpdate Test-WindowsUpdateRestartPending { $false }
        Mock -ModuleName WindowsUpdate Get-PendingWindowsUpdate { @{ Success = $true; Message = ''; Applicable = @(); Excluded = @() } }
        (Invoke-WindowsUpdateCycle)['Status'] | Should -Be 'UpToDate'
    }
    It 'never claims UpToDate when the scan fails' {
        Mock -ModuleName WindowsUpdate Test-WindowsUpdateRestartPending { $false }
        Mock -ModuleName WindowsUpdate Get-PendingWindowsUpdate { @{ Success = $false; Message = 'scan failed'; Applicable = @(); Excluded = @() } }
        $r = Invoke-WindowsUpdateCycle
        $r['Status'] | Should -Be 'ScanFailed'
        $r['Message'] | Should -Be 'scan failed'
    }
    It 'requires a restart first when one is already pending' {
        Mock -ModuleName WindowsUpdate Test-WindowsUpdateRestartPending { $true }
        Mock -ModuleName WindowsUpdate Get-PendingWindowsUpdate { throw 'must not scan' }
        (Invoke-WindowsUpdateCycle)['Status'] | Should -Be 'RestartRequired'
    }
    It 'returns RestartRequired when an installed update needs a restart' {
        Mock -ModuleName WindowsUpdate Test-WindowsUpdateRestartPending { $false }
        Mock -ModuleName WindowsUpdate Get-PendingWindowsUpdate { @{ Success = $true; Message = ''; Applicable = @(@{ Title = 'Cumulative'; KB = 'KB1'; Reason = ''; Update = $null }); Excluded = @() } }
        Mock -ModuleName WindowsUpdate Install-WindowsUpdateItem { @{ Title = 'Cumulative'; KB = 'KB1'; Success = $true; RebootRequired = $true; Message = 'Succeeded' } }
        $r = Invoke-WindowsUpdateCycle
        $r['Status'] | Should -Be 'RestartRequired'
        @($r['Installed']).Count | Should -Be 1
    }
    It 'installs, rescans and then reports UpToDate' {
        $script:scans = 0
        Mock -ModuleName WindowsUpdate Test-WindowsUpdateRestartPending { $false }
        Mock -ModuleName WindowsUpdate Get-PendingWindowsUpdate {
            $script:scans++
            if ($script:scans -eq 1) { @{ Success = $true; Message = ''; Applicable = @(@{ Title = 'Defender'; KB = 'KB1'; Reason = ''; Update = $null }); Excluded = @() } }
            else { @{ Success = $true; Message = ''; Applicable = @(); Excluded = @() } }
        }
        Mock -ModuleName WindowsUpdate Install-WindowsUpdateItem { @{ Title = 'Defender'; KB = 'KB1'; Success = $true; RebootRequired = $false; Message = 'Succeeded' } }
        $r = Invoke-WindowsUpdateCycle
        $r['Status'] | Should -Be 'UpToDate'
        @($r['Installed']).Count | Should -Be 1
        Should -Invoke -ModuleName WindowsUpdate Get-PendingWindowsUpdate -Times 2 -Exactly
    }
    It 'reports Failed (with the remaining updates) when nothing can be installed' {
        Mock -ModuleName WindowsUpdate Test-WindowsUpdateRestartPending { $false }
        Mock -ModuleName WindowsUpdate Get-PendingWindowsUpdate { @{ Success = $true; Message = ''; Applicable = @(@{ Title = 'Broken'; KB = 'KB1'; Reason = ''; Update = $null }); Excluded = @() } }
        Mock -ModuleName WindowsUpdate Install-WindowsUpdateItem { @{ Title = 'Broken'; KB = 'KB1'; Success = $false; RebootRequired = $false; Message = 'Install failed' } }
        $r = Invoke-WindowsUpdateCycle
        $r['Status'] | Should -Be 'Failed'
        @($r['Failed']).Count | Should -Be 1
        @($r['Remaining']).Count | Should -Be 1
    }
    It 'reports Incomplete when updates keep appearing after MaxPasses' {
        Mock -ModuleName WindowsUpdate Test-WindowsUpdateRestartPending { $false }
        Mock -ModuleName WindowsUpdate Get-PendingWindowsUpdate { @{ Success = $true; Message = ''; Applicable = @(@{ Title = 'Endless'; KB = 'KB1'; Reason = ''; Update = $null }); Excluded = @() } }
        Mock -ModuleName WindowsUpdate Install-WindowsUpdateItem { @{ Title = 'Endless'; KB = 'KB1'; Success = $true; RebootRequired = $false; Message = 'Succeeded' } }
        $r = Invoke-WindowsUpdateCycle -MaxPasses 2
        $r['Status'] | Should -Be 'Incomplete'
        @($r['Remaining']).Count | Should -Be 1
    }
    It 'lists excluded feature upgrades instead of hiding them' {
        Mock -ModuleName WindowsUpdate Test-WindowsUpdateRestartPending { $false }
        Mock -ModuleName WindowsUpdate Get-PendingWindowsUpdate { @{ Success = $true; Message = ''; Applicable = @(); Excluded = @(@{ Title = 'Feature update'; KB = ''; Reason = 'Feature upgrade (excluded by onboarding policy)' }) } }
        $r = Invoke-WindowsUpdateCycle
        @($r['Excluded']).Count | Should -Be 1
    }
}
