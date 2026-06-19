@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0RunDesktopPet-Debug.ps1"
set "EXITCODE=%ERRORLEVEL%"
pause
exit /b %EXITCODE%
