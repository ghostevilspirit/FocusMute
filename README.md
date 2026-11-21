# FocusMute

**Windows 失焦自动静音** —— 目标程序在前台才出声，切走立刻静音，切回自动恢复。

纯 Windows PowerShell 5.1 实现，**不需要装 .NET 运行时/NAudio/AutoHotkey/Node**，**不改目标程序任何文件**，不注入进程、不加钩子。

```powershell
# 30 秒上手
install.cmd            # 装到 %LOCALAPPDATA%\FocusMute + 注册登录自启 + 立即生效
```

适用场景：炉石传说 / 魔兽 / Dota / 任何「后台吵人」的游戏与程序——它没有「窗口不活跃时静音」这个选项，Windows 本身也没有按焦点自动静音的开关。

---

## 一、它到底做了什么

| 做法 | 是否采用 | 说明 |
|---|---|---|
| 改游戏配置文件 | ❌ | 游戏更新会覆盖；很多游戏根本没有这个键 |
| 改注册表音量项 | ❌ | 全局生效，影响别的程序 |
| 注入 DLL / 挂钩子 | ❌ | 会被反作弊盯上，也是崩溃源 |
| **WASAPI 会话级静音** | ✅ | 等价于「音量合成器」里对单个程序点静音按钮 |

判定链：

```
GetForegroundWindow → 前台窗口所属进程
   ├─ 在 processes 列表里        → 有声（解除静音）
   ├─ 在 includeOverlay 列表里   → 也算有声（记牌器/悬浮窗场景）
   └─ 都不是                     → 静音该程序的所有音频会话
```

会话级操作（`ISimpleAudioVolume::SetMute`）与游戏内音量设置完全独立：游戏里 `soundvolume` 不动，其它程序、其它游戏的音量也不动。

---

## 二、和 GitHub 上同类项目的关系

已有项目各有取舍，FocusMute 补的是「**零依赖 + 免安装包 + 白名单 JSON + 计划任务自启 + 压音量模式**」这一格：

| 项目 | 语言/形态 | 差异 |
|---|---|---|
| [TomiBelan/mute-on-focus-lost](https://github.com/TomiBelan/mute-on-focus-lost) | AutoHotkey 脚本 | 需要 AutoHotkey；热键逐个启用，不是自启常驻 |
| [nefares/Background-Muter](https://github.com/nefares/Background-Muter) | C# 托盘 | 默认静音**所有**后台程序，要手工加例外；白名单是反的 |
| [acai10/AutoMuteApp](https://github.com/acai10/AutoMuteApp) | C | 按音频设备（麦克风/耳机）静音，解决回声，不是按进程焦点 |
| [ilsd7/UnfocusMute](https://github.com/ilsd7/UnfocusMute) | Rust 托盘 | 体验好，但要下载编译产物，改配置得会 Rust |
| [Lenalein2001/SilentFocus-py](https://github.com/Lenalein2001/SilentFocus-py) | C#/WPF + NAudio | 需 .NET 8 + NAudio，仓库名与实现语言不一致 |
| [YetSen-26/AutoMute](https://github.com/YetSen-26/AutoMute) | C++ 托盘 | 需编译产物；无 Duck 模式 |
| **FocusMute（本仓库）** | **PowerShell 5.1，无依赖** | JSON 白名单、多目标、Duck 压音量、覆盖层例外、计划任务自启、`-Action List` 找进程名、单实例互斥 |

如果你只想要托盘图标，去用 UnfocusMute；如果你想要「一条命令装好、改 JSON 就换游戏、坏了能一行回滚」，用这个。

---

## 三、安装

### 方式 A：安装包（推荐）

1. 下载 Release 里的 `FocusMute-v1.0.0.zip`，解压到任意目录（解压后可以删，安装会复制到 `%LOCALAPPDATA%\FocusMute`）
2. 双击 `install.cmd`

它会做三件事：

- 复制 `FocusMute.ps1` / `FocusMute.vbs` / `focus-mute.json` 到 `%LOCALAPPDATA%\FocusMute`
- 注册计划任务 `FocusMute`（当前用户、登录时触发、隐藏窗口、无时间上限、不允许并发）
- 立刻启动看护

不需要管理员权限。

### 方式 B：命令行直装

```powershell
git clone https://github.com/<owner>/FocusMute.git
cd FocusMute
powershell -NoProfile -ExecutionPolicy Bypass -File .\FocusMute.ps1 -Action Install
```

### 方式 C：便携，不装自启

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\FocusMute.ps1 -Action Run
# Ctrl+C 退出时自动复原静音
```

---

## 四、配置 `focus-mute.json`

安装后在 `%LOCALAPPDATA%\FocusMute\focus-mute.json`，改完跑 `restart.cmd`（或 `FocusMute.ps1 -Action Restart`）。

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

| 键 | 类型 | 说明 |
|---|---|---|
| `processes` | 字符串数组 | 目标进程名（**不带 `.exe`**，大小写不敏感）。可以写多个：`["Hearthstone","Wow","Dota2"]`，任意一个在前台就都出声 |
| `mode` | `"Mute"` / `"Duck"` | `Mute` 全静音；`Duck` 只把音量压到 `duckVolume`，留一点环境声 |
| `duckVolume` | 0–1 | Duck 模式目标音量，`0.1` = 10% |
| `intervalMs` | 整数 ≥100 | 轮询间隔，越小切换越跟手、CPU 略高；`400` 是实测平衡点 |
| `includeOverlay` | 字符串数组 | 这些进程在前台时，**依然算目标有声**。例：记牌器 `["Overwolf","Firestone"]` |
| `logMaxKB` | 整数 | 日志上限，超了轮转为 `focus-mute.log.old` |

### 怎么找进程名

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\FocusMute.ps1 -Action List
# 或双击 list.cmd：列出当前所有带音频会话的进程，`*` 表示配置里已包含
```

进程名 = `Get-Process` 的 `ProcessName`，也就是任务管理器「详细信息」里的映像名去掉 `.exe`。

---

## 五、命令

| 命令 | 作用 |
|---|---|
| `-Action Install` | 安装到 `%LOCALAPPDATA%\FocusMute` + 注册自启 + 启动 |
| `-Action Uninstall` | 停止看护 + 删除自启任务（保留文件和日志） |
| `-Action Uninstall -Purge` | 连安装目录一起删 |
| `-Action Status` | 体检：目标进程 / 音频会话 / 前景判定 / 看护状态 / 任务状态 / 最近日志 |
| `-Action List` | 列出所有带音频会话的进程名 |
| `-Action Test` | 静音 1.5 秒再复原，验证 WASAPI 通路 |
| `-Action Start` / `Stop` / `Restart` | 后台启停（`Start` 走 `wscript`，无黑框） |
| `-Action Run` | 前台常驻，`Ctrl+C` 退出并复原 |
| `-Action Version` | 版本号 |

常用参数覆盖 JSON（不改文件）：

```powershell
.\FocusMute.ps1 -Action Run -ProcessName Hearthstone,Wow -Mode Duck -DuckVolume 0.15
.\FocusMute.ps1 -Action Run -IncludeOverlay            # 加载 JSON 里的 includeOverlay
.\FocusMute.ps1 -Action Status -ConfigPath D:\my.json   # 指定配置
.\FocusMute.ps1 -Action Run -Once                      # 只跑一轮（脚本化/排查用）
```

调试用（不碰系统真实前台，验证失焦分支）：

```powershell
.\FocusMute.ps1 -Action Run -Once -SimulateForegroundPid 4
```

---

## 六、验证方法

```powershell
# 1) 通路
test.cmd                       # 听到一次 1.5 秒静音 = 通路正常

# 2) 真实切换
# 目标程序里放声音 → Alt+Tab 切走 → 应该瞬间静音
# 切回 → 自动恢复

# 3) 判定与状态
status.cmd                     # 看"判定：目标失焦 → 静音"
```

日志：`%LOCALAPPDATA%\FocusMute\logs\focus-mute.log`，每次状态变化一行。

---

## 七、限制与已知情况

- **只操作默认播放设备**上的会话；切换默认设备后自动重新枚举，不必重启看护。
- **独占全屏**：正常 Alt+Tab 会失去前台，能触发；极少数全屏优化组合下系统仍把游戏算作前台，此时不会静音（用 Duck 模式或 `includeOverlay` 反而更稳）。
- **常驻开销**：一个隐藏的 `powershell.exe`，实测 80–90 MB 内存，CPU 基本为 0（400 ms 空转）。
- **被强杀**：`Stop-Process -Force` 会跳过清理；下次 `Start`/`Stop` 都会兜底解除静音。
- **多用户同时登录**：计划任务是「当前用户 + 交互式」，各自登录各跑一份，互不干扰。
- **杀软误报**：脚本用 `Add-Type` 内联编译一段 C# 互操作代码（WASAPI），个别启发式引擎会提示；代码全在 `FocusMute.ps1` 里，可自行审阅。
- **反作弊**：不做任何注入/挂钩/读写游戏内存，只调 Windows 音频 API。

---

## 八、卸载

```powershell
uninstall.cmd          # 停看护 + 删自启任务，保留文件
uninstall.cmd full     # 再删 %LOCALAPPDATA%\FocusMute
```

目标程序从未被修改，卸载后与安装前完全一致。

---

## 九、English

**FocusMute** mutes a chosen Windows program's audio session whenever it is not the foreground window, and unmutes it when you switch back.

- Pure Windows PowerShell 5.1 — no runtime, no NAudio, no AutoHotkey, no injection.
- Uses WASAPI `ISimpleAudioVolume` (same as the per-app mute button in the Volume Mixer); the game's own volume settings are untouched.
- Only touches the processes you list; everything else keeps playing.
- Install as a hidden logon scheduled task; uninstall in one command.

```powershell
install.cmd                                     # install to %LOCALAPPDATA%\FocusMute + autostart
powershell -ExecutionPolicy Bypass -File .\FocusMute.ps1 -Action List      # find process names
# edit %LOCALAPPDATA%\FocusMute\focus-mute.json → "processes": ["Hearthstone"]
restart.cmd
uninstall.cmd full
```

Config keys: `processes`, `mode` (`Mute`|`Duck`), `duckVolume`, `intervalMs`, `includeOverlay`, `logMaxKB`.

## License

MIT — see [LICENSE](LICENSE).
