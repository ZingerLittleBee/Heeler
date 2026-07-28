import SwiftUI

/// The rename sheet (#98), shared by the Agent and workspace rename actions:
/// one text field with the validation and clear-semantics copy the
/// RenameStore derives from the server's live-verified rules. The new name
/// reaches the Console through the store's normal snapshot/delta machinery,
/// so this sheet dismisses on success rather than mutating anything itself.
struct RenameSheetView: View {
    let title: String
    @State private var store: RenameStore
    @Environment(\.dismiss) private var dismiss

    init(title: String, store: RenameStore) {
        self.title = title
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(fieldPrompt, text: $store.input)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
        case .agent: "e.g. reviewer"
        case .workspace: "Workspace label"
        }
    }
}
