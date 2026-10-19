import AppKit
import os

/// The dictation state machine: key gestures → record → transcribe → insert.
///
/// Gestures (same as Wispr Flow):
/// - hold the key, speak, release           → dictate
/// - double-tap the key                     → hands-free (keeps recording); tap again to finish
/// - Esc while recording or transcribing    → cancel, nothing is typed
final class Dictation {
    enum Phase: Equatable { case idle, recording(locked: Bool), transcribing }

    var config: Config
    /// Called on every phase change (menu bar icon), and after each result (menu "Last:" item).
    var onPhaseChange: ((Phase) -> Void)?
    var onResult: (() -> Void)?

    let overlay = Overlay()
    private let recorder = Recorder()
    private let ducker = AudioDucker()

    private(set) var phase: Phase = .idle { didSet { onPhaseChange?(phase) } }
    private(set) var lastText = ""
    private(set) var lastLatency: (audio: Double, total: Double)?
    private(set) var lastFailed: (audio: Data, format: String, context: FocusContext, seconds: Double)?

    private var context = FocusContext.empty
    private var keyDownAt = Date.distantPast
    private var pendingTap: DispatchWorkItem?
    private var ignoreNextKeyUp = false
    private var task: Task<Void, Never>?
    private var generation = 0

    /// A press shorter than this is a "tap" (possible first half of a double-tap).
    private let tapThreshold = 0.30
    /// How long to wait for the second tap.
    private let doubleTapWindow = 0.35

    init(config: Config) {
        self.config = config
        recorder.onLevel = { [weak self] in self?.overlay.level = $0 }
        recorder.onInterrupted = { [weak self] in
            Log.d("audio input lost mid-recording; stopping")
            // Mic route changed mid-recording (e.g. AirPods): keep what we have.
            if case .recording = self?.phase { self?.stop() }
        }
    }

    // MARK: Key gestures

    func trigger(_ down: Bool) {
        Log.d("key \(down ? "down" : "up") phase=\(phase) pendingTap=\(pendingTap != nil)")
        if down {
            if let tap = pendingTap { // second tap → hands-free
                tap.cancel()
                pendingTap = nil
                ignoreNextKeyUp = true
                phase = .recording(locked: true)
                overlay.handsFree()
                return
            }
            if phase == .recording(locked: true) { // tap while hands-free → finish
                ignoreNextKeyUp = true
                stop()
                return
            }
            guard phase == .idle else { return }
            keyDownAt = Date()
            start()
        } else {
            if ignoreNextKeyUp { ignoreNextKeyUp = false; return }
            guard phase == .recording(locked: false) else { return }
            if Date().timeIntervalSince(keyDownAt) < tapThreshold {
                // Keep recording briefly; a second tap within the window turns on hands-free.
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingTap = nil
                    self?.cancel(feedback: false)
                }
                pendingTap = work
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
            } else {
                stop()
            }
        }
    }

    /// Esc: returns true (swallow the key) only when there is something to cancel.
    func escape() -> Bool {
        guard phase != .idle else { return false }
        DispatchQueue.main.async { self.cancel(feedback: true) }
        return true
    }

    // MARK: Recording

    private func start() {
        guard !config.apiKey.isEmpty else {
            overlay.error("Add your OpenRouter key: menu bar › Setup Guide")
            return
        }
        Transcriber.warmUp(apiKey: config.apiKey)
        context = FocusContext.capture()
        do {
            try recorder.start(deviceUID: config.micUID)
        } catch {
            Log.d("recorder.start failed: \(error)")
            overlay.error("Mic error: \(error.localizedDescription)")
            return
        }
        phase = .recording(locked: false)
        overlay.listening()
        if config.sounds { play("Tink", volume: 0.35) }
        if config.muteAudio {
            // Let the start sound play before muting other audio.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, case .recording = self.phase else { return }
                self.ducker.mute()
            }
        }
    }

    private func stop() {
        guard case .recording = phase else { return }
        pendingTap?.cancel()
        pendingTap = nil
        let (pcm, seconds, peak) = recorder.stop()
        ducker.restore()
        Log.d(String(format: "stop: %.2fs audio, peak %.4f", seconds, peak))
        guard seconds >= 0.35 else { phase = .idle; overlay.hide(); return }
        guard peak > 0.004 else { phase = .idle; overlay.message("No speech detected"); return }
        if config.sounds { play("Pop", volume: 0.25) }
        let (audio, format) = PCMConverter.encode(pcm)
        transcribe(audio: audio, format: format, context: context, seconds: seconds)
    }

    func cancel(feedback: Bool) {
        Log.d("cancel feedback=\(feedback) phase=\(phase)")
        pendingTap?.cancel()
        pendingTap = nil
        switch phase {
        case .recording:
            _ = recorder.stop()
            ducker.restore()
        case .transcribing:
            task?.cancel()
            generation += 1 // drop any late result
        case .idle:
            return
        }
        phase = .idle
        if feedback { overlay.message("Cancelled", seconds: 1) } else { overlay.hide() }
    }

    /// Restores audio if the app quits mid-dictation.
    func shutdown() {
        _ = recorder.stop()
        ducker.restore()
    }

    // MARK: Transcription

    /// `paste: false` is used when re-transcribing from the Hub: the result is copied, not typed.
    private func transcribe(audio: Data, format: String, context ctx: FocusContext, seconds: Double,
                            model: String? = nil, paste: Bool = true) {
        phase = .transcribing
        overlay.transcribing()
        generation += 1
        let gen = generation
        var cfg = config
        if let model { cfg.model = model }
        let personalization = Store.shared.personalization(for: ctx)
        let started = Date()
        task = Task { @MainActor [weak self] in
            do {
                let text = try await Transcriber(config: cfg).transcribe(audio: audio, format: format, context: ctx,
                                                                         personalization: personalization)
                guard let self, gen == self.generation else { return }
                self.deliver(text, audio: audio, format: format, ctx: ctx, seconds: seconds,
                             latency: Date().timeIntervalSince(started), model: cfg.model, paste: paste)
            } catch {
                guard let self, gen == self.generation, !(error is CancellationError) else { return }
                self.failed(error, audio: audio, format: format, ctx: ctx, seconds: seconds)
            }
        }
    }

    private func deliver(_ text: String, audio: Data, format: String, ctx: FocusContext, seconds: Double,
                         latency: Double, model: String, paste: Bool) {
        phase = .idle
        lastFailed = nil
        guard !text.isEmpty else { overlay.message("No speech detected"); return }

        let audioFile = config.saveAudio ? Self.saveRecording(audio, format: format, text: text) : nil
        lastText = text
        lastLatency = (seconds, latency)
        print(String(format: "[%.1fs audio → %.2fs] %@: %@", seconds, latency, ctx.appName, text))
        Store.shared.add(HistoryEntry(
            id: UUID().uuidString, date: Date(), app: ctx.appName, model: model,
            audioSeconds: (seconds * 10).rounded() / 10, latency: (latency * 100).rounded() / 100,
            text: text, audioFile: audioFile))
        onResult?()
        if paste {
            insert(Paster.spaced(text, after: ctx.before))
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            overlay.message("New transcript copied to clipboard", seconds: 2)
        }
    }

    private func failed(_ error: Error, audio: Data, format: String, ctx: FocusContext, seconds: Double) {
        phase = .idle
        lastFailed = (audio, format, ctx, seconds)
        Self.saveRecording(audio, format: format, text: "FAILED: \(error.localizedDescription)")
        NSLog("FlowClone error: \(error)")
        if config.sounds { play("Basso", volume: 0.3) }
        overlay.error("Transcription failed — Retry from the menu bar")
        onResult?()
    }

    private func insert(_ text: String) {
        Paster.shared.insert(text) { [weak self] pasted in
            if pasted {
                self?.overlay.success()
            } else {
                self?.overlay.message("No text field focused — copied, press ⌘V", seconds: 3)
            }
        }
    }

    // MARK: Menu actions

    func pasteLast() {
        guard !lastText.isEmpty, phase == .idle else { return }
        insert(lastText)
    }

    func retryLastFailed() {
        guard let f = lastFailed, phase == .idle else { return }
        transcribe(audio: f.audio, format: f.format, context: f.context, seconds: f.seconds)
    }

    /// Hub "Retry": re-transcribes a history entry's saved audio (optionally with another model)
    /// and copies the result. Returns false if the audio wasn't kept or a dictation is in progress.
    @discardableResult
    func retry(_ entry: HistoryEntry, model: String? = nil) -> Bool {
        guard phase == .idle, let file = entry.audioFile,
              let audio = try? Data(contentsOf: Config.recordingsDir.appendingPathComponent(file)) else { return false }
        var ctx = FocusContext.empty
        ctx.appName = entry.app
        transcribe(audio: audio, format: (file as NSString).pathExtension, context: ctx,
                   seconds: entry.audioSeconds, model: model, paste: false)
        return true
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    /// Keeps dictation audio (and always failures) for Retry and `--transcribe <dir>` replays.
    /// Returns the audio file name. Only the newest `keepRecordings` files are kept.
    @discardableResult
    private static func saveRecording(_ audio: Data, format: String, text: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: Config.recordingsDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = f.string(from: Date())
        let base = Config.recordingsDir.appendingPathComponent(name)
        guard (try? audio.write(to: base.appendingPathExtension(format))) != nil else { return nil }
        try? text.write(to: base.appendingPathExtension("out.txt"), atomically: true, encoding: .utf8)
        pruneRecordings()
        return name + "." + format
    }

    private static let keepRecordings = 300

    private static func pruneRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Config.recordingsDir.path) else { return }
        let audio = files.filter { !$0.hasSuffix(".txt") }.sorted()
        guard audio.count > keepRecordings else { return }
        for name in audio.prefix(audio.count - keepRecordings) {
            let base = (name as NSString).deletingPathExtension
            try? fm.removeItem(at: Config.recordingsDir.appendingPathComponent(name))
            try? fm.removeItem(at: Config.recordingsDir.appendingPathComponent(base + ".out.txt"))
        }
    }
}

/// Diagnostics (public, not redacted). View with:
///   /usr/bin/log stream --predicate 'subsystem == "com.flowclone.app"'
enum Log {
    private static let logger = Logger(subsystem: "com.flowclone.app", category: "dictation")
    static func d(_ message: String) { logger.log("\(message, privacy: .public)") }
}
