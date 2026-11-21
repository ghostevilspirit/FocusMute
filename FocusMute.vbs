' FocusMute 隐藏启动器：无窗口闪屏地拉起 FocusMute.ps1 -Action Run
' 停止：运行 FocusMute.ps1 -Action Stop，或双击 stop.cmd
Option Explicit
Dim fso, sh, here, ps, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps = here & "\FocusMute.ps1"
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps & """"
sh.CurrentDirectory = here
sh.Run cmd, 0, False
