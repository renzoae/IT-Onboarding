# Architecture

## Layers

| Layer | Files | Responsibility |
|-------|-------|----------------|
| Launch | `Start-Part*.cmd`, `Scripts/Launcher.ps1` | Environment checks, UAC elevation, STA, drive-letter independent root |
| Workflow | `Scripts/Part1.ps1` | Step catalogue, step implementations, workflow engine |
| GUI | `GUI/MainWindow.*`, `GUI/Components/*` | WPF window, dialogs, thread-safe UI updates |
| Configuration | `Modules/Configuration.psm1`, `Config/*.json` | Settings with safe defaults, path context |
| Local admin | `Modules/LocalAdmin.psm1` | Username/password validation, account creation, verification |
| Device info | `Modules/DeviceInfo.psm1` | CIM/WMI inventory |
| Windows Update | `Modules/WindowsUpdate.psm1` | Windows Update Agent COM API |
| Autopilot | `Modules/Autopilot.psm1` | Hardware hash export + CSV validation |
| Reporting | `Modules/Reporting.psm1` | HTML/JSON reports, sensitive-data filter |
| Resume | `Modules/Resume.psm1` | Checkpoints, resume-after-restart task |
| Cleanup | `Modules/Cleanup.psm1` | Manifest-based, allow-listed deletion |
| Logging | `Modules/Logging.psm1` | File log (USB with local fallback) + GUI feed |
| Later phases | `SoftwareInstaller`, `HardwareDiagnostics`, `SecurityChecks`, `IntuneVerification`, `Wallpaper`, `UserConfiguration` | Placeholders that report "not implemented" |

Modules never reference GUI objects. The GUI never calls OS cmdlets directly;
it calls module functions.

## Threading

* The WPF window runs on the STA UI thread.
* Steps 2-6 run in a **background runspace** started by the GUI.
* The background runspace posts hashtable messages (`Log`, `Step`, `Progress`,
  `Device`, `StepDone`, `WorkflowEnded`) to a `ConcurrentQueue`. A
  `DispatcherTimer` on the UI thread drains the queue and updates controls.
  No WPF object is touched from another thread.
* Step 1 (local administrator) runs on the UI thread before the background
  workflow starts, so the `SecureString` never crosses a thread or runspace.

## Step model

`Get-Part1StepDefinition` lists the steps. Each step returns
`@{ Status; Message; Data }` where Status is `Completed`, `Failed` or
`RestartRequired`. The engine (`Invoke-Part1Workflow`):

* skips steps already `Completed` (except `AlwaysRun` steps such as the device
  inventory and the report, which are cheap and must be current);
* re-verifies the Autopilot CSV on the USB instead of trusting the checkpoint;
* converts exceptions into `Failed` with the error text;
* stops at `RestartRequired` (checkpoint saved);
* keeps going after a Windows Update or Autopilot failure so the technician
  still gets a report, but never marks Part 1 complete and never runs cleanup;
* marks Part 1 complete only when **every** step is `Completed`.

## State and restart recovery

* State file: `%ProgramData%\GRE-IT-Onboarding\State\Part1.state.json`
  (Administrators + SYSTEM only, written atomically, refuses credential-like
  fields). Part 2 uses a separate `Part2.state.json`.
* When Windows Update needs a restart the GUI registers the scheduled task
  `GRE-IT-Onboarding-Resume-Part1`: trigger *at logon*, principal *local
  Administrators group*, run level *highest*. **No password is stored.**
* The task runs a small local stub that searches every drive for the launcher
  at the same relative path (the USB letter may change), verifies its SHA-256
  hash, and starts `Launcher.ps1 -Part 1 -Resume`. If the USB is missing it
  asks the technician to insert it.
* The task and stub are removed by the cleanup step, or by **Start New Session**.
* A step found in `Running` state at start-up was interrupted and runs again.
* Windows Update guards against restart loops with `MaxRestartCycles`.

## USB handling

* All paths derive from the launcher location; nothing is hardcoded.
* Logs go to `Logs\` on the USB and fall back to
  `%ProgramData%\GRE-IT-Onboarding\Logs` if the USB disappears.
* If the USB is missing when the hash or report is written, that step fails
  with a clear message and can be retried after re-inserting the drive.

## Future MEX integration

Not started. No MEX endpoints or authentication are assumed anywhere. The
inventory export (Phase 6) will produce a CSV plus a JSON model that a future
integration module can consume.
