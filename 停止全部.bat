@echo off
chcp 936 >nul
title QQFarmBotHim - stop everything
cd /d "%~dp0"

echo   Stopping main program + SnowLuma ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0panel\panel.ps1" -Action stopp0 -NoPause
echo.
echo   Done.
timeout /t 3 /nobreak >nul
