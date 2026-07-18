import SwiftUI

/// Add/edit form for a Host. Device-key auth shows the copyable
/// `authorized_keys` line (generated on device, never exported beyond its
/// public half); the password goes straight to the Keychain via `HostStore`.
struct HostFormView: View {
    let store: HostStore
    var editing: Host?
    var onSaved: ((Host) -> Void)?

    @State private var draft: HostDraft
    @State private var authorizedKeysLine: String?
    @State private var didCopyKeyLine = false
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss

    private let credentials = HostCredentialsProvider()

    init(store: HostStore, editing: Host? = nil, onSaved: ((Host) -> Void)? = nil) {
        self.store = store
        self.editing = editing
        self.onSaved = onSaved
        _draft = State(initialValue: editing.map(HostDraft.init) ?? HostDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name (optional)", text: $draft.name)
                    TextField("Address", text: $draft.address)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $draft.port)
                        .keyboardType(.numberPad)
                    TextField("User", text: $draft.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Picker("Method", selection: $draft.authMethod) {
                        Text("Device Key").tag(Host.AuthMethod.deviceKey)
                        Text("Password").tag(Host.AuthMethod.password)
                    }
                    .pickerStyle(.segmented)
                    switch draft.authMethod {
                    case .deviceKey:
                        deviceKeySection
                    case .password:
                        SecureField(
                            editing == nil ? "Password" : "Password (blank keeps current)",
                            text: $draft.password)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    if draft.authMethod == .deviceKey {
                        Text(
                            "Add this line to ~/.ssh/authorized_keys on the Host. "
                                + "The private key never leaves this device.")
                    }
                }

                Section {
                    TextField("Session name", text: $draft.sessionName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("herdr Session")
                } footer: {
                    Text("Leave blank for the default herdr session.")
                }

                Section {
                    TextField("socat path", text: $draft.socatPath)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Absolute path of socat on the Host.")
                }
            }
            .navigationTitle(editing == nil ? "Add Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.isValid)
                }
            }
            .alert("Could not save the Host", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            }
            .task {
                authorizedKeysLine = try? credentials.deviceKey()
                    .authorizedKeysLine(comment: "herdr-mobile")
            }
        }
    }

    @ViewBuilder
    private var deviceKeySection: some View {
        if let authorizedKeysLine {
            Text(authorizedKeysLine)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = authorizedKeysLine
                didCopyKeyLine = true
            } label: {
                Label(
                    didCopyKeyLine ? "Copied" : "Copy authorized_keys Line",
                    systemImage: didCopyKeyLine ? "checkmark" : "doc.on.doc")
            }
        } else {
            // Only reachable when the Keychain is unavailable or the stored
            // key is corrupt; there is nothing actionable in-form.
            Label("Device key unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard let host = draft.makeHost(id: editing?.id ?? UUID()) else { return }
        do {
            if editing == nil {
                try store.add(host, password: draft.passwordUpdate)
            } else {
                try store.update(host, password: draft.passwordUpdate)
            }
        } catch {
            saveFailed = true
            return
        }
        dismiss()
        onSaved?(host)
    }
}
