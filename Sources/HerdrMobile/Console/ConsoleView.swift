import SwiftUI

/// The Console home screen (#8): the flat, status-sorted Agent list across
/// every Host. Host management (#14) lives behind the toolbar button.
struct ConsoleView: View {
    let hosts: HostStore
    let console: ConsoleStore
    let terminal: TerminalSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    /// Owns the navigation path (#74): user taps and notification deep links
    /// drive the same stack.
    @Bindable var notificationRouter: AgentNotificationRouter
    /// Announces foreground Blocked/Done transitions in-app (#77).
    let bannerStore: AgentNotificationBannerStore
    /// Scene phase widened by the background grace period; the Attach screen
    /// pauses its work on real suspensions only.
    let activity: AppActivityCoordinator
    @State private var isManagingHosts = false
    @State private var isStartingAgent = false
    @State private var isShowingSettings = false
    /// Narrows the flat list to one Host; nil shows every Host. The list
    /// stays flat either way — this is a filter, not a grouping level.
    @State private var hostFilter: Host.ID?

    var body: some View {
        // A split view instead of a plain stack for the iPad's sake: regular
        // width shows the Agent list beside the Attach terminal; compact
        // width collapses into the familiar push navigation. The router's
        // path stays the single source of truth — the sidebar selection is a
        // projection of it, so notification deep links keep working.
        NavigationSplitView {
            content
                .navigationTitle("Agents")
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
                .toolbar {
                    // A filter is meaningless with a single Host.
                    if hosts.hosts.count > 1 {
                        ToolbarItem(placement: .primaryAction) {
                            Menu(
                                "Filter by Host",
                                systemImage: hostFilter == nil
                                    ? "line.3.horizontal.decrease.circle"
                                    : "line.3.horizontal.decrease.circle.fill"
                            ) {
                                Picker("Host", selection: $hostFilter) {
                                    Text("All Hosts").tag(Host.ID?.none)
                                    ForEach(hosts.hosts) { host in
                                        Text(host.displayName).tag(Host.ID?.some(host.id))
                                    }
                                }
                            }
                        }
                    }
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
                        terminal: terminal,
                        pushRegistration: pushRegistration,
                        notificationPreferences: notificationPreferences,
                        relaySettings: relaySettings)
                }
        } detail: {
            detail
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
        // A filter pointing at a removed Host would silently hide every
        // Agent; fall back to All Hosts instead.
        .onChange(of: hosts.hosts) { _, hosts in
            if let hostFilter, !hosts.contains(where: { $0.id == hostFilter }) {
                self.hostFilter = nil
            }
        }
    }

    /// The sidebar selection as a projection of the router's path. Setting
    /// it (a row tap, or the collapsed stack popping) writes the path back,
    /// so user navigation and deep links keep one source of truth.
    private var selectedAgent: Binding<ConsoleAgent.ID?> {
        Binding(
            get: { notificationRouter.path.last },
            set: { notificationRouter.path = $0.map { [$0] } ?? [] })
    }

    /// The detail column. Not keyed off the live Agent list alone: the
    /// selection must survive the list emptying while an Agent is shown
    /// (a reconnect empties it briefly), so a vanished Agent shows a
    /// placeholder instead of clearing the selection.
    @ViewBuilder
    private var detail: some View {
        if let id = notificationRouter.path.last {
            if let agent = console.agents.first(where: { $0.id == id }) {
                AgentDetailView(
                    agent: agent,
                    console: console,
                    terminal: terminal,
                    pushRegistration: pushRegistration,
                    notificationPreferences: notificationPreferences,
                    relaySettings: relaySettings,
                    activity: activity,
                    onClosed: { notificationRouter.path = [] }
                )
                // Selecting another Agent must tear down the previous Attach
                // and build a fresh one; without the explicit identity the
                // detail column would reuse the old view's state.
                .id(id)
            } else {
                ContentUnavailableView(
                    "Agent Gone", systemImage: "rectangle.on.rectangle.slash",
                    description: Text("This Agent's pane is no longer reported."))
            }
        } else {
            ContentUnavailableView(
                "No Agent Selected", systemImage: "rectangle.on.rectangle",
                description: Text("Choose an Agent to open its terminal."))
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
        } else if filteredAgents.isEmpty {
            // Agents exist, just none on the filtered Host. Its connection
            // issue, if any, is likely the reason — surface it here.
            ContentUnavailableView {
                Label("No Agents on \(filteredHostName)", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                if !visibleHostIssues.isEmpty {
                    Text(visibleHostIssues.map(\.message).joined(separator: "\n"))
                }
            } actions: {
                Button("Show All Hosts") { hostFilter = nil }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List(selection: selectedAgent) {
                ForEach(visibleHostIssues, id: \.id) { issue in
                    Button { isManagingHosts = true } label: {
                        Label(issue.message, systemImage: issue.systemImage)
                            .font(.footnote)
                            .foregroundStyle(issue.isCritical ? Color.red : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(filteredAgents) { agent in
                    NavigationLink(value: agent.id) {
                        AgentCardView(agent: agent)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var filteredAgents: [ConsoleAgent] {
        guard let hostFilter else { return console.agents }
        return console.agents.filter { $0.hostID == hostFilter }
    }

    /// Host issues shown in the list: all of them, or the filtered Host's
    /// only — a filtered Console should not nag about other machines.
    private var visibleHostIssues: [HostIssue] {
        guard let hostFilter else { return hostIssues }
        return hostIssues.filter { $0.id == hostFilter }
    }

    private var filteredHostName: String {
        hosts.hosts.first(where: { $0.id == hostFilter })?.displayName ?? "this Host"
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
            "socat was not found on the Host. Install it or set its path in Hosts."
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
