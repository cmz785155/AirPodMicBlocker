import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import Security

// MARK: - 常量

enum Scope {
    static let global = kAudioObjectPropertyScopeGlobal
    static let input  = kAudioDevicePropertyScopeInput
    static let output = kAudioDevicePropertyScopeOutput
}

let sysObject = AudioObjectID(kAudioObjectSystemObject)

/// 蓝牙传输类型。
/// 老 SDK 常量是 'bluetooth'，但新版 macOS 驱动实际上报的是 'blue' —— 两个都要认。
let kTransportBluetoothOld: UInt32 = 0x626C_7575  // 'bluetooth'
let kTransportBluetoothNew: UInt32 = 0x626C_7565  // 'blue'
let kTransportBluetoothCCWD: UInt32 = 0x6363_7764 // 'ccwd'（Continuity / iPhone 麦克风）

// MARK: - 低层属性读写

@inline(__always)
func halAddr(_ selector: AudioObjectPropertySelector,
            _ scope: AudioObjectPropertyScope,
            _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func halPropSize(_ object: AudioObjectID, _ a: inout AudioObjectPropertyAddress) -> UInt32? {
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr else { return nil }
    return size
}

func halHasProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
    var a = halAddr(selector, scope, element)
    return AudioObjectHasProperty(object, &a)
}

/// 读取定长标量属性
///
/// 注意：不能写成 `var result: T?` 再往里写 —— UInt32 这类没有「富余值」的类型，
/// Swift 会用一个额外的 tag 字节表示 nil。写入数值后 tag 仍然是 nil，读出来永远是 nil。
/// 所以这里直接操作裸内存。
func halRead<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = Scope.global,
                   element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> T? {
    var a = halAddr(selector, scope, element)
    guard AudioObjectHasProperty(object, &a) else { return nil }

    let size = UInt32(MemoryLayout<T>.size)
    guard size > 0 else { return nil }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { buffer.deallocate() }

    var mutableSize = size
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &mutableSize, buffer) == noErr else {
        return nil
    }
    return buffer.load(as: T.self)
}

/// 写入定长标量属性
@discardableResult
func halWrite<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = Scope.global,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                    value: T) -> OSStatus {
    var a = halAddr(selector, scope, element)
    guard AudioObjectHasProperty(object, &a) else { return kAudioHardwareIllegalOperationError }
    let size = UInt32(MemoryLayout<T>.size)
    return withUnsafePointer(to: value) { p in
        AudioObjectSetPropertyData(object, &a, 0, nil, size, UnsafeRawPointer(p))
    }
}

func halReadString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = halAddr(selector, Scope.global, kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(object, &a) else { return nil }

    let size = UInt32(MemoryLayout<CFString?>.size)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { buffer.deallocate() }

    var mutableSize = size
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &mutableSize, buffer) == noErr else {
        return nil
    }
    let cf: CFString = buffer.load(as: CFString.self)
    return cf as String
}

// MARK: - 流配置（Stream Configuration）

struct StreamSnapshot {
    var bytes: Data
    var channels: Int
}

/// 读取设备某个方向的流配置（通道列表 + 通道数）
func halReadStream(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> StreamSnapshot? {
    var a = halAddr(kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(device, &a) else { return nil }
    guard let size = halPropSize(device, &a), size > 0 else { return nil }

    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }

    var mutableSize = size
    let st = AudioObjectGetPropertyData(device, &a, 0, nil, &mutableSize, raw)
    guard st == noErr else { return nil }

    var list = raw.assumingMemoryBound(to: AudioBufferList.self).pointee
    let buffers = UnsafeMutableAudioBufferListPointer(&list)
    let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }

    let bytes = Data(bytes: raw, count: Int(mutableSize))
    return StreamSnapshot(bytes: bytes, channels: channels)
}

// MARK: - 关于「写流配置来关闭麦克风」
//
//  这里曾经实现过一套「把 kAudioDevicePropertyStreamConfiguration 的通道数写成 0」的方案
//  （试过整块写 0 / 保留结构置 0 通道 / 只写 mNumberBuffers=0 / 写全零 ASBD 四种写法）。
//  实测在 macOS 27 上**完全不成立**，代码已移除，原因记录在此以免后人重蹈覆辙：
//
//    设备                                  属性                                 写入结果
//    AirPods :input / :output              kAudioDevicePropertyStreamConfiguration  Illegal Operation
//    MacBook 内置麦克风 / 扬声器            同上                                     Illegal Operation
//    全部设备                              kAudioDevicePropertyIsHidden             Illegal Operation
//    全部设备                              kAudioDevicePropertyConfigurationApplication  Illegal Operation
//    流对象                                kAudioStreamPropertyIsActive             返回成功但回读值不变（静默忽略）
//    流对象                                kAudioStreamPropertyVirtualFormat         返回成功但回读值不变
//
//  唯一可写的音频属性是 kAudioDevicePropertyNominalSampleRate（以及音量 kAudioDevicePropertyVolumeScalar）。
//  也就是说 macOS 已经没有公开 API 能真正「关掉」某个设备的麦克风。
//
//  因此本工具改用两条真正有效的路径：
//    1. 看护 kAudioHardwarePropertyDefaultInputDevice，别让它落到蓝牙设备上；
//    2. 造聚合设备，把「蓝牙 :output」和「笔记本麦克风」合成一个，让程序挑不到蓝牙麦克风。

// MARK: - 设备信息

struct AudioDeviceInfo {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let hasInputScope: Bool
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double
    let isRunning: Bool
    let isDefaultInput: Bool
    let isDefaultOutput: Bool
    let isAggregate: Bool

    /// 是否蓝牙音频设备（含新版 'blue' 与旧版 'bluetooth' 两种上报值）
    var isBluetooth: Bool { transport == kTransportBluetoothNew || transport == kTransportBluetoothOld }
    var hasMic: Bool { hasInputScope && inputChannels > 0 }
    var micGated: Bool { hasInputScope && inputChannels == 0 }

    /// 新版 macOS 会把 AirPods 拆成两个 CoreAudio 设备：
    ///   <MAC>:output —— A2DP 立体声输出，没有输入通道（我们想留着的那个）
    ///   <MAC>:input  —— HFP 麦克风，单声道 16k/24k（需要屏蔽的那个）
    var isCompanionInputDevice: Bool {
        uid.hasSuffix(":input") || (isBluetooth && inputChannels > 0 && outputChannels == 0)
    }
    var isCompanionOutputDevice: Bool { uid.hasSuffix(":output") }

    /// 输出 2 声道 = A2DP 立体声高音质；1 声道 = HFP 单声道低码率
    var isLowQualityHFP: Bool { outputChannels == 1 }
    var transportText: String {
        switch transport {
        case kTransportBluetoothNew, kTransportBluetoothOld: return "蓝牙"
        case kTransportBluetoothCCWD: return "Continuity"
        case UInt32(kAudioDeviceTransportTypeBuiltIn): return "内置"
        case UInt32(kAudioDeviceTransportTypeUSB): return "USB"
        case UInt32(kAudioDeviceTransportTypeVirtual): return "虚拟"
        case UInt32(kAudioDeviceTransportTypeAggregate): return "聚合设备"
        case UInt32(kAudioDeviceTransportTypeHDMI): return "HDMI"
        case UInt32(kAudioDeviceTransportTypeDisplayPort): return "DP"
        case UInt32(kAudioDeviceTransportTypeThunderbolt): return "雷雳"
        case UInt32(kAudioDeviceTransportTypeAirPlay): return "AirPlay"
        default: return "类型 \(transport)"
        }
    }
}

// MARK: - 设备枚举

func halAllDeviceIDs() -> [AudioDeviceID] {
    var a = halAddr(kAudioHardwarePropertyDevices, Scope.global, kAudioObjectPropertyElementMain)
    guard var size = halPropSize(sysObject, &a), size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    let st = ids.withUnsafeMutableBytes { raw -> OSStatus in
        AudioObjectGetPropertyData(sysObject, &a, 0, nil, &size, raw.baseAddress!)
    }
    return st == noErr ? ids.filter { $0 != 0 } : []
}

func halDefaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    let id: AudioDeviceID = halRead(sysObject, selector) ?? 0
    return id
}

@discardableResult
func halSetDefaultDevice(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> OSStatus {
    halWrite(sysObject, selector, value: id)
}

func halDescribe(_ device: AudioDeviceID) -> AudioDeviceInfo? {
    let alive: UInt32 = halRead(device, kAudioDevicePropertyDeviceIsAlive) ?? 0
    guard alive != 0 else { return nil }

    let defaultIn  = halDefaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    let defaultOut = halDefaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
    let tp: UInt32 = halRead(device, kAudioDevicePropertyTransportType) ?? 0
    let sampleRate: Double = halRead(device, kAudioDevicePropertyNominalSampleRate) ?? 0
    let runningFlag: UInt32 = halRead(device, kAudioDevicePropertyDeviceIsRunning) ?? 0
    let inChannels = halReadStream(device, scope: Scope.input)?.channels ?? 0
    let outChannels = halReadStream(device, scope: Scope.output)?.channels ?? 0

    return AudioDeviceInfo(
        id: device,
        uid: halReadString(device, kAudioDevicePropertyDeviceUID) ?? "",
        name: halReadString(device, kAudioObjectPropertyName) ?? "未知设备",
        transport: tp,
        hasInputScope: halHasProperty(device, kAudioDevicePropertyStreamConfiguration, scope: Scope.input),
        inputChannels: inChannels,
        outputChannels: outChannels,
        sampleRate: sampleRate,
        isRunning: runningFlag != 0,
        isDefaultInput: device == defaultIn,
        isDefaultOutput: device == defaultOut,
        isAggregate: tp == UInt32(kAudioDeviceTransportTypeAggregate)
    )
}

func allDevices() -> [AudioDeviceInfo] {
    halAllDeviceIDs().compactMap { halDescribe($0) }
}

/// 带麦克风的蓝牙音频设备。
/// AirPods / Beats 在新版 macOS 上会拆成 `:input`（HFP 麦克风）和 `:output`（A2DP 立体声）两个设备，
/// 只需要屏蔽前者。
func bluetoothAudioDevices() -> [AudioDeviceInfo] {
    allDevices().filter { $0.isBluetooth && $0.hasInputScope }
}

/// 蓝牙播放设备（耳机的 `:output`，A2DP 立体声那一半）
func bluetoothPlaybackDevice() -> AudioDeviceInfo? {
    allDevices().first {
        $0.isBluetooth && $0.outputChannels > 0 && !$0.uid.hasSuffix(":input")
    }
}

/// 蓝牙麦克风设备（耳机的 `:input`，HFP 那一半）
/// isRunning 为 true 就说明有人真的开了 SCO 链路，播放质量已经被拖下去了。
func bluetoothCaptureDevice() -> AudioDeviceInfo? {
    allDevices().first { $0.isBluetooth && $0.uid.hasSuffix(":input") }
        ?? allDevices().first { $0.isBluetooth && $0.inputChannels > 0 }
}

/// 第一个内建设备麦克风
func builtInMicrophone() -> AudioDeviceInfo? {
    allDevices().first { $0.transport == UInt32(kAudioDeviceTransportTypeBuiltIn) && $0.hasMic }
}

/// 任何不是蓝牙的可用麦克风（首选笔记本自带，其次 USB 等）
func preferredNonBluetoothInput(excluding uid: String) -> AudioDeviceInfo? {
    let mics = allDevices().filter { $0.hasMic && !$0.isBluetooth && $0.uid != uid }
    return mics.first { $0.transport == UInt32(kAudioDeviceTransportTypeBuiltIn) } ?? mics.first
}

// MARK: - 音频进程（谁在占用麦克风）

struct AudioProcessInfo {
    let pid: pid_t
    let bundleID: String
    let name: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

/// 通过 kAudioHardwarePropertyProcessObjectList 列出当前占用音频的进程。
/// 这是判断「到底是谁打开了耳机麦克风」的唯一可靠途径。
func audioProcesses() -> [AudioProcessInfo] {
    var addr = halAddr(kAudioHardwarePropertyProcessObjectList, Scope.global, kAudioObjectPropertyElementMain)
    guard var size = halPropSize(sysObject, &addr), size > 0 else { return [] }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(sysObject, &addr, 0, nil, &size, buf) == noErr else { return [] }

    let objects = UnsafeRawBufferPointer(start: buf, count: Int(size)).bindMemory(to: AudioObjectID.self)
    return objects.map { obj -> AudioProcessInfo in
        let pid: pid_t = halRead(obj, kAudioProcessPropertyPID) ?? 0
        let r1: UInt32 = halRead(obj, kAudioProcessPropertyIsRunningInput) ?? 0
        let r2: UInt32 = halRead(obj, kAudioProcessPropertyIsRunningOutput) ?? 0
        return AudioProcessInfo(
            pid: pid,
            bundleID: halReadString(obj, kAudioProcessPropertyBundleID) ?? "",
            name: (pid > 0 ? NSRunningApplication(processIdentifier: pid)?.localizedName : nil) ?? "pid \(pid)",
            isRunningInput: (r1 != 0),
            isRunningOutput: (r2 != 0)
        )
    }
}

/// 正在录音的进程
func processesRecording() -> [AudioProcessInfo] {
    audioProcesses().filter(\.isRunningInput)
}

// MARK: - 错误描述

func osStatusText(_ status: OSStatus) -> String {
    if status == noErr { return "成功" }
    switch status {
    case kAudioHardwareIllegalOperationError: return "设备不允许此操作 (Illegal Operation)"
    case kAudioHardwareUnsupportedOperationError: return "设备不支持该操作 (Unsupported Operation)"
    case kAudioDeviceUnsupportedFormatError:  return "不支持的格式 (Unsupported Format)"
    case kAudioHardwareNotRunningError:      return "音频服务未运行 (Not Running)"
    case kAudioHardwareBadPropertySizeError: return "属性尺寸不匹配 (Bad Property Size)"
    case kAudioHardwareBadDeviceError:       return "无效的设备 (Bad Device)"
    case kAudioDevicePermissionsError:       return "权限不足 (Permissions)"
    case kAudioHardwareUnknownPropertyError: return "未知属性"
    case kAudioHardwareNotReadyError:        return "音频服务未就绪 (Not Ready)"
    default:
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "未知错误"
        return "\(text) [0x\(String(UInt32(bitPattern: status), radix: 16))]"
    }
}
// MARK: - 聚合设备
//
//  核心思路：macOS 上 AirPods 被拆成 `:output`（A2DP 立体声播放）和 `:input`（HFP 麦克风）
//  两个独立的 CoreAudio 设备。微信这类程序会「自己挑设备」，它看到输出是耳机，就去开
//  耳机的 `:input` → 蓝牙链路切 HFP → 音乐变得很小。
//
//  解法：造一个聚合设备，把「耳机的 :output」和「笔记本内置麦克风」合成**一个**设备，
//  并把它设为默认输出 + 默认输入。这样任何程序（哪怕自己挑设备）看到的都是这个聚合设备，
//  它的输入是笔记本麦克风（不是蓝牙），所以永远开不了蓝牙麦克风 → 不会切 HFP。
//  播放依然走耳机 :output，保持 A2DP 高音质。

struct AggregateError: Error {
    let message: String
    var localizedDescription: String { message }
}

/// 已有的聚合设备（按 UID 找）
func findAggregateDevice(uid: String) -> AudioDeviceInfo? {
    allDevices().first { $0.uid == uid }
}

func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus {
    AudioHardwareDestroyAggregateDevice(id)
}

/// 创建聚合设备。`output` 一般传耳机的 :output，`input` 一般传笔记本内置麦克风。
@discardableResult
func createAggregateDevice(name: String,
                           uid: String,
                           output: AudioDeviceInfo?,
                           input: AudioDeviceInfo?) throws -> AudioObjectID {

    var subs: [[String: Any]] = []

    if let o = output, o.outputChannels > 0 {
        subs.append([
            kAudioSubDeviceUIDKey:               o.uid,
            kAudioSubDeviceNameKey:              o.name,
            kAudioSubDeviceInputChannelsKey:     0,
            kAudioSubDeviceOutputChannelsKey:    o.outputChannels,
            kAudioSubDeviceDriftCompensationKey: 1
        ])
    }
    if let i = input, i.inputChannels > 0 {
        subs.append([
            kAudioSubDeviceUIDKey:            i.uid,
            kAudioSubDeviceNameKey:           i.name,
            kAudioSubDeviceInputChannelsKey:  i.inputChannels,
            kAudioSubDeviceOutputChannelsKey: 0
        ])
    }
    guard !subs.isEmpty else {
        throw AggregateError(message: "找不到可用的子设备（蓝牙耳机输出 / 笔记本麦克风）")
    }

    var desc: [String: Any] = [
        kAudioAggregateDeviceUIDKey:              uid,
        kAudioAggregateDeviceNameKey:             name,
        kAudioAggregateDeviceSubDeviceListKey:    subs,
        kAudioAggregateDeviceIsPrivateKey:        false,
        kAudioAggregateDeviceIsStackedKey:        false
    ]
    if let o = output, o.outputChannels > 0 {
        desc[kAudioAggregateDeviceClockDeviceKey]   = o.uid
        desc[kAudioAggregateDeviceMainSubDeviceKey] = o.uid
    }

    var newID: AudioObjectID = kAudioObjectUnknown
    let cf = desc as CFDictionary
    let st = AudioHardwareCreateAggregateDevice(cf, &newID)
    guard st == noErr else {
        throw AggregateError(message: "创建聚合设备失败：\(osStatusText(st))")
    }
    return newID
}

// MARK: - HFP 状态监测（蓝牙链路层，比 CoreAudio 可靠）
//
//  CoreAudio 报告的设备格式在切 HFP 时**不会变**，所以看不到降级。
//  但 bluetoothd 的链路质量日志里有 `HFP handle 0x0000` —— handle 非 0 就说明
//  蓝牙栈真的开了 HFP（SCO/eSCO），也就是音质的那个分水岭。
//
//  优化：不再持续运行 `log stream` 进程（这是功耗的主要来源）。
//  改为 Timer 定期检查，空闲时 10 秒一次，检测到 HFP 时自动升频到 1 秒。
//  同时优先使用 CoreAudio 属性（声道数、采样率）做快速判断，减少子进程调用。

final class HFPWatcher {

    static let shared = HFPWatcher()

    private let lock = NSLock()
    private var _active = false
    private var _lastSeen: Date?

    /// 蓝牙栈当前是否处于 HFP（HFP handle 非 0）
    var isHFPActive: Bool { lock.withLock { _active } }
    var lastUpdate: Date? { lock.withLock { _lastSeen } }

    private init() {}

    // MARK: - 智能定时器（不再启动 log stream 进程）
    // 空闲时 10 秒检查一次，检测到 HFP 降级时自动升频到 1 秒
    private var checkTimer: Timer?
    private var isMonitoring = false

    func start() {
        lock.lock()
        guard !isMonitoring else { lock.unlock(); return }
        isMonitoring = true
        lock.unlock()

        scheduleCheck(interval: 10.0)
    }

    func stop() {
        lock.lock()
        isMonitoring = false
        checkTimer?.invalidate()
        checkTimer = nil
        lock.unlock()
    }

    private func scheduleCheck(interval: TimeInterval) {
        checkTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.doCheck()
        }
        RunLoop.main.add(t, forMode: .common)
        lock.lock()
        checkTimer = t
        lock.unlock()
    }

    /// 单次检查：先通过 CoreAudio 属性判断（零子进程），A2DP 正常时偶尔用 log 命令确认
    private func doCheck() {
        lock.lock()
        guard isMonitoring else { lock.unlock(); return }
        lock.unlock()

        // 方法 1：通过蓝牙设备属性判断（轻量，无需启动子进程）
        if let out = bluetoothPlaybackDevice() {
            if out.outputChannels == 1 || (out.sampleRate > 0 && out.sampleRate < 32000) {
                lock.lock()
                _active = true
                _lastSeen = Date()
                lock.unlock()
                scheduleCheck(interval: 1.0)
                return
            }
        }

        // 方法 2：轻量一次性 log 命令确认（不持续监听）
        checkViaLogOnce()
    }

    /// 一次性 log 命令检查，不持续监听
    private func checkViaLogOnce() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        let bluetoothPred = "subsystem == \"com.apple.bluetooth\" AND message contains \"HFP handle\""
        p.arguments = ["--predicate", bluetoothPred, "--last", "50"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        do { try p.run() } catch { return }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return }

        var active = false
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: #"HFP handle 0x([0-9A-Fa-f]+)"#,
                                        options: .regularExpression) else { continue }
            let hex = line[range].split(separator: "x").last ?? "0"
            if (UInt32(hex, radix: 16) ?? 0) != 0 {
                active = true
                break
            }
        }

        lock.lock()
        _active = active
        _lastSeen = Date()
        lock.unlock()
    }

    /// 便捷判断：耳机是否明显降级
    static func statusText() -> String {
        let w = shared
        guard let seen = w.lastUpdate else { return "未知（监测未启动）" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return w.isHFPActive ? "🔴 HFP 已开启" : "🟢 A2DP（无 HFP）"
            + " · \(f.string(from: seen)) 更新"
    }
}

// MARK: - 蓝牙耳机音量直控
//
//  AirPods 的 :output 设备**没有 master 音量通道**，只有每声道音量（element 1 / 2）。
//  这就是为什么把它放进聚合设备后，系统音量键会失效（系统只会去找 master 音量）。
//  但直接写每声道音量是有效的，所以在 App 里自己做音量条。

/// 读取蓝牙播放设备（耳机的 :output）音量，返回 0…1
func halHeadsetVolume() -> Float32? {
    guard let dev = bluetoothPlaybackDevice() else { return nil }
    var addr = halAddr(kAudioDevicePropertyVolumeScalar, Scope.output, 1)
    guard AudioObjectHasProperty(dev.id, &addr) else { return nil }
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let st = withUnsafeMutablePointer(to: &v) { p in
        p.withMemoryRebound(to: UInt8.self, capacity: 4) { AudioObjectGetPropertyData(dev.id, &addr, 0, nil, &size, $0) }
    }
    return st == noErr ? v : nil
}

/// 设置蓝牙播放设备音量（0…1），写到所有声道
@discardableResult
func halSetHeadsetVolume(_ value: Float32) -> OSStatus {
    guard let dev = bluetoothPlaybackDevice() else { return kAudioHardwareBadDeviceError }
    let v = min(max(value, 0), 1)
    var worst = noErr
    for elem in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
        var addr = halAddr(kAudioDevicePropertyVolumeScalar, Scope.output, elem)
        guard AudioObjectHasProperty(dev.id, &addr) else { continue }
        let st = withUnsafePointer(to: v) { p in
            AudioObjectSetPropertyData(dev.id, &addr, 0, nil, 4, UnsafeRawPointer(p))
        }
        if st != noErr { worst = st }
    }
    return worst
}

/// 蓝牙播放设备静音开关
func halHeadsetMuted() -> Bool? {
    guard let dev = bluetoothPlaybackDevice() else { return nil }
    var addr = halAddr(kAudioDevicePropertyMute, Scope.output, kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(dev.id, &addr) else { return nil }
    var m: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let st = withUnsafeMutablePointer(to: &m) { p in
        p.withMemoryRebound(to: UInt8.self, capacity: 4) { AudioObjectGetPropertyData(dev.id, &addr, 0, nil, &size, $0) }
    }
    return st == noErr ? (m != 0) : nil
}

@discardableResult
func halSetHeadsetMuted(_ muted: Bool) -> OSStatus {
    guard let dev = bluetoothPlaybackDevice() else { return kAudioHardwareIllegalOperationError }
    var addr = halAddr(kAudioDevicePropertyMute, Scope.output, kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(dev.id, &addr) else { return kAudioHardwareIllegalOperationError }
    let m: UInt32 = muted ? 1 : 0
    return withUnsafePointer(to: m) { p in
        AudioObjectSetPropertyData(dev.id, &addr, 0, nil, 4, UnsafeRawPointer(p))
    }
}
