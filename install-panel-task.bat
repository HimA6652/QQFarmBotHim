@echo off
chcp 936 >nul
title QQFarmBotHim - install elevated panel task
cd /d "%~dp0"

echo   Registering scheduled task "QQFarmBotHim-Panel" (runs the panel elevated).
echo   After this, starting/stopping SnowLuma from the panel will NOT pop UAC.
echo.

net session >nul 2>&1
if errorlevel 1 (
    echo   Requesting administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 0
)

schtasks /create /tn "QQFarmBotHim-Panel" /tr "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File D:\ProgramData\QQFarmBotHim\panel\panel.ps1 -Action web -WebPort 3100" /sc onlogon /rl highest /f
if errorlevel 1 (
    echo   [ERROR] task creation failed.
    pause
    exit /b 1
)

echo   Task registered. Starting the panel now...
schtasks /run /tn "QQFarmBotHim-Panel"
echo.
echo   Panel : http://127.0.0.1:3100
echo   Start : schtasks /run    /tn "QQFarmBotHim-Panel"
echo   Stop  : schtasks /end    /tn "QQFarmBotHim-Panel"
echo   Remove: schtasks /delete /tn "QQFarmBotHim-Panel" /f
echo.
pause
