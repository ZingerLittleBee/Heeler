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
    @State private var hostSheet: HostSheet?
    @State private var isStartingAgent = false
    @State private var isShowingSettings = false
    @State private var reconnectingHostIDs: Set<Host.ID> = []
    /// Narrows the flat list to one Host; nil shows every Host. The list
    /// stays flat either way — this is a filter, not a grouping level.
    @State private var hostFilter: Host.ID?
    /// Outlives the detail column's rebuilds, which is the whole point: it
    /// carries the raised keyboard from one Attach screen to the next.
    @State private var keyboardHandoff = TerminalKeyboardHandoff()

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
                            presentHosts()
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
                .sheet(item: $hostSheet) { destination in
                    // HostListView brings its own NavigationStack.
                    HostListView(
                        store: hosts,
                        initialHostID: destination.hostID,
                        connectionStatuses: console.hostStatuses,
                        latencies: console.hostLatencies,
                        reconnectingHostIDs: reconnectingHostIDs,
                        retryConnection: { await reconnectHost($0) })
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
            hostSheet = nil
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
                    hosts: hosts.hosts,
                    activity: activity,
                    keyboardHandoff: keyboardHandoff,
                    onSwitch: { notificationRouter.path = [$0] },
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
                Button("Add Host") { presentHosts() }
                    .buttonStyle(.borderedProminent)
            }
        } else if console.agents.isEmpty {
            ContentUnavailableView {
                Label("No Agents", systemImage: "rectangle.on.rectangle.slash")
            } description: {
                Text(emptyDescription)
            } actions: {
                if let issue = hostIssues.first, hostIssues.count == 1 {
                    Button("Open \(issue.hostName)") { presentHosts(issue.id) }
                        .buttonStyle(.borderedProminent)
                } else if !hostIssues.isEmpty {
                    Button("Manage Hosts") { presentHosts() }
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
                if let issue = visibleHostIssues.first {
                    Button("Host Settings") { presentHosts(issue.id) }
                }
                Button("Show All Hosts") { hostFilter = nil }
            }
        } else {
            List(selection: selectedAgent) {
                ForEach(visibleHostIssues, id: \.id) { issue in
                    Button { presentHosts(issue.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: issue.systemImage)
                                .foregroundStyle(issue.isCritical ? Color.red : Color.orange)
                            Text(issue.message)
                                .font(.footnote)
                                .foregroundStyle(issue.isCritical ? Color.red : Color.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this Host's settings.")
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
        let hostName: String
        let message: String
        let systemImage: String
        let isCritical: Bool
    }

    private struct HostSheet: Identifiable {
        let id = UUID()
        let hostID: Host.ID?
    }

    /// One actionable status per Host. A disconnected session takes priority;
    /// otherwise a connected Host can still have a failing snapshot RPC.
    private var hostIssues: [HostIssue] {
        hosts.hosts.compactMap { host in
            switch console.hostStatuses[host.id] {
            case .reconnecting(_, _, let failure):
                return HostIssue(
                    id: host.id,
                    hostName: host.displayName,
                    message: "Reconnecting to \(host.displayName): \(summary(for: failure))",
                    systemImage: "wifi.exclamationmark",
                    isCritical: false)
            case .failed(let failure):
                return HostIssue(
                    id: host.id,
                    hostName: host.displayName,
                    message: "\(host.displayName): \(failure.connectionGuidance)",
                    systemImage: failure.isHostKeySecurityFailure
                        ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill",
                    isCritical: failure.isHostKeySecurityFailure)
            case .connected, .suspended, .ended, nil:
                break
            }
            if let message = console.hostSyncErrors[host.id] {
                return HostIssue(
                    id: host.id,
                    hostName: host.displayName,
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
        case .apiRejected: "herdr rejected the request"
        default: "connection failed"
        }
    }

    private func presentHosts(_ id: Host.ID? = nil) {
        hostSheet = HostSheet(hostID: id)
    }

    private func reconnectHost(_ id: Host.ID) async {
        guard reconnectingHostIDs.insert(id).inserted else { return }
        await console.retryHost(id)
        try? await Task.sleep(for: .milliseconds(1_200))
        reconnectingHostIDs.remove(id)
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
