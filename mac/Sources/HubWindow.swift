import AppKit
import SwiftUI

// The main app window ("Hub", like Wispr Flow's): sidebar + Home / Dictionary / Snippets / Style / Settings.
// While it's open the app shows a Dock icon; closing it returns FlowClone to a menu-bar-only app.

enum HubSection: String, CaseIterable, Identifiable {
    case home, dictionary, snippets, style, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "book.closed"
        case .snippets: return "scissors"
        case .style: return "textformat"
        case .settings: return "gearshape"
        }
    }
}

/// Hooks from the Hub views back into the running app. Set up by AppDelegate.
final class HubActions {
    static let shared = HubActions()
    /// Re-transcribes a history entry's audio (nil model = current model); false if not possible.
    var retry: (HistoryEntry, String?) -> Bool = { _, _ in false }
    /// Call after writing settings with `Config.set` so the running app picks them up.
    var configChanged: () -> Void = {}
    var openSetupGuide: () -> Void = {}
}

// MARK: Shared look

enum Theme {
    /// Warm off-white in light mode, near-black in dark mode.
    static let background = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.11, alpha: 1) : NSColor(red: 0.976, green: 0.969, blue: 0.953, alpha: 1)
    })
    static let sidebar = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.085, alpha: 1) : NSColor(red: 0.949, green: 0.937, blue: 0.914, alpha: 1)
    })
    static let card = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.16, alpha: 1) : .white
    })
    static let border = Color.primary.opacity(0.08)
    static let accent = Color(red: 0.42, green: 0.33, blue: 0.93)

    static func title(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .semibold, design: .serif) }
}

/// White rounded card used across the Hub.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Page title + one-line description at the top of each section.
struct PageHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.title())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Window

final class HubWindow: NSObject, NSWindowDelegate {
    static let shared = HubWindow()

    private var window: NSWindow?
    private let model = HubModel()

    func show(_ section: HubSection? = nil) {
        if let section { model.section = section }
        Store.shared.reloadHistory()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "FlowClone"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 820, height: 560)
            w.contentViewController = NSHostingController(rootView: HubView(model: model, store: .shared))
            w.setContentSize(NSSize(width: 980, height: 660))
            w.center()
            w.setFrameAutosaveName("FlowCloneHub")
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app (no Dock icon) once the Hub is closed.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

final class HubModel: ObservableObject {
    @Published var section: HubSection = .home
}

struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 40)
                    .padding(.top, 36)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .background(Theme.background)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .home: HomeView(store: store)
        case .dictionary: DictionaryView(store: store)
        case .snippets: SnippetsView(store: store)
        case .style: StyleView(store: store)
        case .settings: SettingsView()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("FlowClone").font(.system(size: 17, weight: .semibold, design: .serif))
            }
            .padding(.horizontal, 10)
            .padding(.top, 44) // clears the traffic lights
            .padding(.bottom, 18)

            ForEach([HubSection.home, .dictionary, .snippets, .style]) { navItem($0) }
            Spacer()
            navItem(.settings)
            Button {
                HubActions.shared.openSetupGuide()
            } label: {
                Label("Setup Guide", systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 200)
        .background(Theme.sidebar)
    }

    private func navItem(_ s: HubSection) -> some View {
        let selected = model.section == s
        return Button {
            model.section = s
        } label: {
            Label(s.title, systemImage: s.symbol)
                .fontWeight(selected ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(selected ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.border : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
