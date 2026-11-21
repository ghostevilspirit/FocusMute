#Requires -Version 5.1
<#
.SYNOPSIS
    FocusMute — Windows 失焦自动静音。目标程序在前台才出声，切走就静音。

.DESCRIPTION
    用 Windows Core Audio（WASAPI）对指定进程的音频会话做「会话级静音 / 压音量」，
    判定依据是当前前台窗口属于哪个进程。等价于音量合成器里点那个静音按钮：

      * 不注入进程、不加钩子、不改游戏/程序任何文件
      * 不写任何注册表音量项以外的状态，退出即复原
      * 只影响 JSON 里列出的进程，其它程序与其他游戏完全不受影响
      * 无第三方依赖：只用 Windows 自带 PowerShell 5.1

.PARAMETER Action
    Run        常驻看护（前台运行，Ctrl+C 退出并复原）——默认
    Status     体检：目标进程 / 音频会话 / 前台判定 / 看护状态 / 任务状态
    List       列出当前所有带音频会话的进程名（用来填 JSON 白名单）
    Test       立即静音 1.5 秒再复原，验证 WASAPI 通路
    Start      后台隐藏启动看护
    Stop       停止看护并复原
    Restart    Stop + Start
    Install    安装到 %LOCALAPPDATA%\FocusMute 并注册登录自启，然后启动
    Uninstall  停止看护 + 删除自启任务（加 -Purge 再删安装目录）
    Version    打印版本

.EXAMPLE
    .\FocusMute.ps1 -Action List
    .\FocusMute.ps1 -Action Install
    .\FocusMute.ps1 -Action Status

.NOTES
    配置文件：<脚本目录>\focus-mute.json
    日志：    <脚本目录>\logs\focus-mute.log（超限自动轮转为 .old）
    许可：    MIT
#>
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Status', 'List', 'Test', 'Start', 'Stop', 'Restart', 'Install', 'Uninstall', 'Version')]
    [string]$Action = 'Run',

    [string[]]$ProcessName,

    [ValidateSet('Mute', 'Duck')]
    [string]$Mode,

    [double]$DuckVolume = -1,

    [int]$Interval = 0,

    [switch]$IncludeOverlay,

    [switch]$Once,

    # 仅调试：伪造前台 pid 以验证失焦分支（0 = 读真实前台）
    [uint32]$SimulateForegroundPid = 0,

    [string]$ConfigPath,

    # Install 时强制用包里的 focus-mute.json 覆盖已装配置（切通用版/炉石版时用）
    [switch]$ForceConfig,

    [switch]$Purge
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.1.0'
$TaskName = 'FocusMute'
$MutexName = 'Local\FocusMuteDaemon'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$InstallDir = Join-Path $env:LOCALAPPDATA 'FocusMute'

# ---------------------------------------------------------------- 配置
function Resolve-ConfigPath {
    param([string]$Explicit)
    if ($Explicit) { return [System.IO.Path]::GetFullPath($Explicit) }
    $candidates = @(
        (Join-Path $ScriptDir 'focus-mute.json'),
        (Join-Path $InstallDir 'focus-mute.json'),
        (Join-Path $env:APPDATA 'FocusMute\focus-mute.json')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $candidates[0]
}

function Get-Config {
    param([string]$Path)
    $default = [ordered]@{
        processes      = @('Hearthstone')
        mode           = 'Mute'
        duckVolume     = 0.1
        intervalMs     = 400
        includeOverlay = @()
        logMaxKB       = 1024
    }
    if (-not (Test-Path $Path)) { return $default }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "配置解析失败，使用默认值：$($_.Exception.Message)"
        return $default
    }

    $cfg = [ordered]@{
        processes      = @()
        mode           = "$($default.mode)"
        duckVolume     = [double]$default.duckVolume
        intervalMs     = [int]$default.intervalMs
        includeOverlay = @()
        logMaxKB       = [int]$default.logMaxKB
    }
    if ($obj.PSObject.Properties.Name -contains 'processes') {
        $cfg.processes = @($obj.processes | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
    if (-not $cfg.processes -or $cfg.processes.Count -eq 0) { $cfg.processes = @($default.processes) }
    if ($obj.PSObject.Properties.Name -contains 'mode') { $cfg.mode = [string]$obj.mode }
    if ($cfg.mode -notin @('Mute', 'Duck')) { $cfg.mode = 'Mute' }
    if ($obj.PSObject.Properties.Name -contains 'duckVolume') { $cfg.duckVolume = [double]$obj.duckVolume }
    if ($obj.PSObject.Properties.Name -contains 'intervalMs') { $cfg.intervalMs = [int]$obj.intervalMs }
    if ($obj.PSObject.Properties.Name -contains 'logMaxKB') { $cfg.logMaxKB = [int]$obj.logMaxKB }
    if ($obj.PSObject.Properties.Name -contains 'includeOverlay') {
        $cfg.includeOverlay = @($obj.includeOverlay | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
    if ($cfg.intervalMs -lt 100) { $cfg.intervalMs = 100 }
    return $cfg
}

$ConfigFile = Resolve-ConfigPath -Explicit $ConfigPath
$Cfg = Get-Config -Path $ConfigFile

# 命令行覆盖配置
$Targets = if ($ProcessName) { @($ProcessName) } else { @($Cfg.processes) }
$EffectiveMode = if ($Mode) { $Mode } else { $Cfg.mode }
$EffectiveDuck = if ($DuckVolume -ge 0) { $DuckVolume } else { $Cfg.duckVolume }
$EffectiveInterval = if ($Interval -gt 0) { $Interval } else { $Cfg.intervalMs }
$OverlayList = @($Cfg.includeOverlay)
$UseOverlay = [bool]$IncludeOverlay -or ($OverlayList.Count -gt 0)

$LogDir = Join-Path $ScriptDir 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'focus-mute.log'
$LogMaxBytes = [math]::Max(64, $Cfg.logMaxKB) * 1024

# ---------------------------------------------------------------- 日志
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $LogMaxBytes) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
    catch { }
    Write-Host $line
}

# ---------------------------------------------------------------- Win32 / WASAPI（内联编译，无需外部 DLL）
$csharp = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace FocusMute.Interop
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject { }

    internal enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    internal enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(EDataFlow dataFlow, int dwStateMask, out IntPtr ppDevices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppEndpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
        int RegisterEndpointNotificationCallback(IntPtr pClient);
        int UnregisterEndpointNotificationCallback(IntPtr pClient);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams,
                     [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        int GetState(out int pdwState);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionManager2
    {
        int GetAudioSessionControl(IntPtr audioSessionGuid, int streamFlags, out IAudioSessionControl sessionControl);
        int GetSimpleAudioVolume(IntPtr audioSessionGuid, int streamFlags, out ISimpleAudioVolume audioVolume);
        int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
        int RegisterSessionNotification(IntPtr sessionNotification);
        int UnregisterSessionNotification(IntPtr sessionNotification);
        int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)] string sessionID, IntPtr duckNotification);
        int UnregisterDuckNotification(IntPtr duckNotification);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionEnumerator
    {
        int GetCount(out int sessionCount);
        int GetSession(int sessionCount, out IAudioSessionControl session);
    }

    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl
    {
        int GetState(out int pRetVal);
        int GetDisplayName(out IntPtr pRetVal);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string value, IntPtr eventContext);
        int GetIconPath(out IntPtr pRetVal);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string value, IntPtr eventContext);
        int GetGroupingParam(out Guid pRetVal);
        int SetGroupingParam(ref Guid overRide, IntPtr eventContext);
        int RegisterAudioSessionNotification(IntPtr newNotifications);
        int UnregisterAudioSessionNotification(IntPtr newNotifications);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl2
    {
        int GetState(out int pRetVal);
        int GetDisplayName(out IntPtr pRetVal);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string value, IntPtr eventContext);
        int GetIconPath(out IntPtr pRetVal);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string value, IntPtr eventContext);
        int GetGroupingParam(out Guid pRetVal);
        int SetGroupingParam(ref Guid overRide, IntPtr eventContext);
        int RegisterAudioSessionNotification(IntPtr newNotifications);
        int UnregisterAudioSessionNotification(IntPtr newNotifications);
        int GetSessionIdentifier(out IntPtr pRetVal);
        int GetSessionInstanceIdentifier(out IntPtr pRetVal);
        int GetProcessId(out uint pRetVal);
        int IsSystemSoundsSession();
        int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
    }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ISimpleAudioVolume
    {
        int SetMasterVolume(float fLevel, ref Guid eventContext);
        int GetMasterVolume(out float pfLevel);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid eventContext);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
    }

    public class AudioSession
    {
        internal ISimpleAudioVolume Vol;
        public uint Pid;
        public string ProcessName = "?";
        public string Id = "";

        public bool Muted
        {
            get { bool m; Marshal.ThrowExceptionForHR(Vol.GetMute(out m)); return m; }
            set { Guid g = Guid.Empty; Marshal.ThrowExceptionForHR(Vol.SetMute(value, ref g)); }
        }

        public float Volume
        {
            get { float v; Marshal.ThrowExceptionForHR(Vol.GetMasterVolume(out v)); return v; }
            set { Guid g = Guid.Empty; Marshal.ThrowExceptionForHR(Vol.SetMasterVolume(value, ref g)); }
        }
    }

    public static class AudioSessions
    {
        const int CLSCTX_ALL = 23;
        static IMMDeviceEnumerator _enumerator;

        static IAudioSessionEnumerator GetSessionEnumerator()
        {
            if (_enumerator == null)
                _enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());

            IMMDevice dev;
            Marshal.ThrowExceptionForHR(_enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out dev));
            Guid iid = typeof(IAudioSessionManager2).GUID;
            object o;
            Marshal.ThrowExceptionForHR(dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o));
            var mgr = (IAudioSessionManager2)o;
            IAudioSessionEnumerator se;
            Marshal.ThrowExceptionForHR(mgr.GetSessionEnumerator(out se));
            return se;
        }

        /// <summary>枚举默认播放设备上的全部音频会话；pids 为 null 时返回所有</summary>
        public static AudioSession[] All(uint[] pids)
        {
            HashSet<uint> want = (pids == null) ? null : new HashSet<uint>(pids);
            var list = new List<AudioSession>();
            var se = GetSessionEnumerator();
            int n;
            if (se.GetCount(out n) != 0) return list.ToArray();

            for (int i = 0; i < n; i++)
            {
                IAudioSessionControl ctl;
                if (se.GetSession(i, out ctl) != 0) continue;
                var c2 = ctl as IAudioSessionControl2;
                if (c2 == null) continue;

                uint pid;
                try { if (c2.GetProcessId(out pid) != 0) continue; }
                catch { continue; }
                if (pid == 0) continue;
                if (want != null && !want.Contains(pid)) continue;

                var s = new AudioSession();
                s.Pid = pid;
                s.Vol = (ISimpleAudioVolume)ctl;

                IntPtr p;
                try
                {
                    if (c2.GetSessionInstanceIdentifier(out p) == 0 && p != IntPtr.Zero)
                    {
                        s.Id = Marshal.PtrToStringUni(p);
                        Marshal.FreeCoTaskMem(p);
                    }
                }
                catch { }
                try { s.ProcessName = Process.GetProcessById((int)pid).ProcessName; }
                catch { s.ProcessName = "?"; }

                list.Add(s);
            }
            return list.ToArray();
        }
    }

    public static class Foreground
    {
        [DllImport("user32.dll")]
        static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        static extern bool IsIconic(IntPtr hWnd);

        public static uint Pid()
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return 0;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return pid;
        }

        public static bool Minimized()
        {
            IntPtr h = GetForegroundWindow();
            return h != IntPtr.Zero && IsIconic(h);
        }
    }
}
'@

if (-not ('FocusMute.Interop.AudioSessions' -as [type])) {
    Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
}

# ---------------------------------------------------------------- 目标与判定
function Get-TargetProcesses {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $Targets -contains $_.ProcessName }
}

function Get-TargetSessions {
    param([uint32[]]$Pids)
    if (-not $Pids -or $Pids.Count -eq 0) { return @() }
    try { [FocusMute.Interop.AudioSessions]::All($Pids) } catch { @() }
}

function Get-ProcessNameById {
    param([uint32]$TargetPid)
    if (-not $TargetPid) { return '<none>' }
    try { (Get-Process -Id $TargetPid -ErrorAction Stop).ProcessName } catch { "pid:$TargetPid" }
}

function Test-IsActive {
    param([uint32[]]$GamePids, [uint32]$FgPid)
    if (-not $FgPid) { return $false }
    if ($GamePids -contains $FgPid) { return $true }
    if ($UseOverlay) {
        if ($OverlayList -contains (Get-ProcessNameById -TargetPid $FgPid)) { return $true }
    }
    return $false
}

function Get-ForegroundPid {
    if ($SimulateForegroundPid) { return $SimulateForegroundPid }
    [FocusMute.Interop.Foreground]::Pid()
}

function Get-DaemonProcesses {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -like '*-WindowStyle Hidden*' -and
            $_.CommandLine -like '*FocusMute.ps1*' -and
            $_.CommandLine -notlike '* -Action *' -and
            $_.ProcessId -ne $PID
        }
}

function Restore-AllMute {
    foreach ($p in (Get-TargetProcesses)) {
        foreach ($s in (Get-TargetSessions -Pids ([uint32[]]@([uint32]$p.Id)))) {
            try { if ($s.Muted) { $s.Muted = $false } } catch { }
        }
    }
}

# ---------------------------------------------------------------- 主循环
function Invoke-WatchLoop {
    param([switch]$SingleShot)

    $mutex = $null
    if (-not $SingleShot) {
        try {
            $mutex = [System.Threading.Mutex]::OpenExisting($MutexName)
            Write-Log '已有看护实例在运行，本次退出' 'WARN'
            return
        }
        catch [System.Threading.WaitHandleCannotBeOpenedException] {
            $mutex = New-Object System.Threading.Mutex($false, $MutexName)
        }
        catch {
            try { $mutex = New-Object System.Threading.Mutex($false, $MutexName) } catch { $mutex = $null }
        }
    }

    $baseVolume = @{}
    $appliedMute = $false
    $lastKey = $null
    $missingLogged = $false
    $started = Get-Date

    Write-Log ("看护启动 v{0}：目标={1} 模式={2} 轮询={3}ms 覆盖层=[{4}] 配置={5} pid={6}" -f `
            $ScriptVersion, ($Targets -join ','), $EffectiveMode, $EffectiveInterval, ($OverlayList -join ','), $ConfigFile, $PID)

    try {
        while ($true) {
            $procs = Get-TargetProcesses
            if (-not $procs) {
                if (-not $missingLogged) {
                    Write-Log ("未发现目标进程（{0}），待机中" -f ($Targets -join ','))
                    $missingLogged = $true
                }
                if ($SingleShot) { return }
                Start-Sleep -Milliseconds 2000
                continue
            }
            $missingLogged = $false
            $pids = [uint32[]]@($procs | ForEach-Object { [uint32]$_.Id })

            $sessions = Get-TargetSessions -Pids $pids
            if (-not $sessions -or $sessions.Count -eq 0) {
                if ($SingleShot) { return }
                Start-Sleep -Milliseconds 800
                continue
            }

            $fgPid = Get-ForegroundPid
            $active = Test-IsActive -GamePids $pids -FgPid $fgPid
            $targetMute = -not $active

            foreach ($s in $sessions) {
                try {
                    if ($EffectiveMode -eq 'Mute') {
                        if ($s.Muted -ne $targetMute) {
                            $s.Muted = $targetMute
                            $appliedMute = $targetMute
                            Write-Log ("[Mute] {0}(pid={1}) 静音={2} 前台={3}" -f `
                                    $s.ProcessName, $s.Pid, $targetMute, (Get-ProcessNameById -TargetPid $fgPid))
                        }
                    }
                    else {
                        if ($targetMute) {
                            if (-not $baseVolume.ContainsKey($s.Id) -and $s.Volume -gt $EffectiveDuck) {
                                $baseVolume[$s.Id] = $s.Volume
                            }
                            if (-not $s.Muted) { $s.Muted = $true }
                            if ([math]::Abs($s.Volume - $EffectiveDuck) -gt 0.005) { $s.Volume = [single]$EffectiveDuck }
                            $appliedMute = $true
                        }
                        else {
                            $restore = if ($baseVolume.ContainsKey($s.Id)) { $baseVolume[$s.Id] } else { 1.0 }
                            if ($s.Muted) { $s.Muted = $false }
                            if ([math]::Abs($s.Volume - $restore) -gt 0.005) { $s.Volume = [single]$restore }
                            $appliedMute = $false
                        }
                    }
                }
                catch {
                    Write-Log ("会话操作失败（会话可能已销毁）：{0}" -f $_.Exception.Message) 'WARN'
                }
            }

            $key = "$active|$($sessions.Count)|$($pids -join ',')"
            if ($key -ne $lastKey) {
                Write-Log ("状态：前台={0} 活跃={1} 应静音={2} 会话={3}" -f `
                        (Get-ProcessNameById -TargetPid $fgPid), $active, $targetMute, $sessions.Count)
                $lastKey = $key
            }

            if ($SingleShot) { return }
            Start-Sleep -Milliseconds $EffectiveInterval
        }
    }
    finally {
        Restore-AllMute
        if ($appliedMute) { Write-Log '退出时已复原静音' }
        Write-Log ("看护退出，运行 {0:hh\:mm\:ss}" -f ((Get-Date) - $started))
        if ($mutex) { $mutex.Dispose() }
    }
}

# ---------------------------------------------------------------- Status
function Invoke-Status {
    Write-Host ('=== FocusMute v{0} 体检 ===' -f $ScriptVersion) -ForegroundColor Cyan
    Write-Host ("脚本     : {0}" -f $PSCommandPath)
    Write-Host ("配置     : {0}" -f $ConfigFile)
    Write-Host ("目标进程 : {0}" -f ($Targets -join ', '))
    Write-Host ("模式     : {0}（Duck 音量={1:P0}，轮询={2}ms）" -f $EffectiveMode, $EffectiveDuck, $EffectiveInterval)
    if ($OverlayList.Count -gt 0) { Write-Host ("覆盖层   : {0}" -f ($OverlayList -join ', ')) }
    Write-Host ''

    $procs = Get-TargetProcesses
    if ($procs) {
        foreach ($p in $procs) {
            Write-Host ("进程     : {0} pid={1} 标题='{2}' 响应={3}" -f $p.ProcessName, $p.Id, $p.MainWindowTitle, $p.Responding)
        }
    }
    else {
        Write-Host '进程     : 目标进程未运行' -ForegroundColor Yellow
    }

    $sessions = Get-TargetSessions -Pids ([uint32[]]@($procs | ForEach-Object { [uint32]$_.Id }))
    if ($sessions -and $sessions.Count -gt 0) {
        Write-Host ("音频会话 : {0} 个" -f $sessions.Count)
        foreach ($s in $sessions) {
            $short = ($s.Id -replace '^.*\|', '')
            Write-Host ("           - {0}(pid={1}) 静音={2} 音量={3:P0} id={4}" -f $s.ProcessName, $s.Pid, $s.Muted, $s.Volume, $short)
        }
    }
    else {
        Write-Host '音频会话 : 无（目标没在出声，或还没创建会话）' -ForegroundColor Yellow
    }

    $fgPid = Get-ForegroundPid
    $active = Test-IsActive -GamePids ([uint32[]]@($procs | ForEach-Object { [uint32]$_.Id })) -FgPid $fgPid
    Write-Host ''
    Write-Host ("当前前台 : {0} (pid={1})" -f (Get-ProcessNameById -TargetPid $fgPid), $fgPid)
    Write-Host ("判定     : {0}" -f $(if ($active) { '目标活跃 → 保持有声' } else { '目标失焦 → 静音' }))

    $daemon = @(Get-DaemonProcesses)
    Write-Host ''
    if ($daemon.Count -gt 0) {
        Write-Host ("看护     : 运行中 pid={0}" -f (($daemon | ForEach-Object { $_.ProcessId }) -join ',')) -ForegroundColor Green
    }
    else {
        Write-Host '看护     : 未运行' -ForegroundColor Yellow
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { Write-Host ("自启任务 : 已注册（{0}）" -f $task.State) -ForegroundColor Green }
    else { Write-Host '自启任务 : 未注册' -ForegroundColor Yellow }

    if (Test-Path $LogFile) {
        Write-Host ''
        Write-Host '最近 8 行日志：' -ForegroundColor Cyan
        Get-Content $LogFile -Tail 8 | ForEach-Object { Write-Host "  $_" }
    }
}

# ---------------------------------------------------------------- List
function Invoke-List {
    Write-Host '=== 当前带音频会话的进程（把要静音的进程名填进 focus-mute.json 的 processes） ===' -ForegroundColor Cyan
    $all = @()
    try { $all = [FocusMute.Interop.AudioSessions]::All($null) } catch { $all = @() }
    if (-not $all -or $all.Count -eq 0) { Write-Host '（没有检测到任何会话）' -ForegroundColor Yellow; return }

    $all | Sort-Object ProcessName | ForEach-Object {
        $mark = if ($Targets -contains $_.ProcessName) { '*' } else { ' ' }
        Write-Host ("{0} {1,-28} pid={2,-7} 静音={3,-5} 音量={4:P0}" -f $mark, $_.ProcessName, $_.Pid, $_.Muted, $_.Volume)
    }
    Write-Host ''
    Write-Host "（* = 当前配置里已包含）"
}

# ---------------------------------------------------------------- 各动作
switch ($Action) {

    'Version' { Write-Host "FocusMute v$ScriptVersion" }

    'Status' { Invoke-Status }

    'List' { Invoke-List }

    'Test' {
        $procs = Get-TargetProcesses
        if (-not $procs) { Write-Log '目标进程未运行，测不了' 'WARN'; break }
        $sessions = Get-TargetSessions -Pids ([uint32[]]@($procs | ForEach-Object { [uint32]$_.Id }))
        if (-not $sessions -or $sessions.Count -eq 0) { Write-Log '目标没有音频会话（没在出声）' 'WARN'; break }
        Write-Log '测试：静音 1.5 秒'
        foreach ($s in $sessions) { try { $s.Muted = $true } catch { } }
        Start-Sleep -Milliseconds 1500
        foreach ($s in $sessions) { try { $s.Muted = $false } catch { } }
        Start-Sleep -Milliseconds 200
        $left = @($sessions | Where-Object { try { $_.Muted } catch { $false } })
        Write-Log ("测试完成，已复原（仍静音的会话数={0}）" -f $left.Count)
    }

    'Run' { Invoke-WatchLoop -SingleShot:$Once }

    'Start' {
        $running = @(Get-DaemonProcesses)
        if ($running.Count -gt 0) {
            Write-Log ("看护已在运行 pid={0}" -f (($running | ForEach-Object { $_.ProcessId }) -join ',')) 'WARN'
            break
        }
        $vbs = Join-Path $ScriptDir 'FocusMute.vbs'
        if (-not (Test-Path $vbs)) { throw "缺少隐藏启动器：$vbs" }
        Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`"" -WindowStyle Hidden
        Start-Sleep -Milliseconds 1200
        $now = @(Get-DaemonProcesses)
        if ($now.Count -gt 0) { Write-Log ("看护已后台启动 pid={0}" -f (($now | ForEach-Object { $_.ProcessId }) -join ',')) }
        else { Write-Log '启动后未检测到看护进程，请检查日志' 'WARN' }
    }

    'Stop' {
        $daemon = @(Get-DaemonProcesses)
        foreach ($d in $daemon) {
            try { Stop-Process -Id $d.ProcessId -Force -ErrorAction Stop; Write-Log ("已结束看护 pid={0}" -f $d.ProcessId) }
            catch { Write-Log ("结束失败 pid={0}: {1}" -f $d.ProcessId, $_.Exception.Message) 'WARN' }
        }
        if ($daemon.Count -eq 0) { Write-Log '看护本来就没在跑' }
        Start-Sleep -Milliseconds 300
        foreach ($p in (Get-TargetProcesses)) {
            foreach ($s in (Get-TargetSessions -Pids ([uint32[]]@([uint32]$p.Id)))) {
                try { if ($s.Muted) { $s.Muted = $false; Write-Log '已解除静音' } } catch { }
            }
        }
    }

    'Restart' {
        & $PSCommandPath -Action Stop
        Start-Sleep -Milliseconds 400
        & $PSCommandPath -Action Start
    }

    'Install' {
        $vbsSrc = Join-Path $ScriptDir 'FocusMute.vbs'
        if (-not (Test-Path $vbsSrc)) { throw "缺少隐藏启动器：$vbsSrc" }
        if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

        $psSrc = $PSCommandPath
        $psDst = Join-Path $InstallDir 'FocusMute.ps1'
        $vbsDst = Join-Path $InstallDir 'FocusMute.vbs'
        $cfgDst = Join-Path $InstallDir 'focus-mute.json'

        # 装的是「正在运行的这份」，除非已经在安装目录里
        if ([System.IO.Path]::GetFullPath($psSrc) -ne [System.IO.Path]::GetFullPath($psDst)) {
            Copy-Item $psSrc $psDst -Force
        }
        Copy-Item $vbsSrc $vbsDst -Force
        if ($ForceConfig -or -not (Test-Path $cfgDst)) {
            if (Test-Path $ConfigFile) { Copy-Item $ConfigFile $cfgDst -Force }
            Write-Log ('配置已写入：{0}' -f $cfgDst)
        }

        $taskAction = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsDst`"" -WorkingDirectory $InstallDir
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Settings $settings `
            -Principal $principal -Description 'FocusMute: 目标程序失焦自动静音（WASAPI 会话级，不改任何程序文件）' -Force | Out-Null

        Write-Log ("已安装到 {0}" -f $InstallDir)
        Write-Log ("已注册登录自启任务：{0}" -f $TaskName)
        & $psDst -Action Start
    }

    'Uninstall' {
        & $PSCommandPath -Action Stop
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Log ("已删除自启任务：{0}" -f $TaskName)
        }
        else { Write-Log '自启任务本来就不存在' }

        if ($Purge) {
            $selfInInstallDir = $PSCommandPath -like "$InstallDir*"
            $targetsToRemove = @($InstallDir)
            foreach ($t in $targetsToRemove) {
                if (Test-Path $t) {
                    if ($selfInInstallDir) { Write-Log '当前脚本就在安装目录里，跳过删除（删之前先把脚本拷出来再跑 -Purge）' 'WARN' }
                    else { Remove-Item $t -Recurse -Force; Write-Log ("已删除安装目录 {0}" -f $t) }
                }
            }
        }
    }
}
