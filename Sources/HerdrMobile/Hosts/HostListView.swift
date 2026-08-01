import Observation
import SwiftUI

struct HostRemovalRequest: Equatable {
    let hosts: [Host]

    var title: String {
        if hosts.count == 1, let host = hosts.first {
            return "Remove \(host.displayName)?"
        }
        return "Remove \(hosts.count) Hosts?"
    }

    var actionTitle: String {
        hosts.count == 1 ? "Remove Host" : "Remove Hosts"
    }

    let message =
        "This permanently deletes the Host configuration and any saved password "
        + "from the Keychain. This cannot be undone."
}

@MainActor
@Observable
final class HostRemovalStore {
    private(set) var errorMessage: String?
    private(set) var pendingRequest: HostRemovalRequest?

    @ObservationIgnored
    private let store: HostStore

    init(store: HostStore) {
        self.store = store
    }

    func requestRemoval(_ ids: [Host.ID]) {
        let requestedIDs = Set(ids)
        let hosts = store.hosts.filter { requestedIDs.contains($0.id) }
        guard !hosts.isEmpty else { return }
        pendingRequest = HostRemovalRequest(hosts: hosts)
    }

    func cancelRemoval() {
        pendingRequest = nil
    }

    func confirmRemoval(_ request: HostRemovalRequest) {
        pendingRequest = nil
        for host in request.hosts {
            do {
                try store.remove(host.id)
            } catch {
                errorMessage = "The Host could not be removed. Its saved credentials may still be in the Keychain."
                return
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }
}

/// Host management (#14): the catalog of Hosts with add/edit/remove, each
/// row leading into that Host's onboarding checklist.
struct HostListView: View {
    let store: HostStore
    private let initialHostID: Host.ID?
    private let connectionStatuses: [Host.ID: EventsSessionStatus]
    private let latencies: [Host.ID: Duration]
    private let reconnectingHostIDs: Set<Host.ID>
    private let retryConnection: (@MainActor @Sendable (Host.ID) async -> Void)?
    @State private var removal: HostRemovalStore
    @State private var isAddingHost = false
    @State private var isScanningToPair = false
    @State private var manualFallbackRequested = false
    @State private var path: [Host.ID] = []

    init(
        store: HostStore,
        initialHostID: Host.ID? = nil,
        connectionStatuses: [Host.ID: EventsSessionStatus] = [:],
        latencies: [Host.ID: Duration] = [:],
        reconnectingHostIDs: Set<Host.ID> = [],
        retryConnection: (@MainActor @Sendable (Host.ID) async -> Void)? = nil
    ) {
        self.store = store
        self.initialHostID = initialHostID
        self.connectionStatuses = connectionStatuses
        self.latencies = latencies
        self.reconnectingHostIDs = reconnectingHostIDs
        self.retryConnection = retryConnection
        _removal = State(initialValue: HostRemovalStore(store: store))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.catalogLoadError != nil {
                    ContentUnavailableView {
                        Label("Hosts Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(
                            "The saved Host catalog could not be read. Its original data was preserved; "
                                + "reinstalling or adding a Host would risk losing it.")
                    }
                } else if store.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "server.rack")
                    } description: {
                        Text("Add a machine that runs herdr to get started.")
                    } actions: {
                        // Scan to Pair is the primary add-Host action; the
                        // manual form is the fallback (ADR 0007).
                        Button("Scan to Pair", systemImage: "qrcode.viewfinder") {
                            isScanningToPair = true
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Add Manually") { isAddingHost = true }
                    }
                } else {
                    List {
                        ForEach(store.hosts) { host in
                            NavigationLink(value: host.id) {
                                HostRow(
                                    host: host,
                                    connectionStatus: connectionStatuses[host.id],
                                    latency: latencies[host.id])
                            }
                        }
                        .onDelete(perform: removeHosts)
                    }
                }
            }
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan to Pair", systemImage: "qrcode.viewfinder") {
                        isScanningToPair = true
                    }
                    .disabled(store.catalogLoadError != nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { isAddingHost = true }
                        .disabled(store.catalogLoadError != nil)
                }
            }
            .navigationDestination(for: Host.ID.self) { id in
                if let host = store.hosts.first(where: { $0.id == id }) {
                    // Keyed by the Host value: editing recreates the
                    // onboarding store so checks run against fresh settings.
                    HostOnboardingView(
                        host: host,
                        catalog: store,
                        connectionStatus: connectionStatuses[id],
                        isReconnecting: reconnectingHostIDs.contains(id),
                        retryConnection: retryAction(for: id))
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
            .sheet(
                isPresented: $isScanningToPair,
                onDismiss: {
                    // The scan sheet's "Add Manually" fallback (camera denied
                    // or unsupported): present the form only once this sheet
                    // is fully gone, so the two sheets never overlap.
                    if manualFallbackRequested {
                        manualFallbackRequested = false
                        isAddingHost = true
                    }
                }
            ) {
                // A successful Pairing lands in the same onboarding preflight
                // a manually added Host enters (session discovery included).
                PairingScanView(catalog: store) { paired in
                    path.append(paired.id)
                } onAddManually: {
                    manualFallbackRequested = true
                }
            }
            .alert(
                removal.pendingRequest?.title ?? "Remove Host?",
                isPresented: removalConfirmationPresented,
                presenting: removal.pendingRequest
            ) { request in
                Button(request.actionTitle, role: .destructive) {
                    removal.confirmRemoval(request)
                }
                Button("Cancel", role: .cancel) {
                    removal.cancelRemoval()
                }
            } message: { request in
                Text(request.message)
            }
            .alert(
                "Could Not Remove Host",
                isPresented: Binding(
                    get: { removal.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            removal.dismissError()
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    removal.dismissError()
                }
            } message: {
                Text(removal.errorMessage ?? "")
            }
            .task(id: initialHostID) {
                guard
                    path.isEmpty,
                    let initialHostID,
                    store.hosts.contains(where: { $0.id == initialHostID })
                else { return }
                path.append(initialHostID)
            }
        }
    }

    private var removalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { removal.pendingRequest != nil },
            set: { if !$0 { removal.cancelRemoval() } })
    }

    private func removeHosts(at offsets: IndexSet) {
        removal.requestRemoval(offsets.map { store.hosts[$0].id })
    }

    private func retryAction(
        for id: Host.ID
    ) -> (@MainActor @Sendable () async -> Void)? {
        guard let retryConnection else { return nil }
        return { await retryConnection(id) }
    }
}

private struct HostRow: View {
    let host: Host
    let connectionStatus: EventsSessionStatus?
    let latency: Duration?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HostConnectionIndicator(
                presentation: HostConnectionPresentation(
                    status: connectionStatus,
                    latency: latency))
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

struct HostConnectionPresentation: Equatable {
    enum Tone: Equatable {
        case connected
        case pending
        case warning
        case unavailable
    }

    let title: String
    let accessibilityLabel: String
    let tone: Tone

    init(status: EventsSessionStatus?, latency: Duration?) {
        switch status {
        case .connected:
            if let latency {
                let formattedLatency = Self.formatted(latency)
                title = formattedLatency
                accessibilityLabel = "Connected, latency \(formattedLatency)"
            } else {
                title = "Measuring…"
                accessibilityLabel = "Connected, measuring latency"
            }
            tone = .connected
        case .reconnecting:
            title = "Reconnecting…"
            accessibilityLabel = "Reconnecting"
            tone = .warning
        case .failed, .ended:
            title = "Unavailable"
            accessibilityLabel = "Unavailable"
            tone = .unavailable
        case .suspended:
            title = "Paused"
            accessibilityLabel = "Connection paused"
            tone = .pending
        case nil:
            title = "Connecting…"
            accessibilityLabel = "Connecting"
            tone = .pending
        }
    }

    private static func formatted(_ latency: Duration) -> String {
        let components = latency.components
        let milliseconds = max(
            0,
            Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000)
        guard milliseconds >= 1 else { return "<1 ms" }
        return "\(Int(milliseconds.rounded())) ms"
    }
}

private struct HostConnectionIndicator: View {
    let presentation: HostConnectionPresentation

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(presentation.title)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var tint: Color {
        switch presentation.tone {
        case .connected: .green
        case .pending: .secondary
        case .warning: .orange
        case .unavailable: .red
        }
    }
}

#Preview {
    HostListView(store: HostStore(secrets: PreviewSecretStore()))
}

/// Keeps previews out of the real Keychain.
private final class PreviewSecretStore: SecretStore {
    func read(account: String) throws -> Data? { nil }
    func readAll() throws -> [String: Data] { [:] }
    func write(_ secret: Data, account: String) throws {}
    func removeSecret(account: String) throws {}
}
