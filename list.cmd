@echo off
chcp 936 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0FocusMute.ps1" -Action List
echo.
pause