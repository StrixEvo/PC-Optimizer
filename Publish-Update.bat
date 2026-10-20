@echo off
rem 1) Raise AppVersion in PCOptimizer.ps1   2) Double-click this file   3) Type what changed
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Publish-Update.ps1"
echo.
pause
