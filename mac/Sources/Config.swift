import Foundation

/// Settings live in ~/Library/Application Support/FlowClone/config.env (KEY=value lines).
/// Environment variables override the file (handy for CLI test runs).
struct Config {
    var apiKey: String
    var model: String
    var hotkey: String
    var dictionary: [String]
    var sendContext: Bool
    var saveAudio: Bool
    var muteAudio: Bool
    var sounds: Bool
    var micUID: String

    /// Release builds for friends are compiled with `-D LOCKED_MODEL`: the model is fixed to Flash-Lite
    /// so a shared, capped key can't be drained by the ~18× pricier Flash.
    #if LOCKED_MODEL
    static let modelLocked = true
    #else
    static let modelLocked = false
    #endif
    static let lockedModel = "google/gemini-3.5-flash-lite"

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FlowClone")
    static var file: URL { dir.appendingPathComponent("config.env") }
    /// Optional system-prompt override, re-read on every dictation so prompt changes need no rebuild.
    static var promptFile: URL { dir.appendingPathComponent("prompt.txt") }
    static var recordingsDir: URL { dir.appendingPathComponent("recordings") }

    static func load() -> Config {
        var kv: [String: String] = [:]
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
                let key = t[..<eq].trimmingCharacters(in: .whitespaces)
                let value = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                kv[key] = value
            }
        }
        let env = ProcessInfo.processInfo.environment
        // Environment wins, so tests can do `MODEL=... FlowClone --transcribe ...` without editing the file.
        func get(_ key: String, _ fallback: String) -> String {
            if let v = env[key], !v.isEmpty { return v }
            if let v = kv[key], !v.isEmpty { return v }
            return fallback
        }
        return Config(
            apiKey: get("OPENROUTER_API_KEY", ""),
            model: modelLocked ? lockedModel : get("MODEL", lockedModel),
            hotkey: get("HOTKEY", "fn"),
            dictionary: get("DICTIONARY", "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            sendContext: get("SEND_CONTEXT", "1") != "0",
            saveAudio: get("SAVE_AUDIO", "1") != "0",
            muteAudio: get("MUTE_AUDIO", "1") != "0",
            sounds: get("SOUNDS", "1") != "0",
            micUID: get("MIC", "")
        )
    }

    /// Updates or appends one KEY=value line, keeping the rest of the file intact (used by menu toggles).
    static func set(_ key: String, _ value: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + "=") }) {
            lines[i] = "\(key)=\(value)"
        } else {
            lines.append("\(key)=\(value)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
