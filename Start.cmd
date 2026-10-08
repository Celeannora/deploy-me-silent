@echo off
REM Double-click this to launch the interactive wizard.
REM No parameters, no switches -- everything is asked in a menu.

setlocal
cd /d "%~dp0"

where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -STA -ExecutionPolicy Bypass -File ".\Start-Wizard.ps1"
) else (
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File ".\Start-Wizard.ps1"
)

echo.
echo Wizard exited with code %ERRORLEVEL%.
pause
endlocal
