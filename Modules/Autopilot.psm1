<#
    GRE IT Onboarding - Windows Autopilot hardware hash module
    Reads the hash from the Microsoft MDM bridge WMI provider
    (root/cimv2/mdm/dmmap : MDM_DevDetail_Ext01.DeviceHardwareData) - the same
    documented source Microsoft's Get-WindowsAutopilotInfo script uses - and
    writes the CSV format accepted by the Intune "Import Autopilot devices" page.
    The hash is sensitive inventory data: it is never logged or put in reports.
#>
Set-StrictMode -Version 2.0

$script:BaseHeader = 'Device Serial Number,Windows Product ID,Hardware Hash'
$script:GroupTagHeader = 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag'

function Get-AutopilotHardwareHash {
    <# Returns @{ SerialNumber; HardwareHash }. Requires elevation. Throws with a clear message on failure. #>
    [CmdletBinding()]
    param()
    $serial = [string](Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    try {
        $detail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' `
            -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" -ErrorAction Stop
    }
    catch {
        throw "The hardware hash could not be read from the MDM WMI provider (run elevated on Windows 10/11): $($_.Exception.Message)"
    }
    $hash = $null
    if ($null -ne $detail) { $hash = [string](@($detail)[0].DeviceHardwareData) }
    if ([string]::IsNullOrWhiteSpace($hash)) {
        throw 'Windows returned an empty hardware hash. This can happen in virtual machines or when the device has no supported TPM/firmware data.'
    }
    return @{ SerialNumber = $serial.Trim(); HardwareHash = $hash.Trim() }
}

function Get-AutopilotCsvFileName {
    <# Autopilot_<serial>.csv with characters that are invalid in file names replaced. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SerialNumber)
    $clean = $SerialNumber.Trim()
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $clean = $clean.Replace([string]$c, '_') }
    $clean = $clean.Replace(' ', '_')
    if (-not $clean) { throw 'The device serial number is empty; the Autopilot file cannot be named.' }
    return ('Autopilot_{0}.csv' -f $clean)
}

function Export-AutopilotHardwareHashCsv {
    <# Writes the CSV (ASCII, no BOM, no quotes) and returns its full path. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SerialNumber,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HardwareHash,
        [Parameter(Mandatory = $true)][string]$Directory,
        [string]$GroupTag = ''
    )
    if ([string]::IsNullOrWhiteSpace($SerialNumber)) { throw 'The device reports no serial number; an Autopilot CSV cannot be created.' }
    if ($SerialNumber -match '[,"\r\n]') { throw 'The serial number contains characters that are not valid in the Autopilot CSV.' }
    if ($GroupTag -match '[,"\r\n]') { throw 'The configured Group Tag contains characters that are not valid in the Autopilot CSV.' }
    if ([string]::IsNullOrWhiteSpace($HardwareHash)) { throw 'The hardware hash is empty.' }

    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null }
    $path = Join-Path $Directory (Get-AutopilotCsvFileName -SerialNumber $SerialNumber)
    if ($GroupTag) {
        $lines = @($script:GroupTagHeader, ('{0},,{1},{2}' -f $SerialNumber.Trim(), $HardwareHash.Trim(), $GroupTag.Trim()))
    }
    else {
        $lines = @($script:BaseHeader, ('{0},,{1}' -f $SerialNumber.Trim(), $HardwareHash.Trim()))
    }
    [System.IO.File]::WriteAllLines($path, [string[]]$lines, [System.Text.Encoding]::ASCII)
    return $path
}

function Test-AutopilotCsv {
    <#
        Validates the structure of an exported Autopilot CSV.
        Returns [pscustomobject] @{ IsValid; Errors (string[]) }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedSerialNumber = '',
        [int]$MinimumHashLength = 1000
    )
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $errors.Add("File not found: $Path")
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }
    $lines = @([System.IO.File]::ReadAllLines($Path) | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -ne 2) {
        $errors.Add("Expected a header row and exactly one device row, found $($lines.Count) non-empty line(s).")
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }
    $header = $lines[0].Trim()
    if ($header -ne $script:BaseHeader -and $header -ne $script:GroupTagHeader) {
        $errors.Add('The header row does not match the Autopilot import format.')
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }
    $expectedColumns = $header.Split(',').Count
    $fields = $lines[1].Split(',')
    if ($fields.Count -ne $expectedColumns) {
        $errors.Add("The device row has $($fields.Count) column(s); expected $expectedColumns.")
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }
    $serial = $fields[0].Trim()
    $hash = $fields[2].Trim()
    if (-not $serial) { $errors.Add('The serial number column is empty.') }
    if ($ExpectedSerialNumber -and ($serial -ne $ExpectedSerialNumber.Trim())) { $errors.Add('The serial number in the file does not match this device.') }
    if (-not $hash) { $errors.Add('The hardware hash column is empty.') }
    else {
        if ($hash.Length -lt $MinimumHashLength) { $errors.Add("The hardware hash is shorter than expected ($($hash.Length) characters).") }
        if ($hash -notmatch '^[A-Za-z0-9+/]+={0,2}$') { $errors.Add('The hardware hash is not valid Base64 text.') }
        else {
            try { [void][System.Convert]::FromBase64String($hash) }
            catch { $errors.Add('The hardware hash could not be decoded as Base64.') }
        }
    }
    return [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Protect-AutopilotExport {
    <#
        Restricts the export to Administrators + SYSTEM where the file system
        supports ACLs (NTFS). USB sticks are usually exFAT/FAT32, which cannot
        enforce permissions - in that case a warning text is returned so the
        report can state that physical control of the USB is the safeguard.
        Returns @{ Protected (bool); Message }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        $format = (New-Object System.IO.DriveInfo($root)).DriveFormat
    }
    catch { return @{ Protected = $false; Message = "File system type could not be determined: $($_.Exception.Message)" } }
    if ($format -ne 'NTFS' -and $format -ne 'ReFS') {
        return @{ Protected = $false; Message = "The drive uses $format, which does not support file permissions. Keep the USB drive physically secured and hand the CSV only to the Intune administrator." }
    }
    try {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
            $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
        }
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return @{ Protected = $true; Message = 'Access restricted to Administrators and SYSTEM.' }
    }
    catch { return @{ Protected = $false; Message = "File permissions could not be restricted: $($_.Exception.Message)" } }
}

Export-ModuleMember -Function Get-AutopilotHardwareHash, Get-AutopilotCsvFileName, Export-AutopilotHardwareHashCsv,
    Test-AutopilotCsv, Protect-AutopilotExport
