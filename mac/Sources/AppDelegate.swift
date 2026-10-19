import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private var statusItem: NSStatusItem!
    private let monitor = InputMonitor()
    private lazy var dictation = Dictation(config: config)
    private var monitorRunning = false

    private let models = [
        ("google/gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite — fast, cheapest"),
        ("google/gemini-3.5-flash", "Gemini 3.5 Flash — most accurate, ~25× cost"),
    ]
    private let hotkeys = [("fn", "Fn 🌐"), ("right_option", "Right ⌥"), ("right_command", "Right ⌘"), ("right_control", "Right ⌃")]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self // rebuilt every time it opens, so checkmarks and devices are current
        statusItem.menu = menu
        setIcon(for: .idle)

        dictation.onPhaseChange = { [weak self] in self?.setIcon(for: $0) }

        monitor.setHotkey(config.hotkey)
        monitor.onTrigger = { [weak self] in self?.dictation.trigger($0) }
        monitor.onEscape = { [weak self] in self?.dictation.escape() ?? false }
        monitor.onPasteLast = { [weak self] in self?.dictation.pasteLast() }

        HubActions.shared.retry = { [weak self] entry, model in self?.dictation.retry(entry, model: model) ?? false }
        HubActions.shared.configChanged = { [weak self] in self?.reloadConfig() }
        HubActions.shared.openSetupGuide = { OnboardingWindow.shared.show() }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if OnboardingWindow.needsSetup { OnboardingWindow.shared.show() }
        startMonitorWhenTrusted()
    }

    /// Clicking the app in Finder/Spotlight/Dock while it's running opens the Hub.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HubWindow.shared.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.shutdown()
    }

    /// The event tap needs Accessibility; poll until it's granted (e.g. during onboarding).
    private func startMonitorWhenTrusted() {
        if AXIsProcessTrusted(), monitor.start() {
            monitorRunning = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startMonitorWhenTrusted() }
    }

    private func setIcon(for phase: Dictation.Phase) {
        let symbol: String
        switch phase {
        case .idle: symbol = "mic"
        case .recording(let locked): symbol = locked ? "mic.badge.plus" : "mic.fill"
        case .transcribing: symbol = "ellipsis.circle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FlowClone")
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "FlowClone")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        reloadConfig() // picks up hand edits to config.env (e.g. DICTIONARY)

        menu.addItem(item("Open FlowClone…", #selector(openHub)))
        menu.addItem(.separator())
        menu.addItem(disabled(statusText()))
        if !dictation.lastText.isEmpty {
            let t = dictation.lastText
            menu.addItem(item("Copy: " + (t.count > 50 ? String(t.prefix(50)) + "…" : t), #selector(copyLast)))
            let paste = item("Paste Last Transcript", #selector(pasteLast))
            paste.keyEquivalent = "v"
            paste.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(paste)
        }
        if dictation.lastFailed != nil {
            menu.addItem(item("Retry Last Failed Dictation", #selector(retryFailed)))
        }
        menu.addItem(.separator())

        // Microphone
        let micMenu = NSMenu()
        let def = item("System Default" + (AudioDevices.defaultInputName().map { " (\($0))" } ?? ""), #selector(pickMic(_:)))
        def.representedObject = ""
        def.state = config.micUID.isEmpty ? .on : .off
        micMenu.addItem(def)
        micMenu.addItem(.separator())
        for d in AudioDevices.inputs() {
            let i = item(d.name, #selector(pickMic(_:)))
            i.representedObject = d.uid
            i.state = d.uid == config.micUID ? .on : .off
            micMenu.addItem(i)
        }
        menu.addItem(submenu("Microphone", micMenu))

        // Model
        let modelMenu = NSMenu()
        for (id, title) in models {
            let i = item(title, #selector(pickModel(_:)))
            i.representedObject = id
            i.state = id == config.model ? .on : .off
            modelMenu.addItem(i)
        }
        menu.addItem(submenu("Model", modelMenu))

        // Hotkey
        let keyMenu = NSMenu()
        for (id, title) in hotkeys {
            let i = item(title, #selector(pickHotkey(_:)))
            i.representedObject = id
            i.state = id == config.hotkey ? .on : .off
            keyMenu.addItem(i)
        }
        menu.addItem(submenu("Dictation Key", keyMenu))

        menu.addItem(toggle("Mute Other Audio While Dictating", config.muteAudio, #selector(toggleMute)))
        menu.addItem(toggle("Sounds", config.sounds, #selector(toggleSounds)))
        let login = toggle("Launch at Login", LoginItem.isEnabled, #selector(toggleLogin))
        if !LoginItem.isAvailable {
            login.title = "Launch at Login (install to /Applications first)"
            login.action = nil
        }
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(item("Setup Guide…", #selector(showOnboarding)))
        menu.addItem(item("Open Config File", #selector(openConfig)))
        menu.addItem(item("Open History", #selector(openHistory)))
        menu.addItem(item("Open Recordings Folder", #selector(openRecordings)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FlowClone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func statusText() -> String {
        if config.apiKey.isEmpty { return "⚠️ No OpenRouter API key — open Setup Guide" }
        if !monitorRunning { return "⚠️ Waiting for Accessibility permission" }
        let key = hotkeys.first { $0.0 == config.hotkey }?.1 ?? config.hotkey
        var s = "Hold \(key) to dictate · double-tap for hands-free"
        if let l = dictation.lastLatency { s += String(format: "\nLast: %.1fs audio → %.1fs", l.audio, l.total) }
        return s
    }

    // MARK: Actions

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dictation.lastText, forType: .string)
    }

    @objc private func pasteLast() {
        // Let the menu close and focus return to the previous app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.dictation.pasteLast() }
    }

    @objc private func retryFailed() { dictation.retryLastFailed() }

    @objc private func pickMic(_ sender: NSMenuItem) { update("MIC", sender.representedObject as? String ?? "") }
    @objc private func pickModel(_ sender: NSMenuItem) { update("MODEL", sender.representedObject as? String ?? "") }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        update("HOTKEY", id)
    }

    @objc private func toggleMute() { update("MUTE_AUDIO", config.muteAudio ? "0" : "1") }
    @objc private func toggleSounds() { update("SOUNDS", config.sounds ? "0" : "1") }

    @objc private func toggleLogin() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            dictation.overlay.error("Launch at Login failed: \(error.localizedDescription)")
        }
    }

    @objc private func showOnboarding() { OnboardingWindow.shared.show() }
    @objc private func openHub() { HubWindow.shared.show(.home) }
    @objc private func openSettings() { HubWindow.shared.show(.settings) }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.file.path) { Config.set("MODEL", config.model) }
        NSWorkspace.shared.open(Config.file)
    }

    @objc private func openHistory() {
        NSWorkspace.shared.open(Config.dir.appendingPathComponent("history.jsonl"))
    }

    @objc private func openRecordings() {
        try? FileManager.default.createDirectory(at: Config.recordingsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Config.recordingsDir)
    }

    /// Persists a setting and reloads config everywhere.
    private func update(_ key: String, _ value: String) {
        Config.set(key, value)
        reloadConfig()
    }

    private func reloadConfig() {
        let old = config.hotkey
        config = Config.load()
        dictation.config = config
        if config.hotkey != old { monitor.setHotkey(config.hotkey) }
    }

    // MARK: Menu item helpers

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }
}
