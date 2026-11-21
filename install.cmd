@echo off
chcp 936 >nul
cd /d "%~dp0"
echo ============================================
echo  FocusMute 安装
echo  装到 %LOCALAPPDATA%\FocusMute 并注册登录自启
echo  配置：focus-mute.json（processes 填进程名）
echo ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%~dp0FocusMute.ps1" -Action Install
echo.
echo 安装完成。看状态：status.cmd   改配置：config.cmd   卸载：uninstall.cmd
pause