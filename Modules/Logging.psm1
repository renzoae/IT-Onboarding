<#
    GRE IT Onboarding - Logging module
    Writes timestamped log lines to the USB (Logs\) with automatic fallback to a
    local directory when the USB is unavailable, and forwards lines to the GUI
    through a thread-safe queue. Passwords are never passed to this module; a
    defensive redaction filter is applied anyway.
#>
Set-StrictMode -Version 2.0

$script:LogState = @{ PrimaryPath = $null; FallbackPath = $null; UiQueue = $null }

function Protect-OnboardingLogMessage {
    <# Defensive redaction of anything that looks like "password = value" / recovery keys. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return '' }
    $m = [regex]::Replace($Message, '(?i)(pass(word|phrase)?|pwd|secret|token|recovery\s*key)(\s*[:=]\s*)(\S+)', '$1$4[REDACTED]')
    # BitLocker numerical recovery password pattern (8 groups of 6 digits)
    $m = [regex]::Replace($m, '\b(\d{6}-){7}\d{6}\b', '[REDACTED-RECOVERY-KEY]')
    return $m
}

function Initialize-OnboardingLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PrimaryDirectory,
        [string]$FallbackDirectory,
        [string]$FileName,
        $UiQueue
    )
    if (-not $FileName) { $FileName = 'Onboarding_{0}_{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss') }
    $script:LogState.PrimaryPath = Join-Path $PrimaryDirectory $FileName
    $script:LogState.FallbackPath = $null
    if ($FallbackDirectory) { $script:LogState.FallbackPath = Join-Path $FallbackDirectory $FileName }
    $script:LogState.UiQueue = $UiQueue
    return $script:LogState.PrimaryPath
}

function Get-OnboardingLogPath {
    [CmdletBinding()]
    param()
    return $script:LogState.PrimaryPath
}

function Add-OnboardingLogLine {
    param([string]$Path, [string]$Line)
    if (-not $Path) { return $false }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            [System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
            return $true
        }
        catch { Start-Sleep -Milliseconds 80 }
    }
    return $false
}

function Write-OnboardingLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')][string]$Level = 'INFO',
        [string]$Step = ''
    )
    $safe = Protect-OnboardingLogMessage -Message $Message
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = ''
    if ($Step) { $prefix = "[$Step] " }
    $line = '{0} [{1,-7}] {2}{3}' -f $stamp, $Level, $prefix, $safe

    # USB first; if it is gone (unplugged), keep logging locally so diagnostics survive.
    $written = Add-OnboardingLogLine -Path $script:LogState.PrimaryPath -Line $line
    if (-not $written) { [void](Add-OnboardingLogLine -Path $script:LogState.FallbackPath -Line $line) }

    $queue = $script:LogState.UiQueue
    if ($null -ne $queue) {
        try { $queue.Enqueue(@{ Type = 'Log'; Level = $Level; Text = $line }) } catch { }
    }
}

Export-ModuleMember -Function Protect-OnboardingLogMessage, Initialize-OnboardingLog, Get-OnboardingLogPath, Write-OnboardingLog
