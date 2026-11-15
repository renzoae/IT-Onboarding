BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\Reporting.psm1') -Force
    function New-TestState([string]$WuStatus = 'Completed') {
        @{
            Part = 1; SessionId = 'session-1'; Technician = 'Test <Tech>'; Completed = $false
            Steps = @{
                LocalAdmin    = @{ Status = 'Completed'; Message = 'Verified'; Timestamp = 't'; Data = @{ UserName = 'itadmin'; Action = 'Created' } }
                DeviceInfo    = @{ Status = 'Completed'; Message = 'ok'; Timestamp = 't'; Data = @{} }
                WindowsUpdate = @{ Status = $WuStatus; Message = 'wu message'; Timestamp = 't'; Data = @{ Warnings = @('Not installed: Feature update') } }
                AutopilotHash = @{ Status = 'Completed'; Message = 'Exported'; Timestamp = 't'; Data = @{ FileName = 'Autopilot_SN1.csv' } }
            }
        }
    }
    $script:device = @{
        ComputerName = 'PC01'; Manufacturer = 'Contoso'; Model = 'Book <15>'; SerialNumber = 'SN1'; OsBuild = '26100.1'
        Tpm = @{ Present = $true; Enabled = $true; Activated = $true; SpecVersion = '2.0' }
        Battery = @{ Present = $false }; Storage = @(@{ Model = 'Disk'; MediaType = 'SSD'; BusType = 'NVMe'; SizeGB = 512; HealthStatus = 'Healthy' })
        NetworkAdapters = @(); Warnings = @('Battery capacity details are not exposed')
    }
}

Describe 'Part 1 report generation' {
    It 'reports COMPLETED only when every mandatory step completed' {
        Get-Part1OverallStatus -State (New-TestState) | Should -Be 'COMPLETED'
        Get-Part1OverallStatus -State (New-TestState -WuStatus 'Failed') | Should -Be 'INCOMPLETE'
        Get-Part1OverallStatus -State (New-TestState -WuStatus 'RestartRequired') | Should -Be 'INCOMPLETE'
        Get-Part1OverallStatus -State @{ Steps = @{} } | Should -Be 'INCOMPLETE'
    }
    It 'collects errors and warnings' {
        $m = New-Part1ReportModel -State (New-TestState -WuStatus 'Failed') -DeviceInfo $script:device
        @($m['Errors']).Count | Should -Be 1
        ($m['Warnings'] -join '|') | Should -Match 'Feature update'
        ($m['Warnings'] -join '|') | Should -Match 'Battery capacity'
    }
    It 'writes HTML and JSON files containing the device identity' {
        $m = New-Part1ReportModel -State (New-TestState) -DeviceInfo $script:device
        $files = Export-Part1Report -Model $m -Directory (Join-Path $TestDrive 'r') -Stamp '20240101_000000'
        Split-Path -Leaf $files['HtmlPath'] | Should -Be 'Part1_SN1_20240101_000000.html'
        $html = Get-Content -LiteralPath $files['HtmlPath'] -Raw
        $html | Should -Match 'READY FOR INTUNE'
        $html | Should -Match 'SN1'
        $html | Should -Match 'Contoso'
        $json = Get-Content -LiteralPath $files['JsonPath'] -Raw | ConvertFrom-Json
        $json.OverallStatus | Should -Be 'COMPLETED'
        $json.Device.SerialNumber | Should -Be 'SN1'
    }
    It 'HTML-encodes values' {
        $html = ConvertTo-Part1ReportHtml -Model (New-Part1ReportModel -State (New-TestState) -DeviceInfo $script:device)
        $html | Should -Match 'Book &lt;15&gt;'
        $html | Should -Not -Match 'Book <15>'
    }
    It 'marks an incomplete run as not ready' {
        $html = ConvertTo-Part1ReportHtml -Model (New-Part1ReportModel -State (New-TestState -WuStatus 'Failed') -DeviceInfo $script:device)
        $html | Should -Match 'NOT READY FOR INTUNE'
        $html | Should -Not -Match 'PART 1 COMPLETED'
    }
    It 'strips passwords, tokens, recovery keys and hardware hashes' {
        $state = New-TestState
        $state['Steps']['LocalAdmin']['Data']['Password'] = 'LEAK-PW'
        $state['Steps']['AutopilotHash']['Data']['HardwareHash'] = 'LEAK-HASH'
        $dev = $script:device.Clone(); $dev['BitLockerRecoveryKey'] = 'LEAK-KEY'; $dev['AccessToken'] = 'LEAK-TOKEN'
        $m = New-Part1ReportModel -State $state -DeviceInfo $dev
        $all = (ConvertTo-Json -InputObject $m -Depth 12) + (ConvertTo-Part1ReportHtml -Model $m)
        $all | Should -Not -Match 'LEAK-'
    }
}
