import SwiftUI

/// The workspace rename sheet (#98). The new label reaches the Console
/// through the store's normal snapshot/delta machinery, so this sheet
/// dismisses on success rather than mutating anything itself.
struct WorkspaceRenameSheetView: View {
    @State private var store: WorkspaceRenameStore
    @Environment(\.dismiss) private var dismiss

    init(store: WorkspaceRenameStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Workspace label", text: $store.input)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Rename Workspace")
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
}
