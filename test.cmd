@echo off
chcp 936 >nul
cd /d "%~dp0"
echo 立即静音 1.5 秒再复原（会听到一次短暂静音）
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0FocusMute.ps1" -Action Test
echo.
pause