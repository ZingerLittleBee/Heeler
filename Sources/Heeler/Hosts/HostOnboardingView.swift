import SwiftUI

/// Per-Host onboarding (#14): the preflight checklist with fix-it hints,
/// plus the TOFU fingerprint confirmation. Checks run automatically on
/// arrival; the goal is zero to green checkmarks without desktop docs.
struct HostOnboardingView: View {
    /// The Host catalog, for the Edit sheet.
    let catalog: HostStore
    let connectionStatus: EventsSessionStatus?
    let standingFailure: TransportError?
    /// Why this connected Host's Agents could not be synced.
    let syncIssue: String?
    /// True while Console is serving a Host-detail Reconnect press (the
    /// retry call plus the 1.2 s visual-feedback hold). Distinct from
    /// `EventsSessionStatus.reconnecting`.
    let isManualReconnectInFlight: Bool
    let retryConnection: (@MainActor @Sendable () async -> Void)?
    @State private var store: HostOnboardingStore
    @State private var isEditing = false
    @State private var isConfirmingHostKeyReplacement = false
    @State private var sessionSelectionError: String?
    /// A passing preflight not yet acted on: it may restart the Console's
    /// connection once (see `HostOnboardingConsoleRecovery`).
    @State private var isConsoleRecoveryArmed = false
    @State private var isShowingPluginNotice = false

    init(
        host: Host,
        catalog: HostStore,
        connectionStatus: EventsSessionStatus? = nil,
        standingFailure: TransportError? = nil,
        syncIssue: String? = nil,
        isManualReconnectInFlight: Bool = false,
        retryConnection: (@MainActor @Sendable () async -> Void)? = nil,
        dependencies: HostOnboardingDependencies = HostOnboardingDependencies()
    ) {
        self.catalog = catalog
        self.connectionStatus = connectionStatus
        self.standingFailure = standingFailure
        self.syncIssue = syncIssue
        self.isManualReconnectInFlight = isManualReconnectInFlight
        self.retryConnection = retryConnection
        _store = State(
            initialValue: HostOnboardingStore(
                host: host,
                connector: dependencies.connector,
                knownHosts: dependencies.knownHosts,
                credentials: dependencies.credentials))
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Address", value: addressLine)
                LabeledContent("Session", value: sessionLine)
                LabeledContent(
                    "Auth",
                    value: authenticationLabel)
                pluginRow
            }

            if retryConnection != nil {
                Section {
                    Button {
                        retry()
                    } label: {
                        ZStack(alignment: .leading) {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                                .opacity(isManualReconnectInFlight ? 0 : 1)
                            HStack {
                                ProgressView()
                                Text("Connecting…")
                            }
                            .opacity(isManualReconnectInFlight ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.smooth(duration: 0.25), value: isManualReconnectInFlight)
                    }
                    .disabled(isManualReconnectInFlight)
                } footer: {
                    if let footerMessage = connectionPresentation.footerMessage {
                        Group {
                            if connectionPresentation.isSyncIssue {
                                // Still connected: the Console's orange, not
                                // a failure's red.
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
                .animation(
                    .smooth(duration: 0.25),
                    value: connectionPresentation.connectionErrorMessage)
            }

            Section {
                ForEach(PreflightCheck.allCases, id: \.self) { check in
                    PreflightCheckRow(check: check, status: status(for: check))
                }
            } header: {
                HStack {
                    Text("Preflight")
                    if store.phase == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.leading, 4)
                    }
                }
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

            availableSessionsSection

            Section {
                Button {
                    Task { await store.runChecks() }
                } label: {
                    Label("Run Checks Again", systemImage: "arrow.clockwise")
                }
                .disabled(store.phase == .running)
            }

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

    private var addressLine: String {
        "\(store.host.username)@\(store.host.address):\(String(store.host.port))"
    }

    private var sessionLine: String {
        if case .namedSession(let name) = store.host.socketLocation {
            return name
        }
        return "default"
    }

    private func retry() {
        guard !isManualReconnectInFlight, let retryConnection else { return }
        Task { @MainActor in
            await retryConnection()
        }
    }

    private var connectionPresentation: HostOnboardingConnectionPresentation {
        HostOnboardingConnectionPresentation(
            status: connectionStatus,
            standingFailure: standingFailure,
            syncIssue: syncIssue,
            isManualReconnectInFlight: isManualReconnectInFlight)
    }

    private func status(for check: PreflightCheck) -> PreflightCheckStatus? {
        store.report?[check]
    }

    private var pluginPresentation: HeelerPluginPresentation {
        HeelerPluginPresentation(store.pluginStatus)
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
                ForEach(store.availableSessions, id: \.name) { session in
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

    init(
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        syncIssue: String? = nil,
        isManualReconnectInFlight: Bool
    ) {
        switch status {
        case .connecting:
            connectionErrorMessage = standingFailure?.presentation.message
        case .reconnecting(_, _, let failure):
            connectionErrorMessage = failure.presentation.explanation
        case .failed(let failure):
            connectionErrorMessage = failure.presentation.message
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
