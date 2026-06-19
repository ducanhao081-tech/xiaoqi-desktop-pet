@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-DesktopPet.ps1" -SelfTest
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
echo.
echo Self-test failed. Run SelfTest-Debug.cmd to keep the self-test log window open.
)
pause
exit /b %EXITCODE%
