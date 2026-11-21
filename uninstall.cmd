@echo off
chcp 936 >nul
cd /d "%~dp0"
if /i "%~1"=="full" goto full
echo 卸载 FocusMute（停止看护 + 删除自启任务，保留安装目录和日志）
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0FocusMute.ps1" -Action Uninstall
echo.
echo 想连安装目录一起删掉：uninstall.cmd full
pause
goto :eof
:full
echo 彻底卸载（停止看护 + 删任务 + 删 %LOCALAPPDATA%\FocusMute）
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0FocusMute.ps1" -Action Uninstall -Purge
pause