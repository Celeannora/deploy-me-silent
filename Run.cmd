@echo off
REM ---------------------------------------------------------------
REM Launcher that keeps the console open and captures FULL output
REM (including anything the script prints before its own trap fires)
REM ---------------------------------------------------------------
setlocal
cd /d "%~dp0"

set "LOG=%~dp0Logs\launch_%DATE:/=-%_%TIME::=-%.log"
set "LOG=%LOG: =0%"
if not exist "%~dp0Logs" mkdir "%~dp0Logs"

echo Launcher log: %LOG%
echo Running Deploy-MESilentInstall.ps1  (args: %*)
echo ---------------------------------------------------------------

REM Prefer PowerShell 7 (pwsh); fall back to Windows PowerShell 5.1
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File ".\Deploy-MESilentInstall.ps1" -Pause -Debug2 %* 2>&1 | tee "%LOG%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\Deploy-MESilentInstall.ps1" -Pause -Debug2 %* 2>&1 > "%LOG%"
    type "%LOG%"
)

echo.
echo ---------------------------------------------------------------
echo Exit code: %ERRORLEVEL%
echo Full launcher log: %LOG%
echo ---------------------------------------------------------------
pause
endlocal
