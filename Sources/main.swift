import AppKit
import CoreAudio
import Foundation

//  AirPodMicBlocker            启动菜单栏 App
//  AirPodMicBlocker --status   查看当前设备 / 链路 / 谁在录音
//  AirPodMicBlocker --watch    实时监控（默认 5 分钟，Ctrl-C 结束）
//  AirPodMicBlocker --apply    立刻把默认输入拉回非蓝牙麦克风
//  AirPodMicBlocker --enable / --disable   开关看护

let args = CommandLine.arguments

func usage() {
    print("""
    AirPod Mic Blocker — 让蓝牙耳机保持 A2DP 高音质，录音走笔记本麦克风

    用法：
      AirPodMicBlocker                启动菜单栏应用
      AirPodMicBlocker --status       打印设备 / 链路 / 录音占用状态
      AirPodMicBlocker --watch        实时监控（Ctrl-C 结束）
      AirPodMicBlocker --direct       切到耳机直连（F11/F12 与控制中心可用）
      AirPodMicBlocker --aggregate    切到聚合设备（通话不降级，用 App 内音量条）
      AirPodMicBlocker --no-aggregate 关闭聚合设备，默认设备还原
      AirPodMicBlocker --apply        立刻把默认输入拉回非蓝牙麦克风
      AirPodMicBlocker --enable       开启看护
      AirPodMicBlocker --disable      关闭看护
      AirPodMicBlocker --help         显示本帮助

    说明：macOS 已不允许软件真正禁用某个设备的麦克风，本工具改为
          看护默认输入设备 + 聚合设备来避免蓝牙链路切到 HFP。
          详见 README.md 与 Sources/HAL.swift 里的实测记录。
    """)
}

let engine = AudioEngine.shared

switch args.count > 1 ? args[1] : "" {
case "-h", "--help":
    usage()
case "--status":
    print(engine.snapshotLines().joined(separator: "\n"))
case "--apply":
    let r = engine.enforce()
    if r.switched { print("✓ 默认输入：\(r.from) → \(r.to)") }
    else if r.alreadySafe { print("✓ 默认输入已经在非蓝牙麦克风上，无需处理。") }
    else { print("✗ 找不到可用的非蓝牙麦克风。") }
case "--direct":
    engine.setUseAggregate(false)
    engine.setOutputMode(.direct)
    print("✓ 已切到「耳机直连」模式：系统音量键 / 控制中心恢复正常")
    print(engine.snapshotLines().joined(separator: "\n"))
case "--aggregate":
    engine.setUseAggregate(true)
    engine.setOutputMode(.aggregate)
    print("✓ 已切到「聚合设备」模式：通话不会切 HFP，但系统音量键失效（用 App 内音量条）")
    print(engine.snapshotLines().joined(separator: "\n"))
case "--enable":
    engine.setEnabled(true); print("✓ 看护已开启")
case "--disable":
    engine.setEnabled(false); print("✓ 看护已关闭")
case "--no-aggregate":
    engine.setUseAggregate(false)
    engine.setOutputMode(.direct)
    print("✓ 已关闭聚合设备，默认设备已还原")
case "--watch":
    HFPWatcher.shared.start()
    print("实时监控中（Ctrl-C 退出），日志同时写入 \(engine.logURL.path)")
    print("现在请打一个电话（或开微信语音），看 🟢/🔴 和「录音中」那一栏的变化。")
    print("")
    engine.monitor(interval: 0.5) { print($0) }
case "":
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
default:
    FileHandle.standardError.write("未知参数：\(args[1])\n\n".data(using: .utf8)!)
    usage()
    exit(2)
}
