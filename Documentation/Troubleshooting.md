# Troubleshooting

Logs: `Logs\Part1_<computer>_<timestamp>.log` on the USB. If the USB was
unavailable, look in `%ProgramData%\GRE-IT-Onboarding\Logs`.

## Exit codes (`Start-Part1.cmd`)

| Code | Meaning |
|------|---------|
| 0 | Completed, or handed over to the elevated window |
| 1 | Unexpected error (see log / message box) |
| 2 | Elevation declined or not available |
| 3 | Window closed while Part 1 was incomplete |
| 4 | Cancelled by the technician |
| 5 | Unsupported environment (not Windows PowerShell 5.1, not Windows 10/11, or Constrained Language Mode) |
| 10 | Restart pending |
| 20 | Requested part is not implemented in this build |

## Common problems

| Symptom | Cause / fix |
|---------|-------------|
| "running scripts is disabled on this system" | An execution policy is enforced by Group Policy/Intune. The tool does not override it. Sign the scripts or ask for an approved exception. |
| Files blocked / security warning for every script | Files carry the "downloaded from internet" mark. Run `Unblock-File` (see Deployment). |
| Nothing happens after UAC | Check the console window that opened; note the error text. Antivirus or application control may block PowerShell from removable media. |
| "Constrained Language Mode" message | WDAC/AppLocker policy. The tool stops by design. The scripts must be signed and allowed by policy. |
| Account creation fails with a password requirement message | The device's own password policy is stricter than `Settings.json`. Choose a stronger password; align `MinimumPasswordLength`. |
| "already exists" prompt | Expected. Yes = reset password, No = keep it, Cancel = pick another name. Nothing changes without Yes. |
| Windows Update: "No internet connectivity" | Connect Wi-Fi/Ethernet. If a proxy or captive portal is used, sign in first. Adjust `Connectivity.ProbeUrls` if the default URLs are blocked. |
| Windows Update: scan failed | Check the Windows Update service and the configured update source (WSUS reachable?). Run Settings > Windows Update once, then Retry. |
| Windows Update: restart loop message | A pending-restart flag does not clear. Restart manually, check Windows Update in Settings, then Retry. |
| Updates listed as "Not installed" | Feature upgrades and updates needing user interaction are excluded on purpose and reported. Change `IncludeFeatureUpgrades` only if company policy allows. |
| Hardware hash: empty or provider error | Virtual machine, very old firmware, or not elevated. Test on physical hardware. |
| Hash exported but "permissions could not be restricted" | USB is exFAT/FAT32. Use an NTFS (ideally BitLocker To Go) drive, or treat the USB as a controlled item. |
| After restart nothing resumes | Sign in with an account that is a member of local Administrators. Or run `Start-Part1.cmd` again - progress is kept. |
| "USB drive was not found" after restart | Insert the same USB and choose Retry. The launcher must be unchanged (its hash is verified). |
| Want to start over | Part 1 page > **Start New Session...**. Accounts, reports and hash files are not deleted. |
| Cleanup "Refused to delete" | A tracked path was outside the tool's working folder. Nothing was deleted; investigate the manifest in `%ProgramData%\GRE-IT-Onboarding\State`. |
