import SwiftUI

/// The Console home screen (#8): the flat, status-sorted Agent list across
/// every Host. Host management (#14) lives behind the toolbar button.
struct ConsoleView: View {
    let hosts: HostStore
    let console: ConsoleStore
    @State private var isManagingHosts = false
    @State private var isStartingAgent = false

    var body: some View {
        NavigationStack {
            content
                // On the always-present node, not the List branch: the
                // destination must survive the list emptying while an
                // Agent detail screen is pushed.
                .navigationDestination(for: ConsoleAgent.ID.self) { id in
                    if let agent = console.agents.first(where: { $0.id == id }) {
                        AgentDetailView(agent: agent, console: console)
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
                    if !hosts.hosts.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Button("New Agent", systemImage: "plus") {
                                isStartingAgent = true
                            }
                        }
                    }
                }
                .sheet(isPresented: $isManagingHosts) {
                    // HostListView brings its own NavigationStack.
                    HostListView(store: hosts)
                }
                .sheet(isPresented: $isStartingAgent) {
                    // StartAgentView brings its own NavigationStack.
                    StartAgentView(hosts: hosts.hosts, console: console)
                }
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
            }
        } else {
            List {
                ForEach(hostIssues, id: \.0) { _, issue in
                    Label(issue.message, systemImage: issue.systemImage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        return hostIssues.map(\.1.message).joined(separator: "\n")
    }

    /// One actionable status per Host. A disconnected session takes priority;
    /// otherwise a connected Host can still have a failing snapshot RPC.
    private var hostIssues: [(Host.ID, (message: String, systemImage: String))] {
        hosts.hosts.compactMap { host in
            if case .reconnecting = console.hostStatuses[host.id] {
                return (
                    host.id,
                    ("Reconnecting to \(host.displayName)…", "wifi.exclamationmark"))
            }
            if let message = console.hostSyncErrors[host.id] {
                return (
                    host.id,
                    ("\(host.displayName): \(message)", "arrow.trianglehead.2.clockwise"))
            }
            return nil
        }
    }
}
