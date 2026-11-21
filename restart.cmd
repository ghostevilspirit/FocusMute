@echo off
chcp 936 >nul
cd /d "%~dp0"
echo 重启看护（改完配置后跑这个）
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0FocusMute.ps1" -Action Restart
echo.
pause