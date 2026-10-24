import SwiftUI

/// Per-Host onboarding (#14): the preflight checklist with fix-it hints,
/// plus the TOFU fingerprint confirmation. Checks run automatically on
/// arrival; the goal is zero to green checkmarks without desktop docs.
struct HostOnboardingView: View {
    /// The Host catalog, for the Edit sheet.
    let catalog: HostStore
    let usage: AgentUsageStore?
    let connectionStatus: EventsSessionStatus?
    let standingFailure: TransportError?
    /// The route the Console's connection reached (ADR 0022).
    let connectedRouteID: HostRoute.ID?
    /// Why this connected Host's Agents could not be synced.
    let syncIssue: String?
    /// True while Console is serving a Host-detail Reconnect press (the
    /// retry call plus the 1.2 s visual-feedback hold). Distinct from
    /// `EventsSessionStatus.reconnecting`.
    let isManualReconnectInFlight: Bool
    let retryConnection: (@MainActor @Sendable () async -> Void)?
    /// Stops the Console's attempt to connect this Host; nil where the
    /// Host detail does not offer it.
    let stopConnecting: (@MainActor @Sendable () async -> Void)?
    @State private var store: HostOnboardingStore
    @State private var isEditing = false
    @State private var isConfirmingHostKeyReplacement = false
    @State private var sessionSelectionError: String?
    /// A passing preflight not yet acted on: it may restart the Console's
    /// connection once (see `HostOnboardingConsoleRecovery`).
    @State private var isConsoleRecoveryArmed = false
    @State private var isShowingPluginNotice = false
    @Environment(OverlayNetworkStore.self) private var overlayNetworks: OverlayNetworkStore?

    init(
        host: Host,
        catalog: HostStore,
        usage: AgentUsageStore? = nil,
        connectionStatus: EventsSessionStatus? = nil,
        standingFailure: TransportError? = nil,
        connectedRouteID: HostRoute.ID? = nil,
        syncIssue: String? = nil,
        isManualReconnectInFlight: Bool = false,
        retryConnection: (@MainActor @Sendable () async -> Void)? = nil,
        stopConnecting: (@MainActor @Sendable () async -> Void)? = nil,
        dependencies: HostOnboardingDependencies = HostOnboardingDependencies()
    ) {
        self.catalog = catalog
        self.usage = usage
        self.connectionStatus = connectionStatus
        self.standingFailure = standingFailure
        self.connectedRouteID = connectedRouteID
        self.syncIssue = syncIssue
        self.isManualReconnectInFlight = isManualReconnectInFlight
        self.retryConnection = retryConnection
        self.stopConnecting = stopConnecting
        _store = State(
            initialValue: HostOnboardingStore(
                host: host,
                connector: dependencies.connector,
                knownHosts: dependencies.knownHosts,
                credentials: dependencies.credentials))
    }

    var body: some View {
        List {
            connectionSection

            routesSection

            Section("Host") {
                LabeledContent("Account", value: store.host.username)
                LabeledContent("Session", value: sessionLine)
                herdrEndpointRows
                LabeledContent(
                    "Auth",
                    value: authenticationLabel)
                pluginRow
            }

            Section {
                ForEach(PreflightCheck.allCases, id: \.self) { @Sendable check in
                    MainActorContent { PreflightCheckRow(check: check, status: status(for: check)) }
                }
            } header: {
                preflightHeader
            } footer: {
                if let info = store.serverInfo {
                    // The notice is advisory and the checks still pass: a Host
                    // newer than this build is usable, just not fully known.
                    Text(
                        info.exceedsGeneratedProtocol
                            ? "herdr \(info.version) · protocol \(info.protocolVersion) — "
                                + "newer than this app was built against, so features added "
                                + "after protocol \(HeelerSSHTransport.generatedProtocolVersion) "
                                + "may be unavailable."
                            : "herdr \(info.version) · protocol \(info.protocolVersion)")
                }
            }

            if let usage { AgentUsageSection(store: usage) }

            availableSessionsSection

            overlaySignInSection

            if store.pendingHostKeyReplacement != nil {
                Section {
                    Button("Trust New Host Key", systemImage: "key.horizontal", role: .destructive) {
                        isConfirmingHostKeyReplacement = true
                    }
                } footer: {
                    Text("Only continue after verifying the new fingerprint with the Host owner.")
                }
            }
        }
        .readableColumnPage()
        .refreshable {
            if let usage { await usage.refresh() }
        }
        .navigationTitle(store.host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            HostFormView(store: catalog, editing: store.host)
        }

        .pluginNoticeSheet(pluginPresentation.notice, isPresented: $isShowingPluginNotice) {
            Task { await store.runChecks() }
        }
        .alert(
            "Trust this Host?",
            isPresented: fingerprintAlertPresented,
            presenting: store.pendingFingerprint
        ) { _ in
            Button("Trust") { store.confirmFingerprint(trusted: true) }
            Button("Don't Trust", role: .cancel) { store.confirmFingerprint(trusted: false) }
        } message: { candidate in
            Text(
                "First connection to \(candidate.host):\(String(candidate.port)).\n\n"
                    + "Key fingerprint:\n\(candidate.fingerprint.displayString)\n\n"
                    + "Verify it matches the Host's key before trusting.")
        }
        .confirmationDialog(
            "Replace the trusted Host key?",
            isPresented: $isConfirmingHostKeyReplacement,
            titleVisibility: .visible
        ) {
            Button("Trust New Key", role: .destructive) {
                Task { await store.trustPresentedHostKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let replacement = store.pendingHostKeyReplacement {
                Text(
                    "Trusted: \(replacement.known.displayString)\n\n"
                        + "Presented: \(replacement.presented.displayString)\n\n"
                        + "A changed key can indicate a reinstalled Host or an attack.")
            }
        }
        .alert(
            "Could Not Select Session",
            isPresented: sessionSelectionErrorPresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionSelectionError ?? "")
        }
        .task {
            if store.phase == .idle {
                await store.runChecks()
            }
        }
        .onChange(of: store.report) { _, report in
            isConsoleRecoveryArmed = report == .allPassed
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
    }

    private var consoleRecoveryInput: HostOnboardingConsoleRecovery.Input {
        HostOnboardingConsoleRecovery.Input(
            isArmed: isConsoleRecoveryArmed,
            status: connectionStatus,
            isManualReconnectInFlight: isManualReconnectInFlight)
    }

    private var authenticationLabel: String {
        switch store.host.authMethod {
        case .deviceKey: "Device Key"
        case .rsaKey: "RSA Key"
        case .password: "Password"
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

    private func networkName(_ id: UUID) -> String {
        overlayNetworks?.network(id: id)?.displayName ?? "Unavailable overlay network"
    }

    private var sessionLine: String {
        if let herdrEndpoint = store.host.herdrEndpoint {
            return herdrEndpoint.session.isEmpty ? "default" : herdrEndpoint.session
        }
        if case .namedSession(let name) = store.host.socketLocation {
            return name
        }
        return "default"
    }

    /// Where a Pairing Code v2 Host's herdr lives; nothing for other Hosts.
    @ViewBuilder
    private var herdrEndpointRows: some View {
        if let herdrEndpoint = store.host.herdrEndpoint {
            LabeledContent("herdr Socket", value: herdrEndpoint.socketPath)
            LabeledContent("herdr Launcher", value: herdrEndpoint.executablePath)
        }
    }

    /// The Console is dialing this Host, or between automatic retries.
    private var isAttemptingConnection: Bool {
        switch connectionStatus {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    private func retry() {
        guard !isManualReconnectInFlight, let retryConnection else { return }
        Task { @MainActor in
            await retryConnection()
        }
    }

    private var routeStatus: HostRouteStatusPresentation {
        HostRouteStatusPresentation(
            status: connectionStatus,
            standingFailure: standingFailure,
            connectedRouteID: connectedRouteID,
            isManualReconnectInFlight: isManualReconnectInFlight,
            routes: store.host.routes,
            describe: routeDescription)
    }

    /// How a route reaches the Host, under its address: `Direct`, its
    /// Overlay Network, or `via` its Jump Host.
    private func routeDescription(_ route: HostRoute) -> String {
        var parts: [String] = []
        if let networkID = route.overlayNetworkID {
            parts.append(networkName(networkID))
        }
        if route.usesJumpHost {
            let jump = route.jumpAddress.trimmingCharacters(in: .whitespaces)
            parts.append("via \(route.jumpPort == 22 ? jump : "\(jump):\(route.jumpPort)")")
        }
        return parts.isEmpty ? "Direct" : parts.joined(separator: " · ")
    }

    /// The status card with its one action, and the failure's whole message
    /// as footer.
    @ViewBuilder
    private var connectionSection: some View {
        if connectionStatus != nil || retryConnection != nil {
            let status = routeStatus
            Section {
                HostConnectionStatusCard(presentation: status) {
                    trailingConnectionAction(status)
                } below: {
                    prominentReconnect(status)
                }
                .animation(.smooth(duration: 0.25), value: status.tone)
            } footer: {
                connectionFooter
            }
            .animation(
                .smooth(duration: 0.25),
                value: connectionPresentation.connectionErrorMessage)
        }
    }

    /// The card's quiet action at its end, always a round button: Stop
    /// while the Console is dialing, Reconnect while connected. A Reconnect
    /// press keeps the circle, spinning, until the dial starts, so the card
    /// holds its size; `retry()` ignores a second press meanwhile.
    @ViewBuilder
    private func trailingConnectionAction(
        _ status: HostRouteStatusPresentation
    ) -> some View {
        if isAttemptingConnection, let stopConnecting {
            Button(role: .cancel) {
                Task { await stopConnecting() }
            } label: {
                // A filled square reads heavier than the outlined arrow.
                HostCircleActionLabel(systemImage: "stop.fill")
                    .imageScale(.small)
            }
            .accessibilityLabel("Stop Connecting")
            .accessibilityHint(
                "Stops trying to connect without waiting for a timeout. "
                    + "The Host stays paused until you reconnect.")
        } else if isManualReconnectInFlight {
            HostCircleActionLabel(systemImage: nil)
                .accessibilityHidden(true)
        } else if status.tone == .connected, retryConnection != nil {
            Button {
                retry()
            } label: {
                HostCircleActionLabel(systemImage: "arrow.clockwise")
            }
            .accessibilityLabel("Reconnect")
        }
    }

    /// Reconnect as the card's main action once nothing is dialing: the
    /// Host can't connect or was stopped.
    @ViewBuilder
    private func prominentReconnect(_ status: HostRouteStatusPresentation) -> some View {
        if status.tone == .failed || status.tone == .idle, retryConnection != nil {
            Button {
                retry()
            } label: {
                HostProminentReconnectLabel()
            }
        }
    }

    @ViewBuilder
    private var connectionFooter: some View {
        if let footerMessage = connectionPresentation.footerMessage {
            Group {
                if connectionPresentation.isSyncIssue {
                    // Still connected: the Console's orange, not a
                    // failure's red.
                    let glyph = Text(Image(systemName: "arrow.trianglehead.2.clockwise"))
                        .foregroundStyle(HostConnectionTone.warning.tint)
                    Text("\(glyph) \(footerMessage)")
                        .accessibilityLabel(footerMessage)
                } else {
                    Text(footerMessage)
                        .foregroundStyle(.red)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Every route, marking the one in use, or each route's own failure
    /// when none reached the Host. Routes are added and edited in Edit.
    private var routesSection: some View {
        let status = routeStatus
        return Section {
            ForEach(store.host.routes) { @Sendable route in
                MainActorContent {
                    let failure = status.routeFailures[route.id]
                    HostRouteLabel(kind: HostRouteKind(route)) {
                        Text(route.endpointDescription)
                            .font(.body.monospaced())
                    } subtitle: {
                        Text(failure ?? routeDescription(route))
                    } trailing: {
                        if route.id == status.inUseRouteID {
                            HostRouteTag(text: "In Use", tint: .green)
                        } else if failure != nil {
                            HostRouteTag(text: "Failed", tint: .red)
                        }
                    }
                }
            }
        } header: {
            Text("Routes")
        } footer: {
            if store.host.routes.count > 1 {
                Text(
                    "Heeler tries every route each time it connects and keeps the first that "
                        + "reaches the Host.")
            }
        }
    }

    private var connectionPresentation: HostOnboardingConnectionPresentation {
        HostOnboardingConnectionPresentation(
            status: connectionStatus,
            standingFailure: standingFailure,
            syncIssue: syncIssue,
            isManualReconnectInFlight: isManualReconnectInFlight,
            usesHerdrEndpoint: store.host.herdrEndpoint != nil,
            itemizesRoutes: !routeStatus.routeFailures.isEmpty)
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
        HeelerPluginPresentation(
            store.pluginStatus, session: store.host.sessionName, endpoint: store.host.herdrEndpoint)
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
                        PluginNoticeIcon(tone: notice.tone)
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
                                    Text(session.isRunning ? "Running" : "Stopped")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isSelected(session) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(isSelected(session) || (!session.isDefault && !session.isRunning))
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

    private func select(_ session: HerdrSession) {
        do {
            try store.selectSession(session, in: catalog)
        } catch {
            sessionSelectionError = "The selected session could not be saved."
        }
    }
}

/// The Host detail's status card and route tags (ADR 0022): which route a
/// connected Host reached, or each route's own failure when none did.
struct HostRouteStatusPresentation: Equatable {
    enum Tone: Equatable {
        case connected
        case connecting
        case retrying
        case failed
        case idle
    }

    let tone: Tone
    let title: String
    let subtitle: String?
    /// The route the connection reached, while connected.
    let inUseRouteID: HostRoute.ID?
    /// Each route's own failure Summary, from a `noRouteReached` failure.
    let routeFailures: [HostRoute.ID: String]

    /// A manual Reconnect in flight reads as Connecting… at once, whatever
    /// the status still says, and drops the outcome it is replacing.
    init(
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        connectedRouteID: HostRoute.ID?,
        isManualReconnectInFlight: Bool = false,
        routes: [HostRoute],
        describe: (HostRoute) -> String
    ) {
        let failure: TransportError?
        switch status {
        case _ where isManualReconnectInFlight:
            tone = .connecting
            title = "Connecting…"
            subtitle = nil
            inUseRouteID = nil
            failure = nil
        case .connected:
            tone = .connected
            title = "Connected"
            let route = routes.first { $0.id == connectedRouteID }
            subtitle = route.map { "\($0.endpointDescription) · \(describe($0))" }
            inUseRouteID = route?.id
            failure = nil
        case .connecting:
            tone = .connecting
            title = "Connecting…"
            subtitle = standingFailure?.presentation.summary
            inUseRouteID = nil
            failure = standingFailure
        case .reconnecting(_, _, let reconnectFailure):
            tone = .retrying
            title = "Reconnecting…"
            subtitle = reconnectFailure.presentation.summary
            inUseRouteID = nil
            failure = reconnectFailure
        case .failed(let stopFailure):
            tone = .failed
            title = "Can't Connect"
            subtitle = stopFailure.presentation.summary
            inUseRouteID = nil
            failure = stopFailure
        case .suspended, .ended, nil:
            tone = .idle
            title = "Not Connected"
            subtitle = nil
            inUseRouteID = nil
            failure = nil
        }
        var routeFailures: [HostRoute.ID: String] = [:]
        if case .noRouteReached(let failures) = failure {
            for routeFailure in failures {
                guard let id = routeFailure.routeID else { continue }
                routeFailures[id] = routeFailure.error.presentation.summary
            }
        }
        self.routeFailures = routeFailures
    }
}

/// The status card leading the Host detail: an action at its end, or one
/// across its foot when it is the page's main action.
private struct HostConnectionStatusCard<Trailing: View, Below: View>: View {
    let presentation: HostRouteStatusPresentation
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let below: Below

    @ScaledMetric(relativeTo: .headline) private var iconSize = 40

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                HStack(spacing: 14) {
                    icon
                        .frame(width: iconSize, height: iconSize)
                        .background(tint.opacity(0.14), in: .rect(cornerRadius: 10))
                        .accessibilityHidden(true)
                    ZStack(alignment: .leading) {
                        // Every state is at least a title and a subtitle
                        // tall, so a one-line Connecting… does not shrink
                        // the card.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: " ").font(.headline)
                            Text(verbatim: " ").font(.subheadline)
                        }
                        .hidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(presentation.title)
                                .font(.headline)
                            if let subtitle = presentation.subtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("hosts.detail.connectionStatus")
                Spacer(minLength: 0)
                trailing
            }
            below
        }
        // The row stays inert; only the actions take taps.
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var icon: some View {
        switch presentation.tone {
        case .connecting:
            ProgressView()
        case .connected:
            Image(systemName: "checkmark").font(.headline).foregroundStyle(tint)
        case .retrying:
            Image(systemName: "arrow.clockwise").font(.headline).foregroundStyle(tint)
        case .failed:
            Image(systemName: "xmark").font(.headline).foregroundStyle(tint)
        case .idle:
            Image(systemName: "pause").font(.headline).foregroundStyle(tint)
        }
    }

    private var tint: Color {
        switch presentation.tone {
        case .connected: .green
        case .connecting, .idle: .secondary
        case .retrying: .orange
        case .failed: .red
        }
    }
}

/// A wash of the tint behind the card's Reconnect, a little stronger on a
/// dark row so it still reads as a button.
private struct HostReconnectFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        TintShapeStyle().opacity(environment.colorScheme == .dark ? 0.22 : 0.12)
    }
}

/// The card's quiet action: a round tinted button that leaves the
/// subtitle its width. No symbol spins in its place.
private struct HostCircleActionLabel: View {
    let systemImage: String?

    @ScaledMetric(relativeTo: .body) private var size = 36

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .background(HostReconnectFill(), in: .circle)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
    }
}

/// Reconnect as the card's main action, across its foot.
private struct HostProminentReconnectLabel: View {
    var body: some View {
        // Not a Label: a List gives a Label's icon a wide fixed slot.
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.footnote.weight(.bold))
                .accessibilityHidden(true)
            Text("Reconnect")
                .font(.body.weight(.semibold))
        }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(HostReconnectFill(), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
    }
}

/// Host detail footer copy, derived from Host Connection Status, or while
/// connected from why the Host's Agents could not be synced.
///
/// Automatic recovery shows the Explanation only — Summary and Detail, no
/// Recovery Suggestion. A stopped Host shows the whole presentation. See
/// Transport Error Presentation in `CONTEXT.md`.
///
/// `isManualReconnectInFlight` is a Console-owned Reconnect press (the
/// retry call plus its 1.2 s hold), not `EventsSessionStatus.reconnecting`.
/// A press hides the footer for both arms — recorded, not endorsed, in #160.
/// The animation value stays `connectionErrorMessage` so a press does not
/// drive the footer's 0.25 s transition.
struct HostOnboardingConnectionPresentation: Equatable {
    /// Status-derived footer text. The footer animation observes this; a
    /// manual Reconnect request does not change it.
    let connectionErrorMessage: String?
    let footerMessage: String?
    /// The message is a connected Host's failing sync, not a lost
    /// connection.
    let isSyncIssue: Bool

    /// `itemizesRoutes`: the Routes list shows each route's own failure and
    /// the status card the Summary, so a `noRouteReached` footer keeps only
    /// what neither says, the Recovery Suggestion.
    init(
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        syncIssue: String? = nil,
        isManualReconnectInFlight: Bool,
        usesHerdrEndpoint: Bool = false,
        itemizesRoutes: Bool = false
    ) {
        func whole(_ failure: TransportError) -> String? {
            let presentation = failure.presentation(usesHerdrEndpoint: usesHerdrEndpoint)
            if itemizesRoutes, case .noRouteReached = failure {
                return presentation.recoverySuggestion
            }
            return presentation.message
        }
        func explanation(_ failure: TransportError) -> String? {
            if itemizesRoutes, case .noRouteReached = failure { return nil }
            return failure.presentation.explanation
        }
        switch status {
        case .connecting:
            connectionErrorMessage = standingFailure.flatMap(whole)
        case .reconnecting(_, _, let failure):
            connectionErrorMessage = explanation(failure)
        case .failed(let failure):
            connectionErrorMessage = whole(failure)
        case .connected:
            connectionErrorMessage = syncIssue
        case .suspended, .ended, nil:
            connectionErrorMessage = nil
        }
        isSyncIssue = if case .connected = status { syncIssue != nil } else { false }
        footerMessage = isManualReconnectInFlight ? nil : connectionErrorMessage
    }
}

/// The Console never prompts for host key trust, so a Host it rejected for
/// an unpinned or mismatched key stays failed after onboarding pins the
/// key. A passing preflight proves the pin and arms one Console retry,
/// decided as soon as the Console settles: retry a trust failure, otherwise
/// disarm, so a later failure never reuses an old proof.
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
        case .failed(let failure) where isHostKeyTrustFailure(failure):
            return .retry
        case .connecting, .reconnecting:
            return .wait
        case .failed, .connected, .suspended, .ended, nil:
            return .disarm
        }
    }

    private static func isHostKeyTrustFailure(_ failure: TransportError) -> Bool {
        switch failure {
        case .hostKeyRejected, .hostKeyMismatch:
            true
        case .jumpHostFailed(let underlying):
            isHostKeyTrustFailure(underlying)
        // As `isHostKeySecurityFailure` reads it: every route, or one that
        // cannot reach another machine.
        case .noRouteReached(let failures):
            (!failures.isEmpty && failures.allSatisfy { isHostKeyTrustFailure($0.error) })
                || failures.contains {
                    !$0.mayNameAnotherMachine && isHostKeyTrustFailure($0.error)
                }
        default:
            false
        }
    }
}

private struct PreflightCheckRow: View {
    let check: PreflightCheck
    /// nil while no report exists yet (first run still in flight).
    let status: PreflightCheckStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusIcon
                Text(check.title)
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
