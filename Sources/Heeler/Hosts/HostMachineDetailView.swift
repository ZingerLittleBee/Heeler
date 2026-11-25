import SwiftUI

/// Host detail (ADR 0047): the Servers found on a Host, each switched on or
/// off, then how the Host is reached. A Server that is on leads to its own
/// page; one that is off is only a switch. The connection is the Host's: its
/// Servers share one route, shown and reconnected here (ADR 0058).
struct HostMachineDetailView: View {
    let catalog: HostStore
    let discoveries: HostServerDiscoveryStore
    let removal: HostRemovalStore
    /// The Console's connections to the Host's Servers.
    let console: HostConsoleLink

    private let dependencies: HostOnboardingDependencies
    /// A record of the Host. Records come and go with its Servers, so the page
    /// moves to another before this one goes.
    @State private var anchor: Host.ID
    /// How the Host was reached when last seen: it finds the Host again once
    /// `anchor` is gone.
    @State private var connection: HostMachine.Connection?
    @State private var scanner: HostServerScanner
    /// What this visit's last look found.
    @State private var scan: HostServerScan?
    /// Counts the looks that reached the Host, each of which may bring its
    /// connection back (ADR 0058).
    @State private var looksThatReached = 0
    /// The Servers that were new when the page opened or turned up since. The
    /// list stops pointing at them once they are seen here; this page keeps
    /// pointing until it closes.
    @State private var newServers: Set<HostServerKey> = []
    /// Servers being turned on, their switches busy.
    @State private var turningOn: Set<HostServerKey> = []
    @State private var switchFailure: String?
    @State private var isEditing = false
    @State private var isAddingByName = false
    @State private var isShowingSetupGuide = false
    @State private var isConfirmingHostKeyReplacement = false
    /// Updates, opened on the item whose failed row asked why.
    @State private var updatesRequest: HostUpdatesRequest?
    @Environment(\.hostRemovalDependencies) private var removalDependencies
    /// What Heeler installed on the Host; nil in previews and tests.
    @Environment(HostUpdatesStore.self) private var updates: HostUpdatesStore?
    @Environment(\.dismiss) private var dismiss

    init(
        catalog: HostStore,
        member: Host.ID,
        discoveries: HostServerDiscoveryStore,
        removal: HostRemovalStore,
        dependencies: HostOnboardingDependencies,
        console: HostConsoleLink = HostConsoleLink()
    ) {
        self.catalog = catalog
        self.discoveries = discoveries
        self.removal = removal
        self.dependencies = dependencies
        self.console = console
        _anchor = State(initialValue: member)
        _connection = State(initialValue: catalog.machine(containing: member)?.id)
        _scanner = State(initialValue: HostServerScanner(dependencies: dependencies))
    }

    private var machine: HostMachine? {
        if let machine = catalog.machine(containing: anchor) { return machine }
        guard let connection else { return nil }
        return catalog.machines.first { $0.id == connection }
    }

    var body: some View {
        Group {
            if let machine {
                page(machine)
            } else {
                ContentUnavailableView("Host removed", systemImage: "server.rack")
            }
        }
        .onChange(of: catalog.hosts) { follow() }
        // A Host reached another way is another Host to look at.
        .task(id: connection) { await look() }
        // The Console never asks about a key, so a dial it stopped at one is
        // answered by a look, which asks (ADR 0058). A key the user just
        // declined is not asked about again until they look themselves.
        .onChange(of: connectionAsksForKey) { _, asks in
            guard asks, !scanner.isLooking, !lastLookWasDeclined else { return }
            Task { await look() }
        }
        // Decided here, where the Console's word is current: the look that
        // counted may have begun long before it ended.
        .onChange(of: looksThatReached) {
            guard let machine else { return }
            Task { await console.redialAfterLook(at: machine) }
        }
        .onDisappear { scanner.cancel() }
    }

    private var connectionAsksForKey: Bool {
        machine.map { console.lookFollowUp(of: $0).asksForKey } ?? false
    }

    private var lastLookWasDeclined: Bool {
        if case .failed(let failure) = scanner.phase { failure.isDeclinedTrust } else { false }
    }

    /// Keeps hold of the Host through a change to its records, and leaves once
    /// it has none.
    private func follow() {
        guard let machine else {
            dismiss()
            return
        }
        if !machine.contains(anchor) { anchor = machine.representative.id }
        connection = machine.id
    }

    private func page(_ machine: HostMachine) -> some View {
        List {
            serversSection(machine)
            routesSection(machine)
            if let replacement = scanner.pendingHostKeyReplacement {
                HostKeyReplacementSection(replacement: replacement) {
                    isConfirmingHostKeyReplacement = true
                }
            }
            if let updates {
                HostUpdatesSection(store: updates, machine: machine) { item in
                    updatesRequest = HostUpdatesRequest(item: item)
                }
            }
            accountSection(machine)
            Section {
                Button("Remove Host", role: .destructive) {
                    removal.requestRemoval(machine.members.map(\.id), dependencies: removalDependencies)
                }
                .accessibilityIdentifier("hosts.host.remove")
            }
        }
        .readableColumnPage()
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .modifier(
            HostMachineDetailSheets(
                catalog: catalog, machine: machine, scan: scan, isEditing: $isEditing,
                isAddingByName: $isAddingByName, isShowingSetupGuide: $isShowingSetupGuide,
                turnOn: { turnOn($0) }))
        .modifier(HostUpdatesSheet(store: updates, request: $updatesRequest))
        .alert("Trust this Host?", isPresented: fingerprintAlertPresented, presenting: scanner.pendingFingerprint) { _ in
            Button("Trust") { scanner.confirmFingerprint(trusted: true) }
            Button("Don't Trust", role: .cancel) { scanner.confirmFingerprint(trusted: false) }
        } message: { candidate in
            Text(
                String(localized: "First connection to \(candidate.host):\(String(candidate.port)).\n\nKey fingerprint:\n\(candidate.fingerprint.displayString)\n\nVerify it matches the Host's key before trusting."))
        }
        .hostKeyReplacementAlert(scanner.pendingHostKeyReplacement, isPresented: $isConfirmingHostKeyReplacement) {
            let records = machine.members.map(\.id)
            Task {
                await scanner.trustPresentedHostKey(for: records)
                await look()
            }
        }
        .alert("Could Not Turn On", isPresented: switchFailurePresented) {
            Button("OK", role: .cancel) { switchFailure = nil }
        } message: {
            Text(switchFailure ?? "")
        }
    }

    /// Presentation tracks the pending candidate; dismissal is decided by the
    /// buttons or the scanner's own timeout, never by the binding.
    private var fingerprintAlertPresented: Binding<Bool> {
        Binding(get: { scanner.pendingFingerprint != nil }, set: { _ in })
    }

    private var switchFailurePresented: Binding<Bool> {
        Binding(get: { switchFailure != nil }, set: { if !$0 { switchFailure = nil } })
    }

    // MARK: Servers

    /// One row of the Servers list: a Server that is on, by its record, or one
    /// a look found that is off.
    private struct ServerRow: Identifiable {
        /// The Server, so a row keeps its place while its switch is thrown. A
        /// second record of the same Server has a row of its own.
        enum ID: Hashable {
            case server(HostServerKey)
            case duplicate(Host.ID)
        }

        let id: ID
        let key: HostServerKey
        let record: Host?
        let found: FoundServer?
    }

    /// Every Server known on the Host, in an order a switch does not disturb:
    /// by kind, a kind's default first, then by name.
    private func serverRows(_ machine: HostMachine) -> [ServerRow] {
        let found = discoveries.found(on: machine.id)
        // Pairing a machine twice, or a catalog from before Hosts listed
        // Servers, can leave two records for one Server. Each stays removable.
        var listed: Set<HostServerKey> = []
        var rows = machine.servers.compactMap { record -> ServerRow? in
            guard let key = record.serverKey else { return nil }
            let id: ServerRow.ID = listed.insert(key).inserted ? .server(key) : .duplicate(record.id)
            return ServerRow(id: id, key: key, record: record, found: found.first { $0.key == key })
        }
        rows += found.filter { !listed.contains($0.key) }.map {
            ServerRow(id: .server($0.key), key: $0.key, record: nil, found: $0)
        }
        let kinds: [ServerKind] = [.herdrTUI, .herdrCore, .tmux, .rex]
        return rows.sorted { lhs, rhs in
            let left = (
                kinds.firstIndex(of: lhs.key.kind) ?? kinds.count, lhs.key.distinguishingName ?? "",
                lhs.record?.id.uuidString ?? ""
            )
            let right = (
                kinds.firstIndex(of: rhs.key.kind) ?? kinds.count, rhs.key.distinguishingName ?? "",
                rhs.record?.id.uuidString ?? ""
            )
            return left < right
        }
    }

    private func serversSection(_ machine: HostMachine) -> some View {
        let rows = serverRows(machine)
        return Section {
            if case .failed(let failure) = scanner.phase, !failure.isDeclinedTrust {
                lookFailureRow(failure)
            }
            if rows.isEmpty, scanner.isLooking {
                Text("Looking for servers…")
                    .foregroundStyle(.secondary)
            } else if rows.isEmpty, scan != nil {
                Text("No servers found")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { @Sendable row in
                MainActorContent { serverRow(row, on: machine) }
            }
            if let scan {
                ForEach(scan.missing, id: \.kind) { @Sendable missing in
                    MainActorContent { missingRow(missing) }
                }
            }
            Button("Add by Name…") { isAddingByName = true }
                .accessibilityIdentifier("hosts.host.addByName")
        } header: {
            serversHeader
        } footer: {
            Text(
                "Heeler shows the Agents, Terminals and notifications of every server that is on. Switching one off changes nothing on \(machine.name). Servers it finds later arrive switched off.")
        }
    }

    private var serversHeader: some View {
        HStack {
            Text("Servers")
            if scanner.isLooking {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 4)
            }
            Spacer()
            Group {
                if scanner.isLooking {
                    Button("Cancel", role: .cancel) { scanner.cancel() }
                        .accessibilityHint("Stops looking without waiting for the timeout")
                } else {
                    Button("Scan Again") {
                        Task { await look() }
                    }
                    .accessibilityIdentifier("hosts.host.scanAgain")
                }
            }
            .font(.subheadline)
            .textCase(nil)
        }
    }

    private func serverRow(_ row: ServerRow, on machine: HostMachine) -> some View {
        let name = "\(row.key.kind.rawValue).\(row.key.name)"
        let isBusy =
            turningOn.contains(row.key) || row.record.map { removalDependencies.inFlight.contains($0.id) } == true
        return HStack(spacing: 12) {
            if let record = row.record {
                // On: the name opens the Server's page. The switch sits beside
                // the link, not in it, so each is its own target and VoiceOver
                // reads both.
                NavigationLink(value: HostDetailDestination.server(record.id)) {
                    serverTitle(row, state: console.stateLine(of: record, found: row.found))
                }
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityIdentifier("hosts.host.serverPage.\(name)")
            } else {
                serverTitle(row, state: nil)
                    .accessibilityElement(children: .combine)
            }
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Toggle(row.key.label, isOn: isOn(row))
                    .labelsHidden()
                    .accessibilityIdentifier("hosts.host.server.\(name)")
            }
            // The chevron the link would draw, kept on every row so the
            // switches line up.
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(row.record == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
    }

    /// Under a Server's name: its own state. While it is off, what the last
    /// look saw of it. The connection is the Host's, in Routes (ADR 0058).
    private func serverTitle(_ row: ServerRow, state: HostServerStateLine?) -> some View {
        let line = if let state { state.text } else { row.found?.stateLine ?? String(localized: "Off") }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.key.label)
                if row.record == nil, newServers.contains(row.key) {
                    HostRouteTag(text: String(localized: "New"), tint: .blue)
                }
            }
            if let line {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(state?.isProblem == true ? Color.errorInk : Color.secondary)
                    // A reason is longer than the switch leaves room for on
                    // one line.
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isOn(_ row: ServerRow) -> Binding<Bool> {
        Binding(
            get: { row.record != nil },
            set: { isOn in
                if isOn {
                    turnOn(row.key)
                } else if let record = row.record {
                    let dependencies = removalDependencies
                    Task { await removal.turnOff(record.id, dependencies: dependencies) }
                }
            })
    }

    @ViewBuilder
    private func missingRow(_ missing: HostServerScan.Missing) -> some View {
        if missing.kind == .rex {
            // The Setup Guide sets up herdr. A Rex named missing runs already,
            // under an account this one cannot use (ADR 0049).
            missingLabel(title: missing.kind.displayName, note: missing.note)
                .accessibilityElement(children: .combine)
        } else {
            Button {
                isShowingSetupGuide = true
            } label: {
                LabeledContent {
                    Text("Setup Guide")
                        .foregroundStyle(.tint)
                } label: {
                    missingLabel(
                        title: String(localized: "\(missing.kind.displayName) not found"), note: missing.note)
                }
            }
        }
    }

    private func missingLabel(title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // A color, not the hierarchical style: inside a button that
            // one is a shade of the tint.
            Text(title)
                .foregroundStyle(Color.secondary)
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func lookFailureRow(_ failure: HostServerScanner.Failure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.summary)
                        .font(.headline)
                    Text(failure.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let loginURL = failure.overlayLoginURL {
                Link(destination: loginURL) {
                    Label("Open Sign-In Link", systemImage: "person.badge.key")
                }
            }
        }
        .accessibilityIdentifier("hosts.host.lookFailure")
    }

    // MARK: Connection

    private func routesSection(_ machine: HostMachine) -> some View {
        HostRoutesSection(
            routes: machine.representative.routes,
            presentation: console.routes(of: machine),
            reconnect: action(console.reconnect, on: machine),
            stopConnecting: action(console.stopConnecting, on: machine))
    }

    /// One of the Console's Host actions as a button's, for this Host.
    private func action(
        _ run: (@MainActor @Sendable (HostMachine) async -> Void)?, on machine: HostMachine
    ) -> (@MainActor () -> Void)? {
        guard let run else { return nil }
        return { Task { await run(machine) } }
    }

    private func accountSection(_ machine: HostMachine) -> some View {
        Section("Account") {
            LabeledContent("User", value: machine.representative.username)
            LabeledContent("Authentication", value: machine.representative.authMethod.displayName)
        }
    }

    // MARK: Actions

    /// Looks at the Host once. What it finds is kept for the next visit, and
    /// counts as seen: the user is looking at it.
    private func look() async {
        guard let machine else { return }
        let record = machine.representative
        newServers.formUnion(discoveries.unseen(on: machine).map(\.key))
        discoveries.markShown(on: machine.id)
        guard let found = await scanner.look(at: record) else { return }
        scan = found
        await HostServerSwitch(catalog: catalog, dependencies: dependencies).shareTrust(of: record.id)
        // The Host as it is now: a switch may have been thrown meanwhile.
        guard let machine = self.machine else { return }
        discoveries.note(found, on: machine.id)
        newServers.formUnion(discoveries.unseen(on: machine).map(\.key))
        discoveries.markShown(on: machine.id)
        looksThatReached += 1
    }

    private func turnOn(_ server: HostServerKey) {
        guard !turningOn.contains(server) else { return }
        turningOn.insert(server)
        let switcher = HostServerSwitch(catalog: catalog, dependencies: dependencies)
        Task {
            defer { turningOn.remove(server) }
            do {
                try await switcher.turnOn(server, onHostOf: anchor, scan: scan)
            } catch {
                switchFailure = switcher.refusal(error, turningOn: server)
            }
        }
    }
}

/// Host detail's sheets, in a chain of their own: joined to the page's, the
/// chain exceeds Xcode 26.6's type-checking limit.
private struct HostMachineDetailSheets: ViewModifier {
    let catalog: HostStore
    let machine: HostMachine
    let scan: HostServerScan?
    @Binding var isEditing: Bool
    @Binding var isAddingByName: Bool
    @Binding var isShowingSetupGuide: Bool
    let turnOn: (HostServerKey) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isEditing) {
                HostFormView(store: catalog, editing: machine.formRecord)
            }
            .sheet(isPresented: $isAddingByName) {
                HostServerNameSheet(machine: machine, isNativeWindows: scan?.isNativeWindows == true, onTurnOn: turnOn)
            }
            .sheet(isPresented: $isShowingSetupGuide) {
                NavigationStack {
                    HostSetupGuideView(onClose: { isShowingSetupGuide = false })
                }
            }
    }
}

/// Turns on a Server a look cannot find: a session or socket by a name the
/// user knows, running or not. Rex is not among the kinds: a Host's one Rex
/// Server has no name to type, and a look lists it wherever Rex is installed
/// (ADR 0049).
private struct HostServerNameSheet: View {
    let machine: HostMachine
    let isNativeWindows: Bool
    let onTurnOn: (HostServerKey) -> Void

    @State private var kind: ServerKind = .herdrTUI
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    private var server: HostServerKey { HostServerKey(kind: kind, name: name) }

    private var refusal: String? {
        if let refusal = kind.sessionNameRefusal(name) { return refusal }
        if isNativeWindows, kind == .herdrCore, let refusal = HerdrCoreSessionName.windowsRefusal(name) {
            return refusal
        }
        return machine.record(of: server) == nil ? nil : String(localized: "This server is already on.")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        Text(ServerKind.herdrTUI.displayName).tag(ServerKind.herdrTUI)
                        Text(ServerKind.herdrCore.displayName).tag(ServerKind.herdrCore)
                        Text(ServerKind.tmux.displayName).tag(ServerKind.tmux)
                    }
                    TextField(kind == .tmux ? "Socket (blank for default)" : "Session (blank for default)", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("hosts.host.addByName.name")
                } footer: {
                    if let refusal {
                        Text(refusal)
                            .foregroundStyle(.errorInk)
                    } else {
                        Text(
                            "For a session or socket that Scan Again does not list. Heeler connects to it by this name once it runs on \(machine.name).")
                    }
                }
            }
            .navigationTitle("Add by Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Turn On") {
                        onTurnOn(server)
                        dismiss()
                    }
                    .disabled(refusal != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension HostMachine {
    /// The record the Host form edits: one of the Host's own, under the name
    /// the Host goes by, which a save then gives every record.
    var formRecord: Host {
        var record = representative
        record.name = givenName
        return record
    }
}

extension Host.AuthMethod {
    var displayName: String {
        switch self {
        case .deviceKey: String(localized: "Device Key")
        case .rsaKey: String(localized: "RSA Key")
        case .password: String(localized: "Password")
        }
    }
}
