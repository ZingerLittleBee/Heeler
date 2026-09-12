import SwiftUI

/// Lists the Hosts the Console filter resolves to, with the herdr sessions
/// discovered on each (#269). Choosing a session rewrites that Host's stored
/// `sessionName`; no Host is duplicated to reach a second session.
struct HostSessionSwitcherView: View {
    let catalog: HostStore
    /// The Console sidebar's Host filter, if one is set.
    let hostFilter: Host.ID?
    /// Resolves one Host's live Console transport and lists its sessions.
    let listSessions: @Sendable (Host.ID) async throws -> [HerdrSession]

    @Environment(\.dismiss) private var dismiss
    @State private var store = HostSessionSwitcherStore()
    @State private var selectionError: String?

    var body: some View {
        // Presented straight from ConsoleView, so this sheet brings its own
        // NavigationStack the way HostListView does.
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    ContentUnavailableView(
                        "No Hosts",
                        systemImage: "server.rack",
                        description: Text("Add a Host to choose its herdr session."))
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Could Not Select Session",
                isPresented: Binding(
                    get: { selectionError != nil },
                    set: { if !$0 { selectionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(selectionError ?? "")
            }
            .task { await store.load(hosts: hosts, using: listSessions) }
        }
    }

    private var hosts: [Host] {
        guard let hostFilter else { return catalog.hosts }
        return catalog.hosts.filter { $0.id == hostFilter }
    }

    private var sessionList: some View {
        List {
            ForEach(hosts) { host in
                Section {
                    sessionRows(for: host)
                } header: {
                    Text(host.displayName)
                } footer: {
                    Text("Stopped named sessions must be started on the Host before selection.")
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRows(for host: Host) -> some View {
        switch store.discoveries[host.id] ?? .loading {
        case .loading:
            HStack {
                Text("Looking for sessions…").foregroundStyle(.secondary)
                Spacer()
                ProgressView()
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .available(let sessions):
            if sessions.isEmpty {
                Text("No sessions reported.").foregroundStyle(.secondary)
            }
            ForEach(sessions, id: \.name) { session in
                Button {
                    select(session, on: host)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.name)
                            Text(session.isRunning ? "Running" : "Stopped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if HerdrSessionSelection.isSelected(
                            session, currentSessionName: host.sessionName)
                        {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(
                    !HerdrSessionSelection.isSelectable(
                        session, currentSessionName: host.sessionName))
            }
        }
    }

    private func select(_ session: HerdrSession, on host: Host) {
        do {
            try store.select(session, for: host.id, in: catalog)
        } catch {
            selectionError = "The selected session could not be saved."
        }
    }
}
