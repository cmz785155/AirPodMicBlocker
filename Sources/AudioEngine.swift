import Foundation
import CoreAudio
import AppKit

/// 引擎。
///
/// macOS 27 上已经没有公开 API 可以真正「关掉」一个蓝牙设备的麦克风
/// （kAudioDevicePropertyStreamConfiguration / IsHidden / DeviceCanBeDefaultDevice 全部只读）。
/// 所以这里做两件确实有效的事：
///
///  1. **默认输入设备看管**：只要系统默认输入被切到蓝牙耳机麦克风，就立刻拉回笔记本自带麦克风。
///     所有「使用默认输入」的 App（FaceTime / 通话 / 录屏 / 大部分播放器）都会走笔记本麦克风，
///     耳机麦克风不会被打开 → 蓝牙链路不会切到 HFP → 音质保持 A2DP。
///
///  3. **占用侦测**：实时找出到底哪个进程打开了耳机麦克风（走 kAudioHardwarePropertyProcessObjectList），
///     在菜单栏直接显示，这样就能定位那些「不用默认输入、自己挑设备」的 App。
///
///  另外还把「耳机的 :output」和「笔记本内置麦克风」合成一个**聚合设备**并设为默认输出+默认输入，
///  这样微信这类程序也只能开到笔记本麦克风 —— 见 ensureAggregate()。
final class AudioEngine {

    static let shared = AudioEngine()

    /// 我们创建的聚合设备 UID
    static let aggregateUID = "local.airpodmicblocker.aggregate"
    static let aggregateName = "耳机 + 内置麦克风"

    /// 输出模式
    enum OutputMode: String, Codable, CaseIterable {
        /// 聚合设备同时管输出+输入。微信等自己挑设备的程序开不到蓝牙麦克风 → 不切 HFP。
        /// 代价：聚合设备没有 master 音量通道，系统音量键会失效，改用 App 内的音量条。
        case aggregate
        /// 输出直接用 AirPods（系统音量键可用），输入用聚合设备（笔记本麦克风）。
        case direct

        var label: String {
            switch self {
            case .aggregate: return "聚合设备（音质优先）"
            case .direct:    return "耳机直连（音量键可用）"
            }
        }
        /// 菜单栏折叠标题用的短名 —— 长名字在菜单里太占地方
        var shortLabel: String {
            switch self {
            case .aggregate: return "聚合设备"
            case .direct:    return "耳机直连"
            }
        }
        var note: String {
            switch self {
            case .aggregate: return "系统音量键失效，用 App 内音量条"
            case .direct:    return "系统音量键可用，但个别程序仍可能开耳机麦克风"
            }
        }
    }

    struct Settings: Codable {
        /// 是否开启看护
        var enabled: Bool = true
        /// 是否使用聚合设备（解决微信等自己挑设备的程序）
        var useAggregate: Bool = true
        /// 输出模式
        var outputMode: OutputMode = .aggregate
        /// 记住用户偏好的非蓝牙麦克风 UID
        var fallbackUID: String?
        /// 创建聚合设备时用的子设备 UID，用于判断是否需要重建
        var aggregateOutUID: String?
        var aggregateInUID: String?
    }

    // MARK: 状态

    private let lock = NSLock()
    private var settings = Settings()
    private var lastEvent: String?
    private var lastEventAt: Date?
    private var switchedCount = 0

    var onChange: (() -> Void)?

    var isEnabled: Bool { lock.withLock { settings.enabled } }

    // MARK: - 设备缓存（减少 CoreAudio 枚举频率）
    private var deviceCache: [AudioDeviceInfo]? = nil
    private var cacheTimestamp: Date? = nil
    private let cacheTTL: TimeInterval = 2.0

    /// 带缓存的设备枚举——2 秒内直接返回缓存，减少昂贵的 CoreAudio 调用
    private func cachedAllDevices() -> [AudioDeviceInfo] {
        let now = Date()
        if let cache = deviceCache,
           let ts = cacheTimestamp,
           now.timeIntervalSince(ts) < cacheTTL {
            return cache
        }
        deviceCache = allDevices()
        cacheTimestamp = now
        return deviceCache!
    }

    /// 强制刷新缓存（设备插拔等事件后调用）
    private func flushDeviceCache() {
        lock.lock()
        deviceCache = nil
        cacheTimestamp = nil
        lock.unlock()
    }

    var lastEventDescription: String? {
        lock.withLock {
            guard let e = lastEvent else { return nil }
            guard let at = lastEventAt else { return e }
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return "\(f.string(from: at))  \(e)"
        }
    }

    var switchCount: Int { lock.withLock { switchedCount } }

    private let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("AirPodMicBlocker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AirPodMicBlocker.log")
    }()

    private init() { load() }

    // MARK: 持久化

    /// 读取持久化设置。state.json 可能是旧版本写的（缺字段），
    /// 解码失败时逐个字段兜底，避免用户升级后设置被清空。
    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            settings = try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            // 逐字段尽力恢复
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let v = obj["enabled"] as? Bool { settings.enabled = v }
                if let v = obj["useAggregate"] as? Bool { settings.useAggregate = v }
                if let v = obj["fallbackUID"] as? String { settings.fallbackUID = v }
                if let v = obj["aggregateOutUID"] as? String { settings.aggregateOutUID = v }
                if let v = obj["aggregateInUID"] as? String { settings.aggregateInUID = v }
                if let v = obj["outputMode"] as? String, let m = OutputMode(rawValue: v) {
                    settings.outputMode = m
                }
            }
            log("⚠︎ 设置文件解析失败，已按默认值恢复：\(error.localizedDescription)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    func setEnabled(_ v: Bool) {
        lock.withLock { settings.enabled = v }
        persist()
        if v { enforce() }
        notify()
    }

    func setUseAggregate(_ v: Bool) {
        lock.withLock { settings.useAggregate = v }
        // 关闭聚合设备时必须同时回到直连模式：聚合设备的时钟绑在蓝牙输出上，
        // 耳机不在时会退化成 0 Hz 的空壳，占着默认输入的位置导致麦克风用不了。
        if !v { lock.withLock { settings.outputMode = .direct } }
        persist()
        if v {
            if let err = ensureAggregate() { note("聚合设备：\(err)") }
        } else {
            note(disableAggregate() ?? "聚合设备：已关闭")
        }
        notify()
    }

    var isAggregateActive: Bool { lock.withLock { settings.useAggregate } }

    // MARK: 聚合设备

    private func note(_ msg: String) {
        lock.withLock {
            lastEvent = msg
            lastEventAt = Date()
        }
        log(msg)
    }

    /// 聚合设备是否健康可用。
    ///
    /// 关键判断是**采样率必须大于 0**。蓝牙耳机断开时，聚合设备的时钟设备
    /// （我们绑的是 AirPods 的 `:output`）会失效，它会退化成 `1 入 / 0 出 · 0 Hz`
    /// 的空壳 —— 看起来还在设备列表里，但录音完全打不开，而且它还占着
    /// 「默认输入」的位置，会让用户以为麦克风坏了。
    static func isAggregateUsable(_ d: AudioDeviceInfo) -> Bool {
        d.inputChannels > 0 && d.outputChannels > 0 && d.sampleRate > 0
    }

    /// 建立（或修复）聚合设备，并把默认输出/系统输出/默认输入都指向它。
    /// 返回错误描述；成功返回 nil。
    @discardableResult
    func ensureAggregate() -> String? {
        guard let playback = playbackDevice() else {
            // 耳机不在 → 千万别用聚合设备，退回直连
            return "未连接蓝牙耳机，聚合设备不可用（已保持直连模式）"
        }
        guard let mic = preferredNonBluetoothInput(excluding: "") else {
            return "找不到可用的非蓝牙麦克风"
        }

        // 已经存在且子设备没变 → 只确保默认设备指向它
        if let agg = findAggregateDevice(uid: Self.aggregateUID) {
            let sameOut = lock.withLock { settings.aggregateOutUID } == playback.uid
            let sameIn  = lock.withLock { settings.aggregateInUID } == mic.uid
            if sameOut && sameIn && Self.isAggregateUsable(agg) {
                pointDefaults(to: agg)
                return nil
            }
            // 不健康或子设备变了 → 先把默认设备从它身上挪开，再删
            restoreSafeDefaults()
            _ = destroyAggregateDevice(agg.id)
            Thread.sleep(forTimeInterval: 0.4)
        }

        do {
            _ = try createAggregateDevice(name: Self.aggregateName,
                                          uid: Self.aggregateUID,
                                          output: playback,
                                          input: mic)
        } catch {
            return "\(error.localizedDescription)"
        }

        // 设备刚创建，等 coreaudiod 把它列出来，并确认它是健康的
        var agg: AudioDeviceInfo?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.2)
            if let a = findAggregateDevice(uid: Self.aggregateUID), Self.isAggregateUsable(a) {
                agg = a
                break
            }
        }
        guard let agg else {
            restoreSafeDefaults()
            if findAggregateDevice(uid: Self.aggregateUID) != nil { _ = destroyAggregateDevice(findAggregateDevice(uid: Self.aggregateUID)!.id) }
            return "聚合设备创建失败或不可用，已保持直连模式"
        }

        lock.withLock {
            settings.aggregateOutUID = playback.uid
            settings.aggregateInUID = mic.uid
        }
        persist()
        pointDefaults(to: agg)
        note("已启用聚合设备「\(Self.aggregateName)」：播放→\(playback.name)，录音→\(mic.name)")
        return nil
    }

    /// 把默认输出 / 默认系统输出 / 默认输入按当前模式指向正确设备
    private func pointDefaults(to agg: AudioDeviceInfo) {
        let mode = lock.withLock { settings.outputMode }
        switch mode {
        case .aggregate:
            halSetDefaultDevice(agg.id, kAudioHardwarePropertyDefaultOutputDevice)
            halSetDefaultDevice(agg.id, kAudioHardwarePropertyDefaultSystemOutputDevice)
            halSetDefaultDevice(agg.id, kAudioHardwarePropertyDefaultInputDevice)
        case .direct:
            // 直连模式下默认输入直接用笔记本麦克风，**不要**用聚合设备 ——
            // 聚合设备的时钟绑在蓝牙输出上，耳机一断它就 0 Hz 失效，
            // 会让「不用耳机、只插内置扬声器」的场景麦克风完全用不了。
            if let bt = playbackDevice() {
                halSetDefaultDevice(bt.id, kAudioHardwarePropertyDefaultOutputDevice)
                halSetDefaultDevice(bt.id, kAudioHardwarePropertyDefaultSystemOutputDevice)
            }
            if let mic = preferredNonBluetoothInput(excluding: "") {
                halSetDefaultDevice(mic.id, kAudioHardwarePropertyDefaultInputDevice)
            }
        }
    }

    /// 把默认设备挪到「肯定能用」的组合，绝不指向聚合设备。
    /// 输出 → 蓝牙耳机（若有）否则不动；输入 → 笔记本麦克风。
    private func restoreSafeDefaults() {
        if let bt = playbackDevice() {
            halSetDefaultDevice(bt.id, kAudioHardwarePropertyDefaultOutputDevice)
            halSetDefaultDevice(bt.id, kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
        if let mic = preferredNonBluetoothInput(excluding: "") {
            halSetDefaultDevice(mic.id, kAudioHardwarePropertyDefaultInputDevice)
        }
    }

    var outputMode: OutputMode { lock.withLock { settings.outputMode } }

    func setOutputMode(_ mode: OutputMode) {
        lock.withLock { settings.outputMode = mode }
        persist()
        if let err = ensureAggregate() { note("输出模式：\(err)") }
        else { note("输出模式已切到「\(mode.label)」· \(mode.note)") }
        notify()
    }

    // MARK: 耳机音量直控（聚合设备没有 master 音量，系统音量键对它无效）

    var currentHeadsetVolume: Float32 { halHeadsetVolume() ?? 0.5 }

    func setHeadsetVolume(_ v: Float32) {
        let st = halSetHeadsetVolume(v)
        if st != noErr { log("⚠︎ 设置耳机音量失败：\(osStatusText(st))") }
    }

    var isHeadsetMuted: Bool { halHeadsetMuted() ?? false }

    func setHeadsetMuted(_ m: Bool) {
        let st = halSetHeadsetMuted(m)
        if st != noErr { log("⚠︎ 静音切换失败：\(osStatusText(st))") }
    }

    /// 关闭聚合设备：把默认设备还原成「耳机的 :output」+「笔记本麦克风」，然后删掉聚合设备
    @discardableResult
    func disableAggregate() -> String? {
        let bt = playbackDevice()
        let mic = preferredNonBluetoothInput(excluding: "")
        lock.withLock { settings.outputMode = .direct }
        if let bt { halSetDefaultDevice(bt.id, kAudioHardwarePropertyDefaultOutputDevice)
                    halSetDefaultDevice(bt.id, kAudioHardwarePropertyDefaultSystemOutputDevice) }
        if let mic { halSetDefaultDevice(mic.id, kAudioHardwarePropertyDefaultInputDevice) }

        if let agg = findAggregateDevice(uid: Self.aggregateUID) {
            let st = destroyAggregateDevice(agg.id)
            if st != noErr { return "删除聚合设备失败：\(osStatusText(st))" }
        }
        lock.withLock {
            settings.aggregateOutUID = nil
            settings.aggregateInUID = nil
        }
        persist()
        return "已关闭聚合设备"
    }

    // MARK: 核心：看护默认输入设备

    struct Report {
        var switched = false
        var from = ""
        var to = ""
        var alreadySafe = false
        var noFallback = false
    }

    /// 若默认输入设备是蓝牙设备的麦克风，把它拉回非蓝牙麦克风
    @discardableResult
    func enforce() -> Report {
        var report = Report()
        guard isEnabled else { return report }

        // 蓝牙耳机不在时，聚合设备的时钟会失效、退化成 0 Hz 空壳，
        // 必须先把它从默认设备的位置上撤下来，否则麦克风会完全用不了。
        if let agg = findAggregateDevice(uid: Self.aggregateUID), !Self.isAggregateUsable(agg) {
            lock.withLock {
                if settings.outputMode == .aggregate {
                    settings.outputMode = .direct
                    lastEvent = "蓝牙耳机已断开，聚合设备失效，自动切回直连"
                    lastEventAt = Date()
                }
            }
            persist()
            restoreSafeDefaults()
            _ = destroyAggregateDevice(agg.id)
            log("⚠︎ 聚合设备已失效（蓝牙耳机断开），已删除并还原默认设备")
        }

        // 聚合设备是主力手段：设备插拔 / 子设备变化时自动重建
        if lock.withLock({ settings.useAggregate }) {
            if let err = ensureAggregate() {
                lock.withLock {
                    if lastEvent != err { lastEvent = err; lastEventAt = Date(); switchedCount += 1 }
                }
                log("⚠︎ \(err)")
            }
        }

        let cached = cachedAllDevices()
        let inID = halDefaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
        guard inID != 0, let current = cached.first(where: { $0.id == inID }) ?? halDescribe(inID) else {
            report.noFallback = true
            return report
        }
        // 默认输入已经是安全的（非蓝牙）设备，什么都不用做
        guard current.isBluetooth else {
            lock.withLock { settings.fallbackUID = current.uid }
            persist()
            report.alreadySafe = true
            return report
        }

        guard let fallback = cached.first(where: { $0.hasMic && !$0.isBluetooth && $0.uid != current.uid }) ??
            preferredNonBluetoothInput(excluding: current.uid) else {
            report.noFallback = true
            log("⚠︎ 默认输入是「\(current.name)」，但找不到可用的非蓝牙麦克风")
            return report
        }

        let st = halSetDefaultDevice(fallback.id, kAudioHardwarePropertyDefaultInputDevice)
        guard st == noErr else {
            report.noFallback = true
            log("⚠︎ 切换默认输入失败：\(osStatusText(st))")
            return report
        }

        report.switched = true
        report.from = current.name
        report.to = fallback.name
        lock.withLock {
            settings.fallbackUID = fallback.uid
            switchedCount += 1
            lastEvent = "默认输入：\(current.name) → \(fallback.name)"
            lastEventAt = Date()
        }
        persist()
        log("↩︎ 默认输入已从「\(current.name)」拉回「\(fallback.name)」")
        notify()
        return report
    }

    // MARK: 蓝牙耳机状态

    /// 蓝牙音频设备（含 :input / :output 两半）
    var bluetoothDevices: [AudioDeviceInfo] {
        cachedAllDevices().filter { $0.isBluetooth }
    }

    /// AirPods 输出侧（A2DP 立体声播放）
    func playbackDevice() -> AudioDeviceInfo? { bluetoothPlaybackDevice() }

    /// AirPods 麦克风侧（HFP）
    func captureDevice() -> AudioDeviceInfo? { bluetoothCaptureDevice() }

    /// 正在占用麦克风的进程
    var recorders: [AudioProcessInfo] { processesRecording() }

    /// 蓝牙耳机麦克风（HFP 侧）此刻是否真的被打开了。
    ///
    /// 这是判断「有没有东西在偷用耳机麦克风」最直接的依据：
    /// `kAudioDevicePropertyDeviceIsRunning` 在 `:input` 设备上，只有真的开了
    /// SCO/eSCO 链路才会变成 true。一旦为 true，播放质量就已经被拖到 HFP 了。
    var bluetoothMicInUse: Bool {
        bluetoothCaptureDevice()?.isRunning ?? false
    }

    /// 判定耳机是否处于 HFP（音质变差）状态。
    /// 蓝牙链路层的数据（bluetoothd 的 HFP handle）才是真正的分水岭 ——
    /// CoreAudio 报告的设备格式在切 HFP 时根本不会变。
    func hfpState() -> (isHFP: Bool, detail: String) {
        guard let out = playbackDevice() else { return (false, "未连接蓝牙耳机") }
        let coreAudio = "\(Int(out.sampleRate)) Hz · \(out.outputChannels) 声道"
        let w = HFPWatcher.shared
        if let seen = w.lastUpdate {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let link = w.isHFPActive ? "🔴 HFP" : "🟢 A2DP"
            let age = Date().timeIntervalSince(seen)
            let fresh = age < 8 ? "\(f.string(from: seen))" : "已 \(Int(age))s 未更新"
            return (w.isHFPActive, "\(link) · \(fresh) · CoreAudio \(coreAudio)")
        }
        // 没连上蓝牙栈日志时退回启发式判断
        if out.outputChannels == 1 { return (true, coreAudio + "（单声道 = HFP）") }
        if out.sampleRate > 0 && out.sampleRate < 32000 { return (true, coreAudio + "（低采样率 = HFP）") }
        return (false, coreAudio + "（立体声 = A2DP）")
    }

    // MARK: 日志

    private let logLock = NSLock()
    private var logBuffer: [String] = []
    private var logFlushTimer: Timer?
    private let maxLogBatch = 10

    func log(_ message: String) {
        logLock.lock()
        logBuffer.append(message)
        // 满 10 条立即刷盘，否则等 5 秒再批量写入
        if logBuffer.count >= maxLogBatch {
            flushLog()
        } else if logFlushTimer == nil {
            logFlushTimer = Timer(timeInterval: 5.0, repeats: false) { [weak self] _ in
                self?.flushLog()
                self?.logFlushTimer = nil
            }
            RunLoop.main.add(logFlushTimer!, forMode: .common)
        }
        logLock.unlock()
    }

    func flushLog() {
        logLock.lock()
        guard !logBuffer.isEmpty else { logLock.unlock(); return }
        let entries = logBuffer
        logBuffer.removeAll()
        logLock.unlock()

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let lines = entries.map { "[\(f.string(from: Date()))] \($0)\n" }
        let batch = lines.joined()
        do {
            if let fh = FileHandle(forWritingAtPath: logURL.path) {
                fh.seekToEndOfFile()
                fh.write(Data(batch.utf8))
                try? fh.close()
            } else {
                try Data(batch.utf8).write(to: logURL, options: .atomic)
            }
        } catch {
            // 日志写入失败静默忽略
        }
    }

    /// 监控：每秒采样一次，输出音频状态变化
    func monitor(interval: TimeInterval, until: Date? = nil, onLine: ((String) -> Void)? = nil) {
        var previous = ""
        while until == nil || Date() < until! {
            let r = enforce()
            if r.switched { previous = "" }

            let hfp = hfpState()
            let inDev = cachedAllDevices().first { $0.id == halDefaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) }
            let outDev = cachedAllDevices().first { $0.id == halDefaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) }
            let users = recorders.map { "\($0.name)(\($0.bundleID))" }.joined(separator: ",")

            let line = String(
                format: "输入=%@ | 输出=%@ | 耳机=%@ | 录音中=%@",
                inDev?.name ?? "-", outDev?.name ?? "-", hfp.detail, users.isEmpty ? "无" : users)

            if line != previous {
                let tag = hfp.isHFP ? "🔴HFP" : "🟢A2DP"
                onLine?("\(tag) \(line)")
                log("\(tag) \(line)")
                previous = line
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    // MARK: 快照文本

    func snapshotLines() -> [String] {
        var lines: [String] = []
        let all = cachedAllDevices()
        let inDev = all.first { $0.id == halDefaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) }
        let outDev = all.first { $0.id == halDefaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) }
        let hfp = hfpState()

        lines.append("默认输出：\(outDev?.name ?? "无")")
        let btWarn = (inDev?.isBluetooth ?? false) ? "  ⚠️ 正在用蓝牙麦克风" : ""
        lines.append("默认输入：\(inDev?.name ?? "无")\(btWarn)")
        lines.append("耳机链路：\(hfp.detail)")
        lines.append("看护开关：\(isEnabled ? "已开启" : "已关闭")（累计拉回 \(switchCount) 次）")
        lines.append("输出模式：\(outputMode.label) — \(outputMode.note)")

        // 聚合设备健康状况 —— 不健康时明确告诉用户麦克风为什么用不了
        if let agg = findAggregateDevice(uid: Self.aggregateUID) {
            let ok = Self.isAggregateUsable(agg)
            lines.append(ok
                ? "聚合设备：可用（\(agg.inputChannels) 入 / \(agg.outputChannels) 出 · \(Int(agg.sampleRate)) Hz）"
                : "聚合设备：⚠️ 不可用（\(agg.inputChannels) 入 / \(agg.outputChannels) 出 · \(Int(agg.sampleRate)) Hz）—— 蓝牙耳机断开导致失效")
        } else {
            lines.append("聚合设备：不存在")
        }
        lines.append("耳机麦克风：\(bluetoothMicInUse ? "⚠️ 正在被使用（HFP 已激活，音质变差）" : "未被使用")")
        lines.append("")

        let bs = bluetoothDevices
        if bs.isEmpty {
            lines.append("未检测到蓝牙音频设备。")
        } else {
            lines.append("蓝牙音频设备：")
            for d in bs {
                let role = d.uid.hasSuffix(":input") ? "麦克风侧(HFP)" : (d.uid.hasSuffix(":output") ? "输出侧(A2DP)" : "")
                lines.append("  • \(d.name)\(role.isEmpty ? "" : "  [\(role)]")")
                lines.append("      \(d.inputChannels) 入 / \(d.outputChannels) 出 · \(Int(d.sampleRate)) Hz")
                lines.append("      UID \(d.uid)")
            }
        }

        lines.append("")
        let rec = recorders
        if rec.isEmpty {
            lines.append("当前没有程序在录音。")
        } else {
            lines.append("正在占用麦克风的程序：")
            for p in rec { lines.append("  • \(p.name)  [\(p.bundleID)]  pid \(p.pid)") }
        }
        if let e = lastEventDescription { lines.append(""); lines.append("最近动作：\(e)") }
        return lines
    }

    func notify() { onChange?() }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}