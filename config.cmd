@echo off
chcp 936 >nul
cd /d "%~dp0"
set "CFG=%LOCALAPPDATA%\FocusMute\focus-mute.json"
if not exist "%CFG%" set "CFG=%~dp0focus-mute.json"
if not exist "%CFG%" echo 找不到 focus-mute.json & pause & goto :eof
echo 用记事本打开：%CFG%
echo 改完保存后跑 restart.cmd 生效。
notepad "%CFG%"