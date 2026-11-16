# GRE IT Onboarding

Prepares a new Windows 11 laptop in two parts. Each part is one script.

| File | Purpose |
|------|---------|
| `Start-Part1.cmd` + `Part1.ps1` | Before Intune (new laptop) |
| `Start-Part2.cmd` + `Part2.ps1` | After Intune (employee signed in) |

Settings are the few lines at the top of each `.ps1` file.

## Part 1 - before Intune

1. **Local administrator** - a dialog asks for username, password and confirm
   password, creates the account, adds it to Administrators and verifies it.
   An existing account is only changed if you click Yes.
2. **Device information** - manufacturer, model, serial, BIOS, Windows, CPU,
   RAM, storage, battery, TPM, Secure Boot, network adapters.
3. **Autopilot hardware hash** - saved to `Reports\HardwareHash\Autopilot_<serial>.csv`.
4. **Windows Update** (last) - installs updates. If a restart is needed,
   restart and run `Start-Part1.cmd` again; finished steps are skipped.

Ends with **PART 1 COMPLETED - READY FOR INTUNE** and a report in
`Reports\Part1_<serial>.html`. It does not enroll the device or run Sysprep.

How to run: connect power and a network, double-click `Start-Part1.cmd`,
approve the administrator prompt. Then give the CSV in `Reports\HardwareHash`
to the Intune administrator.

## In between (done by the Intune administrator, not by this tool)

Import the CSV into Windows Autopilot, assign the profile, provision or reset
the laptop, and let the employee sign in with the company account.

## Part 2 - after Intune

Run it while the **employee** is signed in. Double-click `Start-Part2.cmd`
normally (not "Run as administrator"); it asks for administrator rights itself
halfway through.

- **As the employee:** checks Entra ID join and company sign-in, applies the
  company wallpaper to the employee's profile, checks OneDrive sign-in and
  Desktop/Documents backup.
- **As administrator:** installs Adobe Acrobat Reader, 7-Zip and Google Earth
  Pro with WinGet if missing; verifies Microsoft 365 Apps, Teams and Sophos
  (these come from Intune or the company installer); checks Intune enrollment,
  BitLocker, recovery key backup, TPM, Secure Boot, firewall and antivirus.

Result in `Reports\Part2_<serial>.html`:

- **READY** - every check passed
- **NOT READY** - at least one check failed
- **MANUAL REVIEW REQUIRED** - nothing failed, but something could not be confirmed

Before running Part 2, put the company wallpaper at `Assets\CompanyWallpaper.jpg`.

## Notes

- Passwords and BitLocker recovery keys are never written to any file.
- Part 2 changes no security setting and no Intune policy. It cannot decide
  Intune compliance; confirm that in the Intune portal.
- Feature upgrades are skipped; update license terms are accepted automatically.
- The hardware hash usually cannot be read inside a virtual machine.
- Neither script has been run on a real device yet. Test on a spare laptop first.
