# Security considerations

## Local administrator password

* Entered in a WPF `PasswordBox` (masked). Only `SecurePassword` (a
  `SecureString`) is read; the plain `.Password` property is never used.
* Policy checks copy the characters into a `char[]` through a BSTR that is
  zero-freed, and the array is cleared immediately. No managed `String` of the
  password is created by this tool.
* The `SecureString` is passed straight to `New-LocalUser` / `Set-LocalUser`,
  then disposed; the password boxes are cleared and a garbage collection is
  requested.
* It is never written to logs, the state file, reports, the scheduled task or
  the USB. The logger also redacts `password=...`-style text and BitLocker
  recovery-key patterns as a second safeguard; the state writer refuses
  credential-like field names.
* Limitation: Windows itself handles the password inside the account APIs, and
  .NET cannot guarantee that no transient copy ever exists in process memory.
  The process exits when the window closes.

## Existing accounts

An existing account is never modified silently. Password reset, enabling, and
adding to Administrators each require an explicit confirmation in the GUI, and
the module functions do nothing without the matching switch.

## Elevation and policies

* Elevation is requested with the standard UAC prompt only.
* Execution policy is set for the process only; enforced policies are respected.
* The tool stops in Constrained Language Mode instead of working around it.
* Windows Update uses the update source the organization configured. Feature
  upgrades are excluded by default. No security control is disabled.
* `WindowsUpdate.AcceptEulas` (default `true`) accepts update license terms on
  the organization's behalf - review this with the responsible person.

## Restart resume

* Scheduled task principal is the local Administrators **group**; no
  credentials are stored. It runs only when an administrator signs in.
* The stub it runs is stored in a folder restricted to Administrators and
  SYSTEM and verifies the SHA-256 hash of the USB launcher before starting it.
  Residual risk: the hash covers `Launcher.ps1`, not every script on the USB.
  Keep the USB under IT control; sign the scripts for production.

## Hardware hash

Sensitive device inventory data. It is written only to
`Reports/HardwareHash/`, never to logs or reports. On NTFS the file is
restricted to Administrators and SYSTEM. exFAT/FAT32 cannot enforce
permissions - the tool says so in the log and the report.

## Reports and state

* Reports contain device inventory (including MAC addresses) and the local
  administrator **username**, never the password. Treat them as internal.
* State is non-sensitive progress data in `%ProgramData%\GRE-IT-Onboarding`.

## Cleanup

Deletes only paths recorded in the tool's own manifest that are strictly inside
`%ProgramData%\GRE-IT-Onboarding\Work`. Links/junctions, wildcards, traversal
and protected locations (the USB application, Windows, Program Files, user
profiles) are refused. There is no self-deletion.

## Recommended before production

1. Code-sign all scripts.
2. Use BitLocker To Go on the onboarding USB drives.
3. Decide a retention/collection process for reports and hash files on the USB.
4. Consider Windows LAPS for the local administrator password after enrollment.
