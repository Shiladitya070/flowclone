import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// Live status of the three setup checks. Refreshed by OnboardingWindow's timer.
final class OnboardingModel: ObservableObject {
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var keyPresent = false

    var allDone: Bool { micGranted && axGranted && keyPresent }

    func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
        keyPresent = !Config.load().apiKey.isEmpty
    }
}

/// First-run setup window. Shown from the menu bar or automatically when `needsSetup` is true.
final class OnboardingWindow {
    static let shared = OnboardingWindow()

    static var needsSetup: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            || !AXIsProcessTrusted()
            || Config.load().apiKey.isEmpty
    }

    private let model = OnboardingModel()
    private var window: NSWindow?
    private var timer: Timer?

    private init() {}

    func show() {
        let w = window ?? makeWindow()
        window = w
        model.refresh()
        startTimer()
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let root = OnboardingView(model: model, onDone: { [weak self] in
            self?.window?.close()
        })
        let hosting = NSHostingController(rootView: root.tint(Theme.accent))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Set up FlowClone"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 460, height: hosting.view.fittingSize.height))
        w.isReleasedWhenClosed = false
        w.level = .floating
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak self] _ in
            self?.stopTimer()
        }
        return w
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.model.refresh()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Actions

private enum SetupActions {
    static let microphonePane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let keyboardPane = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"

    static func openPane(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    static func microphone(model: OnboardingModel) {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { model.refresh() }
            }
        } else {
            openPane(microphonePane)
        }
    }

    static func accessibility() {
        // Passing the prompt option makes macOS show its own "grant access" dialog as well.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPane(accessibilityPane)
    }

    static func openConfig() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Config.file.path) {
            try? fm.createDirectory(at: Config.dir, withIntermediateDirectories: true)
            let template = "OPENROUTER_API_KEY=\nMODEL=google/gemini-3.5-flash-lite\nHOTKEY=fn\n"
            fm.createFile(
                atPath: Config.file.path,
                contents: Data(template.utf8),
                attributes: [.posixPermissions: 0o600]
            )
        }
        NSWorkspace.shared.open(Config.file)
    }
}

// MARK: - Views

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onDone: () -> Void

    var body: some View {
        let micUndetermined = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up FlowClone")
                    .font(.title2.bold())
                Text("Hold Fn, speak, release — your words are typed where your cursor is.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                ChecklistRow(
                    title: "Microphone",
                    caption: "Needed to hear you while you hold the key.",
                    done: model.micGranted,
                    buttonTitle: micUndetermined ? "Allow" : "Open Settings",
                    action: { SetupActions.microphone(model: model) }
                )
                ChecklistRow(
                    title: "Accessibility",
                    caption: "Needed to detect the Fn key and type into other apps.",
                    done: model.axGranted,
                    buttonTitle: "Open Settings",
                    action: { SetupActions.accessibility() }
                )
                ChecklistRow(
                    title: "OpenRouter API key",
                    caption: "Add OPENROUTER_API_KEY to config.env.",
                    done: model.keyPresent,
                    buttonTitle: "Open Config",
                    action: { SetupActions.openConfig() }
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended: System Settings › Keyboard › “Press 🌐 key to” → Do Nothing")
                    .font(.callout)
                HStack {
                    Spacer()
                    Button("Open Keyboard Settings") { SetupActions.openPane(SetupActions.keyboardPane) }
                        .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))

            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcuts")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    shortcutRow("Hold Fn", "Dictate")
                    shortcutRow("Double-tap Fn", "Hands-free")
                    shortcutRow("Esc", "Cancel")
                    shortcutRow("⌃⌥V", "Paste last transcript")
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(model.allDone ? "Done" : "Continue Anyway") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
            Text(action)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ChecklistRow: View {
    let title: String
    let caption: String
    let done: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(buttonTitle, action: action)
                .controlSize(.small)
        }
    }
}
