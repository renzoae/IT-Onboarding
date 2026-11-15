# GRE IT Onboarding

Prepares a new Windows 11 laptop before Intune. Two files do everything:

| File | Purpose |
|------|---------|
| `Start-Part1.cmd` | Double-click this to start |
| `Part1.ps1` | The script (settings are at the top) |

## What it does, in order

1. **Local administrator** - a dialog asks for username, password and confirm
   password, creates the account, adds it to Administrators and verifies it.
   An existing account is only changed if you click Yes.
2. **Device information** - manufacturer, model, serial, BIOS, Windows, CPU,
   RAM, storage, battery, TPM, Secure Boot, network adapters.
3. **Autopilot hardware hash** - saved to `Reports\HardwareHash\Autopilot_<serial>.csv`.
4. **Windows Update** (last) - installs updates. If a restart is needed,
   restart and run `Start-Part1.cmd` again; finished steps are skipped.

A report is saved to `Reports\Part1_<serial>.html` and a log next to it.
When everything is done it shows **PART 1 COMPLETED - READY FOR INTUNE**.
It does not enroll the device and does not run Sysprep.

## How to use

1. Copy this folder to a USB drive (or any folder on the laptop).
2. Connect the laptop to power and a network.
3. Double-click `Start-Part1.cmd` and approve the administrator prompt.
4. Give `Reports\HardwareHash\Autopilot_<serial>.csv` to the Intune administrator.

## Settings

Edit the three lines at the top of `Part1.ps1`:

- `$MinPasswordLength` - minimum password length (default 12)
- `$IncludeDriverUpdates` - also install driver updates (default no)
- `$AutopilotGroupTag` - optional Autopilot Group Tag

## Notes

- The password is never written to a file, log or the USB drive.
- Feature upgrades are skipped; update license terms are accepted automatically.
- The hardware hash usually cannot be read inside a virtual machine.
- Test on a spare laptop first. This single-script version has not yet been
  run on a real device.
