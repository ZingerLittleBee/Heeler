import SwiftUI

struct AgentTitleRenameSheet: View {
    @State private var store: AgentTitleRenameStore
    @Environment(\.dismiss) private var dismiss

    init(store: AgentTitleRenameStore) { _store = State(initialValue: store) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $store.input)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(store.isBusy)
                } footer: {
                    if !store.input.isEmpty, let message = AgentTitleNaming.validation(store.input) {
                        Text(message).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await store.generate() }
                    } label: {
                        HStack {
                            Label("Generate Automatically", systemImage: "sparkles")
                            if store.state == .generating { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!store.canGenerate)
                } footer: {
                    if let reason = store.generationUnavailable { Text(reason) }
                }
                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(store.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.state == .saving { ProgressView() }
                    else {
                        Button("Save") { Task { await store.save() } }
                            .disabled(!store.canSave)
                    }
                }
            }
            .onChange(of: store.state) { if store.state == .renamed { dismiss() } }
            .task { await store.refreshInitialTitle() }
            .interactiveDismissDisabled(store.isBusy)
        }
        .presentationDetents([.medium, .large])
    }
}
