# AirPodMicBlocker

让蓝牙耳机（AirPods / Beats 等）**始终保持 A2DP 立体声高音质**，录音改走笔记本自带麦克风。

macOS 上一旦有程序打开蓝牙耳机的麦克风，蓝牙链路就会从 A2DP 切到 HFP，音质会断崖式下降 —— 音乐变得又小又闷。这个工具阻止这件事发生。

```
默认状态（被降级）                     使用本工具后
─────────────────────                  ─────────────────────
输出  AirPods  1 声道 16k  🔇 又小又闷   输出  AirPods  2 声道 48k  🎵 立体声
输入  AirPods  麦克风   🎤               输入  MacBook 麦克风
                                       链路  A2DP 全程保持
```

## 特性

- **菜单栏常驻**，图标直接显示当前状态（🟢 A2DP / 🔴 HFP）
- **默认输入看护**：每秒检查一次，系统默认输入一旦被切到蓝牙麦克风就立刻拉回
- **真实 HFP 检测**：解析 `bluetoothd` 的 `HFP handle`，而不是 CoreAudio 报告的设备格式（后者在切 HFP 时根本不变）
- **占用侦测**：实时列出到底哪个进程在录音，一眼看出是微信还是别的程序
- **App 内音量条**：直接控制 AirPods 的声道音量（见下方「已知限制」）
- 无需安装依赖，`./build.sh` 即可构建通用二进制

## 安装

```bash
git clone https://github.com/<你的用户名>/AirPodMicBlocker.git
cd AirPodMicBlocker
./build.sh
open ~/Applications/AirPodMicBlocker.app
```

`build.sh` 会把 App 装到 `~/Applications/`（不需要 `sudo`），并在 `~/bin/` 建一个命令行软链。

构建参数：

```bash
./build.sh --no-install   # 只在 build/ 产出，不动 ~/Applications
./build.sh --release      # 额外打一个 zip 到 dist/，用于分发
```

## 两种输出模式

菜单栏 →「输出模式」可以随时切换。

### 耳机直连（默认）

| 项目 | 值 |
|---|---|
| 默认输出 | AirPods（系统直接管理） |
| 默认输入 | 聚合设备 → 笔记本麦克风 |
| 系统音量键 F11/F12 | ✅ 正常 |
| 治微信等"自己挑设备"的程序 | ⚠️ 部分有效 |

### 聚合设备（音质优先）

| 项目 | 值 |
|---|---|
| 默认输出 | 聚合设备 → AirPods |
| 默认输入 | 聚合设备 → 笔记本麦克风 |
| 系统音量键 F11/F12 | ❌ 失效，用 App 内音量条 |
| 治微信等"自己挑设备"的程序 | ✅ 更有效 |

聚合设备把「耳机的 `:output`」和「笔记本内置麦克风」合成一个设备，系统里只看到它一个。程序想录音就只能拿到笔记本麦克风，开不到蓝牙麦克风，自然不会触发 HFP。

## 命令行

```bash
AirPodMicBlocker                # 启动菜单栏 App
AirPodMicBlocker --status       # 打印设备 / 链路 / 录音占用状态
AirPodMicBlocker --watch        # 实时监控（Ctrl-C 退出）
AirPodMicBlocker --direct       # 切到耳机直连（F11/F12 可用）
AirPodMicBlocker --aggregate    # 切到聚合设备（通话不降级）
AirPodMicBlocker --no-aggregate # 关闭聚合设备，默认设备还原
AirPodMicBlocker --apply        # 立刻把默认输入拉回非蓝牙麦克风
AirPodMicBlocker --enable       # 开启看护
AirPodMicBlocker --disable      # 关闭看护
```

日志写在 `~/Library/Logs/AirPodMicBlocker.log`。

## 为什么不能直接"关掉"耳机麦克风

这个项目最早的做法是把 `kAudioDevicePropertyStreamConfiguration` 的通道数写成 0，让系统"看不到"麦克风。**这条路在 macOS 27 上行不通**，实测记录如下：

| 设备 | 属性 | 写入结果 |
|---|---|---|
| 全部设备 | `kAudioDevicePropertyStreamConfiguration` | `Illegal Operation` |
| 全部设备 | `kAudioDevicePropertyIsHidden` | `Illegal Operation` |
| 全部设备 | `kAudioDevicePropertyConfigurationApplication` | `Illegal Operation` |
| 流对象 | `kAudioStreamPropertyIsActive` | 返回成功但**回读值不变**（静默忽略） |
| 流对象 | `kAudioStreamPropertyVirtualFormat` | 返回成功但回读值不变 |

试过四种写法（整块写 0 / 保留结构置 0 通道 / 只写 `mNumberBuffers=0` / 写全零 ASBD），全部失败。唯一可写的音频属性是 `kAudioDevicePropertyNominalSampleRate` 和音量。

所以 Apple 已经把「禁用某个设备的麦克风」这个能力从公开 API 里拿掉了。当前实现改用两条确实有效的路径：看护默认输入设备 + 聚合设备。相关说明写在 `Sources/HAL.swift` 里，免得后人重蹈覆辙。

## 已知限制

**系统音量键在聚合设备模式下失效。** 原因不是实现问题：macOS 的音量键只找默认输出设备的 **master 音量**通道，而 AirPods 的 `:output` 设备本身就没有 master 音量（音量存在声道 element 1/2 上），聚合设备自然也没有。换成 `stacked`（堆叠）模式会更糟 —— 输入通道会直接变成 0。

所以聚合设备模式下请用 App 菜单里的音量条，它直接写 AirPods 的声道音量（实测有效）。日常用「耳机直连」模式就能保住 F11/F12。

**微信可能仍然触发降级。** 微信不读系统默认输入，而是自己去找耳机麦克风。聚合设备模式能拦住大部分情况，但如果它硬编码去找 `…:input` 设备，那只能在微信自己的设置里改麦克风。菜单里「正在占用麦克风的程序」会告诉你到底是谁。

**其他逃逸方式。** 拔插一次耳机、重启 `coreaudiod`（`sudo killall coreaudiod`）或重启系统，都会让 macOS 重建 CoreAudio 设备树。工具里的 1 秒看护会自己修复默认设备指针，但已有的播放会话可能需要重启应用。

## 环境

macOS 13.0+，Swift 5+，无需第三方依赖。构建脚本用 `swiftc` 直接编译（不是 SwiftPM），产出 arm64 + x86_64 通用二进制。

## 项目结构

```
Sources/
  HAL.swift         CoreAudio 底层封装：属性读写、设备枚举、聚合设备、
                    录音进程枚举、HFP 链路监测
  AudioEngine.swift 引擎：默认输入看护、聚合设备管理、日志、诊断快照
  AppDelegate.swift 菜单栏 UI：状态显示、输出模式、音量条、图标选择
  main.swift        命令行入口与参数分发
Tools/
  MakeIcon.swift    生成应用图标（SF Symbol + 渐变底 → .icns）
Resources/
  Info.plist        LSUIElement 菜单栏应用配置
build.sh            构建脚本
```

## 许可

MIT