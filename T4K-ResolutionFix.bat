@echo off
rem Tempest 4000 Resolution List Fix - double-click to patch your Steam install.
rem Runs the PowerShell patcher next to this file. Pass Tempest4000.exe paths or -Check / -Restore / -NoCave as arguments.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0T4K-ResolutionFix.ps1" %*
echo.
if errorlevel 1 (echo Something went wrong - see the messages above.) else (echo Done.)
pause
