@echo off
rem Builds PCOptimizer.exe from PCOptimizer.ps1 (needs internet once, to get the ps2exe tool).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Exe.ps1"
echo.
if exist "%~dp0PCOptimizer.exe" (echo Done: PCOptimizer.exe is in this folder.) else (echo Build failed. Scroll up to see why.)
pause
