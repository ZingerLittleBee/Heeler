import SwiftUI

/// The rename sheet (#98), shared by the Agent and workspace rename actions:
/// one text field with the validation and clear-semantics copy the
/// RenameStore derives from the server's live-verified rules. The new name
/// reaches the Console through the store's normal snapshot/delta machinery,
/// so this sheet dismisses on success rather than mutating anything itself.
struct RenameSheetView: View {
    let title: String
    @State private var store: RenameStore
    @FocusState private var isInputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, store: RenameStore) {
        self.title = title
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField(fieldPrompt, text: $store.input)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($isInputFocused)
                            .disabled(store.state == .renaming)
                        if !store.input.isEmpty, store.state != .renaming {
                            Button {
                                store.input = ""
                                isInputFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(Color(uiColor: .systemGray))
                            }
                            // Borderless, or the whole row would be the button.
                            .buttonStyle(.borderless)
                            .tint(Color(uiColor: .systemGray))
                            .contentShape(Rectangle().inset(by: -6))
                            .accessibilityLabel(
                                Text(
                                    "Clear text",
                                    comment: "Accessibility label for the button that clears the rename text field."
                                ))
                        }
                    }
                } footer: {
                    if let message = store.validationMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    } else if let hint = store.clearHint {
                        Text(hint)
                    }
                }

                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(!store.canDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.state == .renaming {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await store.submit() }
                        }
                        .disabled(!store.canSubmit)
                    }
                }
            }
            .onChange(of: store.state) {
                if store.state == .renamed { dismiss() }
            }
            .interactiveDismissDisabled(!store.canDismiss)
        }
        .presentationDetents([.medium])
    }

    private var fieldPrompt: String {
        switch store.subject {
        case .agent: String(localized: "e.g. reviewer")
        case .workspace: String(localized: "Workspace label")
        }
    }
}
