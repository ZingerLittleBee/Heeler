import SwiftUI

/// Per-Host onboarding (#14): the preflight checklist with fix-it hints,
/// plus the TOFU fingerprint confirmation. Checks run automatically on
/// arrival; the goal is zero to green checkmarks without desktop docs.
struct HostOnboardingView: View {
    /// The Host catalog, for the Edit sheet.
    let catalog: HostStore
    let connectionStatus: EventsSessionStatus?
    /// True while Console is serving a Host-detail Reconnect press (the
    /// retry call plus the 1.2 s visual-feedback hold). Distinct from
    /// `EventsSessionStatus.reconnecting`.
    let isManualReconnectInFlight: Bool
    let retryConnection: (@MainActor @Sendable () async -> Void)?
    @State private var store: HostOnboardingStore
    @State private var isEditing = false
    @State private var isConfirmingHostKeyReplacement = false
    @State private var sessionSelectionError: String?

    init(
        host: Host,
        catalog: HostStore,
        connectionStatus: EventsSessionStatus? = nil,
        isManualReconnectInFlight: Bool = false,
        retryConnection: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.catalog = catalog
        self.connectionStatus = connectionStatus
        self.isManualReconnectInFlight = isManualReconnectInFlight
        self.retryConnection = retryConnection
        _store = State(initialValue: HostOnboardingStore(host: host))
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Address", value: addressLine)
                LabeledContent("Session", value: sessionLine)
                LabeledContent(
                    "Auth",
                    value: store.host.authMethod == .deviceKey ? "Device Key" : "Password")
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
                        Text(footerMessage)
                            .foregroundStyle(.red)
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
            isPresented: Binding(
                get: { sessionSelectionError != nil },
                set: { if !$0 { sessionSelectionError = nil } })
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
    }

    /// Presentation tracks the pending candidate; dismissal is decided by
    /// the buttons (or the store's own timeout), never by the binding, so a
    /// dismiss-then-answer race cannot double-resolve the decision.
    private var fingerprintAlertPresented: Binding<Bool> {
        Binding(
            get: { store.pendingFingerprint != nil },
            set: { _ in })
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
            isManualReconnectInFlight: isManualReconnectInFlight)
    }

    private func status(for check: PreflightCheck) -> PreflightCheckStatus? {
        store.report?[check]
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

/// Host detail footer copy, derived from Host Connection Status.
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

    init(status: EventsSessionStatus?, isManualReconnectInFlight: Bool) {
        switch status {
        case .reconnecting(_, _, let failure):
            connectionErrorMessage = failure.presentation.explanation
        case .failed(let failure):
            connectionErrorMessage = failure.presentation.message
        case .connected, .suspended, .ended, nil:
            connectionErrorMessage = nil
        }
        footerMessage = isManualReconnectInFlight ? nil : connectionErrorMessage
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
