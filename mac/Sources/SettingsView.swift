import AppKit
import SwiftUI

/// The Hub's Settings page. Every change is written straight to config.env and pushed to the running app.
struct SettingsView: View {
    @ObservedObject private var store = Store.shared

    // General
    @State private var hotkey = "fn"
    @State private var micUID = ""
    @State private var devices: [AudioDevices.Device] = []
    @State private var sounds = true
    @State private var muteAudio = true
    @State private var launchAtLogin = false
    @State private var loginError: String?

    // Transcription
    @State private var model = "google/gemini-3.5-flash-lite"
    @State private var savedKey = ""
    @State private var keyDraft = ""
    @State private var keyTest: KeyTestState = .idle
    @State private var sendContext = true
    @State private var saveAudio = true

    // Data
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Settings", subtitle: "Tune how FlowClone listens, transcribes and stores your data.")

            section("General") {
                row("Dictation key", "Hold this key to talk. Double-tap for hands-free.") {
                    Picker("", selection: bind($hotkey, key: "HOTKEY") { $0 }) {
                        ForEach(Self.hotkeys, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                divider
                row("Microphone", "Which input FlowClone records from.") {
                    HStack(spacing: 6) {
                        Picker("", selection: bind($micUID, key: "MIC") { $0 }) {
                            Text("System default (\(AudioDevices.defaultInputName() ?? "unknown"))").tag("")
                            ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
                            if !micUID.isEmpty, !devices.contains(where: { $0.uid == micUID }) {
                                Text("Unavailable device").tag(micUID)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Button(action: refreshDevices) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Re-scan audio devices")
                    }
                }
                divider
                row("Sounds", "Play a soft chime when recording starts and stops.") {
                    Toggle("", isOn: bind($sounds, key: "SOUNDS", bool)).labelsHidden().toggleStyle(.switch)
                }
                divider
                row("Mute other audio while dictating", "Silences music and videos until you finish.") {
                    Toggle("", isOn: bind($muteAudio, key: "MUTE_AUDIO", bool)).labelsHidden().toggleStyle(.switch)
                }
                divider
                row("Launch at login", LoginItem.isAvailable ? "Start FlowClone when you log in." : "Install to /Applications first.") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Toggle("", isOn: loginBinding).labelsHidden().toggleStyle(.switch)
                            .disabled(!LoginItem.isAvailable)
                        if let loginError {
                            Text(loginError).font(.caption).foregroundStyle(.red)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            section("Transcription") {
                row("Model", "Trades speed and cost against accuracy.") {
                    Picker("", selection: bind($model, key: "MODEL") { $0 }) {
                        ForEach(Self.models, id: \.id) { Text($0.label).tag($0.id) }
                        if !Self.models.contains(where: { $0.id == model }) {
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                divider
                apiKeyBlock
                divider
                row("Use context from the focused app",
                    "Sends the app name and the text before your cursor so punctuation and names flow naturally.") {
                    Toggle("", isOn: bind($sendContext, key: "SEND_CONTEXT", bool)).labelsHidden().toggleStyle(.switch)
                }
                divider
                row("Keep audio for Retry", "Keeps the last 300 recordings on this Mac.") {
                    Toggle("", isOn: bind($saveAudio, key: "SAVE_AUDIO", bool)).labelsHidden().toggleStyle(.switch)
                }
            }

            section("Data & privacy") {
                row("Config file", "API key, dictation key and preferences, stored locally.") {
                    Button("Open") { openConfigFile() }
                }
                divider
                row("Recordings folder", "Audio kept for Retry when \u{201C}Keep audio\u{201D} is on.") {
                    Button("Open") { openFolder(Config.recordingsDir) }
                }
                divider
                row("Data folder", "History, dictionary, snippets and settings.") {
                    Button("Open") { openFolder(Config.dir) }
                }
                divider
                row("Clear history", "Removes \(store.history.count) saved transcript\(store.history.count == 1 ? "" : "s"). This can\u{2019}t be undone.") {
                    Button("Clear\u{2026}", role: .destructive) { confirmClear = true }
                        .disabled(store.history.isEmpty)
                }
            }
            .confirmationDialog("Clear all transcription history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { Store.shared.clearHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes \(store.history.count) transcript\(store.history.count == 1 ? "" : "s").")
            }

            section("Help") {
                VStack(alignment: .leading, spacing: 12) {
                    shortcut("Hold \(hotkeyLabel)", "Dictate")
                    shortcut("Double-tap \(hotkeyLabel)", "Hands-free dictation")
                    shortcut("Esc", "Cancel")
                    shortcut("\u{2303}\u{2325}V", "Paste last transcript")
                }
                .padding(18)
                divider
                row("FlowClone \(Self.version)", "Guides you through permissions and setup again.") {
                    Button("Open Setup Guide") { HubActions.shared.openSetupGuide() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: load)
    }

    // MARK: - API key block

    private var apiKeyBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenRouter API key").font(.body)
                    Text("Powers transcription. Stored only on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(savedKey.isEmpty ? "No key saved" : Self.mask(savedKey))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                SecureField("Paste a new key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveDraft)
                Button("Save", action: saveDraft)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Test", action: testKey)
                    .disabled(savedKey.isEmpty && keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if keyTest != .idle {
                keyTestLabel
            }
        }
        .padding(18)
    }

    @ViewBuilder private var keyTestLabel: some View {
        switch keyTest {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking key\u{2026}").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .ok(let detail):
            Text("\u{2705} Key works\(detail)").font(.callout)
        case .failed(let reason):
            Text("\u{274C} \(reason)").font(.callout).foregroundStyle(.red)
        }
    }

    // MARK: - Layout helpers

    /// A titled white card holding one or more rows.
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            Card(padding: 0) {
                VStack(spacing: 0) { content() }
            }
        }
    }

    /// Label and caption on the left, control on the right.
    private func row<Control: View>(_ title: String, _ caption: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                Text(caption).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Divider().padding(.horizontal, 18)
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 14) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
                .frame(minWidth: 150, alignment: .leading)
            Text(action).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Data

    private func load() {
        let c = Config.load()
        hotkey = c.hotkey
        micUID = c.micUID
        sounds = c.sounds
        muteAudio = c.muteAudio
        model = c.model
        savedKey = c.apiKey
        sendContext = c.sendContext
        saveAudio = c.saveAudio
        launchAtLogin = LoginItem.isEnabled
        refreshDevices()
    }

    private func refreshDevices() {
        devices = AudioDevices.inputs()
    }

    /// Two-way binding that writes the value to config.env and tells the running app to reload.
    private func bind<T>(_ state: Binding<T>, key: String, _ encode: @escaping (T) -> String) -> Binding<T> {
        Binding(
            get: { state.wrappedValue },
            set: { value in
                state.wrappedValue = value
                Config.set(key, encode(value))
                HubActions.shared.configChanged()
            })
    }

    private func bool(_ value: Bool) -> String { value ? "1" : "0" }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { on in
                do {
                    try LoginItem.set(on)
                    loginError = nil
                } catch {
                    loginError = "Couldn\u{2019}t change login item: \(error.localizedDescription)"
                }
                launchAtLogin = LoginItem.isEnabled
            })
    }

    private var hotkeyLabel: String {
        Self.hotkeys.first { $0.id == hotkey }?.label ?? "Fn"
    }

    /// Stores the typed key; the draft is cleared so the secret does not linger in the field.
    private func saveDraft() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Config.set("OPENROUTER_API_KEY", key)
        HubActions.shared.configChanged()
        savedKey = key
        keyDraft = ""
        keyTest = .idle
    }

    /// Checks the typed key if there is one, otherwise the saved key. The key is never logged.
    private func testKey() {
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? savedKey : typed
        guard !key.isEmpty else { return }
        keyTest = .testing
        Task {
            keyTest = await Self.checkKey(key)
        }
    }

    private static func checkKey(_ key: String) async -> KeyTestState {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return .failed("Key rejected (HTTP \(status))")
            }
            var detail = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let info = json["data"] as? [String: Any],
               let remaining = info["limit_remaining"] as? Double {
                detail = " \u{00B7} $" + String(format: "%.2f", remaining) + " credit left"
            }
            return .ok(detail)
        } catch {
            return .failed("Couldn\u{2019}t reach OpenRouter: \(error.localizedDescription)")
        }
    }

    private func openConfigFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Config.file.path) {
            fm.createFile(atPath: Config.file.path, contents: nil)
        }
        NSWorkspace.shared.open(Config.file)
    }

    private func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// Masks a key as "sk-or-v1-…e0e9" so only the prefix and last four characters show.
    static func mask(_ key: String) -> String {
        guard key.count > 13 else { return "••••••••" }
        return String(key.prefix(9)) + "…" + String(key.suffix(4))
    }

    private static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    // MARK: - Static options

    fileprivate struct Option: Identifiable {
        let id: String
        let label: String
    }

    fileprivate static let hotkeys: [Option] = [
        Option(id: "fn", label: "Fn \u{1F310}"),
        Option(id: "right_option", label: "Right \u{2325}"),
        Option(id: "right_command", label: "Right \u{2318}"),
        Option(id: "right_control", label: "Right \u{2303}"),
    ]

    fileprivate static let models: [Option] = [
        Option(id: "google/gemini-3.5-flash-lite", label: "Gemini 3.5 Flash-Lite \u{2014} fast, ~$0.06/hour of speech"),
        Option(id: "google/gemini-3.5-flash", label: "Gemini 3.5 Flash \u{2014} most accurate, ~$1.70/hour"),
    ]
}

/// Result of the OpenRouter key check shown under the API key row.
fileprivate enum KeyTestState: Equatable {
    case idle
    case testing
    case ok(String)
    case failed(String)
}
