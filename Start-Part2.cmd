@echo off
rem GRE IT Onboarding - Part 2. Double-click (do NOT use "Run as administrator"). Works from any drive letter.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0Part2.ps1" goto :missing

rem Windows blocks script files that were downloaded from the internet. Unblock this folder.
"%PS%" -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File | Unblock-File" 2>nul

"%PS%" -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Part2.ps1"
if errorlevel 1 goto :failed
exit /b 0

:missing
echo Part2.ps1 was not found next to this file.
echo If you opened this inside the ZIP, extract it first: right-click the ZIP, Extract All.
pause
exit /b 1

:failed
echo.
echo Part 2 stopped (code %errorlevel%). Read the message above.
pause
exit /b 1
