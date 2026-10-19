import AppKit
import ApplicationServices

/// What Wispr's Swift helper reads through Accessibility before a dictation: the focused app and
/// the text just before the cursor (used for continuity and capitalization).
struct FocusContext {
    var appName = ""
    var bundleID = ""
    var before = ""

    static let empty = FocusContext()

    static func capture() -> FocusContext {
        var ctx = FocusContext()
        let app = NSWorkspace.shared.frontmostApplication
        ctx.appName = app?.localizedName ?? ""
        ctx.bundleID = app?.bundleIdentifier ?? ""

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return ctx }
        let el = ref as! AXUIElement

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return ctx } // never read password fields

        var value: CFTypeRef?
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let r = range, CFGetTypeID(r) == AXValueGetTypeID() else { return ctx }
        var cf = CFRange()
        AXValueGetValue(r as! AXValue, .cfRange, &cf)
        let ns = text as NSString
        let end = max(0, min(cf.location, ns.length))
        let start = max(0, end - 500)
        ctx.before = ns.substring(with: NSRange(location: start, length: end - start))
        return ctx
    }
}

/// Inserts text the way Wispr does: put it on the clipboard lazily, send Cmd+V, and detect the paste by
/// watching for the target app to request the data. Then restore the user's clipboard.
/// Main-thread API: call `insert` from main.
final class Paster: NSObject, NSPasteboardItemDataProvider {
    static let shared = Paster()

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// One insertion in flight.
    private final class Job {
        let text: String
        let saved: [NSPasteboardItem]
        var changeCount = 0
        var delivered = false
        var reported = false
        var completion: ((Bool) -> Void)?
        var timeout: DispatchWorkItem?
        var restore: DispatchWorkItem?

        init(text: String, saved: [NSPasteboardItem], completion: @escaping (Bool) -> Void) {
            self.text = text
            self.saved = saved
            self.completion = completion
        }
    }

    private var job: Job?

    /// Puts `text` on the clipboard, posts Cmd+V, and calls `completion` exactly once on main:
    /// `true` once the target app requests the data, `false` if nothing requests it within ~1 s
    /// (the text is then left on the clipboard as a plain string for a manual Cmd+V).
    /// After a success the previous clipboard is restored ~1 s later, unless the user copied something since.
    func insert(_ text: String, completion: @escaping (Bool) -> Void) {
        if let previous = job { settle(previous) }

        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let d = item.data(forType: type) { copy.setData(d, forType: type) } }
            return copy
        }

        let current = Job(text: text, saved: saved, completion: completion)
        job = current

        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        // Tells clipboard managers not to record this temporary entry.
        item.setData(Data(), forType: Self.transientType)
        pb.clearContents()
        pb.writeObjects([item])
        current.changeCount = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        let timeout = DispatchWorkItem { [weak self] in self?.onTimeout(current) }
        current.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timeout)
    }

    /// Adds a leading space when continuing right after a word.
    static func spaced(_ text: String, after before: String) -> String {
        guard let last = before.last, !last.isWhitespace, let first = text.first,
              !",.!?;:)".contains(first) else { return text }
        return " " + text
    }

    // MARK: - NSPasteboardItemDataProvider

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .string, let current = job else { return }
        item.setString(current.text, forType: .string)
        if Thread.isMainThread {
            markDelivered(current)
        } else {
            DispatchQueue.main.async { [weak self] in self?.markDelivered(current) }
        }
    }

    // MARK: - Job lifecycle (main thread)

    private func markDelivered(_ current: Job) {
        guard job === current, !current.delivered, !current.reported else { return }
        current.delivered = true
        current.timeout?.cancel()
        report(current, success: true)

        let restore = DispatchWorkItem { [weak self] in self?.restoreClipboard(current) }
        current.restore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: restore)
    }

    private func onTimeout(_ current: Job) {
        guard job === current, !current.delivered else { return }
        current.timeout = nil
        job = nil
        materialize(current.text)
        report(current, success: false)
    }

    /// Finishes a job immediately (used when a new insertion starts before the previous one ended).
    private func settle(_ previous: Job) {
        previous.timeout?.cancel()
        previous.restore?.cancel()
        if job === previous { job = nil }
        if previous.delivered {
            restoreClipboard(previous)
        } else {
            materialize(previous.text)
            report(previous, success: false)
        }
    }

    private func restoreClipboard(_ current: Job) {
        current.restore = nil
        if job === current { job = nil }
        let pb = NSPasteboard.general
        // Only restore if nothing else has touched the clipboard since our write.
        guard pb.changeCount == current.changeCount else { return }
        pb.clearContents()
        if !current.saved.isEmpty { pb.writeObjects(current.saved) }
    }

    /// Leaves the text on the clipboard as a plain string (so the user can Cmd+V it manually).
    private func materialize(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func report(_ current: Job, success: Bool) {
        guard !current.reported else { return }
        current.reported = true
        let completion = current.completion
        current.completion = nil
        completion?(success)
    }
}

enum History {
    static func append(_ entry: [String: Any]) {
        let url = Config.dir.appendingPathComponent("history.jsonl")
        guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
            try? line.write(to: url)
        }
    }
}
