import AppKit
import CoreAudio
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastSignature = ""

    private let engine = AudioEngine.shared

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine.onChange = { [weak self] in self?.refresh(force: true) }
        HFPWatcher.shared.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refresh(force: true)
        engine.enforce()

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showWelcome() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        HFPWatcher.shared.stop()
    }

    private var lastHFPSignature: String?

    private func tick() {
        let report = engine.enforce()

        // HFP 状态变化时写一条日志（通话降级就是这一刻）
        let hfp = engine.hfpState()
        let sig = hfp.isHFP ? "HFP" : "A2DP"
        if sig != lastHFPSignature {
            lastHFPSignature = sig
            let recs = processesRecording().map(\.name).joined(separator: ", ")
            engine.log(hfp.isHFP
                ? "🔴 蓝牙链路切到 HFP（音质变差） · \(hfp.detail) · 录音中: \(recs.isEmpty ? "无" : recs)"
                : "🟢 蓝牙链路回到 A2DP（高音质） · \(hfp.detail)")
        }

        refresh(force: report.switched)
    }

    // MARK: - 状态

    private var signature: String {
        let all = allDevices()
        let out = all.first { $0.id == halDefaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) }
        let inp = all.first { $0.id == halDefaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) }
        let hfp = engine.hfpState()
        let users = processesRecording().map { String($0.pid) }.joined(separator: ",")
        return "\(out?.uid ?? "")#\(inp?.uid ?? "")#\(hfp.isHFP)#\(users)#\(engine.isEnabled)#\(isLoginItemEnabled())"
    }

    private func refresh(force: Bool = false) {
        let sig = signature
        guard force || sig != lastSignature else { return }
        lastSignature = sig
        rebuildMenu()
    }

    // MARK: - 菜单

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let all = allDevices()
        let out = all.first { $0.id == halDefaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) }
        let inp = all.first { $0.id == halDefaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) }
        let hfp = engine.hfpState()
        let enabled = engine.isEnabled

        let title = NSMenuItem(title: "AirPod 音质保护", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        // 链路状态
        addInfo(to: menu,
                text: hfp.isHFP ? "🔴 耳机处于 HFP（音质变差）" : "🟢 耳机处于 A2DP（高音质）",
                bold: true,
                color: hfp.isHFP ? .systemRed : .systemGreen)
        if let out, out.isBluetooth { addInfo(to: menu, text: "　\(out.name) · \(hfp.detail)") }

        if let inp {
            let warn = inp.isBluetooth
            addInfo(to: menu, text: warn ? "⚠︎ 输入用了耳机麦克风：\(inp.name)" : "输入：\(inp.name)",
                    color: warn ? .systemRed : nil)
        }
        if engine.bluetoothMicInUse {
            addInfo(to: menu, text: "⚠︎ 耳机麦克风正在被使用（音质已降级）",
                    bold: true, color: .systemRed)
        }
        if enabled, let event = engine.lastEventDescription {
            addInfo(to: menu, text: "上次拉回：\(event)", color: .secondaryLabelColor)
        }
        menu.addItem(.separator())

        // 谁在录音
        let rec = processesRecording()
        if rec.isEmpty {
            addInfo(to: menu, text: "没有程序正在录音")
        } else {
            for p in rec {
                addInfo(to: menu, text: "🎤 \(p.name)", bold: true, color: .systemOrange)
            }
        }
        menu.addItem(.separator())

        // 蓝牙耳机
        let bs = engine.bluetoothDevices
        if !bs.isEmpty {
            let header = NSMenuItem(title: "蓝牙音频设备", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for d in bs {
                let role = d.uid.hasSuffix(":input") ? "麦克风侧" : (d.uid.hasSuffix(":output") ? "输出侧" : "")
                addInfo(to: menu, text: "  \(d.name)\(role.isEmpty ? "" : " · \(role)")")
                addInfo(to: menu, text: "    \(d.inputChannels) 入 / \(d.outputChannels) 出 · \(Int(d.sampleRate)) Hz",
                        color: .secondaryLabelColor)
            }
            menu.addItem(.separator())
        }

        menu.addItem(.separator())

        addVolumeControl(to: menu)

        let iconHeader = NSMenuItem(title: "菜单栏图标", action: nil, keyEquivalent: "")
        iconHeader.isEnabled = false
        menu.addItem(iconHeader)
        addIconPicker(to: menu)

        menu.addItem(.separator())

        addOutputModePicker(to: menu)

        let aggItem = NSMenuItem(title: "用聚合设备当默认输入",
                                 action: #selector(toggleAggregate), keyEquivalent: "")
        aggItem.target = self
        aggItem.state = engine.isAggregateActive ? .on : .off
        menu.addItem(aggItem)

        let guardItem = NSMenuItem(title: "看护默认输入（离开蓝牙麦克风）",
                                  action: #selector(toggleGuard), keyEquivalent: "")
        guardItem.target = self
        guardItem.state = enabled ? .on : .off
        menu.addItem(guardItem)

        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let apply = NSMenuItem(title: "立刻应用", action: #selector(manualApply), keyEquivalent: "r")
        apply.target = self
        menu.addItem(apply)

        let diag = NSMenuItem(title: "复制诊断报告", action: #selector(copyReport), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)

        let sound = NSMenuItem(title: "打开「系统设置 › 声音」", action: #selector(openSoundSettings), keyEquivalent: "")
        sound.target = self
        menu.addItem(sound)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateIcon(hfp: hfp.isHFP)
    }

    private func addInfo(to menu: NSMenu, text: String, bold: Bool = false, color: NSColor? = nil) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let baseFont = NSFont.menuFont(ofSize: 0)
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: bold ? NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold) : baseFont,
            .foregroundColor: color ?? NSColor.labelColor
        ])
        menu.addItem(item)
    }

    // MARK: - 菜单栏图标

    private struct IconChoice {
        let name: String
        let symbol: String
    }

    private static let iconChoices: [IconChoice] = [
        IconChoice(name: "AirPods", symbol: "airpods"),
        IconChoice(name: "AirPods Pro", symbol: "airpodspro"),
        IconChoice(name: "AirPods Max", symbol: "airpods.max"),
        IconChoice(name: "耳机", symbol: "headphones"),
        IconChoice(name: "耳塞", symbol: "earbuds"),
        IconChoice(name: "波形", symbol: "waveform"),
        IconChoice(name: "高保真音箱", symbol: "hifispeaker"),
        IconChoice(name: "隔空播放", symbol: "airplayaudio")
    ]

    private var chosenIconSymbol: String {
        let saved = UserDefaults.standard.string(forKey: "menubarSymbol")
        if let saved, Self.iconChoices.contains(where: { $0.symbol == saved }) { return saved }
        return "airpods"
    }

    private func updateIcon(hfp: Bool) {
        let symbol = chosenIconSymbol
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "AirPod 音质保护") {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.toolTip = hfp
                ? "AirPod 音质保护 — ⚠️ 耳机已降到 HFP，音质变差"
                : "AirPod 音质保护 — 耳机保持 A2DP 高音质"
        }
    }

    private func addIconPicker(to menu: NSMenu) {
        let current = chosenIconSymbol
        for choice in Self.iconChoices {
            let item = NSMenuItem(title: "　\(choice.name)", action: #selector(pickIcon(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.symbol
            item.state = choice.symbol == current ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func pickIcon(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }
        UserDefaults.standard.set(symbol, forKey: "menubarSymbol")
        refresh(force: true)
    }

    // MARK: - 音量控制
    //
    //  耳机的 :output 设备没有 master 音量通道，所以一旦默认输出是聚合设备，
    //  系统音量键就找不到可调的东西。直接写它的每声道音量是有效的，所以在菜单里自己做一个。

    @objc private func volumeChanged(_ sender: NSSlider) {
        engine.setHeadsetVolume(Float32(sender.doubleValue))
        if sender.doubleValue > 0, engine.isHeadsetMuted { engine.setHeadsetMuted(false) }
    }

    @objc private func toggleMute() {
        engine.setHeadsetMuted(!engine.isHeadsetMuted)
        refresh(force: true)
    }

    private func addVolumeControl(to menu: NSMenu) {
        guard engine.playbackDevice() != nil else { return }

        let muted = engine.isHeadsetMuted
        let slider = NSSlider(value: Double(engine.currentHeadsetVolume),
                              minValue: 0, maxValue: 1,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 26))
        slider.frame = NSRect(x: 6, y: 3, width: 198, height: 20)
        container.addSubview(slider)

        let sliderItem = NSMenuItem()
        sliderItem.view = container

        let title = muted ? "🔇 已静音（点此取消）" : String(format: "🔊 音量 %.0f%%", engine.currentHeadsetVolume * 100)
        let titleItem = NSMenuItem(title: title, action: #selector(toggleMute), keyEquivalent: "")
        titleItem.target = self
        titleItem.isEnabled = false
        titleItem.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: muted ? NSColor.systemRed : NSColor.labelColor
        ])
        // 让整行都可点（取消静音）
        let muteItem = NSMenuItem(title: muted ? "取消静音" : "静音",
                                  action: #selector(toggleMute), keyEquivalent: "")
        muteItem.target = self

        menu.addItem(sliderItem)
        menu.addItem(titleItem)
        menu.addItem(muteItem)
        menu.addItem(.separator())
    }

    @objc private func selectOutputMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String,
              let m = AudioEngine.OutputMode(rawValue: mode) else { return }
        engine.setOutputMode(m)
        refresh(force: true)
    }

    private func addOutputModePicker(to menu: NSMenu) {
        let header = NSMenuItem(title: "输出模式", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for mode in AudioEngine.OutputMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(selectOutputMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = engine.outputMode == mode ? .on : .off
            menu.addItem(item)
            let noteItem = NSMenuItem(title: "      \(mode.note)", action: nil, keyEquivalent: "")
            noteItem.isEnabled = false
            noteItem.attributedTitle = NSAttributedString(string: "      \(mode.note)", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            menu.addItem(noteItem)
        }
        menu.addItem(.separator())
    }

    // MARK: - 动作

    @objc private func toggleAggregate() {
        let turningOn = !engine.isAggregateActive
        engine.setUseAggregate(turningOn)
        refresh(force: true)
        if turningOn {
            present(title: "聚合设备已启用",
                    message: "现在系统里的默认音频设备是「\(AudioEngine.aggregateName)」：\n\n"
                           + "• 播放 → 蓝牙耳机（A2DP 立体声，不变）\n"
                           + "• 录音 → 笔记本内置麦克风\n\n"
                           + "微信这类会自己挑设备的程序，现在只能拿到笔记本麦克风，"
                           + "开不到蓝牙麦克风，所以不会切到 HFP。\n\n"
                           + "试试打语音通话，看菜单栏图标是否还是 🟢。")
        }
    }

    @objc private func toggleGuard() {
        engine.setEnabled(!engine.isEnabled)
        refresh(force: true)
    }

    @objc private func manualApply() {
        let r = engine.enforce()
        refresh(force: true)
        if r.switched {
            present(title: "已拉回默认输入", message: "\(r.from) → \(r.to)\n\n现在录音走笔记本麦克风，耳机只负责放声音。")
        } else if r.alreadySafe {
            present(title: "无需处理", message: "默认输入已经在非蓝牙麦克风上。")
        } else {
            present(title: "处理失败", message: "找不到可用的非蓝牙麦克风。请检查系统设置 › 声音 › 输入。")
        }
    }

    @objc private func copyReport() {
        let text = engine.snapshotLines().joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        present(title: "诊断报告已复制", message: "内容已复制到剪贴板，可直接粘贴给我。")
    }

    @objc private func openSoundSettings() {
        if #available(macOS 13.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane"))
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 开机启动

    private func isLoginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if isLoginItemEnabled() { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            present(title: "无法修改开机启动", message: "\(error.localizedDescription)\n\n请手动把应用拖到「系统设置 › 通用 › 登录项」。")
        }
        refresh(force: true)
    }

    // MARK: - 弹窗

    private func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showWelcome() {
        let msg = """
        作用：让蓝牙耳机始终保持 A2DP 立体声高音质，录音改走笔记本自带麦克风。

        macOS 27 已经不允许软件真正关闭一个蓝牙设备的麦克风，所以这里做的是：
        • 每秒检查一次，只要系统默认输入被切到耳机麦克风，就立刻拉回笔记本麦克风
          （FaceTime、通话、录屏等「使用默认输入」的程序都会被挡住）
        • 实时显示到底是哪个程序在占用麦克风 —— 那些自己挑设备、绕开默认值的
          程序（比如微信）只能去它自己的设置里改

        菜单栏图标：🟢 高音质　🔴 已降级（HFP）
        """
        present(title: "AirPod 音质保护已启动", message: msg)
    }
}