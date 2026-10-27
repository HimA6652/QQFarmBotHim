@echo off
chcp 936 >nul
title QQFarmBot - LAN firewall rules
setlocal

rem ============================================================================
rem  Allow other PCs on the SAME subnet to reach:
rem    3100  web control panel  (this panel)
rem    3007  main program web UI
rem  Scope: remoteip=LocalSubnet  -> LAN only, NOT reachable from the internet.
rem  Usage:  enable-lan-firewall.bat          (add / refresh)
rem          enable-lan-firewall.bat remove   (delete)
rem ============================================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%*'"
    exit /b
)

if /i "%~1"=="remove" goto REMOVE

echo.
echo   [1/2] TCP 3100  (web control panel)
netsh advfirewall firewall delete rule name="QQFarmBot Panel 3100" >nul 2>&1
netsh advfirewall firewall add rule name="QQFarmBot Panel 3100" dir=in action=allow protocol=TCP localport=3100 remoteip=LocalSubnet profile=private,public description="QQFarmBot web control panel, LAN only"

echo   [2/2] TCP 3007  (main program web UI)
netsh advfirewall firewall delete rule name="QQFarmBot Web 3007" >nul 2>&1
netsh advfirewall firewall add rule name="QQFarmBot Web 3007" dir=in action=allow protocol=TCP localport=3007 remoteip=LocalSubnet profile=private,public description="QQFarmBot main web UI, LAN only"

echo.
echo   Done. Current IPv4 addresses of this PC:
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4"') do echo      %%a
echo.
echo   Open from another PC:  http://THIS-PC-IP:3100
echo   Remove rules later  :  %~nx0 remove
echo.
pause
exit /b 0

:REMOVE
netsh advfirewall firewall delete rule name="QQFarmBot Panel 3100" >nul 2>&1
netsh advfirewall firewall delete rule name="QQFarmBot Web 3007" >nul 2>&1
echo.
echo   Rules removed.
echo.
pause
exit /b 0
