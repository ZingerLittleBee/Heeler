import SwiftUI

/// Add Host as three steps in one sheet (ADR 0047): Connect, Trust, Servers.
/// A step that fails stays where it is with what was typed, and the Host is
/// saved on the last one, already reached and trusted.
struct NewHostWizardView: View {
    let catalog: HostStore
    let discoveries: HostServerDiscoveryStore
    /// Called with a record of the Host once it is in the catalog and the
    /// sheet is on its way out, for the list to point at its row.
    let onAdded: @MainActor (Host.ID) -> Void

    private let dependencies: HostOnboardingDependencies
    @State private var wizard: NewHostWizard
    @State private var path: [HostRoutePage] = []
    @State private var isFindingLocalMachine = false
    @State private var isShowingSetupGuide = false
    @State private var didCopyCommand = false
    /// The Host saved while a Server could not be turned on: the alert that
    /// says so closes the sheet.
    @State private var savedMember: Host.ID?
    @FocusState private var isUserFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(OverlayNetworkStore.self) private var overlayNetworks: OverlayNetworkStore?

    init(
        catalog: HostStore,
        discoveries: HostServerDiscoveryStore,
        dependencies: HostOnboardingDependencies,
        prefill: HostDraft? = nil,
        onAdded: @escaping @MainActor (Host.ID) -> Void
    ) {
        self.catalog = catalog
        self.discoveries = discoveries
        self.dependencies = dependencies
        self.onAdded = onAdded
        _wizard = State(
            initialValue: NewHostWizard(catalog: catalog, dependencies: dependencies, prefill: prefill))
    }

    /// Add Host from the step `wizard` is on: Scan to Pair hands over one that
    /// has already looked for the paired machine's Servers (ADR 0057).
    init(
        wizard: NewHostWizard,
        catalog: HostStore,
        discoveries: HostServerDiscoveryStore,
        dependencies: HostOnboardingDependencies,
        onAdded: @escaping @MainActor (Host.ID) -> Void
    ) {
        self.catalog = catalog
        self.discoveries = discoveries
        self.dependencies = dependencies
        self.onAdded = onAdded
        _wizard = State(initialValue: wizard)
    }

    var body: some View {
        NavigationStack(path: $path) {
            form
                .navigationTitle("New Host")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { leadingButton }
                }
                .navigationDestination(for: HostRoutePage.self) { page in
                    if case .route(let routeID) = page {
                        HostRouteFormView(
                            draft: Bindable(wizard).draft, routeID: routeID, otherHosts: catalog.hosts)
                    }
                }
        }
        // Past the first step a swipe would throw away a trusted key or a
        // finished look without a word.
        .interactiveDismissDisabled(wizard.step != .connect || wizard.isConnecting)
        .task {
            // A prefill that already says where the Host is starts in User.
            if !wizard.address.isEmpty, wizard.draft.username.isEmpty { isUserFocused = true }
        }
        .onDisappear {
            Task { await wizard.close() }
        }
    }

    /// The steps and their sheets, apart from `body`'s chain, which stays
    /// under Xcode 26.6's type-checking limit.
    private var form: some View {
        Form {
            Section {
                NewHostWizardSteps(current: wizard.step)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            switch wizard.step {
            case .connect: connectSections
            case .trust: trustSections
            case .servers: serversSections
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .localMachinePicker(isPresented: $isFindingLocalMachine) { machine in
            if let routeID = wizard.draft.routes.first?.id {
                wizard.draft.applyDiscoveredMachine(machine, toRoute: routeID)
            }
        }
        .sheet(isPresented: $isShowingSetupGuide) {
            NavigationStack {
                HostSetupGuideView(onClose: { isShowingSetupGuide = false })
            }
        }
        .alert("Could Not Finish", isPresented: saveFailurePresented) {
            Button("OK", role: .cancel) {
                wizard.dismissSaveFailure()
                if let savedMember { close(pointingAt: savedMember) }
            }
        } message: {
            Text(wizard.saveFailure ?? "")
        }
    }

    private var saveFailurePresented: Binding<Bool> {
        Binding(get: { wizard.saveFailure != nil }, set: { _ in })
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch wizard.step {
        case .connect, .servers:
            Button("Cancel") { dismiss() }
        case .trust:
            Button("Back") { wizard.backToConnect() }
        }
    }

    // MARK: Connect

    @ViewBuilder
    private var connectSections: some View {
        @Bindable var wizard = wizard
        if let failure = wizard.failure {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Couldn't reach \(wizard.address)")
                            .font(.headline)
                        Text(failure.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("hosts.wizard.failure")
                if let loginURL = failure.overlayLoginURL {
                    Link(destination: loginURL) {
                        Label("Open Sign-In Link", systemImage: "person.badge.key")
                    }
                }
            }
        }
        Section {
            HStack {
                TextField("Address", text: $wizard.draft.address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("hosts.wizard.address")
                Button {
                    isFindingLocalMachine = true
                } label: {
                    Image(systemName: "wifi")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Find on Local Network")
            }
            TextField("User", text: $wizard.draft.username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isUserFocused)
                .accessibilityIdentifier("hosts.wizard.user")
            if let routeID = wizard.draft.routes.first?.id {
                NavigationLink(value: HostRoutePage.route(routeID)) {
                    Text("More Options")
                }
            }
        } header: {
            Text("Address")
        } footer: {
            Text(moreOptionsHint)
        }
        .disabled(wizard.isConnecting)

        HostAuthenticationSection(
            authMethod: $wizard.draft.authMethod, password: $wizard.draft.password,
            passwordPrompt: String(localized: "Password")
        )
        .disabled(wizard.isConnecting)
    }

    /// What More Options holds, naming the port the route uses now and the
    /// Overlay Network or Jump Host it already goes through.
    private var moreOptionsHint: String {
        let route = wizard.draft.primaryRoute
        var parts = [String(localized: "Port \(route.port).")]
        if let networkID = route.overlayNetworkID {
            if let network = overlayNetworks?.network(id: networkID) {
                parts.append(String(localized: "Over overlay network “\(network.displayName)”."))
            } else {
                parts.append(String(localized: "Over an overlay network that no longer exists."))
            }
        }
        if route.usesJumpHost {
            parts.append(String(localized: "Through the Jump Host \(route.jumpAddress)."))
        }
        if parts.count == 1 {
            parts.append(String(localized: "Add a Jump Host or an overlay network under More Options."))
        }
        return parts.joinedAsSentences()
    }

    // MARK: Trust

    @ViewBuilder
    private var trustSections: some View {
        if let candidate = wizard.candidate {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Trust this Host?")
                        .font(.title3.weight(.semibold))
                    Text(
                        "First connection to \(candidate.host):\(String(candidate.port)). Verify the fingerprint matches the Host's key before trusting.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                // One line: a wrapped fingerprint gains hyphens that are not
                // in it.
                Text(candidate.fingerprint.displayString)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("hosts.wizard.fingerprint")
                Button {
                    UIPasteboard.general.string = candidate.fingerprint.printCommand
                    didCopyCommand = true
                } label: {
                    Label {
                        Text(didCopyCommand ? "Copied" : "Copy the Command That Prints It")
                    } icon: {
                        // The tall two-page glyph otherwise outgrows the text.
                        Image(systemName: didCopyCommand ? "checkmark" : "doc.on.doc")
                            .font(.footnote)
                    }
                }
            } header: {
                Text("Key Fingerprint")
            } footer: {
                Text("Run the command on the Host and compare what it prints with this fingerprint.")
            }
        }
    }

    // MARK: Servers

    @ViewBuilder
    private var serversSections: some View {
        @Bindable var wizard = wizard
        if let scan = wizard.scan {
            if scan.servers.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No servers yet")
                        Text(lookedForLine(scan))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Found on \(wizard.address)")
                        .textCase(nil)
                }
                Section {
                    ForEach(scan.missing, id: \.kind) { @Sendable missing in
                        MainActorContent {
                            if missing.kind == .rex {
                                // The Setup Guide sets up herdr. A Rex named
                                // missing runs already, under an account this
                                // one cannot use (ADR 0049).
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(missing.kind.displayName)
                                    if let note = missing.note {
                                        Text(note)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            } else {
                                Button {
                                    isShowingSetupGuide = true
                                } label: {
                                    LabeledContent {
                                        Text("Setup Guide")
                                            .foregroundStyle(.tint)
                                    } label: {
                                        Text(missing.kind.displayName)
                                            .foregroundStyle(Color.primary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Set One Up")
                } footer: {
                    Text("Install or start one on the Host, then scan again.")
                }
            } else {
                Section {
                    ForEach(scan.servers) { @Sendable server in
                        MainActorContent { serverRow(server) }
                    }
                } header: {
                    Text("Found on \(wizard.address)")
                        .textCase(nil)
                } footer: {
                    if let existing = wizard.existing, wizard.replacesTrustedKey {
                        Text(
                            "\(existing.name) is already in Heeler. Checked servers are turned on there. Its host key changed, and the key from the Pairing Code replaces the one trusted before.")
                    } else if let existing = wizard.existing {
                        Text("\(existing.name) is already in Heeler. Checked servers are turned on there.")
                    } else {
                        Text(
                            "Checked servers bring their Agents into Heeler. The rest stay on this Host, switched off.")
                    }
                }
            }
            // A Host that is in the catalog keeps the name it has.
            if wizard.existing == nil {
                Section("Name") {
                    TextField("Name (optional)", text: $wizard.draft.name)
                        .accessibilityIdentifier("hosts.wizard.name")
                }
            }
        }
    }

    private func serverRow(_ server: FoundServer) -> some View {
        // On already, on a Host that is in the catalog: nothing here turns it off.
        let isOn = wizard.isAlreadyOn(server.key)
        let isChecked = isOn || wizard.checked.contains(server.key)
        return Button {
            if isChecked {
                wizard.checked.remove(server.key)
            } else {
                wizard.checked.insert(server.key)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked && !isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.key.label)
                        .foregroundStyle(isOn ? Color.secondary : Color.primary)
                    Text(isOn ? String(localized: "Already on") : server.stateLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOn)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
        .accessibilityIdentifier("hosts.wizard.server.\(server.key.kind.rawValue).\(server.key.name)")
    }

    /// `Heeler looked for Herdr TUI, herdr-core and tmux.`
    private func lookedForLine(_ scan: HostServerScan) -> String {
        let kinds = scan.missing.map(\.kind.displayName)
        return String(localized: "Heeler looked for \(kinds.formatted(.list(type: .and))).")
    }

    // MARK: Actions

    private var actionBar: some View {
        VStack(spacing: 6) {
            switch wizard.step {
            case .connect:
                if wizard.failure != nil, !wizard.isConnecting {
                    primary(String(localized: "Try Again"), isEnabled: wizard.canConnect) { connect() }
                    // A Host that is in the catalog is saved already.
                    if wizard.existing == nil {
                        secondary(String(localized: "Save Without Connecting"), isEnabled: wizard.canConnect) { finish() }
                    }
                } else {
                    primary(
                        wizard.isConnecting ? String(localized: "Connecting…") : String(localized: "Connect"),
                        isBusy: wizard.isConnecting, isEnabled: wizard.canConnect
                    ) { connect() }
                }
            case .trust:
                if wizard.isLookingAfterTrust {
                    primary(String(localized: "Looking for servers…"), isBusy: true, isEnabled: false) {}
                } else {
                    primary(String(localized: "Trust and Continue")) {
                        // The next key, a Jump Host's then the Host's, has its own command.
                        didCopyCommand = false
                        wizard.trust()
                    }
                    secondary(String(localized: "Don't Trust")) {
                        wizard.declineTrust()
                        dismiss()
                    }
                }
            case .servers:
                if wizard.scan?.servers.isEmpty == true {
                    primary(
                        wizard.isScanningAgain
                            ? String(localized: "Looking for servers…") : String(localized: "Scan Again"),
                        isBusy: wizard.isScanningAgain, isEnabled: !wizard.isScanningAgain && !wizard.isSaving
                    ) {
                        Task { await wizard.scanAgain() }
                    }
                    secondary(finishTitle, isEnabled: !wizard.isScanningAgain && !wizard.isSaving) { finish() }
                } else {
                    primary(finishTitle, isBusy: wizard.isSaving, isEnabled: !wizard.isSaving) { finish() }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var finishTitle: String {
        let count = wizard.checkedCount
        // Nothing is added to a Host that is in the catalog: its Servers turn on.
        guard wizard.existing == nil else {
            guard count > 0 else { return String(localized: "Done") }
            return String(
                localized: "Turn On \(count) Servers",
                comment: "Button on Add Host's last step for a Host that is already added. Argument: how many servers are checked.")
        }
        guard count > 0 else { return String(localized: "Add Host Without Servers") }
        return String(
            localized: "Add Host with \(count) Servers",
            comment: "Button on Add Host's last step. Argument: how many servers are checked.")
    }

    private func primary(
        _ title: String, isBusy: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView() }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!isEnabled)
        .accessibilityIdentifier("hosts.wizard.primary")
    }

    private func secondary(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!isEnabled)
            .accessibilityIdentifier("hosts.wizard.secondary")
    }

    private func connect() {
        didCopyCommand = false
        Task { await wizard.connect() }
    }

    private func finish() {
        Task {
            let switcher = HostServerSwitch(catalog: catalog, dependencies: dependencies)
            guard let member = await wizard.finish(switcher: switcher, discoveries: discoveries) else { return }
            if wizard.saveFailure == nil {
                close(pointingAt: member)
            } else {
                savedMember = member
            }
        }
    }

    private func close(pointingAt member: Host.ID) {
        dismiss()
        onAdded(member)
    }
}

/// Where the wizard is among its three steps.
private struct NewHostWizardSteps: View {
    let current: NewHostWizard.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(NewHostWizard.Step.allCases, id: \.self) { @Sendable [current] step in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(step.rawValue <= current.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(height: 4)
                    Text(step.title)
                        .font(.caption.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "Step \(current.rawValue + 1) of \(NewHostWizard.Step.allCases.count), \(current.title)"))
    }
}

extension NewHostWizard.Step {
    var title: String {
        switch self {
        case .connect: String(localized: "Connect")
        case .trust: String(localized: "Trust")
        case .servers: String(localized: "Servers")
        }
    }
}
