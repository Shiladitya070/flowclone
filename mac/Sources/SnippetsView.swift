import SwiftUI

// Snippets page: say a short trigger, FlowClone types the full expansion.

/// Editor state for the sheet. `snippetID` is nil when creating a new snippet.
private struct SnippetDraft: Identifiable {
    let id = UUID()
    var snippetID: UUID?
    var trigger = ""
    var expansion = ""
}

struct SnippetsView: View {
    @ObservedObject var store: Store
    @State private var draft: SnippetDraft?

    /// Starter triggers offered in the empty state; they open the editor prefilled.
    private let suggestions = ["my email", "my address"]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                PageHeader(
                    title: "Snippets",
                    subtitle: "Say a short trigger, get the full text. e.g. “my email” → your email address."
                )
                Button {
                    draft = SnippetDraft()
                } label: {
                    Label("New snippet", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
            }

            if store.snippets.isEmpty {
                emptyState
            } else {
                VStack(spacing: 12) {
                    ForEach(store.snippets) { snippet in
                        SnippetCard(
                            snippet: snippet,
                            onEdit: { draft = SnippetDraft(snippetID: snippet.id, trigger: snippet.trigger, expansion: snippet.expansion) },
                            onDelete: { store.snippets.removeAll { $0.id == snippet.id } }
                        )
                    }
                }
            }
        }
        .sheet(item: $draft) { d in
            SnippetEditorSheet(store: store, draft: d)
        }
    }

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "scissors")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                Text("No snippets yet")
                    .font(.headline)
                Text("Snippets save you from typing things you write often. Try one of these:")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(suggestions, id: \.self) { trigger in
                        Button {
                            draft = SnippetDraft(trigger: trigger)
                        } label: {
                            Label("“\(trigger)”", systemImage: "plus")
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
}

/// One snippet: trigger in quotes, expansion beneath. Edit and Delete appear on hover.
private struct SnippetCard: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("“\(snippet.trigger)”")
                        .font(.system(size: 15, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(snippet.expansion)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    iconButton("pencil", help: "Edit", action: onEdit)
                    iconButton("trash", help: "Delete", action: onDelete)
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Create/edit sheet. Save is disabled until both fields are filled and the trigger is unique.
private struct SnippetEditorSheet: View {
    @ObservedObject var store: Store
    let draft: SnippetDraft
    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var expansion: String

    init(store: Store, draft: SnippetDraft) {
        self.store = store
        self.draft = draft
        _trigger = State(initialValue: draft.trigger)
        _expansion = State(initialValue: draft.expansion)
    }

    private var cleanTrigger: String { trigger.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanExpansion: String { expansion.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isDuplicate: Bool {
        !cleanTrigger.isEmpty && store.snippets.contains {
            $0.id != draft.snippetID && $0.trigger.lowercased() == cleanTrigger.lowercased()
        }
    }

    private var canSave: Bool { !cleanTrigger.isEmpty && !cleanExpansion.isEmpty && !isDuplicate }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.snippetID == nil ? "New snippet" : "Edit snippet")
                .font(Theme.title(22))

            VStack(alignment: .leading, spacing: 6) {
                Text("Trigger").font(.subheadline.weight(.medium))
                TextField("e.g. my email", text: $trigger)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                if isDuplicate {
                    Text("A snippet with this trigger already exists.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Expansion").font(.subheadline.weight(.medium))
                TextEditor(text: $expansion)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.background)
    }

    /// Replaces an existing snippet in place, or appends a new one.
    private func save() {
        guard canSave else { return }
        var list = store.snippets
        if let id = draft.snippetID, let i = list.firstIndex(where: { $0.id == id }) {
            list[i] = Snippet(id: id, trigger: cleanTrigger, expansion: cleanExpansion)
        } else {
            list.append(Snippet(trigger: cleanTrigger, expansion: cleanExpansion))
        }
        store.snippets = list
        dismiss()
    }
}
