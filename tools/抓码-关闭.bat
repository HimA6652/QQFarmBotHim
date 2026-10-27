@echo off
chcp 936 >nul
title QQFarmBotHim - disable local code capture
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0抓码-关闭.ps1"
if errorlevel 1 pause
