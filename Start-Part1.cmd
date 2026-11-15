@echo off
rem GRE IT Onboarding - Part 1. Double-click to start. Works from any drive letter.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0Part1.ps1"
