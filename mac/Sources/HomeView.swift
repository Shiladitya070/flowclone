import AppKit
import SwiftUI

// Hub "Home" page, modelled on Wispr Flow's: a greeting, usage stats, and a searchable
// history of dictations grouped by day. Rows offer copy / retry / delete on hover and in a context menu.

/// How many history rows are rendered before "Show more".
private let homePageSize = 100

struct HomeView: View {
    @ObservedObject var store: Store
    @State private var query = ""
    @State private var limit = homePageSize

    var body: some View {
        let stats = store.stats
        VStack(alignment: .leading, spacing: 32) {
            PageHeader(title: greeting, subtitle: "Hold Fn to dictate anywhere · double-tap for hands-free")
            statGrid(stats)
            historySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: query) { _, _ in limit = homePageSize }
    }

    private var greeting: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Welcome back" : "Welcome back, \(first)"
    }

    // MARK: Stats

    private func statGrid(_ s: Stats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            HomeStatCard(value: s.totalWords.formatted(), caption: "Total words", symbol: "text.alignleft")
            HomeStatCard(value: s.weekWords.formatted(), caption: "Words this week", symbol: "calendar")
            HomeStatCard(value: "\(s.wpm)", caption: "Speaking speed (wpm)", symbol: "speedometer")
            HomeStatCard(value: String(format: "%.1f", s.hoursSaved), caption: "Hours saved vs. typing", symbol: "clock")
            HomeStatCard(value: "\(s.streakDays)", caption: "Day streak", symbol: "flame")
            HomeStatCard(value: homeCostText(s.monthCost), caption: "Cost this month", symbol: "dollarsign.circle")
        }
    }

    // MARK: History

    private var filteredHistory: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.history }
        return store.history.filter {
            $0.text.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q)
        }
    }

    private var historySection: some View {
        let filtered = filteredHistory
        let shown = Array(filtered.prefix(limit))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("History").font(Theme.title(22))
                Spacer()
                searchField
            }

            if store.history.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text("No dictations match \"\(query)\".")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(homeGroupByDay(shown)) { group in
                        daySection(group)
                    }
                }
                if filtered.count > shown.count {
                    Button {
                        limit += homePageSize
                    } label: {
                        Text("Show more (\(filtered.count - shown.count) left)")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search history", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 180)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
    }

    private func daySection(_ group: HomeDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(homeDayTitle(group.day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        HomeHistoryRow(entry: entry, store: store)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                Text("Your dictations will appear here")
                    .font(Theme.title(20))
                Text("Dictate in any app and every result is saved here.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    HomeStep(number: "1", text: "Hold Fn")
                    HomeStep(number: "2", text: "Speak naturally")
                    HomeStep(number: "3", text: "Release to type it where your cursor is")
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: Helpers

/// "$0.00"-style money, showing "<$0.01" for tiny non-zero amounts.
private func homeCostText(_ usd: Double) -> String {
    if usd > 0 && usd < 0.01 { return "<$0.01" }
    return String(format: "$%.2f", usd)
}

/// "Today", "Yesterday", or "Mon, 19 Oct".
private func homeDayTitle(_ day: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(day) { return "Today" }
    if cal.isDateInYesterday(day) { return "Yesterday" }
    return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
}

/// A run of consecutive entries that share a calendar day (history is newest first).
private struct HomeDayGroup: Identifiable {
    let day: Date
    var entries: [HistoryEntry]
    var id: Date { day }
}

private func homeGroupByDay(_ entries: [HistoryEntry]) -> [HomeDayGroup] {
    let cal = Calendar.current
    var groups: [HomeDayGroup] = []
    for entry in entries {
        let day = cal.startOfDay(for: entry.date)
        if let last = groups.indices.last, groups[last].day == day {
            groups[last].entries.append(entry)
        } else {
            groups.append(HomeDayGroup(day: day, entries: [entry]))
        }
    }
    return groups
}

// MARK: Subviews

/// Rounded stat tile: an accent icon, a large figure and a caption.
private struct HomeStatCard: View {
    let value: String
    let caption: String
    let symbol: String

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Numbered instruction line for the empty state.
private struct HomeStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Theme.accent, in: Circle())
            Text(text)
        }
    }
}

/// One dictation: time, app tag, transcript and a meta line. Actions appear on hover and in the context menu.
private struct HomeHistoryRow: View {
    let entry: HistoryEntry
    let store: Store

    @State private var hovering = false
    /// Brief inline feedback such as "Copied"; cleared after ~1.5 s.
    @State private var note: String?

    private var canRetry: Bool { entry.audioFile != nil }
    /// Hidden when the entry was already transcribed with Gemini Flash (not Flash-Lite).
    private var offersFlashRetry: Bool {
        !Config.modelLocked && !(entry.model.contains("flash") && !entry.model.contains("flash-lite"))
    }
    private var retryHelp: String {
        canRetry ? "Retry transcription" : "Audio wasn't kept for this dictation"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(entry.date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "en_GB"))))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: 48, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    appTag
                    Spacer(minLength: 8)
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    actions
                        .opacity(hovering ? 1 : 0)
                }
                // Not `.textSelection(.enabled)`: on macOS 27 selectable Text inside this LazyVStack
                // renders upside down. Copy is available from the row actions and context menu.
                Text(entry.text)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: note)
        .contextMenu {
            Button("Copy") { copy() }
            Button("Retry") { retry(nil) }
                .disabled(!canRetry)
            if offersFlashRetry {
                Button("Retry with Flash") { retry("google/gemini-3.5-flash") }
                    .disabled(!canRetry)
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(entry.id) }
        }
    }

    private var appTag: some View {
        Text(entry.app.isEmpty ? "Unknown app" : entry.app)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var actions: some View {
        HStack(spacing: 2) {
            rowButton("doc.on.doc", help: "Copy") { copy() }
            rowButton("arrow.clockwise", help: retryHelp, disabled: !canRetry) { retry(nil) }
            if offersFlashRetry {
                rowButton("bolt", help: canRetry ? "Retry with Flash" : retryHelp, disabled: !canRetry) {
                    retry("google/gemini-3.5-flash")
                }
            }
            rowButton("trash", help: "Delete") { store.delete(entry.id) }
        }
    }

    private func rowButton(_ symbol: String, help: String, disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .help(help)
    }

    /// "12.5 s · 1.8 s · flash-lite": audio length, latency, model.
    private var metaLine: String {
        var parts = [String(format: "%.1f s", entry.audioSeconds), String(format: "%.1f s", entry.latency)]
        if let model = entry.model.split(separator: "/").last, !model.isEmpty {
            parts.append(String(model))
        }
        return parts.joined(separator: " · ")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        flash("Copied")
    }

    /// Re-transcribes the saved audio; the result is copied and added to history by the app.
    private func retry(_ model: String?) {
        let started = HubActions.shared.retry(entry, model)
        flash(started ? "Retrying… result will be copied" : "Couldn't retry")
    }

    private func flash(_ message: String) {
        note = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if note == message { note = nil }
        }
    }
}
