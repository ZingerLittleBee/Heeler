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
    @State private var rsaPublicKeyLine: String?
    @State private var didCopyKeyLine = false
    @State private var saveFailed = false
    @State private var deviceKeyIsCorrupt = false
    @State private var rsaKeyIsCorrupt = false
    @State private var isConfirmingDeviceKeyReplacement = false
    @State private var isConfirmingRSAKeyReplacement = false
    @State private var deviceKeyReplacementError: String?
    @State private var rsaKeyReplacementError: String?
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
                        Text("RSA Key").tag(Host.AuthMethod.rsaKey)
                        Text("Password").tag(Host.AuthMethod.password)
                    }
                    .onChange(of: draft.authMethod) {
                        didCopyKeyLine = false
                        if draft.authMethod == .rsaKey,
                           rsaPublicKeyLine == nil,
                           !rsaKeyIsCorrupt
                        {
                            loadRSAKey()
                        }
                    }
                    switch draft.authMethod {
                    case .deviceKey:
                        deviceKeySection
                    case .rsaKey:
                        rsaKeySection
                    case .password:
                        SecureField(
                            editing == nil ? "Password" : "Password (blank keeps current)",
                            text: $draft.password)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    switch draft.authMethod {
                    case .deviceKey:
                        Text(
                            "Add this line to ~/.ssh/authorized_keys on the Host. "
                                + "The private key never leaves this device.")
                    case .rsaKey:
                        Text(
                            "Register this public key wherever the Host accepts SSH identities. "
                                + "The private key never leaves this device.")
                    case .password:
                        EmptyView()
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
                    TextField("Jump Host address (optional)", text: $draft.jumpAddress)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if draft.usesJumpHost {
                        TextField("Jump Host port", text: $draft.jumpPort)
                            .keyboardType(.numberPad)
                        TextField("Jump Host user (blank = same as Host)", text: $draft.jumpUsername)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Jump Host")
                } footer: {
                    if draft.usesJumpHost {
                        Text(jumpHostFooter)
                    } else {
                        Text("Leave blank to connect to the Host directly.")
                    }
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
                        .disabled(!draft.canSave(editing: editing))
                }
            }
            .alert("Could not save the Host", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            }
            .alert(
                "Could not replace the Device Key",
                isPresented: Binding(
                    get: { deviceKeyReplacementError != nil },
                    set: { if !$0 { deviceKeyReplacementError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deviceKeyReplacementError ?? "")
            }
            .alert(
                "Could not replace the RSA Key",
                isPresented: Binding(
                    get: { rsaKeyReplacementError != nil },
                    set: { if !$0 { rsaKeyReplacementError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(rsaKeyReplacementError ?? "")
            }
            .confirmationDialog(
                "Replace the Device Key?",
                isPresented: $isConfirmingDeviceKeyReplacement,
                titleVisibility: .visible
            ) {
                Button("Replace Device Key", role: .destructive) { replaceDeviceKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Every Host using Device Key authentication will reject the replacement "
                        + "until you add its new public key to ~/.ssh/authorized_keys.")
            }
            .confirmationDialog(
                "Replace the RSA Key?",
                isPresented: $isConfirmingRSAKeyReplacement,
                titleVisibility: .visible
            ) {
                Button("Replace RSA Key", role: .destructive) { replaceRSAKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Every Host using RSA Key authentication will reject the replacement "
                        + "until you register its new public key on that Host.")
            }
            .task {
                loadDeviceKey()
                if draft.authMethod == .rsaKey {
                    loadRSAKey()
                }
            }
        }
    }

    private var jumpHostFooter: String {
        let credentialRequirement =
            switch draft.authMethod {
            case .deviceKey:
                "Both machines must authorize the Device Key."
            case .rsaKey:
                "Both machines must authorize the RSA Key."
            case .password:
                "Both machines must accept the same password; separate passwords are not supported."
            }
        return "The Host's Address and Port are resolved from the Jump Host, usually through "
            + "a loopback-only reverse tunnel. \(credentialRequirement) You confirm each "
            + "machine's host key fingerprint independently on first connect."
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
            Label(
                deviceKeyIsCorrupt ? "Device key is corrupted" : "Device key unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if deviceKeyIsCorrupt {
                Button("Replace Device Key", role: .destructive) {
                    isConfirmingDeviceKeyReplacement = true
                }
            } else {
                Button("Try Again") { loadDeviceKey() }
            }
        }
    }

    @ViewBuilder
    private var rsaKeySection: some View {
        if let rsaPublicKeyLine {
            Text(rsaPublicKeyLine)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = rsaPublicKeyLine
                didCopyKeyLine = true
            } label: {
                Label(
                    didCopyKeyLine ? "Copied" : "Copy RSA Public Key",
                    systemImage: didCopyKeyLine ? "checkmark" : "doc.on.doc")
            }
        } else {
            Label(
                rsaKeyIsCorrupt ? "RSA Key is corrupted" : "RSA Key unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if !rsaKeyIsCorrupt {
                Button("Try Again") { loadRSAKey() }
            } else {
                Button("Replace RSA Key", role: .destructive) {
                    isConfirmingRSAKeyReplacement = true
                }
            }
        }
    }

    private func loadDeviceKey() {
        do {
            let key = try credentials.deviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
            deviceKeyIsCorrupt = false
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = true
        } catch {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = false
        }
    }

    private func loadRSAKey() {
        do {
            let key = try credentials.rsaKey()
            rsaPublicKeyLine = key.authorizedKeysLine(comment: "heeler rsa")
            rsaKeyIsCorrupt = false
        } catch RSAKeyStoreError.storedKeyCorrupt {
            rsaPublicKeyLine = nil
            rsaKeyIsCorrupt = true
        } catch {
            rsaPublicKeyLine = nil
            rsaKeyIsCorrupt = false
        }
    }

    private func replaceDeviceKey() {
        do {
            let key = try credentials.replaceDeviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
            deviceKeyIsCorrupt = false
            didCopyKeyLine = false
        } catch {
            deviceKeyReplacementError = "The replacement could not be saved to the Keychain."
        }
    }

    private func replaceRSAKey() {
        do {
            let key = try credentials.replaceRSAKey()
            rsaPublicKeyLine = key.authorizedKeysLine(comment: "heeler rsa")
            rsaKeyIsCorrupt = false
            didCopyKeyLine = false
        } catch {
            rsaKeyReplacementError = "The replacement could not be saved to the Keychain."
        }
    }

    private func save() {
        guard draft.canSave(editing: editing) else { return }
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
