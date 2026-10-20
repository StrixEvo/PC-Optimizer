@echo off
rem Same as Run-PCOptimizer.bat but keeps a console open and prints errors.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCOptimizer.ps1" -ShowConsole
