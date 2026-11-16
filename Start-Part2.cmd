@echo off
rem GRE IT Onboarding - Part 2. Double-click (do NOT use "Run as administrator"). Works from any drive letter.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Part2.ps1"
