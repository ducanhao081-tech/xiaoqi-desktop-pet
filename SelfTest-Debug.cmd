@echo off
setlocal
cd /d "%~dp0"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "LOG_DIR=%~dp0logs"
set "LOG_PATH=%LOG_DIR%\desktop-pet-selftest.log"

if not exist "%POWERSHELL_EXE%" (
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
>"%LOG_PATH%" echo powershell.exe was not found at "%POWERSHELL_EXE%". The Windows self-test host could not be launched.
echo powershell.exe was not found at "%POWERSHELL_EXE%". The Windows self-test host could not be launched.
set "EXITCODE=1"
pause
exit /b %EXITCODE%
)

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0SelfTest-Debug.ps1"
set "EXITCODE=%ERRORLEVEL%"
pause
exit /b %EXITCODE%
