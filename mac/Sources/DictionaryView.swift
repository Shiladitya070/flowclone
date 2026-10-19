import SwiftUI

// Dictionary page: words and names the transcriber must spell exactly as written.

struct DictionaryView: View {
    @ObservedObject var store: Store
    @State private var input = ""
    @State private var query = ""
    @FocusState private var inputFocused: Bool

    /// Suggestions shown in the empty state; tapping one adds it.
    private let examples = ["Shiladitya", "Cooch Behar", "OpenRouter"]

    /// Alphabetical, case-insensitive, optionally filtered by the search field.
    private var visibleWords: [String] {
        let sorted = store.dictionary.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? sorted : sorted.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(
                title: "Dictionary",
                subtitle: "Words and names FlowClone should always spell exactly like this — names, places, brands, Hinglish spellings."
            )
            addRow
            if store.dictionary.isEmpty {
                emptyState
            } else {
                wordsCard
            }
        }
    }

    // MARK: Add

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Add a word or name…", text: $input)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit { addWords(parseWords(input)) }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))

                Button("Add") { addWords(parseWords(input)) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .disabled(parseWords(input).isEmpty)
            }
            Text("Separate several words with commas to add them at once.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Adds words that are not already present (case-insensitive). Store is only written when something changed.
    private func addWords(_ new: [String]) {
        var list = store.dictionary
        var seen = Set(list.map { $0.lowercased() })
        var added = false
        for word in new where seen.insert(word.lowercased()).inserted {
            list.append(word)
            added = true
        }
        if added { store.dictionary = list }
        input = ""
    }

    private func removeWord(_ word: String) {
        store.dictionary.removeAll { $0 == word }
    }

    // MARK: Content

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "book.closed")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                Text("No words yet")
                    .font(.headline)
                Text("Add names and terms that dictation often gets wrong. For example:")
                    .foregroundStyle(.secondary)
                AnyLayout(DictFlowLayout()) {
                    ForEach(examples, id: \.self) { word in
                        Button {
                            addWords([word])
                        } label: {
                            Label(word, systemImage: "plus")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 13))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var wordsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(store.dictionary.count) \(store.dictionary.count == 1 ? "word" : "words")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if store.dictionary.count > 8 {
                    searchField
                }

                if visibleWords.isEmpty {
                    Text("No words match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                        .foregroundStyle(.secondary)
                } else {
                    AnyLayout(DictFlowLayout()) {
                        ForEach(visibleWords, id: \.self) { word in
                            DictChip(word: word) { removeWord(word) }
                        }
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search words", text: $query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Splits comma-separated input into trimmed, non-empty words.
private func parseWords(_ text: String) -> [String] {
    text.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// A word shown as a pill; the × appears on hover.
private struct DictChip: View {
    let word: String
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(word)
                .font(.system(size: 13))
                .lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Remove")
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Color.primary.opacity(hovering ? 0.09 : 0.05), in: Capsule())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Wraps subviews onto new lines when they run out of width.
private struct DictFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
