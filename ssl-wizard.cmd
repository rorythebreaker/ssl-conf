@echo off
rem Launcher for ssl-wizard.ps1 - double-click to start the wizard.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssl-wizard.ps1" %*
if errorlevel 1 pause
