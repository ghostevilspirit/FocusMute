# FocusMute

程序切到后台，就把它的声音关掉；切回前台，自己恢复。

当前版本 **1.1.0**。两个安装包，按需选一个：

| 版本 | 下载文件 | 适合谁 |
|---|---|---|
| 通用版 | `FocusMute-v1.1.0.zip` | 任何程序：给进程名，它就盯那个程序 |
| 炉石版 | `FocusMute-Hearthstone-v1.1.0.zip` | 只玩炉石传说，下载解压就能用，不用改配置 |

下载页：<https://github.com/ghostevilspirit/FocusMute/releases/latest>

从源码用的话：根目录是通用版；`hearthstone/` 里放的是炉石版的两个差异文件（预填配置 + 效果说明），复制到安装目录就能变成炉石版。

---

## 为什么需要它

炉石传说（魔兽、Dota 也一样）的设置里没有「窗口不活跃时静音」。`options.txt` 里跟声音有关的只有四个键：`music`、`musicvolume`、`sound`、`soundvolume`。Windows 也没有「按窗口焦点自动静音」的开关。

所以这个工具换了个思路：不动游戏，改用 Windows 自带的音频接口，盯住游戏的「音频会话」——就是音量合成器里那一路单独的音量条。前台窗口不是它，就点静音；切回去，取消静音。

这样做的结果：

- 游戏文件一个字节都不改。战网更新、扫描修复都覆盖不到它。
- 游戏内的音量设置原样保留。
- 别的程序、别的游戏、麦克风、系统声音都不受影响。

---

## 安装（三步）

1. 解压 zip 到任意目录。
2. 双击 `install.cmd`。它会装到 `%LOCALAPPDATA%\FocusMute`，加一个登录自启的计划任务（名字 FocusMute），然后立刻开始工作。不需要管理员权限。
3. 通用版：打开 `config.cmd`，把 `processes` 改成你要盯的程序名，保存后双击 `restart.cmd`。炉石版跳过这一步。

装完解压出来的文件夹可以删，程序已经复制到 `%LOCALAPPDATA%\FocusMute` 了。

不确定进程名？双击 `list.cmd`，它会列出当前所有正在出声的程序，`*` 是配置里已经有的。

---

## 配置文件

路径：`%LOCALAPPDATA%\FocusMute\focus-mute.json`（双击 `config.cmd` 直接打开）

```json
{
  "processes": ["Hearthstone"],
  "mode": "Mute",
  "duckVolume": 0.1,
  "intervalMs": 400,
  "includeOverlay": [],
  "logMaxKB": 1024
}
```

| 键 | 怎么填 | 作用 |
|---|---|---|
| `processes` | 程序名数组，**不带 .exe** | 要盯哪些程序。写多个：`["Hearthstone","Wow","Dota2"]`，任意一个在前台就都出声 |
| `mode` | `Mute` 或 `Duck` | `Mute` 直接静音；`Duck` 只把音量压小 |
| `duckVolume` | 0 到 1 | `Duck` 模式压到多少，`0.1` 就是 10% |
| `intervalMs` | 100 以上 | 多久检查一次前台窗口，默认 400 毫秒。越小反应越快，CPU 略高 |
| `includeOverlay` | 程序名数组 | 这些程序在前台时，仍然算目标程序「活着」。记牌器用户可以填 `["Overwolf","OverwolfBrowser","OverwolfHelper"]` |
| `logMaxKB` | 整数 | 日志上限，超了自动切成 `focus-mute.log.old` |

改完记得双击 `restart.cmd`。

---

## 命令

在安装目录（或解压目录）里跑，执行策略会用 Bypass，不用改系统设置：

| 命令 | 做什么 |
|---|---|
| `install.cmd` | 安装到 `%LOCALAPPDATA%\FocusMute`，加自启，马上启动 |
| `uninstall.cmd` | 停止、删自启任务，文件和日志留着 |
| `uninstall.cmd full` | 连安装目录一起删 |
| `status.cmd` | 体检：目标进程、音频会话、当前判定、看护是否在跑、任务状态、最近日志 |
| `list.cmd` | 列出所有正在出声的程序名 |
| `test.cmd` | 立刻静音 1.5 秒再恢复，确认能控住声音 |
| `config.cmd` | 用记事本打开配置文件 |
| `restart.cmd` | 改完配置后重启看护 |

上面这些 cmd 跑完会停住等你看输出，按任意键关闭。

等价的手写命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\FocusMute.ps1 -Action Status
powershell -NoProfile -ExecutionPolicy Bypass -File .\FocusMute.ps1 -Action Run -ProcessName Hearthstone,Wow -Mode Duck -DuckVolume 0.15
powershell -NoProfile -ExecutionPolicy Bypass -File .\FocusMute.ps1 -Action Install -ForceConfig   # 用包里的配置覆盖已装配置
```

---

## 怎么确认它在工作

1. 双击 `test.cmd`：听到一次 1.5 秒的静音，说明通道是通的。
2. 让目标程序出声，Alt+Tab 切走：声音应该立刻没了。切回来：声音回来。
3. 双击 `status.cmd`：看「判定」那一行写的是不是你想要的结果。

日志在 `%LOCALAPPDATA%\FocusMute\logs\focus-mute.log`，每次状态变化写一行。

---

## 限制（实话）

- 只管**默认播放设备**上的声音。换默认设备后它会重新找，不用重启。
- 独占全屏下 Alt+Tab 通常能正常触发。极少数全屏优化组合里，系统仍把游戏当成前台窗口，这时不会静音——改用 `Duck` 模式，或者把 `includeOverlay` 填上。
- 常驻一个隐藏的 powershell 进程，实测 80–90 MB 内存，CPU 基本为 0。
- 被强杀（任务管理器结束进程）会跳过清理。下次启动或执行 `uninstall.cmd` 都会顺手解除静音。
- 脚本里用 `Add-Type` 现场编译一小段 C# 调 Windows 音频接口，个别杀毒软件会提示。代码全在 `FocusMute.ps1` 里，可以直接看。
- 不做注入、不挂钩子、不读游戏内存。

---

## 卸载

```powershell
uninstall.cmd          # 停看护 + 删自启任务
uninstall.cmd full     # 再把 %LOCALAPPDATA%\FocusMute 删掉
```

目标程序从来没被改过，卸载后和装之前一样。

---

## 常见问题

**切出去了但没静音？**
先跑 `status.cmd` 看「当前前台」是不是你以为的那个程序。有些全屏游戏切出去后系统仍认为它在前面；也有可能是你切到的是同一进程的另一个窗口。

**能同时盯好几个游戏吗？**
能，`processes` 写多个。规则是：任意一个在前台，就都出声；都切走了，就都静音。

**想让它在失焦时只压低声音、不完全静音？**
`mode` 改 `Duck`，`duckVolume` 填 `0.1`（10%）。会先静音再降音量，避免切走瞬间的爆音。

**会不会影响语音通话、音乐播放器？**
不会。脚本只碰 `processes` 里列出的程序。

**开机自启会不会弹黑框？**
不会。用 `wscript.exe` 拉起，窗口隐藏。

---

## English

**FocusMute** mutes a program's audio session while it is not the foreground window, and unmutes it when you switch back. Pure Windows PowerShell 5.1 — no runtime, no injection, no game files touched. It talks to the Windows audio session (the same mute button you see in the Volume Mixer).

- Generic edition: fill in process names yourself.
- Hearthstone edition: pre-configured, install and play.

```powershell
install.cmd                 # install to %LOCALAPPDATA%\FocusMute + logon task
list.cmd                    # show processes that currently have audio
restart.cmd                 # apply config changes
uninstall.cmd full          # remove everything
```

Config keys: `processes`, `mode` (`Mute`|`Duck`), `duckVolume`, `intervalMs`, `includeOverlay`, `logMaxKB`.

---

## License

MIT，见 [LICENSE](LICENSE)。
