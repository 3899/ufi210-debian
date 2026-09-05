@echo off
setlocal
cd /d "%~dp0"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" set "POWERSHELL=powershell.exe"
"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\enter_fastboot.ps1"
set "result=%ERRORLEVEL%"
echo.
if not "%result%"=="0" echo Entering fastboot failed with exit code %result%.
pause
exit /b %result%
