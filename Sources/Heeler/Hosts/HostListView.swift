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

/// Host management (#14): the catalog of Hosts with add/edit/remove, one
/// card per Host (#316) leading into that Host's onboarding checklist.
struct HostListView: View {
    let store: HostStore
    private let initialHostID: Host.ID?
    private let connectionStatuses: [Host.ID: EventsSessionStatus]
    private let standingFailures: [Host.ID: TransportError]
    private let latencies: [Host.ID: Duration]
    /// Only Hosts whose inventory is known; see `HostInventory.known`.
    private let inventories: [Host.ID: HostInventory]
    /// Hosts whose Host-detail Reconnect request is in flight. Distinct from
    /// `EventsSessionStatus.reconnecting`.
    private let manualReconnectInFlightHostIDs: Set<Host.ID>
    private let retryConnection: (@MainActor @Sendable (Host.ID) async -> Void)?
    /// Where `initialHostID` was opened from. Its detail's back button goes
    /// back there instead of to this list.
    private let origin: HostListOrigin?
    @State private var removal: HostRemovalStore
    @State private var isAddingHost = false
    @State private var editingHost: Host?
    @State private var isScanningToPair = false
    @State private var manualFallbackRequested = false
    /// Stashed while a Host form / Pairing scan sheet dismisses; navigation
    /// waits for `onDismiss` so the TOFU alert is not suppressed mid-transition
    /// (#359).
    @State private var pendingOnboardingHostID: Host.ID?
    @State private var path: [Host.ID] = []

    init(
        store: HostStore,
        initialHostID: Host.ID? = nil,
        connectionStatuses: [Host.ID: EventsSessionStatus] = [:],
        standingFailures: [Host.ID: TransportError] = [:],
        latencies: [Host.ID: Duration] = [:],
        inventories: [Host.ID: HostInventory] = [:],
        manualReconnectInFlightHostIDs: Set<Host.ID> = [],
        retryConnection: (@MainActor @Sendable (Host.ID) async -> Void)? = nil,
        origin: HostListOrigin? = nil
    ) {
        self.store = store
        self.initialHostID = initialHostID
        self.connectionStatuses = connectionStatuses
        self.standingFailures = standingFailures
        self.latencies = latencies
        self.inventories = inventories
        self.manualReconnectInFlightHostIDs = manualReconnectInFlightHostIDs
        self.retryConnection = retryConnection
        self.origin = origin
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
                            Section { card(for: host) }
                        }
                    }
                    .listSectionSpacing(12)
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
                        standingFailure: standingFailures[id],
                        isManualReconnectInFlight: manualReconnectInFlightHostIDs.contains(id),
                        retryConnection: retryAction(for: id))
                        .id(host)
                        .modifier(ReturnToOrigin(origin: returnOrigin(for: id)))
                } else {
                    ContentUnavailableView("Host removed", systemImage: "server.rack")
                }
            }
            .sheet(
                isPresented: $isAddingHost,
                onDismiss: {
                    navigateToPendingOnboardingHostIfNeeded()
                }
            ) {
                HostFormView(store: store) { saved in
                    pendingOnboardingHostID = saved.id
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
                        return
                    }
                    navigateToPendingOnboardingHostIfNeeded()
                }
            ) {
                // A successful Pairing lands in the same onboarding preflight
                // a manually added Host enters (session discovery included).
                PairingScanView(catalog: store) { paired in
                    pendingOnboardingHostID = paired.id
                } onAddManually: {
                    manualFallbackRequested = true
                }
            }
            .sheet(item: $editingHost) { host in
                HostFormView(store: store, editing: host)
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

    private func card(for host: Host) -> some View {
        let retry = retryAction(for: host.id)
        return HostCard(
            host: host,
            presentation: HostCardPresentation(
                host: host,
                status: connectionStatuses[host.id],
                standingFailure: standingFailures[host.id],
                latency: latencies[host.id],
                inventory: inventories[host.id],
                canRetry: retry != nil),
            isRetryInFlight: manualReconnectInFlightHostIDs.contains(host.id),
            onOpen: { path.append(host.id) },
            onRetry: { if let retry { Task { await retry() } } },
            onEdit: { editingHost = host }
        )
        .listRowBackground(ListCard.fill)
        // Every removal asks first. No `.destructive` role: List would
        // animate the card out while the confirmation is still up.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                removal.requestRemoval([host.id])
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editingHost = host }
            Button("Remove Host", systemImage: "trash", role: .destructive) {
                removal.requestRemoval([host.id])
            }
        }
    }

    /// Only the detail opened on request, still the first thing pushed.
    private func returnOrigin(for id: Host.ID) -> HostListOrigin? {
        guard id == initialHostID, path.first == id else { return nil }
        return origin
    }

    private func navigateToPendingOnboardingHostIfNeeded() {
        guard let id = pendingOnboardingHostID else { return }
        pendingOnboardingHostID = nil
        path.append(id)
    }

    private func retryAction(
        for id: Host.ID
    ) -> (@MainActor @Sendable () async -> Void)? {
        guard let retryConnection else { return nil }
        return { await retryConnection(id) }
    }
}

/// The screen that opened a Host's detail from outside the Hosts list.
struct HostListOrigin {
    /// Names the destination for VoiceOver, e.g. "Agents".
    let title: String
    let goBack: () -> Void
}

/// Swaps the back button for one that returns to `origin`, so opening a Host
/// from somewhere else and backing out lands where the user started.
private struct ReturnToOrigin: ViewModifier {
    let origin: HostListOrigin?

    func body(content: Content) -> some View {
        if let origin {
            content
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: origin.goBack) {
                            Image(systemName: "chevron.backward")
                        }
                        .accessibilityLabel("Back to \(origin.title)")
                    }
                }
        } else {
            content
        }
    }
}

/// What a Host holds, counted only once its inventory is known: while a
/// Host connects or loads, none is not the same as unknown (see Agent
/// Inventory in `CONTEXT.md`).
struct HostInventory: Equatable {
    let agents: Int
    let terminals: Int

    static func known(
        statuses: [Host.ID: EventsSessionStatus],
        awaitingSnapshot: Set<Host.ID>,
        agents: [ConsoleAgent],
        terminals: [ConsoleTerminal]
    ) -> [Host.ID: HostInventory] {
        var inventories: [Host.ID: HostInventory] = [:]
        for (id, status) in statuses {
            guard case .connected = status, !awaitingSnapshot.contains(id) else { continue }
            inventories[id] = HostInventory(
                agents: agents.count { $0.hostID == id },
                terminals: terminals.count { $0.hostID == id })
        }
        return inventories
    }

    var agentsText: String { agents == 1 ? "1 Agent" : "\(agents) Agents" }
    var terminalsText: String { terminals == 1 ? "1 Terminal" : "\(terminals) Terminals" }
}

/// One Host card on the Hosts list (#316). A Host with a connection problem
/// says what it is in the connection sheet's words and rules, and offers
/// Retry once nothing else will: stopped, or dialing the user's own retry.
struct HostCardPresentation: Equatable {
    enum Content: Equatable {
        /// Connected; nil while the inventory is still unknown.
        case inventory(HostInventory?)
        case problem(HostConnectionDetailPresentation)
        /// Paused, or connecting with nothing to explain.
        case quiet
    }

    let status: String
    let tone: HostConnectionTone
    let address: String
    let content: Content
    let offersRetry: Bool

    init(
        host: Host,
        status: EventsSessionStatus?,
        standingFailure: TransportError?,
        latency: Duration?,
        inventory: HostInventory?,
        canRetry: Bool = true
    ) {
        var address = "\(host.username)@\(host.address)"
        if host.port != 22 { address += ":\(host.port)" }
        if case .namedSession(let session) = host.socketLocation {
            address += " · session \(session)"
        }
        self.address = address
        if let problem = HostConnectionDetailPresentation(
            host: host, status: status, standingFailure: standingFailure)
        {
            self.status = problem.title
            tone = problem.tone
            content = .problem(problem)
            let isStopped = if case .failed = status { true } else { false }
            offersRetry = canRetry && (isStopped || problem.isDialing)
        } else {
            let chip = HostConnectionPresentation(
                status: status, standingFailure: standingFailure, latency: latency)
            self.status = chip.title
            tone = chip.tone
            content = if case .connected = status { .inventory(inventory) } else { .quiet }
            offersRetry = false
        }
    }
}

private struct HostCard: View {
    let host: Host
    let presentation: HostCardPresentation
    let isRetryInFlight: Bool
    let onOpen: () -> Void
    let onRetry: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The actions below stay out of this button, so they never
            // open the Host by accident.
            Button(action: onOpen) {
                summary
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this Host.")
            if presentation.offersRetry {
                actions
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HostStatusGlyph(tone: presentation.tone)
                Text(host.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HostStatusPill(text: presentation.status, tone: presentation.tone)
            }
            Text(presentation.address)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.content {
        case .inventory(let inventory?):
            HStack(spacing: 8) {
                countPill(inventory.agentsText)
                countPill(inventory.terminalsText)
            }
            .padding(.top, 2)
        case .problem(let problem):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(problem.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(problem.isDialing ? .secondary : .primary)
                    if let attempt = problem.attempt {
                        Text(attempt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = problem.detail {
                    Text(detail)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let suggestion = problem.recoverySuggestion {
                    Text(suggestion)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        case .inventory(nil), .quiet:
            EmptyView()
        }
    }

    private func countPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.fill.tertiary, in: Capsule())
    }

    private var actions: some View {
        let busy = isRetryInFlight || isDialing
        return HStack(spacing: 10) {
            Button(action: onRetry) {
                Text(busy ? "Connecting…" : "Retry")
                    // An overlay, not a sibling: the spinner would grow the
                    // button, as in the connection sheet.
                    .overlay(alignment: .leading) {
                        if busy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                                .offset(x: -24)
                        }
                    }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .allowsHitTesting(!busy)
            .accessibilityAddTraits(busy ? .updatesFrequently : [])
            Button(action: onEdit) {
                Text("Edit").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
        }
        .buttonBorderShape(.capsule)
    }

    private var isDialing: Bool {
        if case .problem(let problem) = presentation.content { return problem.isDialing }
        return false
    }
}

/// A Host card's status pill while the Host has no connection problem to
/// explain; a problem takes `HostConnectionDetailPresentation`'s title
/// instead (see `HostCardPresentation`). The pill itself renders Host
/// Connection Status, never a Transport Error Presentation.
struct HostConnectionPresentation: Equatable {
    let title: String
    let accessibilityLabel: String
    let tone: HostConnectionTone

    init(
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        latency: Duration?
    ) {
        switch status {
        case .connected:
            if let latency {
                let formattedLatency = HostLatencyFormatting.formatted(latency)
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
            tone = .reconnecting
        case .connecting:
            if standingFailure != nil {
                title = "Unavailable"
                accessibilityLabel = "Unavailable"
                tone = .unavailable
            } else {
                title = "Connecting…"
                accessibilityLabel = "Connecting"
                tone = .pending
            }
        case .failed, .ended:
            title = "Unavailable"
            accessibilityLabel = "Unavailable"
            tone = .unavailable
        case .suspended:
            title = "Paused"
            accessibilityLabel = "Connection paused"
            tone = .paused
        case nil:
            title = "Connecting…"
            accessibilityLabel = "Connecting"
            tone = .pending
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
