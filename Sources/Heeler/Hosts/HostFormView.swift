import SwiftUI

/// Add/edit form for a Host. Device-key auth shows the copyable
/// `authorized_keys` line (generated on device, never exported beyond its
/// public half); the password goes straight to the Keychain via `HostStore`.
struct HostFormView: View {
    let store: HostStore
    var editing: Host?
    var onSaved: ((Host) -> Void)?
    /// Starts in User, for a prefill that already says where the Host is.
    var focusesUsername = false

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
    @State private var isChoosingOverlayPeer = false
    @FocusState private var isUsernameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    /// Absent in previews and hosting tests; the Network picker then offers
    /// only Direct (plus the Host's current choice).
    @Environment(OverlayNetworkStore.self) private var overlayNetworks: OverlayNetworkStore?

    private let credentials = HostCredentialsProvider()

    init(store: HostStore, editing: Host? = nil, onSaved: ((Host) -> Void)? = nil) {
        self.store = store
        self.editing = editing
        self.onSaved = onSaved
        _draft = State(initialValue: editing.map(HostDraft.init) ?? HostDraft())
    }

    /// Adds a new Host starting from `prefill`, as Duplicate does: saving
    /// never touches the Host the draft was copied from.
    init(
        store: HostStore, prefill: HostDraft, focusesUsername: Bool = false,
        onSaved: ((Host) -> Void)? = nil
    ) {
        self.store = store
        self.editing = nil
        self.onSaved = onSaved
        self.focusesUsername = focusesUsername
        _draft = State(initialValue: prefill)
    }

    var body: some View {
        NavigationStack {
            Form {
                formSections
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
            .sheet(isPresented: $isChoosingOverlayPeer) {
                if let overlayNetworks, let network = selectedOverlayNetwork {
                    OverlayPeerPickerView(
                        network: network,
                        target: draft.overlayPeerTarget,
                        chosenAddress: draft.overlayPeerAddress,
                        model: OverlayPeerPickerModel(store: overlayNetworks, networkID: network.id),
                        // The Host being edited is not another Host to warn about.
                        hosts: store.hosts.filter { $0.id != editing?.id }
                    ) { candidate, style in
                        draft.applyOverlayPeer(candidate, style: style)
                    }
                }
            }
            .task {
                if focusesUsername { isUsernameFocused = true }
                loadDeviceKey()
                if draft.authMethod == .rsaKey {
                    loadRSAKey()
                }
            }
        }
    }

    /// Split out of `body` so the type checker sees two smaller
    /// expressions instead of one very long modifier chain.
    @ViewBuilder
    private var formSections: some View {
        // The network decides which address to enter (and offers its peers
        // beside it), so it leads the form once there is one to choose.
        if networkLeadsForm {
            networkSection
        }

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
                .focused($isUsernameFocused)
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

        if !networkLeadsForm {
            networkSection
        }
    }

    /// Without Overlay Networks the Network section is only a pointer to
    /// Settings, so it stays at the end, out of a direct Host's way.
    private var networkLeadsForm: Bool {
        !(overlayNetworks?.networks.isEmpty ?? true) || draft.overlayNetworkID != nil
    }

    /// The Overlay Network the draft names, when it still exists.
    private var selectedOverlayNetwork: OverlayNetwork? {
        draft.overlayNetworkID.flatMap { overlayNetworks?.network(id: $0) }
    }

    /// Under the network: pick the first hop's address (the Host's, or the
    /// Jump Host's when one is set) from its peers instead of typing it.
    /// Once that address is a known peer's, as after Add on a machine in
    /// Settings, the row names the peer like a picker showing its choice.
    /// ZeroTier reports no member addresses; its footer says where they are.
    @ViewBuilder
    private var overlayPeerChooser: some View {
        if let network = selectedOverlayNetwork, OverlayPeerList.offersPeers(network.kind) {
            Button {
                isChoosingOverlayPeer = true
            } label: {
                if let chosen = chosenOverlayPeer(on: network) {
                    // Styled like the Network picker above, not as a tinted button.
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(chosen.displayName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    } label: {
                        // `.primary` would resolve to the button's tint.
                        Text(network.kind == .tailscale ? "Machine" : "Peer")
                            .foregroundStyle(Color.primary)
                    }
                } else {
                    Text(OverlayPeerList.chooseTitle(for: network.kind))
                }
            }
            .accessibilityHint("Lists the peers of \(network.displayName)")
        }
    }

    /// The peer the first hop already dials, from the network's last report.
    private func chosenOverlayPeer(on network: OverlayNetwork) -> OverlayPeerCandidate? {
        let peers = overlayNetworks?.details[network.id]?.peers ?? []
        return OverlayPeerList.chosen(
            among: OverlayPeerList.candidates(from: peers), address: draft.overlayPeerAddress)
    }

    /// Direct, or one of Settings › Overlay Networks. A Host still naming a
    /// removed network keeps that choice visible as unavailable instead of
    /// silently becoming Direct.
    private var networkSection: some View {
        let networks = overlayNetworks?.networks ?? []
        let selectionIsMissing =
            draft.overlayNetworkID.map { id in !networks.contains { $0.id == id } } ?? false
        return Section {
            Picker("Network", selection: $draft.overlayNetworkID) {
                Text("Direct").tag(UUID?.none)
                ForEach(networks) { network in
                    Text("\(network.displayName) (\(network.kind.displayName))")
                        .tag(UUID?.some(network.id))
                }
                if selectionIsMissing {
                    Text("Unavailable network").tag(draft.overlayNetworkID)
                }
            }
            overlayPeerChooser
        } header: {
            Text("Network")
        } footer: {
            Text(networkFooter(hasNetworks: !networks.isEmpty, selectionIsMissing: selectionIsMissing))
        }
    }

    private func networkFooter(hasNetworks: Bool, selectionIsMissing: Bool) -> String {
        if selectionIsMissing {
            return "This Host's overlay network was removed. Choose another network or Direct."
        }
        guard draft.overlayNetworkID != nil else {
            return hasNetworks
                ? "Direct uses this device's own network connection."
                : "Direct uses this device's own network connection. Add Tailscale, ZeroTier, "
                    + "or EasyTier networks in Settings › Overlay Networks."
        }
        let target = draft.usesJumpHost ? "the Jump Host" : "this Host"
        let base = "Heeler reaches \(target) through this network without turning on a VPN."
        guard let network = selectedOverlayNetwork, !OverlayPeerList.offersPeers(network.kind) else {
            return base
        }
        return base + " ZeroTier does not report member addresses; copy \(target)'s managed IP "
            + "from ZeroTier Central or your controller."
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
