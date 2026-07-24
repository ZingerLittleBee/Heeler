import SwiftUI

/// The Console home screen (#8): the flat, status-sorted Agent list across
/// every Host. Host management (#14) lives behind the toolbar button.
struct ConsoleView: View {
    let hosts: HostStore
    let console: ConsoleStore
    let terminalThemes: TerminalThemeSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    /// Owns the navigation path (#74): user taps and notification deep links
    /// drive the same stack.
    @Bindable var notificationRouter: AgentNotificationRouter
    /// Announces foreground Blocked/Done transitions in-app (#77).
    let bannerStore: AgentNotificationBannerStore
    @State private var isManagingHosts = false
    @State private var isStartingAgent = false
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack(path: $notificationRouter.path) {
            content
                // On the always-present node, not the List branch: the
                // destination must survive the list emptying while an
                // Agent detail screen is pushed.
                .navigationDestination(for: ConsoleAgent.ID.self) { id in
                    if let agent = console.agents.first(where: { $0.id == id }) {
                        AgentDetailView(
                            agent: agent,
                            console: console,
                            terminalThemes: terminalThemes,
                            pushRegistration: pushRegistration,
                            notificationPreferences: notificationPreferences,
                            relaySettings: relaySettings)
                    } else {
                        ContentUnavailableView(
                            "Agent Gone", systemImage: "rectangle.on.rectangle.slash",
                            description: Text("This Agent's pane is no longer reported."))
                    }
                }
                .navigationTitle("Console")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Hosts", systemImage: "server.rack") {
                            isManagingHosts = true
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Settings", systemImage: "gearshape") {
                            isShowingSettings = true
                        }
                    }
                    if !hosts.hosts.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Button("New Agent", systemImage: "plus") {
                                isStartingAgent = true
                            }
                        }
                    }
                }
                .sheet(
                    isPresented: $isManagingHosts,
                    onDismiss: { Task { await console.retryFailedHosts() } }
                ) {
                    // HostListView brings its own NavigationStack.
                    HostListView(store: hosts)
                }
                .sheet(isPresented: $isStartingAgent) {
                    // StartAgentView brings its own NavigationStack.
                    StartAgentView(hosts: hosts.hosts, console: console)
                }
                .sheet(isPresented: $isShowingSettings) {
                    SettingsView(
                        terminalThemes: terminalThemes,
                        pushRegistration: pushRegistration,
                        notificationPreferences: notificationPreferences,
                        relaySettings: relaySettings)
                }
        }
        // Above the NavigationStack so a banner also shows over a pushed
        // Attach screen; a tap deep-links exactly like a push tap would.
        .overlay(alignment: .top) {
            if let banner = bannerStore.banner {
                AgentNotificationBannerView(banner: banner) {
                    bannerStore.dismiss()
                    notificationRouter.open(banner.target)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: bannerStore.banner)
        // A notification deep link must land on the Attach even when one of
        // the Console's sheets covers it. User-driven pushes cannot happen
        // while a sheet is up, so this only acts on notification taps.
        .onChange(of: notificationRouter.path) { _, path in
            guard !path.isEmpty else { return }
            isManagingHosts = false
            isStartingAgent = false
            isShowingSettings = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if hosts.hosts.isEmpty {
            ContentUnavailableView {
                Label("No Hosts", systemImage: "server.rack")
            } description: {
                Text("Add a machine that runs herdr to see its Agents here.")
            } actions: {
                Button("Add Host") { isManagingHosts = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if console.agents.isEmpty {
            ContentUnavailableView {
                Label("No Agents", systemImage: "rectangle.on.rectangle.slash")
            } description: {
                Text(emptyDescription)
            } actions: {
                if !hostIssues.isEmpty {
                    Button("Manage Hosts") { isManagingHosts = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            List {
                ForEach(hostIssues, id: \.id) { issue in
                    Button { isManagingHosts = true } label: {
                        Label(issue.message, systemImage: issue.systemImage)
                            .font(.footnote)
                            .foregroundStyle(issue.isCritical ? Color.red : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(console.agents) { agent in
                    NavigationLink(value: agent.id) {
                        AgentCardView(agent: agent)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyDescription: String {
        if hostIssues.isEmpty {
            return "Agents detected on your Hosts appear here."
        }
        return hostIssues.map(\.message).joined(separator: "\n")
    }

    private struct HostIssue {
        let id: Host.ID
        let message: String
        let systemImage: String
        let isCritical: Bool
    }

    /// One actionable status per Host. A disconnected session takes priority;
    /// otherwise a connected Host can still have a failing snapshot RPC.
    private var hostIssues: [HostIssue] {
        hosts.hosts.compactMap { host in
            switch console.hostStatuses[host.id] {
            case .reconnecting(_, _, let failure):
                return HostIssue(
                    id: host.id,
                    message: "Reconnecting to \(host.displayName): \(summary(for: failure))",
                    systemImage: "wifi.exclamationmark",
                    isCritical: false)
            case .failed(let failure):
                return HostIssue(
                    id: host.id,
                    message: "\(host.displayName): \(guidance(for: failure))",
                    systemImage: failure.isHostKeySecurityFailure
                        ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill",
                    isCritical: failure.isHostKeySecurityFailure)
            case .connected, .suspended, .ended, nil:
                break
            }
            if let message = console.hostSyncErrors[host.id] {
                return HostIssue(
                    id: host.id,
                    message: "\(host.displayName): \(message)",
                    systemImage: "arrow.trianglehead.2.clockwise",
                    isCritical: false)
            }
            return nil
        }
    }

    private func summary(for failure: TransportError) -> String {
        switch failure {
        case .sshUnreachable: "SSH unavailable"
        case .serverNotRunning: "herdr is not answering"
        case .timedOut: "request timed out"
        case .cancelled: "request was cancelled"
        case .channelFailed: "connection dropped"
        default: "connection failed"
        }
    }

    private func guidance(for failure: TransportError) -> String {
        switch failure {
        case .authenticationFailed:
            "Authentication failed. Update the credentials in Hosts."
        case .deviceKeyCorrupt:
            "The Device Key is corrupted. Edit this Host, replace the Device Key, then install its new public key on every Device Key Host."
        case .hostKeyRejected:
            "The host key is not trusted. Verify it in Hosts."
        case .hostKeyMismatch:
            "Host key changed. Verify the machine before updating trust in Hosts."
        case .protocolVersionMismatch(let server, let supported):
            "herdr protocol \(server) is incompatible with app protocol \(supported). Update herdr or the app."
        case .socketNotFound:
            "The herdr socket was not found. Check the session in Hosts."
        case .socatMissing:
            "socat was not found. Check its path in Hosts."
        case .homeDirectoryUnresolvable:
            "The remote home directory could not be resolved. Check the Host login shell."
        case .malformedResponse:
            "herdr returned an invalid response. Check its version, then retry."
        case .eventsChannelAlreadyOpen, .terminalChannelAlreadyOpen:
            "The connection is busy. Close the other terminal, then retry."
        default:
            "Connection failed. Check this Host, then retry."
        }
    }
}

private extension TransportError {
    var isHostKeySecurityFailure: Bool {
        switch self {
        case .hostKeyMismatch: true
        default: false
        }
    }
}
