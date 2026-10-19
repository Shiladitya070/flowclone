import Foundation

/// One call does ASR + romanization + cleanup: Gemini (via OpenRouter chat completions) hears the
/// audio and returns the final text. This replaces Wispr's transcriber + formatter stages.
struct Transcriber {
    let config: Config

    static let systemPrompt = """
    You are a dictation engine. Turn the user's spoken audio into the exact text they want typed.
    - The speaker freely mixes English with Hindi and Bengali, often inside one sentence. Write \
    EVERYTHING in Roman (Latin) script: Hindi and Bengali words romanized the way Indians type in \
    chat (e.g. "kal meeting hai", "baadi jabo", "theek hai"), English words in normal English \
    spelling. Never translate; keep every word in the language it was spoken in.
    - Remove filler sounds (um, uh, hmm) and false starts. Apply spoken self-corrections \
    ("Tuesday, no wait, Wednesday" becomes "Wednesday"). Keep casual words like "like" and "yaar".
    - Add natural punctuation and capitalization. Do not paraphrase, summarize, or reply to the \
    content; if the speaker asks a question, transcribe the question.
    - If the audio has no clear human speech (silence, noise, breathing), output exactly NO_SPEECH. \
    Never invent words that were not spoken.
    Output only the text to type, with no quotes or commentary.
    """

    /// Opens the TLS connection to OpenRouter while the user is still speaking, so the real
    /// request reuses it (saves ~0.1–0.3 s on a cold connection).
    static func warmUp(apiKey: String) {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req).resume()
    }

    static func currentPrompt() -> String {
        if let custom = try? String(contentsOf: Config.promptFile, encoding: .utf8),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return custom }
        return systemPrompt
    }

    func transcribe(audio: Data, format: String, context: FocusContext,
                    personalization p: Personalization = Personalization()) async throws -> String {
        var notes: [String] = []
        if config.sendContext {
            if !context.appName.isEmpty { notes.append("Target app: \(context.appName)") }
            if !context.before.isEmpty {
                notes.append("Text already before the cursor (continue its style; do not repeat it):\n\"\"\"\(context.before)\"\"\"")
            }
        }
        if !p.dictionary.isEmpty {
            notes.append("Spell these names/terms exactly like this: \(p.dictionary.joined(separator: ", "))")
        }
        if !p.snippets.isEmpty {
            let list = p.snippets.map { "\"\($0.trigger)\" → \"\($0.expansion)\"" }.joined(separator: "\n")
            notes.append("Snippets: when the speaker says one of these trigger phrases, output the expansion text exactly instead of the phrase:\n\(list)")
        }
        if let style = p.style {
            notes.append("Formatting style for this app: \(style.instruction)")
        }
        let userText = notes.isEmpty ? "Transcribe this dictation." : "Context:\n" + notes.joined(separator: "\n") + "\n\nTranscribe this dictation."

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "reasoning": ["effort": "minimal"],
            "provider": ["sort": "latency"],
            "messages": [
                ["role": "system", "content": Self.currentPrompt()],
                ["role": "user", "content": [
                    ["type": "text", "text": userText],
                    ["type": "input_audio", "input_audio": ["data": audio.base64EncodedString(), "format": format]],
                ]],
            ],
        ]
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("FlowClone", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let request = req

        // Hedged request: if the first call hasn't answered in 3.5 s (a slow provider node), fire an
        // identical second one and take whichever finishes first. Typical calls take ~2 s, so the
        // hedge rarely fires.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await Self.send(request) }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_500_000_000)
                return try await Self.send(request)
            }
            defer { group.cancelAll() }
            var lastError: Error?
            for _ in 0..<2 {
                do {
                    if let text = try await group.next() { return text }
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? NSError(domain: "OpenRouter", code: -1)
        }
    }

    private static func send(_ req: URLRequest) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw NSError(domain: "OpenRouter", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(msg)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw NSError(domain: "OpenRouter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response"])
        }
        let text = Self.clean(message["content"] as? String ?? "")
        return text.contains("NO_SPEECH") && text.count < 20 ? "" : text
    }

    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") { t = t.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n") }
        if t.count >= 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "“" && l == "”") {
            t = String(t.dropFirst().dropLast())
        }
        return removeFillers(t.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Standalone English filler sounds, whole words only ("hum", "umbrella", "human" are untouched).
    /// The lookarounds also refuse a letter/digit/underscore/apostrophe/hyphen on either side.
    private static let fillerRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_'’-])(uh|uhh|um|umm|uhm|erm|hmm)(?![\\p{L}\\p{N}_'’-])",
        options: [.caseInsensitive])

    private static func removeFillers(_ input: String) -> String {
        var text = input
        var removed = false
        while let m = fillerRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) {
            removed = true
            text = splice(before: String(text[..<r.lowerBound]), after: String(text[r.upperBound...]))
        }
        guard removed else { return input }

        // Collapse the gaps left behind and drop spaces before punctuation.
        var out = text.replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "[ \t]+([,.!?;])", with: "$1", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing left but punctuation (only fillers were spoken) means nothing to type.
        return out.contains(where: { $0.isLetter || $0.isNumber }) ? out : ""
    }

    /// Joins the text around one removed filler.
    private static func splice(before: String, after: String) -> String {
        var pre = Substring(before)
        while let c = pre.last, c.isWhitespace { pre.removeLast() }
        let sentenceStart = pre.isEmpty || [".", "!", "?", "…"].contains(pre.last!)

        if sentenceStart {
            // "Uh, take" -> "Take"; "done. Um so" -> "done. So"
            let rest = after.drop(while: { $0.isWhitespace || ",.;:!?".contains($0) })
            var word = String(rest)
            if let f = word.first { word = f.uppercased() + String(word.dropFirst()) }
            return pre.isEmpty ? word : String(pre) + " " + word
        }

        // Mid-sentence: "make it, uh, better" -> "make it better"; "kya hum uh chalte" -> "kya hum chalte"
        if pre.last == "," { pre.removeLast() }
        let rest = String(after.drop(while: { $0.isWhitespace || $0 == "," }))
        return rest.isEmpty ? String(pre) : String(pre) + " " + rest
    }
}
