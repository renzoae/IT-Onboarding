<#
    GRE IT Onboarding - Cleanup module
    Deletes ONLY items the application registered in its own manifest, and only
    when they are located strictly inside an application-owned root. Anything
    else is refused. The application on the USB, reports, hardware hashes,
    Windows, installed software and user files are never touched.
#>
Set-StrictMode -Version 2.0

function Get-CleanupLocalRoot {
    if ($env:GRE_ONBOARDING_LOCALROOT) { return $env:GRE_ONBOARDING_LOCALROOT }
    $base = $env:ProgramData
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path $base 'GRE-IT-Onboarding')
}

function Get-OnboardingCleanupManifestPath {
    [CmdletBinding()]
    param()
    return (Join-Path (Join-Path (Get-CleanupLocalRoot) 'State') 'CleanupManifest.json')
}

function Get-OnboardingCleanupAllowedRoots {
    <# The only places cleanup may delete from. #>
    [CmdletBinding()]
    param()
    return @((Join-Path (Get-CleanupLocalRoot) 'Work'))
}

function ConvertTo-CleanupNormalizedPath {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.TrimEnd([char[]]@('\', '/'))
}

function Test-OnboardingCleanupPathSafe {
    <#
        Returns [pscustomobject] @{ IsSafe; Reason }.
        Safe = absolute, no traversal, strictly inside an allowed root, not inside
        a protected root, and not a reparse point (junction/symlink).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$AllowedRoots,
        [string[]]$ProtectedRoots = @()
    )
    $deny = { param($r) [pscustomobject]@{ IsSafe = $false; Reason = $r } }
    if ([string]::IsNullOrWhiteSpace($Path)) { return (& $deny 'Empty path.') }
    if ($Path -match '[\*\?]') { return (& $deny 'Wildcards are not allowed.') }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return (& $deny 'Path is not absolute.') }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') { return (& $deny 'Path traversal is not allowed.') }
    try { $full = ConvertTo-CleanupNormalizedPath $Path } catch { return (& $deny 'Path is not valid.') }
    $sep = [System.IO.Path]::DirectorySeparatorChar

    foreach ($p in $ProtectedRoots) {
        if (-not $p) { continue }
        $pr = ConvertTo-CleanupNormalizedPath $p
        if ($full.Equals($pr, [System.StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($pr + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
            return (& $deny "Path is inside a protected location ($pr).")
        }
    }
    $inside = $false
    foreach ($a in $AllowedRoots) {
        if (-not $a) { continue }
        $ar = ConvertTo-CleanupNormalizedPath $a
        if ($full.StartsWith($ar + $sep, [System.StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break }
    }
    if (-not $inside) { return (& $deny 'Path is not inside an application-owned working folder.') }

    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return (& $deny 'Path is a link/junction and will not be followed.')
        }
    }
    return [pscustomobject]@{ IsSafe = $true; Reason = '' }
}

function Get-OnboardingCleanupManifest {
    [CmdletBinding()]
    param()
    $path = Get-OnboardingCleanupManifestPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))
        return @($parsed | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }
    catch { return @() }
}

function Register-OnboardingCleanupItem {
    <# Records a temp file/folder created by the application so cleanup can remove it later. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $check = Test-OnboardingCleanupPathSafe -Path $Path -AllowedRoots (Get-OnboardingCleanupAllowedRoots)
    if (-not $check.IsSafe) { throw "Refusing to track '$Path' for cleanup: $($check.Reason)" }
    $items = @(Get-OnboardingCleanupManifest)
    $full = ConvertTo-CleanupNormalizedPath $Path
    if ($items -notcontains $full) { $items += $full }
    $manifest = Get-OnboardingCleanupManifestPath
    $dir = Split-Path -Parent $manifest
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject @($items)), (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-OnboardingTrackedItems {
    <#
        Deletes every manifest entry that passes the safety test.
        Returns @{ Removed = @(); Refused = @(); Errors = @() }.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$ProtectedRoots = @())
    $result = @{ Removed = @(); Refused = @(); Errors = @() }
    $allowed = Get-OnboardingCleanupAllowedRoots
    $keep = @()
    foreach ($item in @(Get-OnboardingCleanupManifest)) {
        $check = Test-OnboardingCleanupPathSafe -Path $item -AllowedRoots $allowed -ProtectedRoots $ProtectedRoots
        if (-not $check.IsSafe) { $result.Refused += ('{0} ({1})' -f $item, $check.Reason); continue }
        if (-not (Test-Path -LiteralPath $item)) { continue }
        try {
            if ($PSCmdlet.ShouldProcess($item, 'Remove application temporary item')) {
                Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction Stop
                $result.Removed += $item
            }
        }
        catch { $result.Errors += ('{0}: {1}' -f $item, $_.Exception.Message); $keep += $item }
    }
    $manifest = Get-OnboardingCleanupManifestPath
    if ($keep.Count -eq 0) { if (Test-Path -LiteralPath $manifest) { Remove-Item -LiteralPath $manifest -Force } }
    else { [System.IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject @($keep)), (New-Object System.Text.UTF8Encoding($false))) }
    return $result
}

function Invoke-OnboardingPart1Cleanup {
    <#
        Part 1 cleanup. Runs only after the deliverables are verified on the USB.
        Preserves: hardware hash CSV, reports, logs, the application itself.
        Returns @{ Success; Message; Removed; Refused; Errors }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HardwareHashPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReportPath
    )
    $out = @{ Success = $false; Message = ''; Removed = @(); Refused = @(); Errors = @() }
    if (-not $HardwareHashPath -or -not (Test-Path -LiteralPath $HardwareHashPath -PathType Leaf)) {
        $out.Message = 'Cleanup skipped: the hardware hash CSV could not be verified on the USB drive.'
        return $out
    }
    if (-not $ReportPath -or -not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        $out.Message = 'Cleanup skipped: the Part 1 report could not be verified on the USB drive.'
        return $out
    }
    $candidates = @($AppRoot, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:SystemDrive 'Users')) | Where-Object { $_ }
    # A protected location that CONTAINS the application's own working folder cannot be
    # blocked wholesale, or nothing could ever be cleaned (e.g. a working root redirected
    # below a user profile). The "strictly inside the working folder" rule still applies.
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $workRoots = @(Get-OnboardingCleanupAllowedRoots | ForEach-Object { ConvertTo-CleanupNormalizedPath $_ })
    $protected = @()
    foreach ($candidate in $candidates) {
        $normalized = ConvertTo-CleanupNormalizedPath $candidate
        $containsWorkRoot = $false
        foreach ($w in $workRoots) {
            if ($w.StartsWith($normalized + $sep, [System.StringComparison]::OrdinalIgnoreCase)) { $containsWorkRoot = $true }
        }
        if (-not $containsWorkRoot) { $protected += $candidate }
    }
    $r = Remove-OnboardingTrackedItems -ProtectedRoots $protected
    $out.Removed = $r.Removed; $out.Refused = $r.Refused; $out.Errors = $r.Errors
    $out.Success = (@($r.Errors).Count -eq 0)
    $out.Message = 'Removed {0} temporary item(s); {1} refused; {2} error(s). Hardware hash, reports and logs were preserved.' -f @($r.Removed).Count, @($r.Refused).Count, @($r.Errors).Count
    return $out
}

Export-ModuleMember -Function Get-OnboardingCleanupManifestPath, Get-OnboardingCleanupAllowedRoots, Test-OnboardingCleanupPathSafe,
    Get-OnboardingCleanupManifest, Register-OnboardingCleanupItem, Remove-OnboardingTrackedItems, Invoke-OnboardingPart1Cleanup

