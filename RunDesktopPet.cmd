@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-DesktopPet.ps1"
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
echo.
echo Desktop Pet failed before opening. Run RunDesktopPet-Debug.cmd to keep the log window open.
pause
)
exit /b %EXITCODE%
