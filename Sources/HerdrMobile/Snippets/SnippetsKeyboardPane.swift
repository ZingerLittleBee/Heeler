import SwiftUI

/// The Snippets pane inside the Keys keyboard: a single scrolling column, one
/// Snippet per row.
///
/// There is deliberately no search field here. A `UITextField` inside a
/// `UIInputView` becomes first responder by replacing the keyboard it lives
/// in, which would take the search field and the list it filters off screen
/// together. Search lives in the management sheet, where the responder
/// environment is ordinary.
struct SnippetsKeyboardPane: View {
    let store: SnippetStore
    let onSend: (Snippet) -> Void
    let onManage: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.snippets.isEmpty {
                    emptyState
                } else {
                    ForEach(store.snippets) { snippet in
                        SnippetRowButton(snippet: snippet) { onSend(snippet) }
                            .contextMenu {
                                Button("Manage Snippets", systemImage: "slider.horizontal.3") {
                                    onManage()
                                }
                            }
                        Divider().padding(.leading, 16)
                    }
                    manageRow
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No Snippets yet")
                .font(.subheadline.weight(.medium))
            Text("Keep the phrases you send an Agent over and over, one tap away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Snippet", systemImage: "plus") { onManage() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    /// The end-of-list entry to the full surface. It sits where scrolling
    /// naturally ends rather than behind an over-scroll gesture, which would
    /// fire every time a fast flick overshoots the last Snippet.
    private var manageRow: some View {
        Button(action: onManage) {
            Label("Manage Snippets", systemImage: "slider.horizontal.3")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}

/// One Snippet as a row: its Title on top and its text below, or just its
/// text when it has no Title and there is nothing to put on the first line.
struct SnippetRowButton: View {
    let snippet: Snippet
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle = snippet.displaySubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snippet.displayTitle)
        .accessibilityHint("Inserts this Snippet without sending it")
    }
}
