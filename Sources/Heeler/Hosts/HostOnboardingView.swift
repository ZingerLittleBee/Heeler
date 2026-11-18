import SwiftUI

/// One Server's page (#14, ADR 0047): the preflight checklist with fix-it
/// hints, plus the TOFU fingerprint confirmation. Checks run automatically
/// on arrival; the goal is zero to green checkmarks without desktop docs.
/// The connection, its routes and the switch that keeps the Server in
/// Heeler are its Host's, on Host detail behind this page (ADR 0058).
struct HostOnboardingView: View {
    /// The catalog's copy of this Host. Onboarding restarts for it when it
    /// changes (see `adopt`).
    let host: Host
    /// The Host catalog: the Host this Server is on, and its other records.
    let catalog: HostStore
    let usage: AgentUsageStore?
    /// Shows this Host on the Usage tab; nil where the Host detail stands
    /// outside the Console.
    let openUsage: (() -> Void)?
    /// The Console's connection to this Server, which the checks follow.
    let connectionStatus: EventsSessionStatus?
    /// Why this connected Host's Agents could not be synced.
    let syncIssue: String?
    /// The variables the connected core inherited, on a herdr-core Host.
    let coreEnvironmentNotice: HerdrCoreEnvironmentNotice?
    /// The Console, for the harness edits this device applied on this Host.
    let harnessEdits: ConsoleStore?
    /// True while Console is serving a Reconnect press for this Server (the
    /// retry call plus the 1.2 s visual-feedback hold). Distinct from
    /// `EventsSessionStatus.reconnecting`.
    let isManualReconnectInFlight: Bool
    /// Dials this Server again once its checks pass. The page has no button
    /// for it: Reconnect is the Host's.
    let retryConnection: (@MainActor @Sendable () async -> Void)?
    private let dependencies: HostOnboardingDependencies
    @State private var store: HostOnboardingStore
    /// Set by a route change until its first checks finish, which then ask
    /// about a changed key at once: the edit may now reach another machine.
    @State private var offersHostKeyReplacement = false
    @State private var isConfirmingHostKeyReplacement = false
    @State private var sessionSelectionError: String?
    /// A passing preflight not yet acted on: it may restart the Console's
    /// connection once (see `HostOnboardingConsoleRecovery`).
    @State private var isConsoleRecoveryArmed = false
    @State private var isShowingPluginNotice = false
    @State private var isShowingHostHelper = false
    /// Asked for by whoever opened this page, until the Helper sheet first shows.
    @State private var opensHostHelperOnArrival: Bool

    init(
        host: Host,
        catalog: HostStore,
        usage: AgentUsageStore? = nil,
        openUsage: (() -> Void)? = nil,
        connectionStatus: EventsSessionStatus? = nil,
        syncIssue: String? = nil,
        coreEnvironmentNotice: HerdrCoreEnvironmentNotice? = nil,
        harnessEdits: ConsoleStore? = nil,
        isManualReconnectInFlight: Bool = false,
        retryConnection: (@MainActor @Sendable () async -> Void)? = nil,
        opensHostHelper: Bool = false,
        dependencies: HostOnboardingDependencies = HostOnboardingDependencies()
    ) {
        self.host = host
        self.catalog = catalog
        self.usage = usage
        self.openUsage = openUsage
        self.connectionStatus = connectionStatus
        self.syncIssue = syncIssue
        self.coreEnvironmentNotice = coreEnvironmentNotice
        self.harnessEdits = harnessEdits
        self.isManualReconnectInFlight = isManualReconnectInFlight
        self.retryConnection = retryConnection
        self.dependencies = dependencies
        _store = State(initialValue: Self.makeStore(host, dependencies))
        _opensHostHelperOnArrival = State(initialValue: opensHostHelper)
    }

    static func makeStore(
        _ host: Host, _ dependencies: HostOnboardingDependencies
    ) -> HostOnboardingStore {
        HostOnboardingStore(
            host: host,
            connector: dependencies.connector,
            knownHosts: dependencies.knownHosts,
            credentials: dependencies.credentials,
            hostHelperDidChange: dependencies.hostHelperDidChange,
            harnessEdits: dependencies.harnessEdits,
            noteTmuxPaths: dependencies.noteTmuxPaths,
            notePlugin: dependencies.notePlugin,
            noteRexSocket: dependencies.noteRexSocket)
    }

    /// The page with its sheets, outside `page`'s modifier chain, which
    /// stays under Xcode 26.6's type-checking limit.
    var body: some View {
        page
            .onChange(of: host) { _, updated in
                adopt(updated)
            }
            .onChange(of: store.phase) { _, phase in
                guard phase == .finished, offersHostKeyReplacement else { return }
                offersHostKeyReplacement = false
                isConfirmingHostKeyReplacement = store.pendingHostKeyReplacement != nil
            }
            .sheet(isPresented: $isShowingHostHelper) {
                if let helper = store.hostHelper { HostHelperSheet(store: helper) }
            }
            .modifier(
                HostHelperOnArrival(
                    isReady: store.hostHelper != nil, isRequested: $opensHostHelperOnArrival,
                    isShowing: $isShowingHostHelper))
    }

    /// Restarts onboarding for a changed Host: a selected session, or an edit
    /// made in Host detail.
    private func adopt(_ updated: Host) {
        guard updated != store.host else { return }
        offersHostKeyReplacement = updated.routes != store.host.routes
        store = Self.makeStore(updated, dependencies)
        isConfirmingHostKeyReplacement = false
        sessionSelectionError = nil
        isConsoleRecoveryArmed = false
        isShowingPluginNotice = false
        isShowingHostHelper = false
    }

    private var listPage: some View {
        List {
            syncIssueSection

            if let replacement = store.pendingHostKeyReplacement {
                HostKeyReplacementSection(replacement: replacement) {
                    isConfirmingHostKeyReplacement = true
                }
            }

            integrationSection

            preflightSection
            HerdrCoreStartSection(store: store)
            if let coreEnvironmentNotice {
                HerdrCoreEnvironmentSection(notice: coreEnvironmentNotice)
            }
            if let harnessEdits {
                HarnessConfigEditsSection(console: harnessEdits, hostID: store.host.id)
                if store.host.serverKind == .tmux, harnessEdits.hostStatuses[store.host.id] == .connected {
                    ClaudeCodeHooksSection(flow: harnessEdits.claudeCodeHooksFlow(on: store.host.id))
                }
            }

            if let usage, store.host.serverKind.hasHostIntegrations {
                AgentUsageSection(
                    hostID: store.host.id, hostName: store.host.displayName, store: usage,
                    openUsage: openUsage)
            }

            availableSessionsSection

            overlaySignInSection
        }
        .readableColumnPage()
        .refreshable {
            if let usage { await usage.pullToRefresh() }
        }
        .navigationTitle(store.host.serverKey?.label ?? store.host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .pluginNoticeSheet(
            pluginPresentation.notice, isPresented: $isShowingPluginNotice,
            actionState: store.pluginAction,
            runAction: { action in Task { await store.runPluginAction(action) } },
            runChecks: { Task { await store.runChecks() } })
        .alert(
            "Trust this Host?",
            isPresented: fingerprintAlertPresented,
            presenting: store.pendingFingerprint
        ) { _ in
            Button("Trust") { store.confirmFingerprint(trusted: true) }
            Button("Don't Trust", role: .cancel) { store.confirmFingerprint(trusted: false) }
        } message: { candidate in
            Text(
                String(localized: "First connection to \(candidate.host):\(String(candidate.port)).\n\nKey fingerprint:\n\(candidate.fingerprint.displayString)\n\nVerify it matches the Host's key before trusting."))
        }
        // Also opens on its own after a route edit.
        .hostKeyReplacementAlert(store.pendingHostKeyReplacement, isPresented: $isConfirmingHostKeyReplacement) {
            // One Host presents one key, whichever of its Servers is asked.
            let siblings = hostMachine?.members.map(\.id).filter { $0 != store.host.id } ?? []
            Task { await store.trustPresentedHostKey(sharedWith: siblings) }
        }
        .alert(
            "Could Not Select Session",
            isPresented: sessionSelectionErrorPresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionSelectionError ?? "")
        }
    }

    /// The page and what follows its checks, in a chain of their own: joined to
    /// `listPage`'s, the chain exceeded Xcode 26.6's type-checking limit.
    private var page: some View {
        listPage
        // A new store, after `adopt`, cancels the old one's checks.
        .task(id: ObjectIdentifier(store)) {
            if store.phase == .idle {
                await store.runChecks()
            }
        }
        .onChange(of: store.report) { _, report in
            handleReportChange(report)
        }
        .onChange(of: consoleRecoveryInput) { _, input in
            switch HostOnboardingConsoleRecovery.action(for: input) {
            case .wait:
                break
            case .disarm:
                isConsoleRecoveryArmed = false
            case .retry:
                isConsoleRecoveryArmed = false
                retry()
            }
        }
        .onChange(of: store.coreStart) { _, coreStart in
            let action = HostOnboardingCoreFollow.action(
                afterCoreStart: coreStart, reportPassed: store.report == .allPassed, status: connectionStatus)
            if action == .wakeConsole { retry() }
        }
        // The reading, not the status: every backoff would otherwise count.
        .onChange(of: HostOnboardingCoreFollow.reading(connectionStatus)) { _, reading in
            let action = HostOnboardingCoreFollow.action(
                afterConsoleReads: reading, serverKind: store.host.serverKind, phase: store.phase,
                coreStart: store.coreStart, reportPassed: store.report == .allPassed,
                offersStart: store.coreStartOffer != nil || store.isWaitingForTmuxServer)
            if action == .runChecks { Task { await store.runChecks() } }
        }
    }

    /// The checklist of a Host whose kind is confirmed, over the version the
    /// Server reported.
    private var preflightSection: some View {
        Section {
            ForEach(PreflightCheck.cases(for: store.host.serverKind), id: \.self) { @Sendable check in
                MainActorContent {
                    PreflightCheckRow(
                        title: check.title(for: store.host.serverKind), status: status(for: check))
                }
            }
        } header: {
            preflightHeader
        } footer: {
            if let info = store.serverInfo, store.host.serverKind == .herdrTUI {
                // The notice is advisory and the checks still pass: a Host
                // newer than this build is usable, just not fully known.
                Text(
                    info.exceedsGeneratedProtocol
                        ? String(localized: "herdr \(info.version) · protocol \(info.protocolVersion) — newer than this app was built against, so features added after protocol \(HeelerSSHTransport.generatedProtocolVersion) may be unavailable.")
                        : String(localized: "herdr \(info.version) · protocol \(info.protocolVersion)"))
            } else if store.serverKindSummary != store.host.serverKind.displayName {
                // A core's or tmux's version, once the checks have read it.
                Text(store.serverKindSummary)
                    .accessibilityIdentifier("hosts.detail.serverKind")
            }
        }
    }

    private var consoleRecoveryInput: HostOnboardingConsoleRecovery.Input {
        HostOnboardingConsoleRecovery.Input(
            isArmed: isConsoleRecoveryArmed,
            status: connectionStatus,
            isManualReconnectInFlight: isManualReconnectInFlight)
    }

    /// The Host this Server is on.
    private var hostMachine: HostMachine? {
        catalog.machine(containing: store.host.id)
    }

    /// Why this connected Server's Agents could not be synced. It is still
    /// connected: the Console's orange, not a failure's red.
    @ViewBuilder
    private var syncIssueSection: some View {
        if case .connected = connectionStatus, let syncIssue {
            Section {
                Label {
                    Text(syncIssue)
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .foregroundStyle(HostConnectionTone.warning.tint)
                }
                .accessibilityIdentifier("hosts.detail.syncIssue")
            }
        }
    }

    /// What Heeler installed for this Server on the Host, and where a paired
    /// herdr lives. Nothing for a Server with none of them.
    @ViewBuilder
    private var integrationSection: some View {
        let showsPlugin = store.host.serverKind == .herdrTUI || store.host.serverKind == .herdrCore
        if showsPlugin || store.hostHelper != nil || store.host.herdrEndpoint != nil {
            Section {
                herdrEndpointRows
                if showsPlugin { pluginRow }
                if let helper = store.hostHelper { hostHelperRow(helper) }
            }
        }
    }

    /// Presentation tracks the pending candidate; dismissal is decided by
    /// the buttons (or the store's own timeout), never by the binding, so a
    /// dismiss-then-answer race cannot double-resolve the decision.
    private var fingerprintAlertPresented: Binding<Bool> {
        Binding(
            get: { store.pendingFingerprint != nil },
            set: { _ in })
    }

    /// Out of the body's modifier chain: inline, this closure exceeded
    /// Xcode 26.6's type-checking limit for the whole body.
    private var sessionSelectionErrorPresented: Binding<Bool> {
        Binding(
            get: { sessionSelectionError != nil },
            set: { isPresented in
                if !isPresented { sessionSelectionError = nil }
            })
    }

    /// Where a Pairing Code v2 Host's herdr lives; nothing for other Hosts.
    @ViewBuilder
    private var herdrEndpointRows: some View {
        if let herdrEndpoint = store.host.herdrEndpoint {
            LabeledContent("herdr Socket", value: herdrEndpoint.socketPath)
            LabeledContent("herdr Launcher", value: herdrEndpoint.executablePath)
        }
    }

    private func handleReportChange(_ report: PreflightReport?) {
        isConsoleRecoveryArmed = report == .allPassed
        let action = HostOnboardingCoreFollow.action(
            afterTmuxChecks: report == .allPassed,
            isWaitingForServer: store.isWaitingForTmuxServer,
            serverKind: store.host.serverKind,
            status: connectionStatus)
        if action == .wakeConsole { retry() }
    }

    private func retry() {
        guard !isManualReconnectInFlight, let retryConnection else { return }
        Task { @MainActor in
            await retryConnection()
        }
    }

    private func status(for check: PreflightCheck) -> PreflightCheckStatus? {
        store.report?[check]
    }

    /// Preflight, with Run Checks Again (Cancel Checks while running) at
    /// its end: within reach, unlike a button below every check on a tall
    /// screen. Out of `body`, which stays under Xcode 26.6's type-checking
    /// limit.
    private var preflightHeader: some View {
        HStack {
            Text("Preflight")
            if store.phase == .running {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 4)
            }
            Spacer()
            Group {
                if store.phase == .running {
                    Button("Cancel Checks", role: .cancel) {
                        store.cancelChecks()
                    }
                    .accessibilityHint("Stops connecting without waiting for the timeout")
                } else {
                    Button("Run Checks Again") {
                        Task { await store.runChecks() }
                    }
                    .disabled(store.pluginAction == .running || store.coreStart == .running)
                }
            }
            .font(.subheadline)
            .textCase(nil)
        }
    }

    /// The overlay sign-in link, while a check is waiting on it.
    @ViewBuilder
    private var overlaySignInSection: some View {
        if let loginURL = store.overlayLoginURL {
            Section {
                Link(destination: loginURL) {
                    Label("Open Sign-In Link", systemImage: "person.badge.key")
                }
            } footer: {
                Text("Sign in to the overlay network in the browser, then run the checks again.")
            }
        }
    }

    private var pluginPresentation: HeelerPluginPresentation {
        store.pluginPresentation
    }

    /// The installed version. When the user has something to do on the Host
    /// (install, update, enable, or replace the plugin) the row carries an
    /// icon and opens the details.
    @ViewBuilder
    private var pluginRow: some View {
        let presentation = pluginPresentation
        if let notice = presentation.notice {
            Button {
                isShowingPluginNotice = true
            } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(presentation.value)
                        if store.pluginAction == .running {
                            ProgressView()
                                .controlSize(.small)
                        } else if HeelerPluginPresentation.unattendedUpdate(
                            for: store.pluginStatus, on: store.host) != nil
                        {
                            // Nothing is wrong with what is installed.
                            HostUpdateMark()
                        } else {
                            PluginNoticeIcon(tone: notice.tone)
                        }
                    }
                } label: {
                    // Not the button tint: the row reads like its neighbors.
                    Text("Heeler Plugin")
                        .foregroundStyle(Color.primary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(notice.message)
            .accessibilityIdentifier("hosts.detail.plugin.version")
        } else {
            LabeledContent("Heeler Plugin", value: presentation.value)
                .accessibilityIdentifier("hosts.detail.plugin.version")
        }
    }

    private func hostHelperRow(_ helper: HostHelperStore) -> some View {
        Button {
            isShowingHostHelper = true
        } label: {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(helper.rowValue)
                    if helper.running != nil {
                        ProgressView()
                            .controlSize(.small)
                    } else if helper.installAction == .update {
                        HostUpdateMark()
                    } else if helper.needsAttention {
                        PluginNoticeIcon(tone: .warning)
                    }
                }
            } label: {
                // Not the button tint: the row reads like its neighbors.
                Text("Host Helper")
                    .foregroundStyle(Color.primary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hosts.detail.hostHelper")
    }

    @ViewBuilder
    private var availableSessionsSection: some View {
        if !store.availableSessions.isEmpty || store.sessionDiscoveryError != nil {
            Section {
                ForEach(store.availableSessions, id: \.name) { @Sendable session in
                    MainActorContent {
                        Button {
                            select(session)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(session.name)
                                    Text(isOnElsewhere(session) ? "Already on" : session.isRunning ? "Running" : "Stopped")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isSelected(session) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(
                            isSelected(session) || isOnElsewhere(session)
                                || (!session.isDefault && !session.isRunning))
                    }
                }
                if let error = store.sessionDiscoveryError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Available Sessions")
            } footer: {
                Text("Stopped named sessions must be started on the Host before selection.")
            }
        }
    }

    private func isSelected(_ session: HerdrSession) -> Bool {
        session.isDefault ? store.host.sessionName.isEmpty : store.host.sessionName == session.name
    }

    /// Whether the Host already has `session` on as a Server of its own, which
    /// this record must not become a second copy of (ADR 0047).
    private func isOnElsewhere(_ session: HerdrSession) -> Bool {
        var moved = store.host
        moved.sessionName = session.isDefault ? "" : session.name
        guard let server = moved.serverKey, let hostMachine else { return false }
        return hostMachine.members.contains { $0.id != store.host.id && $0.serverKey == server }
    }

    private func select(_ session: HerdrSession) {
        do {
            try store.selectSession(session, in: catalog)
        } catch {
            sessionSelectionError = String(localized: "The selected session could not be saved.")
        }
    }
}

/// What a core Host's detail does when the Console finds out something its
/// checks have not. Only ever the locator and `hello`, so nothing here starts a
/// core (ADR 0031). A tmux Host's detail follows its server the same way, with
/// asks that start none (ADR 0044).
enum HostOnboardingCoreFollow {
    /// What the Console says of the core, which is what the checks may contradict.
    enum Reading: Equatable {
        case notRunning
        case connected
        case other
    }

    enum Action: Equatable {
        case none
        case runChecks
        case wakeConsole
    }

    static func reading(_ status: EventsSessionStatus?) -> Reading {
        switch status {
        case .reconnecting(_, _, .herdrCoreNotRunning), .reconnecting(_, _, .tmuxServerNotRunning): .notRunning
        case .connected: .connected
        default: .other
        }
    }

    /// Checks that passed read a core that has since stopped, or checks that offer
    /// Start read one that has since come back. After a Start the checks may fail
    /// on something more exact than not running, so only a pass is run again. For a
    /// tmux Host, `offersStart` is checks that found no server running.
    static func action(
        afterConsoleReads reading: Reading, serverKind: ServerKind, phase: HostOnboardingStore.Phase,
        coreStart: CoreStartState, reportPassed: Bool, offersStart: Bool
    ) -> Action {
        guard serverKind == .herdrCore || serverKind == .tmux, phase == .finished, coreStart != .running
        else { return .none }
        switch reading {
        case .notRunning: return reportPassed ? .runChecks : .none
        case .connected: return offersStart ? .runChecks : .none
        case .other: return .none
        }
    }

    /// A core that just started should not wait out a Console's backoff, up to 30
    /// seconds, with the checks above it all green. A link that is up is left alone.
    static func action(
        afterCoreStart coreStart: CoreStartState, reportPassed: Bool, status: EventsSessionStatus?
    ) -> Action {
        guard reportPassed, case .reconnecting = status else { return .none }
        switch coreStart {
        case .started, .alreadyRunning: return .wakeConsole
        case .idle, .running, .failed: return .none
        }
    }

    /// Checks on a tmux Host that found a running server wake a Console still
    /// backing off or stopped on an install check; checks that found a usable
    /// tmux with no server running wake a Console still stopped on an install check.
    static func action(
        afterTmuxChecks reportPassed: Bool, isWaitingForServer: Bool, serverKind: ServerKind,
        status: EventsSessionStatus?
    ) -> Action {
        guard serverKind == .tmux else { return .none }
        switch status {
        case .failed(.tmuxNotInstalled), .failed(.tmuxUpdateRequired):
            return reportPassed || isWaitingForServer ? .wakeConsole : .none
        case .reconnecting:
            return reportPassed ? .wakeConsole : .none
        default:
            return .none
        }
    }
}

/// A Server's page has no Reconnect of its own: the connection is the
/// Host's (ADR 0058). So checks that pass are what brings a stopped Server
/// back. The Console never prompts for host key trust, and stops for good on
/// a Server that is missing or not running; a passing preflight proves the
/// key is pinned and the Server answers, and arms one Console retry, decided
/// as soon as the Console settles: retry a Server it stopped on or is still
/// backing off from, otherwise disarm, so a later failure never reuses an
/// old proof.
enum HostOnboardingConsoleRecovery {
    struct Input: Equatable {
        let isArmed: Bool
        let status: EventsSessionStatus?
        let isManualReconnectInFlight: Bool
    }

    enum Action: Equatable {
        case wait
        case disarm
        case retry
    }

    static func action(for input: Input) -> Action {
        // A manual Reconnect in flight is already retrying; decide once its
        // outcome is known.
        guard input.isArmed, !input.isManualReconnectInFlight else { return .wait }
        switch input.status {
        case .failed, .reconnecting:
            // The checks just reached the Server: there is nothing to wait
            // out a backoff for.
            return .retry
        case .connecting:
            return .wait
        case .connected, .suspended, .ended, nil:
            return .disarm
        }
    }
}

private struct PreflightCheckRow: View {
    let title: String
    /// nil while no report exists yet (first run still in flight).
    let status: PreflightCheckStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusIcon
                Text(title)
            }
            if case .failed(let hint) = status {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .blocked:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case nil:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        }
    }
}

extension EnvironmentValues {
    /// Where Host detail preflights connect; see `HostOnboardingDependencies`.
    @Entry var hostOnboardingDependencies = HostOnboardingDependencies()
}

/// Shows the Host Helper sheet once, when the page was opened for it and its
/// Helper store exists; the store appears as the first checks start.
private struct HostHelperOnArrival: ViewModifier {
    let isReady: Bool
    @Binding var isRequested: Bool
    @Binding var isShowing: Bool

    func body(content: Content) -> some View {
        content.onChange(of: isReady, initial: true) { _, isReady in
            guard isReady, isRequested else { return }
            isRequested = false
            isShowing = true
        }
    }
}
