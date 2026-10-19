import Foundation

// Personal data shown in the Hub window: history, dictionary, snippets and per-app style.
// History stays in history.jsonl (one JSON object per line); the rest lives in personal.json.

struct HistoryEntry: Identifiable, Hashable {
    var id: String
    var date: Date
    var app: String
    var model: String
    var audioSeconds: Double
    var latency: Double
    var text: String
    /// File name inside `Config.recordingsDir`, when the audio was kept (enables "Retry").
    var audioFile: String?

    var words: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

struct Snippet: Identifiable, Codable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

enum StyleLevel: String, Codable, CaseIterable, Identifiable {
    case formal, casual, veryCasual
    var id: String { rawValue }

    var title: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }

    var example: String {
        switch self {
        case .formal: return "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual: return "Hey are you free for lunch tomorrow? Let's do 12 if that works for you"
        case .veryCasual: return "hey are you free for lunch tomorrow? let's do 12 if that works for you"
        }
    }

    /// Instruction appended to the transcription prompt.
    var instruction: String {
        switch self {
        case .formal: return "Use full sentences with proper capitalization and punctuation."
        case .casual: return "Keep capitalization, but use light punctuation and drop the final period of a message."
        case .veryCasual: return "Write like a quick chat message: all lowercase, minimal punctuation, no final period."
        }
    }
}

enum AppCategory: String, Codable, CaseIterable, Identifiable {
    case personal, work, email, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .personal: return "Personal messages"
        case .work: return "Work messages"
        case .email: return "Email"
        case .other: return "Other"
        }
    }

    var apps: String {
        switch self {
        case .personal: return "WhatsApp, Messages, Telegram, Discord"
        case .work: return "Slack, Teams, Google Chat"
        case .email: return "Mail, Gmail, Outlook, Superhuman"
        case .other: return "Everything else"
        }
    }

    /// Classifies the focused app. Browsers are classified by window title (e.g. "Inbox - Gmail").
    static func of(bundleID: String, windowTitle: String) -> AppCategory {
        let b = bundleID.lowercased()
        let t = windowTitle.lowercased()
        if b.contains("whatsapp") || b == "com.apple.mobilesms" || b.contains("telegram") || b.contains("discord")
            || t.contains("whatsapp") || t.contains("telegram") || t.contains("discord") || t.contains("messenger") {
            return .personal
        }
        if b.contains("slack") || b.contains("teams") || t.contains("slack") || t.contains("google chat") {
            return .work
        }
        if b == "com.apple.mail" || b.contains("outlook") || b.contains("superhuman") || b.contains("spark")
            || t.contains("gmail") || t.contains("outlook") || t.contains("inbox") {
            return .email
        }
        return .other
    }
}

/// Snapshot of personal data handed to the Transcriber (a value type, safe off the main thread).
struct Personalization {
    var dictionary: [String] = []
    var snippets: [Snippet] = []
    var style: StyleLevel?
}

struct Stats {
    var totalWords = 0
    var weekWords = 0
    var dictations = 0
    /// Speaking speed, words per minute of audio.
    var wpm = 0
    /// Time saved versus typing at 40 wpm, in hours.
    var hoursSaved = 0.0
    /// Consecutive days, ending today or yesterday, with at least one dictation.
    var streakDays = 0
    /// Estimated OpenRouter spend this calendar month, in USD.
    var monthCost = 0.0
}

/// Main-thread store observed by the Hub views. Every mutation is saved to disk immediately.
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var history: [HistoryEntry] = [] // newest first
    @Published var dictionary: [String] = [] { didSet { savePersonal() } }
    @Published var snippets: [Snippet] = [] { didSet { savePersonal() } }
    @Published var styles: [AppCategory: StyleLevel] = [:] { didSet { savePersonal() } }

    static var historyFile: URL { Config.dir.appendingPathComponent("history.jsonl") }
    static var personalFile: URL { Config.dir.appendingPathComponent("personal.json") }

    private var loading = false

    private struct Personal: Codable {
        var dictionary: [String]
        var snippets: [Snippet]
        var styles: [String: StyleLevel]
    }

    init() {
        loading = true
        let p = Self.loadPersonal()
        dictionary = p.dictionary
        snippets = p.snippets
        styles = Dictionary(uniqueKeysWithValues: p.styles.compactMap { k, v in AppCategory(rawValue: k).map { ($0, v) } })
        loading = false
        reloadHistory()
    }

    // MARK: History

    func reloadHistory() {
        guard let text = try? String(contentsOf: Self.historyFile, encoding: .utf8) else { history = []; return }
        let iso = ISO8601DateFormatter()
        var out: [HistoryEntry] = []
        for (i, line) in text.split(separator: "\n").enumerated() {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = o["text"] as? String else { continue }
            let date = (o["ts"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast
            out.append(HistoryEntry(
                id: o["id"] as? String ?? "legacy-\(i)-\(Int(date.timeIntervalSince1970))",
                date: date, app: o["app"] as? String ?? "", model: o["model"] as? String ?? "",
                audioSeconds: o["audio_s"] as? Double ?? 0, latency: o["latency_s"] as? Double ?? 0,
                text: t, audioFile: o["audio"] as? String))
        }
        history = out.reversed()
    }

    /// Called by Dictation after every successful dictation.
    func add(_ e: HistoryEntry) {
        history.insert(e, at: 0)
        var o: [String: Any] = [
            "id": e.id, "ts": ISO8601DateFormatter().string(from: e.date), "app": e.app, "model": e.model,
            "audio_s": e.audioSeconds, "latency_s": e.latency, "text": e.text,
        ]
        if let a = e.audioFile { o["audio"] = a }
        History.append(o)
    }

    func delete(_ id: String) {
        if let e = history.first(where: { $0.id == id }), let a = e.audioFile {
            try? FileManager.default.removeItem(at: Config.recordingsDir.appendingPathComponent(a))
        }
        history.removeAll { $0.id == id }
        rewriteHistory()
    }

    func clearHistory() {
        history = []
        rewriteHistory()
    }

    private func rewriteHistory() {
        let iso = ISO8601DateFormatter()
        let lines: [String] = history.reversed().compactMap { e in
            var o: [String: Any] = [
                "id": e.id, "ts": iso.string(from: e.date), "app": e.app, "model": e.model,
                "audio_s": e.audioSeconds, "latency_s": e.latency, "text": e.text,
            ]
            if let a = e.audioFile { o["audio"] = a }
            guard let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: Self.historyFile, atomically: true, encoding: .utf8)
    }

    var stats: Stats {
        var s = Stats()
        let cal = Calendar.current
        let now = Date()
        let weekAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        var seconds = 0.0
        var days = Set<Date>()
        for e in history {
            let w = e.words
            s.totalWords += w
            s.dictations += 1
            seconds += e.audioSeconds
            if e.date >= weekAgo { s.weekWords += w }
            if e.date >= monthStart { s.monthCost += e.audioSeconds * Self.costPerSecond(model: e.model) }
            days.insert(cal.startOfDay(for: e.date))
        }
        if seconds > 0 { s.wpm = Int(Double(s.totalWords) / (seconds / 60)) }
        s.hoursSaved = max(0, Double(s.totalWords) / 40 / 60 - seconds / 3600)
        var day = cal.startOfDay(for: now)
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        while days.contains(day) {
            s.streakDays += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return s
    }

    /// Measured OpenRouter cost per second of audio (benchmarks in docs/wispr-flow-analysis.md).
    static func costPerSecond(model: String) -> Double {
        model.contains("flash-lite") ? 0.000016 : model.contains("flash") ? 0.00048 : 0.00003
    }

    // MARK: Personalization

    func personalization(for ctx: FocusContext) -> Personalization {
        let category = AppCategory.of(bundleID: ctx.bundleID, windowTitle: ctx.windowTitle)
        return Personalization(dictionary: dictionary, snippets: snippets, style: styles[category])
    }

    /// Reads personal data straight from disk (used by the CLI replay mode).
    static func loadPersonalization() -> Personalization {
        let p = loadPersonal()
        return Personalization(dictionary: p.dictionary, snippets: p.snippets, style: nil)
    }

    private static func loadPersonal() -> Personal {
        if let d = try? Data(contentsOf: personalFile), let p = try? JSONDecoder().decode(Personal.self, from: d) {
            return p
        }
        // First run: migrate the old DICTIONARY= line from config.env.
        return Personal(dictionary: Config.load().dictionary, snippets: [], styles: [:])
    }

    private func savePersonal() {
        guard !loading else { return }
        let p = Personal(dictionary: dictionary, snippets: snippets,
                         styles: Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value) }))
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(p).write(to: Self.personalFile, options: .atomic)
    }
}
