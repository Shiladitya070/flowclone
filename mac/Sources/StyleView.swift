import SwiftUI

// Style page: how dictation is formatted in each kind of app. "Default" means no override.

struct StyleView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            PageHeader(
                title: "Style",
                subtitle: "Choose how your dictation is formatted in different kinds of apps."
            )
            ForEach(AppCategory.allCases) { category in
                StyleSection(store: store, category: category)
            }
        }
    }
}

/// One app category: its name, the apps it covers, and a row of style options.
private struct StyleSection: View {
    @ObservedObject var store: Store
    let category: AppCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .font(.headline)
                Text(category.apps)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                StyleOption(
                    title: "Default",
                    example: "Dictation keeps FlowClone’s standard punctuation and capitalization.",
                    selected: store.styles[category] == nil
                ) {
                    store.styles[category] = nil
                }
                ForEach(StyleLevel.allCases) { level in
                    StyleOption(
                        title: level.title,
                        example: level.example,
                        selected: store.styles[category] == level
                    ) {
                        store.styles[category] = level
                    }
                }
            }
        }
    }
}

/// A selectable card. Equal width within its row; accent border and checkmark when selected.
private struct StyleOption: View {
    let title: String
    let example: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(example)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}
