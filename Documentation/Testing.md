# Testing

## Current test status - read this first

| Test type | Status |
|-----------|--------|
| Pester unit tests (mocked) | **Written, not yet executed.** The development environment had no PowerShell. |
| Script parse/syntax check on Windows PowerShell 5.1 | **Not done** |
| GUI on a real Windows 11 device | **Not done** |
| Account creation, Windows Update, hardware hash on real hardware | **Not done** |
| Intune / Autopilot import of the generated CSV | **Not done** |

Nothing in this repository should be described as "tested" until the steps
below have been carried out.

## 1. Automated tests (development PC, no admin rights needed)

```powershell
Install-Module Pester -MinimumVersion 5.3 -Scope CurrentUser -Force -SkipPublisherCheck
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Tests\Invoke-Tests.ps1
```

Windows ships Pester 3.4, which cannot run these tests.

| File | Covers |
|------|--------|
| `LocalAdmin.Tests.ps1` | Username validation, password policy, SecureString comparison, existing-account protection, rollback, verification |
| `Autopilot.Tests.ps1` | CSV naming, export format, structure validation |
| `Resume.Tests.ps1` | Checkpoint round trip, attempts, interrupted steps, corrupt state, credential refusal, resume stub |
| `Cleanup.Tests.ps1` | Path allow-list, traversal, protected roots, tampered manifest, deliverable verification |
| `Reporting.Tests.ps1` | Overall status, HTML/JSON output, encoding, sensitive-data filter |
| `WindowsUpdate.Tests.ps1` | Scan/install/rescan decisions, restart, failure handling |
| `Part1Workflow.Tests.ps1` | Step ordering, skipping, retry, restart resume, failure handling |

All operating-system calls are mocked. Passing tests prove the decision logic
only - not that accounts, updates or the hardware hash work on a real device.
Application-detection tests arrive with Phase 3.

## 2. Syntax check on Windows

```powershell
Get-ChildItem -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
    if ($errors) { "$($_.Name): $($errors[0].Message)" }
}
```

## 3. Pilot checklist (non-production laptop or VM with a snapshot)

Use a disposable device. A VM is fine for everything except the hardware hash,
which usually cannot be read in a VM.

- [ ] `Start-Part1.cmd` shows the UAC prompt; declining it gives exit code 2.
- [ ] The window opens; navigation works; the window stays responsive.
- [ ] Dialog rejects: empty name, `bad/name`, mismatched passwords, short password.
- [ ] A valid entry creates the account. Check with `Get-LocalUser` and
      `Get-LocalGroupMember -SID S-1-5-32-544`.
- [ ] Search `Logs\`, `Reports\` and `%ProgramData%\GRE-IT-Onboarding` for the
      test password: it must not appear anywhere.
- [ ] Enter an existing account name: nothing changes unless you confirm.
      Test No / Cancel and verify the existing password still works.
- [ ] Device information matches `msinfo32`.
- [ ] Disconnect the network: the Windows Update task fails with a clear
      message; reconnect and **Retry** works.
- [ ] Updates install; when a restart is requested, choose Yes; after sign-in
      Part 1 resumes automatically and does not ask for the administrator again.
- [ ] Repeat with the USB on a different port/drive letter after the restart.
- [ ] Remove the USB before signing in after a restart: the "insert USB" prompt appears.
- [ ] Final state: Settings > Windows Update shows no pending quality updates.
- [ ] `Reports\HardwareHash\Autopilot_<serial>.csv` exists (physical device) and
      imports successfully into a **test** Autopilot tenant/group.
- [ ] `Reports\Part1\*.html` opens and matches the device.
- [ ] After completion: scheduled task `GRE-IT-Onboarding-Resume-Part1` is gone.
- [ ] Device is not enrolled, Sysprep was not run.
