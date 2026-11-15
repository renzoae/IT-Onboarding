# GRE IT Onboarding

Portable Windows 11 laptop onboarding tool for the IT department. It runs from a
USB drive, needs no installation, and automates the onboarding workflow in two
independent parts:

| Part | When | Status in this build |
|------|------|----------------------|
| **Part 1 - Pre-Intune** | New laptop, before Autopilot/Intune | **Implemented** (Phases 1-2) |
| **Part 2 - Post-Intune** | After provisioning, employee signed in | Not implemented yet (Phases 3-7) |

> **Pilot status:** the code in this repository has **not yet been executed on a
> Windows device**. The automated tests are written but have not been run (see
> [Documentation/Testing.md](Documentation/Testing.md)). Run the test suite and
> the pilot checklist on a non-production laptop before any real use.

## What Part 1 does

1. **Local administrator** - secure dialog (username, password, confirm). The
   account is created, added to the local Administrators group and verified.
   Existing accounts are never changed without explicit confirmation.
2. **Device information** - manufacturer, model, serial, BIOS, Windows edition /
   version / build, CPU, RAM, storage, battery, TPM, Secure Boot, network adapters.
3. **Windows Update** - connectivity check, scan, download, install, restart
   detection, automatic resume after restart, rescan, final build recorded.
4. **Autopilot hardware hash** - exported to `Reports/HardwareHash/Autopilot_<serial>.csv`
   and validated.
5. **Report** - `Reports/Part1/Part1_<serial>_<timestamp>.html` and `.json`.
6. **Cleanup** - removes only the tool's own tracked temporary files.

Part 1 then stops with **PART 1 COMPLETED - READY FOR INTUNE**. It does **not**
enroll the device and does **not** run Sysprep. The Intune administrator imports
the CSV into Windows Autopilot manually.

## Quick start

1. Copy the whole repository folder to a USB drive (see
   [Documentation/Deployment.md](Documentation/Deployment.md)).
2. Review `Config/Settings.json`.
3. On the new laptop, double-click **`Start-Part1.cmd`** and approve the UAC prompt.
4. Click **Start Part 1**.

## Repository layout

```
Start-Part1.cmd / Start-Part2.cmd   Launchers (double-click)
Scripts/    Launcher.ps1 (elevation), Part1.ps1 (workflow), Part2.ps1 (placeholder)
GUI/        MainWindow.xaml/.ps1, Components/LocalAdminDialog.xaml/.ps1
Modules/    Business logic, one module per concern (see Documentation/Architecture.md)
Config/     Settings.json, Applications.json (templates - no secrets)
Assets/     CompanyWallpaper.jpg (company-supplied, Part 2)
Installers/ Company-supplied installers (never committed)
Reports/    Generated output (never committed)
Logs/       Generated logs (never committed)
Tests/      Pester 5 tests (mocked)
Documentation/
```

## Company-specific prerequisites (not invented by this tool)

| Item | Where | Needed for |
|------|-------|-----------|
| Password policy (minimum length, forbidden terms, expiry) | `Config/Settings.json` -> `LocalAdmin` | Part 1 |
| Windows Update choices (drivers, feature upgrades, EULA acceptance) | `Config/Settings.json` -> `WindowsUpdate` | Part 1 |
| Autopilot Group Tag (optional) | `Config/Settings.json` -> `Autopilot.GroupTag` | Part 1 |
| Organization name / default technician | `Config/Settings.json` -> `Reporting` | Reports |
| Corporate wallpaper | `Assets/CompanyWallpaper.jpg` | Part 2 |
| Sophos installer, Office Deployment Tool configuration | `Installers/` | Part 2 |
| Verified WinGet package IDs | `Config/Applications.json` | Part 2 |

## Documentation

* [Architecture](Documentation/Architecture.md)
* [USB deployment](Documentation/Deployment.md)
* [Testing](Documentation/Testing.md)
* [Troubleshooting and exit codes](Documentation/Troubleshooting.md)
* [Security considerations](Documentation/Security.md)

## What must never be committed

Credentials, employee data, real hardware hash exports, BitLocker recovery keys,
generated reports/logs, and licensed installers. `.gitignore` excludes the
folders where these are produced; keep the GitHub repository **private**.
