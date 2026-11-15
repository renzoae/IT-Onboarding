<#
    GRE IT Onboarding - Reporting module (HTML + JSON)
    Reports never contain passwords, tokens, BitLocker recovery keys or the
    Autopilot hardware hash. A sanitiser removes credential-like fields as a
    second line of defence.
#>
Set-StrictMode -Version 2.0

$script:SensitiveKeyPattern = '(?i)(password|passphrase|secret|token|recoverykey|recoverypassword|hardwarehash)'

function ConvertTo-OnboardingHtmlText {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Remove-OnboardingSensitiveData {
    <# Returns a deep copy of a hashtable/array structure without credential-like keys. #>
    [CmdletBinding()]
    param([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [securestring]) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [System.ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($k in @($InputObject.Keys)) {
            if ([string]$k -match $script:SensitiveKeyPattern) { continue }
            $copy[[string]$k] = Remove-OnboardingSensitiveData -InputObject $InputObject[$k]
        }
        return $copy
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($i in $InputObject) { $list += , (Remove-OnboardingSensitiveData -InputObject $i) }
        return , $list
    }
    return [string]$InputObject
}

function Get-Part1OverallStatus {
    <# COMPLETED only when every mandatory Part 1 step is Completed. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$State, [string[]]$MandatorySteps = @('LocalAdmin', 'DeviceInfo', 'WindowsUpdate', 'AutopilotHash'))
    foreach ($s in $MandatorySteps) {
        if (-not $State['Steps'].ContainsKey($s) -or $State['Steps'][$s]['Status'] -ne 'Completed') { return 'INCOMPLETE' }
    }
    return 'COMPLETED'
}

function New-Part1ReportModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [hashtable]$DeviceInfo = @{},
        [hashtable]$Settings = @{},
        [string[]]$StepOrder = @('LocalAdmin', 'DeviceInfo', 'WindowsUpdate', 'AutopilotHash'),
        [hashtable]$StepTitles = @{}
    )
    $steps = @()
    $errors = @(); $warnings = @()
    foreach ($name in $StepOrder) {
        $status = 'Pending'; $message = ''; $data = @{}; $time = ''
        if ($State['Steps'].ContainsKey($name)) {
            $s = $State['Steps'][$name]
            $status = [string]$s['Status']; $message = [string]$s['Message']; $time = [string]$s['Timestamp']
            if ($s['Data'] -is [hashtable]) { $data = $s['Data'] }
        }
        $title = $name
        if ($StepTitles.ContainsKey($name)) { $title = $StepTitles[$name] }
        $steps += [ordered]@{ Name = $name; Title = $title; Status = $status; Message = $message; Timestamp = $time; Details = (Remove-OnboardingSensitiveData -InputObject $data) }
        if ($status -eq 'Failed') { $errors += ('{0}: {1}' -f $title, $message) }
        elseif ($status -ne 'Completed') { $warnings += ('{0}: not completed (status: {1}). {2}' -f $title, $status, $message) }
        if ($data.ContainsKey('Warnings')) { foreach ($w in @($data['Warnings'])) { if ($w) { $warnings += ('{0}: {1}' -f $title, $w) } } }
    }
    if ($DeviceInfo.ContainsKey('Warnings')) { foreach ($w in @($DeviceInfo['Warnings'])) { if ($w) { $warnings += ('Device information: {0}' -f $w) } } }

    $org = ''
    if ($Settings.ContainsKey('Reporting') -and $Settings['Reporting'] -is [hashtable]) { $org = [string]$Settings['Reporting']['OrganizationName'] }
    return [ordered]@{
        ReportType    = 'Part 1 - Pre-Intune Preparation'
        Organization  = $org
        SessionId     = [string]$State['SessionId']
        Technician    = [string]$State['Technician']
        GeneratedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        OverallStatus = (Get-Part1OverallStatus -State $State -MandatorySteps $StepOrder)
        Device        = (Remove-OnboardingSensitiveData -InputObject $DeviceInfo)
        Steps         = $steps
        Errors        = $errors
        Warnings      = $warnings
    }
}

function ConvertTo-Part1ReportHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Model)
    $e = { param($v) ConvertTo-OnboardingHtmlText -Value $v }
    $d = $Model['Device']
    $sb = New-Object System.Text.StringBuilder
    $statusClass = 'bad'
    $statusText = 'PART 1 INCOMPLETE &mdash; NOT READY FOR INTUNE'
    if ($Model['OverallStatus'] -eq 'COMPLETED') { $statusClass = 'ok'; $statusText = 'PART 1 COMPLETED &mdash; READY FOR INTUNE' }

    [void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>GRE IT Onboarding - Part 1 Report</title>')
    [void]$sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f3f6fa;color:#1b2733}header{background:#0b2a4a;color:#fff;padding:20px 32px}h1{margin:0;font-size:22px}header p{margin:4px 0 0;opacity:.85}main{padding:24px 32px;max-width:1000px}section{background:#fff;border-radius:8px;padding:16px 20px;margin-bottom:18px;box-shadow:0 1px 3px rgba(0,0,0,.12)}h2{font-size:16px;color:#0b2a4a;margin:0 0 10px}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #e3e8ef;vertical-align:top;font-size:13px}th{width:220px;color:#445}thead th{width:auto;background:#eef2f7}.banner{font-weight:700;padding:12px 16px;border-radius:6px;color:#fff}.ok{background:#1e9e57}.bad{background:#d64545}.Completed{color:#1e9e57;font-weight:600}.Failed{color:#d64545;font-weight:600}.Pending,.Skipped,.RestartRequired,.Running{color:#b97a00;font-weight:600}ul{margin:0;padding-left:20px}footer{padding:0 32px 24px;color:#667;font-size:12px}</style></head><body>')
    [void]$sb.AppendLine(('<header><h1>GRE IT Onboarding &mdash; Part 1 Report</h1><p>{0}</p></header><main>' -f (& $e $Model['Organization'])))
    [void]$sb.AppendLine(('<section><div class="banner {0}">{1}</div></section>' -f $statusClass, $statusText))

    [void]$sb.AppendLine('<section><h2>Session</h2><table>')
    foreach ($row in @(@('Completion timestamp', $Model['GeneratedAt']), @('IT technician', $Model['Technician']), @('Session ID', $Model['SessionId']))) {
        [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1}</td></tr>' -f (& $e $row[0]), (& $e $row[1])))
    }
    [void]$sb.AppendLine('</table></section>')

    [void]$sb.AppendLine('<section><h2>Device information</h2><table>')
    $simple = @(
        @('Device name', 'ComputerName'), @('Manufacturer', 'Manufacturer'), @('Model', 'Model'), @('Serial number', 'SerialNumber'),
        @('BIOS version', 'BiosVersion'), @('BIOS release date', 'BiosReleaseDate'), @('Windows edition', 'WindowsEdition'),
        @('Windows version', 'WindowsVersion'), @('OS build', 'OsBuild'), @('CPU', 'Cpu'), @('Logical processors', 'LogicalProcessors'),
        @('RAM (GB)', 'RamGB'), @('Internal storage total (GB)', 'StorageTotalGB'), @('Secure Boot', 'SecureBoot'), @('Signed-in user', 'CurrentUser'))
    foreach ($pair in $simple) {
        $val = ''
        if ($null -ne $d -and $d.Contains($pair[1])) { $val = $d[$pair[1]] }
        [void]$sb.AppendLine(('<tr><th>{0}</th><td>{1}</td></tr>' -f (& $e $pair[0]), (& $e $val)))
    }
    if ($null -ne $d -and $d.Contains('Tpm') -and $null -ne $d['Tpm']) {
        $t = $d['Tpm']
        $tpmText = 'Not detected'
        if ($t['Present']) { $tpmText = 'Present; Enabled: {0}; Activated: {1}; Spec version: {2}' -f $t['Enabled'], $t['Activated'], $t['SpecVersion'] }
        [void]$sb.AppendLine(('<tr><th>TPM</th><td>{0}</td></tr>' -f (& $e $tpmText)))
    }
    if ($null -ne $d -and $d.Contains('Battery') -and $null -ne $d['Battery']) {
        $b = $d['Battery']
        $batText = 'No battery detected'
        if ($b['Present']) {
            $batText = '{0}; Design: {1} mWh; Full charge: {2} mWh; Estimated health: {3}%' -f $b['Name'], $b['DesignCapacity_mWh'], $b['FullChargeCapacity_mWh'], $b['HealthPercent']
        }
        [void]$sb.AppendLine(('<tr><th>Battery</th><td>{0}</td></tr>' -f (& $e $batText)))
    }
    [void]$sb.AppendLine('</table>')
    if ($null -ne $d -and $d.Contains('Storage') -and @($d['Storage']).Count -gt 0) {
        [void]$sb.AppendLine('<h2 style="margin-top:14px">Storage devices</h2><table><thead><tr><th>Model</th><th>Type</th><th>Bus</th><th>Size (GB)</th><th>Reported health</th></tr></thead><tbody>')
        foreach ($s in @($d['Storage'])) {
            [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f (& $e $s['Model']), (& $e $s['MediaType']), (& $e $s['BusType']), (& $e $s['SizeGB']), (& $e $s['HealthStatus'])))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    if ($null -ne $d -and $d.Contains('NetworkAdapters') -and @($d['NetworkAdapters']).Count -gt 0) {
        [void]$sb.AppendLine('<h2 style="margin-top:14px">Network adapters</h2><table><thead><tr><th>Name</th><th>Description</th><th>MAC</th><th>Status</th><th>Link speed</th></tr></thead><tbody>')
        foreach ($n in @($d['NetworkAdapters'])) {
            [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f (& $e $n['Name']), (& $e $n['Description']), (& $e $n['MacAddress']), (& $e $n['Status']), (& $e $n['LinkSpeed'])))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    [void]$sb.AppendLine('</section>')

    [void]$sb.AppendLine('<section><h2>Task results</h2><table><thead><tr><th>Task</th><th>Status</th><th>Details</th><th>Time</th></tr></thead><tbody>')
    foreach ($s in @($Model['Steps'])) {
        [void]$sb.AppendLine(('<tr><td>{0}</td><td class="{1}">{1}</td><td>{2}</td><td>{3}</td></tr>' -f (& $e $s['Title']), (& $e $s['Status']), (& $e $s['Message']), (& $e $s['Timestamp'])))
    }
    [void]$sb.AppendLine('</tbody></table></section>')

    foreach ($block in @(@('Errors', 'Errors'), @('Warnings', 'Warnings'))) {
        [void]$sb.AppendLine(('<section><h2>{0}</h2>' -f $block[0]))
        $items = @($Model[$block[1]])
        if ($items.Count -eq 0) { [void]$sb.AppendLine('<p>None recorded.</p>') }
        else {
            [void]$sb.AppendLine('<ul>')
            foreach ($i in $items) { [void]$sb.AppendLine(('<li>{0}</li>' -f (& $e $i))) }
            [void]$sb.AppendLine('</ul>')
        }
        [void]$sb.AppendLine('</section>')
    }
    [void]$sb.AppendLine('</main><footer>Hardware detection is not proof of physical functionality. This report intentionally contains no passwords, recovery keys or hardware hash data. Next step: the Intune administrator imports the hardware hash CSV into Windows Autopilot. Part 2 runs only after provisioning.</footer></body></html>')
    return $sb.ToString()
}

function Export-Part1Report {
    <# Writes <Directory>\Part1_<serial>_<stamp>.html and .json; verifies both; returns their paths. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Model,
        [Parameter(Mandatory = $true)][string]$Directory,
        [string]$Stamp = (Get-Date -Format 'yyyyMMdd_HHmmss')
    )
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null }
    $serial = 'UnknownSerial'
    $dev = $Model['Device']
    if ($null -ne $dev -and $dev.Contains('SerialNumber') -and $dev['SerialNumber'] -and $dev['SerialNumber'] -ne 'Unknown') { $serial = [string]$dev['SerialNumber'] }
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $serial = $serial.Replace([string]$c, '_') }
    $serial = $serial.Replace(' ', '_')
    $base = Join-Path $Directory ('Part1_{0}_{1}' -f $serial, $Stamp)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $htmlPath = "$base.html"; $jsonPath = "$base.json"
    [System.IO.File]::WriteAllText($htmlPath, (ConvertTo-Part1ReportHtml -Model $Model), $utf8)
    [System.IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $Model -Depth 12), $utf8)
    foreach ($p in @($htmlPath, $jsonPath)) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).Length -eq 0) { throw "Report file was not written correctly: $p" }
    }
    return @{ HtmlPath = $htmlPath; JsonPath = $jsonPath }
}

Export-ModuleMember -Function ConvertTo-OnboardingHtmlText, Remove-OnboardingSensitiveData, Get-Part1OverallStatus,
    New-Part1ReportModel, ConvertTo-Part1ReportHtml, Export-Part1Report
