import SwiftUI

/// The full Snippets surface, presented as a sheet from Attach. Presenting it
/// resigns the terminal's first responder and takes the keyboard down; it
/// comes back on dismiss, which is what `allowsKeyboardActivation` in
/// `HeelerTerminalView` exists to guarantee.
struct SnippetsManagementView: View {
    let store: SnippetStore
    @State private var query = ""
    @State private var editing: SnippetEditorTarget?

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Snippets")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search Snippets")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Snippet", systemImage: "plus") {
                            editing = .new
                        }
                    }
                }
                .navigationDestination(item: $editing) { target in
                    SnippetEditorView(store: store, target: target)
                }
        }
    }

    @ViewBuilder
    private var list: some View {
        let results = store.matching(query)
        if store.catalogLoadError != nil {
            ContentUnavailableView {
                Label("Snippets Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(
                    "The saved Snippets could not be read. They have been left untouched "
                        + "rather than overwritten, so nothing is lost.")
            }
        } else if store.snippets.isEmpty {
            ContentUnavailableView {
                Label("No Snippets", systemImage: "quote.bubble")
            } description: {
                Text("Keep the phrases you send an Agent over and over, one tap away.")
            } actions: {
                Button("New Snippet") { editing = .new }
                    .buttonStyle(.borderedProminent)
            }
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(results) { snippet in
                    Button {
                        editing = .existing(snippet)
                    } label: {
                        SnippetRow(snippet: snippet)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for snippet in offsets.map({ results[$0] }) {
                        try? store.remove(snippet.id)
                    }
                }
                .onMove { source, destination in
                    // Reordering a filtered list would move the wrong rows, so
                    // it is offered only on the unfiltered one.
                    guard query.isEmpty else { return }
                    try? store.move(fromOffsets: source, toOffset: destination)
                }
            }
            .toolbar {
                if query.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snippet.displayTitle)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let subtitle = snippet.displaySubtitle {
                Text(subtitle)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

enum SnippetEditorTarget: Hashable, Identifiable {
    case new
    case existing(Snippet)

    var id: Snippet.ID? {
        switch self {
        case .new: nil
        case .existing(let snippet): snippet.id
        }
    }
}

struct SnippetEditorView: View {
    let store: SnippetStore
    let target: SnippetEditorTarget

    @State private var title = ""
    @State private var body_ = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isBodyFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Optional", text: $title)
            } header: {
                Text("Title")
            } footer: {
                Text("A short name. Leave it empty and the Snippet's own text is its name.")
            }

            Section {
                TextField("What you want to say", text: $body_, axis: .vertical)
                    .lineLimit(4...12)
                    .fontDesign(.monospaced)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isBodyFocused)
            } header: {
                Text("Text")
            } footer: {
                Text("Tapping this Snippet inserts the text. You still press Enter to send it.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isNew ? "New Snippet" : "Edit Snippet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if case .existing(let snippet) = target {
                title = snippet.title
                body_ = snippet.body
            } else {
                isBodyFocused = true
            }
        }
    }

    private var isNew: Bool {
        if case .new = target { true } else { false }
    }

    private func save() {
        do {
            switch target {
            case .new:
                try store.add(Snippet.make(title: title, body: body_))
            case .existing(let snippet):
                try store.update(Snippet.make(id: snippet.id, title: title, body: body_))
            }
            dismiss()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case SnippetValidationError.emptyBody:
            "A Snippet needs some text."
        case SnippetValidationError.bodyTooLong(let limit):
            "A Snippet can hold at most \(limit) characters."
        case SnippetValidationError.unsupportedControlCharacters:
            // Refused here rather than at send time, where the user could no
            // longer do anything about it.
            "This text contains control characters a terminal would read as "
                + "commands. Remove them and try again."
        case SnippetStoreError.catalogUnreadable:
            "The saved Snippets could not be read, so nothing was changed."
        default:
            "The Snippet could not be saved."
        }
    }
}
