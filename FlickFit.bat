@echo off
REM FlickFit v1.0.0 launcher entry (FlickFitLauncher.ps1)
setlocal

echo FlickFit を起動しています...

set "SCRIPT_DIR=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "LAUNCHER=%SCRIPT_DIR%FlickFitLauncher.ps1"

start "" "%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "%LAUNCHER%"

endlocal
exit /b 0