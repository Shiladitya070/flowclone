import AppKit

// Replay mode: FlowClone --transcribe <files or folders…>
// Runs the real pipeline (decode → 16 kHz → m4a → OpenRouter) on every file in parallel. If
// `<name>.txt` exists next to a file it is shown as the reference. MODEL=… / FORMAT=wav override.
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--transcribe" {
    let config = Config.load()
    let audioExts: Set<String> = ["m4a", "wav", "mp3", "aiff", "aif", "caf", "flac", "aac"]
    var files: [URL] = []
    for path in args.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            files += items.filter { audioExts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        } else {
            files.append(url)
        }
    }
    let wantWav = ProcessInfo.processInfo.environment["FORMAT"] == "wav"
    let personalization = Store.loadPersonalization()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let started = Date()
        let results = await withTaskGroup(of: (Int, String).self) { group in
            for (i, file) in files.enumerated() {
                group.addTask {
                    let t0 = Date()
                    var out = "━━ \(file.lastPathComponent)\n"
                    do {
                        let pcm = try PCMConverter.pcmFromFile(file)
                        let (audio, fmt) = wantWav ? (PCMConverter.wav(pcm), "wav") : PCMConverter.encode(pcm)
                        let text = try await Transcriber(config: config).transcribe(audio: audio, format: fmt, context: .empty,
                                                                                    personalization: personalization)
                        out += String(format: "   %.1fs audio → %.2fs\n", Double(pcm.count) / 32000, Date().timeIntervalSince(t0))
                        let ref = file.deletingPathExtension().appendingPathExtension("txt")
                        if let r = try? String(contentsOf: ref, encoding: .utf8) { out += "   REF: \(r.trimmingCharacters(in: .whitespacesAndNewlines))\n" }
                        out += "   OUT: \(text)\n"
                    } catch {
                        out += "   error: \(error.localizedDescription)\n"
                    }
                    return (i, out)
                }
            }
            var all: [(Int, String)] = []
            for await r in group { all.append(r) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        results.forEach { print($0) }
        print(String(format: "%d file(s) with %@ in %.2fs", files.count, config.model, Date().timeIntervalSince(started)))
        done.signal()
    }
    done.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
