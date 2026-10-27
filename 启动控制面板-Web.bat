@echo off
chcp 936 >nul
title QQFarmBot-S - Control Panel
cd /d "%~dp0"

net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 0
)

echo.
echo   ============================================================
echo    QQFarmBot S - SnowLuma edition - control panel
echo   ============================================================
echo    Panel   : http://127.0.0.1:3100
echo    Main    : http://127.0.0.1:3007
echo    SnowLuma: http://127.0.0.1:5099
echo    Stop    : close this window or Ctrl+C
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0panel\panel.ps1" -Action web -WebPort 3100
if errorlevel 1 pause
