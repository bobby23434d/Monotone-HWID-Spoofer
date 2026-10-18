@echo off
setlocal
title Monotone Temp Spoofer

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)

:menu
cls
echo.
echo   ================================
echo     MONOTONE  -  TEMP SPOOFER
echo   ================================
echo.
echo     [1]  Apply spoof (manual restore)
echo     [2]  Apply spoof + auto-revert (choose minutes)
echo     [3]  Apply spoof + rename host
echo     [4]  Restore / revert
echo     [5]  Status
echo     [0]  Exit
echo.
set /p "choice=  select> "

if "%choice%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0temp-spoof.ps1" -Mode apply
if "%choice%"=="2" (
    set /p "mins=  minutes until revert> "
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0temp-spoof.ps1" -Mode apply -Seconds %mins%*60
)
if "%choice%"=="3" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0temp-spoof.ps1" -Mode apply -Hostname
if "%choice%"=="4" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0temp-spoof.ps1" -Mode restore
if "%choice%"=="5" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0temp-spoof.ps1" -Mode status
if "%choice%"=="0" exit /b

echo.
pause
goto :menu
