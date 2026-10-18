@echo off
setlocal enableextensions
title Monotone Control Panel

rem --- elevate ---------------------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'" >nul 2>&1
    exit /b
)

cd /d "%~dp0"

if not exist "ui\index.html" (
    echo [!] ui\index.html is missing. Run this from the repo root.
    pause
    exit /b 1
)

echo Starting control panel backend...
start "MonotoneUI-Server" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ui-server.ps1"

rem give the listener a moment to bind
ping -n 3 127.0.0.1 >nul

set "URL=http://127.0.0.1:8787/"

set "EDGE1=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
set "EDGE2=C:\Program Files\Microsoft\Edge\Application\msedge.exe"

if exist "%EDGE1%" (
    start "" "%EDGE1%" --app=%URL% --window-size=1100,760
    goto done
)
if exist "%EDGE2%" (
    start "" "%EDGE2%" --app=%URL% --window-size=1100,760
    goto done
)

echo Edge not found; opening in your default browser.
start "" "%URL%"

:done
echo.
echo Control panel is running at %URL%
echo Close the minimized "MonotoneUI-Server" window to stop the backend.
timeout /t 5 >nul
exit /b 0
