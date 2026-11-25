import SwiftUI

struct AgentTitleRenameSheet: View {
    @State private var store: AgentTitleRenameStore
    @FocusState private var isInputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: AgentTitleRenameStore) { _store = State(initialValue: store) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("Title", text: $store.input)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($isInputFocused)
                            .disabled(store.isBusy)
                        if !store.input.isEmpty, !store.isBusy {
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
                    if !store.input.isEmpty, let message = AgentTitleNaming.validation(store.input) {
                        Text(message).foregroundStyle(.errorInk)
                    } else if store.hasQueuedRename {
                        Text(
                            "Saved on this device. Will be sent once the Agent stops.",
                            comment: "Footer shown in the Rename sheet when a title is queued locally until the running Agent stops."
                        )
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
                            .foregroundStyle(.errorInk)
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
            .interactiveDismissDisabled(store.isBusy || store.deferredSaveConfirmation != nil)
            .alert(
                Text(
                    "Rename After Agent Stops?",
                    comment: "Alert title confirming that a title rename will be saved locally and sent once the running Agent stops."
                ),
                isPresented: Binding(
                    get: { store.deferredSaveConfirmation != nil },
                    set: { if !$0 { store.cancelDeferredSave() } }),
                presenting: store.deferredSaveConfirmation
            ) { confirmation in
                Button("Save") {
                    store.confirmDeferredSave(confirmation, suppressNextTime: false)
                }
                Button(
                    String(
                        localized: "Save and Don’t Show Again",
                        comment: "Alert button that queues a title rename until the Agent stops and suppresses this confirmation next time."
                    )
                ) {
                    store.confirmDeferredSave(confirmation, suppressNextTime: true)
                }
                Button("Cancel", role: .cancel) {
                    store.cancelDeferredSave()
                }
            } message: { _ in
                Text(
                    "This Agent is currently running. Your new title will be saved on this device and sent automatically once the Agent stops.",
                    comment: "Alert message explaining that a rename saved while an Agent is running will be sent automatically once it stops."
                )
            }
        }
        .presentationDetents([.medium, .large])
    }
}
