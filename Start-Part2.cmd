@echo off
rem GRE IT Onboarding - Part 2 (Post-Intune) launcher
rem Runs from any drive letter; the launcher requests elevation through UAC.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
    echo Windows PowerShell 5.1 was not found at "%PS%".
    pause
    exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0Scripts\Launcher.ps1" -Part 2
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo GRE IT Onboarding launcher exited with code %RC%.
    echo See Documentation\Troubleshooting.md for the meaning of exit codes.
    pause
)
endlocal & exit /b %RC%
