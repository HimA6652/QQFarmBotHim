@echo off
chcp 936 >nul
title QQFarmBotHim - enable local code capture
cd /d "%~dp0"

echo.
echo   Installing CA + setting system proxy to 127.0.0.1:18000 ...
echo   (a UAC prompt will appear - please click Yes)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0抓码-开启.ps1"
if errorlevel 1 pause
