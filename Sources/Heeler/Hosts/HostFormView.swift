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
    /// The route page on screen: Add Route's, or a listed route's.
    @State private var routePath: [HostRoutePage] = []
    /// Reorder and delete controls for the Routes list, from its header.
    @State private var isEditingRoutes = false
    @FocusState private var isUsernameFocused: Bool
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack(path: $routePath) {
            Form {
                formSections
            }
            .environment(\.editMode, .constant(isEditingRoutes ? .active : .inactive))
            .onChange(of: draft.routes.count) { _, count in
                if count < 2 { isEditingRoutes = false }
            }
            .navigationDestination(for: HostRoutePage.self) { page in
                switch page {
                case .route(let routeID):
                    HostRouteFormView(draft: $draft, routeID: routeID, otherHosts: otherHosts)
                case .newRoute:
                    NewHostRouteView(draft: $draft, otherHosts: otherHosts)
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
        Section("Host") {
            TextField("Name (optional)", text: $draft.name)
            TextField("User", text: $draft.username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isUsernameFocused)
        }

        routesSection

        authenticationSection

        herdrSection
    }

    /// The session name, or for a Pairing Code v2 Host its endpoint, which
    /// replaces the session name and is not editable here.
    @ViewBuilder
    private var herdrSection: some View {
        if let herdrEndpoint = draft.herdrEndpoint {
            Section {
                LabeledContent("Socket", value: herdrEndpoint.socketPath)
                LabeledContent("Launcher", value: herdrEndpoint.executablePath)
            } header: {
                Text("herdr Endpoint")
            } footer: {
                Text("Set by this Host's Pairing Code.")
            }
        } else {
            Section {
                Picker("Backend", selection: $draft.backend) {
                    ForEach(HostBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                TextField("Session name", text: $draft.sessionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Backend and Session")
            } footer: {
                Text(draft.backend == .herdrCore
                    ? "Choose herdr-app / herdr-core for desktop agents. Leave the session blank for default. Add this Host with an SSH key or password; TUI Pairing Codes select herdr."
                    : "Leave blank for the default herdr session.")
            }
        }
    }

    /// Every route, one row each opening its own page, then Add Route.
    private var routesSection: some View {
        Section {
            ForEach(draft.routes) { @Sendable [routeCount = draft.routes.count] route in
                NavigationLink(value: HostRoutePage.route(route.id)) {
                    HostRouteRow(route: route)
                }
                .deleteDisabled(routeCount < 2)
            }
            .onDelete { draft.removeRoutes(atOffsets: $0) }
            .onMove { draft.moveRoutes(fromOffsets: $0, toOffset: $1) }
            if !isEditingRoutes {
                addRouteButton
            }
        } header: {
            HStack {
                Text("Routes")
                Spacer()
                if draft.routes.count > 1 {
                    Button(isEditingRoutes ? "Done" : "Edit") {
                        withAnimation { isEditingRoutes.toggle() }
                    }
                    .font(.subheadline)
                    .textCase(nil)
                    .accessibilityLabel(isEditingRoutes ? "Done Editing Routes" : "Edit Routes")
                }
            }
        } footer: {
            if draft.routes.isEmpty {
                Text(
                    "Add the address Heeler connects to: directly, over an overlay network, "
                        + "or through a Jump Host.")
            } else if draft.routes.count > 1 {
                Text(
                    "Heeler tries every route each time it connects and keeps the first that "
                        + "reaches the Host. Routes over this device's own network start first; "
                        + "the rest start a moment later.")
            } else {
                Text(
                    "Add another way to reach this Host, such as its LAN address at home and "
                        + "an overlay network or Jump Host elsewhere.")
            }
        }
    }

    private var addRouteButton: some View {
        Button {
            routePath.append(.newRoute)
        } label: {
            Label("Add Route", systemImage: "plus")
        }
    }

    /// The Host being edited is not another Host for the peer picker to tag.
    private var otherHosts: [Host] {
        store.hosts.filter { $0.id != editing?.id }
    }

    private var authenticationSection: some View {
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
                Label {
                    Text(didCopyKeyLine ? "Copied" : "Copy authorized_keys Line")
                } icon: {
                    // The tall two-page glyph otherwise outgrows the text.
                    Image(systemName: didCopyKeyLine ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                }
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
                Label {
                    Text(didCopyKeyLine ? "Copied" : "Copy RSA Public Key")
                } icon: {
                    // The tall two-page glyph otherwise outgrows the text.
                    Image(systemName: didCopyKeyLine ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                }
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
