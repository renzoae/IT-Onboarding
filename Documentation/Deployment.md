# USB deployment

## Prepare the USB drive

1. Use a drive the IT department controls. **NTFS is recommended**: it lets the
   tool restrict the hardware hash CSV to Administrators. On exFAT/FAT32 the
   tool still works but reports that file permissions could not be applied.
   A BitLocker To Go protected drive is recommended for data at rest.
2. Copy the complete repository folder to the drive (root or a subfolder).
   Do not rename `Scripts`, `GUI`, `Modules` or `Config`.
3. If the files were downloaded as a ZIP from GitHub, Windows marks them as
   "from the internet". On the USB, run once from an elevated PowerShell:
   `Get-ChildItem -Recurse <USB folder> | Unblock-File`
4. Edit `Config/Settings.json` for the company (see README prerequisites).
5. Do not store passwords, keys or tokens anywhere on the drive.

## Run Part 1 on a new laptop

1. Complete Windows setup far enough to reach a desktop with a local
   administrator-capable account (company process).
2. Connect the laptop to power and to a network.
3. Insert the USB drive, double-click `Start-Part1.cmd`, approve UAC.
4. Optionally enter the technician name, click **Start Part 1**.
5. Enter the local administrator username and password in the dialog.
6. If a restart is required, choose **Yes**. Leave the USB inserted and sign in
   with an administrator account afterwards; Part 1 resumes on its own.
7. Wait for **PART 1 COMPLETED - READY FOR INTUNE**.
8. Hand `Reports/HardwareHash/Autopilot_<serial>.csv` to the Intune administrator.

## Manual Intune stage (outside this tool)

Import the CSV into Windows Autopilot, assign the deployment profile, wait for
registration and profile assignment, run the company's approved provisioning or
reset process, and let the employee sign in. Importing the hash alone does not
mean the device is enrolled. Part 2 is run only after that.

## Execution policy

The launchers start PowerShell with `-ExecutionPolicy RemoteSigned` for that
process only. If the organization enforces an execution policy by Group Policy
or Intune, that policy wins and is not overridden. In that case the scripts
must be signed with the company's code-signing certificate (recommended for
production anyway).
