BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\Autopilot.psm1') -Force
    # Synthetic Base64 payload - NOT a real hardware hash.
    $script:FakeHash = [Convert]::ToBase64String([byte[]](1..1500 | ForEach-Object { $_ % 256 }))
}

Describe 'Autopilot CSV export and validation' {
    It 'names the file after the serial number' {
        Get-AutopilotCsvFileName -SerialNumber 'SN123456' | Should -Be 'Autopilot_SN123456.csv'
    }
    It 'replaces characters that are invalid in file names' {
        Get-AutopilotCsvFileName -SerialNumber 'AB/12 34' | Should -Be 'Autopilot_AB_12_34.csv'
    }
    It 'writes a CSV that passes validation' {
        $path = Export-AutopilotHardwareHashCsv -SerialNumber 'SN123456' -HardwareHash $script:FakeHash -Directory $TestDrive
        Split-Path -Leaf $path | Should -Be 'Autopilot_SN123456.csv'
        $lines = [System.IO.File]::ReadAllLines($path)
        $lines[0] | Should -Be 'Device Serial Number,Windows Product ID,Hardware Hash'
        $lines[1] | Should -Be "SN123456,,$($script:FakeHash)"
        (Test-AutopilotCsv -Path $path -ExpectedSerialNumber 'SN123456').IsValid | Should -BeTrue
    }
    It 'adds the Group Tag column when configured' {
        $dir = Join-Path $TestDrive 'tag'
        $path = Export-AutopilotHardwareHashCsv -SerialNumber 'SN9' -HardwareHash $script:FakeHash -Directory $dir -GroupTag 'Sales'
        ([System.IO.File]::ReadAllLines($path))[0] | Should -Be 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag'
        (Test-AutopilotCsv -Path $path).IsValid | Should -BeTrue
    }
    It 'refuses an empty serial number or hash' {
        { Export-AutopilotHardwareHashCsv -SerialNumber '' -HardwareHash $script:FakeHash -Directory $TestDrive } | Should -Throw
        { Export-AutopilotHardwareHashCsv -SerialNumber 'SN1' -HardwareHash '' -Directory $TestDrive } | Should -Throw
    }
    It 'refuses a serial number that would break the CSV' {
        { Export-AutopilotHardwareHashCsv -SerialNumber 'SN,1' -HardwareHash $script:FakeHash -Directory $TestDrive } | Should -Throw
    }
}

Describe 'Test-AutopilotCsv rejects malformed files' {
    BeforeEach { $script:file = Join-Path $TestDrive ("bad_{0}.csv" -f [guid]::NewGuid().ToString('N')) }

    It 'missing file' { (Test-AutopilotCsv -Path (Join-Path $TestDrive 'nope.csv')).IsValid | Should -BeFalse }
    It 'wrong header' {
        Set-Content -LiteralPath $script:file -Value @('Serial,ProductId,Hash', "SN1,,$($script:FakeHash)")
        (Test-AutopilotCsv -Path $script:file).IsValid | Should -BeFalse
    }
    It 'header only' {
        Set-Content -LiteralPath $script:file -Value 'Device Serial Number,Windows Product ID,Hardware Hash'
        (Test-AutopilotCsv -Path $script:file).IsValid | Should -BeFalse
    }
    It 'more than one device row' {
        Set-Content -LiteralPath $script:file -Value @('Device Serial Number,Windows Product ID,Hardware Hash', "SN1,,$($script:FakeHash)", "SN2,,$($script:FakeHash)")
        (Test-AutopilotCsv -Path $script:file).IsValid | Should -BeFalse
    }
    It 'wrong column count' {
        Set-Content -LiteralPath $script:file -Value @('Device Serial Number,Windows Product ID,Hardware Hash', "SN1,$($script:FakeHash)")
        (Test-AutopilotCsv -Path $script:file).IsValid | Should -BeFalse
    }
    It 'hash that is not Base64' {
        Set-Content -LiteralPath $script:file -Value @('Device Serial Number,Windows Product ID,Hardware Hash', ('SN1,,' + ('!' * 1200)))
        (Test-AutopilotCsv -Path $script:file).IsValid | Should -BeFalse
    }
    It 'hash that is too short' {
        Set-Content -LiteralPath $script:file -Value @('Device Serial Number,Windows Product ID,Hardware Hash', 'SN1,,QUJDRA==')
        (Test-AutopilotCsv -Path $script:file).IsValid | Should -BeFalse
    }
    It 'serial number of another device' {
        Set-Content -LiteralPath $script:file -Value @('Device Serial Number,Windows Product ID,Hardware Hash', "SN1,,$($script:FakeHash)")
        (Test-AutopilotCsv -Path $script:file -ExpectedSerialNumber 'OTHER').IsValid | Should -BeFalse
    }
}
