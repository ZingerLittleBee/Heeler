import SwiftUI

/// Host management (#14): the catalog of Hosts with add/edit/remove, each
/// row leading into that Host's onboarding checklist.
struct HostListView: View {
    let store: HostStore
    @State private var isAddingHost = false
    @State private var path: [Host.ID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "server.rack")
                    } description: {
                        Text("Add a machine that runs herdr to get started.")
                    } actions: {
                        Button("Add Host") { isAddingHost = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.hosts) { host in
                            NavigationLink(value: host.id) {
                                HostRow(host: host)
                            }
                        }
                        .onDelete(perform: removeHosts)
                    }
                }
            }
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { isAddingHost = true }
                }
            }
            .navigationDestination(for: Host.ID.self) { id in
                if let host = store.hosts.first(where: { $0.id == id }) {
                    // Keyed by the Host value: editing recreates the
                    // onboarding store so checks run against fresh settings.
                    HostOnboardingView(host: host, catalog: store)
                        .id(host)
                } else {
                    ContentUnavailableView("Host removed", systemImage: "server.rack")
                }
            }
            .sheet(isPresented: $isAddingHost) {
                HostFormView(store: store) { saved in
                    path.append(saved.id)
                }
            }
        }
    }

    private func removeHosts(at offsets: IndexSet) {
        for id in offsets.map({ store.hosts[$0].id }) {
            try? store.remove(id)
        }
    }
}

private struct HostRow: View {
    let host: Host

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.displayName)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var text = "\(host.username)@\(host.address)"
        if host.port != 22 { text += ":\(host.port)" }
        if case .namedSession(let session) = host.socketLocation {
            text += " · session \(session)"
        }
        return text
    }
}

#Preview {
    HostListView(store: HostStore(secrets: PreviewSecretStore()))
}

/// Keeps previews out of the real Keychain.
private final class PreviewSecretStore: SecretStore {
    func read(account: String) throws -> Data? { nil }
    func write(_ secret: Data, account: String) throws {}
    func removeSecret(account: String) throws {}
}
