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

/// Host management (#14): the catalog of Hosts with add/edit/remove, grouped
/// by what each needs from the user (#316), every row leading into that
/// Host's onboarding checklist.
struct HostListView: View {
    let store: HostStore
    private let initialHostID: Host.ID?
    private let connectionStatuses: [Host.ID: EventsSessionStatus]
    private let standingFailures: [Host.ID: TransportError]
    private let latencies: [Host.ID: Duration]
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
    /// State, not `@AppStorage`: a defaults write lands outside the toggle's
    /// animation, so the group would snap shut.
    @State private var collapsedGroups: Set<HostHealthGroup>
    @State private var isScanningToPair = false
    @State private var manualFallbackRequested = false
    /// Stashed while a Host form / Pairing scan sheet dismisses; navigation
    /// waits for `onDismiss` so the TOFU alert is not suppressed mid-transition
    /// (#359).
    @State private var pendingOnboardingHostID: Host.ID?
    @State private var path: [Host.ID] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: HostStore,
        initialHostID: Host.ID? = nil,
        connectionStatuses: [Host.ID: EventsSessionStatus] = [:],
        standingFailures: [Host.ID: TransportError] = [:],
        latencies: [Host.ID: Duration] = [:],
        manualReconnectInFlightHostIDs: Set<Host.ID> = [],
        retryConnection: (@MainActor @Sendable (Host.ID) async -> Void)? = nil,
        origin: HostListOrigin? = nil
    ) {
        self.store = store
        self.initialHostID = initialHostID
        self.connectionStatuses = connectionStatuses
        self.standingFailures = standingFailures
        self.latencies = latencies
        self.manualReconnectInFlightHostIDs = manualReconnectInFlightHostIDs
        self.retryConnection = retryConnection
        self.origin = origin
        _removal = State(initialValue: HostRemovalStore(store: store))
        _collapsedGroups = State(initialValue: HostHealthGroup.collapsed(in: .standard))
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
                        ForEach(HostListEntry.grouped(entries)) { section in
                            let isCollapsed = isCollapsed(section.group)
                            Section {
                                if !isCollapsed {
                                    ForEach(section.entries) { row(for: $0) }
                                }
                            } header: {
                                HostGroupHeader(
                                    group: section.group, count: section.entries.count,
                                    isCollapsed: isCollapsed
                                ) { toggle(section.group) }
                            }
                        }
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

    private var entries: [HostListEntry] {
        store.hosts.map { host in
            HostListEntry(
                host: host,
                presentation: HostRowPresentation(
                    host: host,
                    status: connectionStatuses[host.id],
                    standingFailure: standingFailures[host.id],
                    latency: latencies[host.id],
                    canRetry: retryConnection != nil))
        }
    }

    private func isCollapsed(_ group: HostHealthGroup) -> Bool {
        collapsedGroups.contains(group)
    }

    private func toggle(_ group: HostHealthGroup) {
        withAnimation(reduceMotion ? nil : .snappy) {
            if !collapsedGroups.insert(group).inserted { collapsedGroups.remove(group) }
        }
        HostHealthGroup.save(collapsedGroups, in: .standard)
    }

    @ViewBuilder
    private func row(for entry: HostListEntry) -> some View {
        let host = entry.host
        Group {
            if entry.presentation.offersRetry {
                // A Retry row opens the Host from everything but its button,
                // which a whole-row link would swallow.
                HStack(spacing: 12) {
                    Button { path.append(host.id) } label: {
                        HostRowLabel(host: host, presentation: entry.presentation)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this Host.")
                    HostRetryButton(
                        isBusy: entry.presentation.isDialing
                            || manualReconnectInFlightHostIDs.contains(host.id)
                    ) {
                        if let retry = retryAction(for: host.id) { Task { await retry() } }
                    }
                }
            } else {
                NavigationLink(value: host.id) {
                    HostRowLabel(host: host, presentation: entry.presentation)
                }
            }
        }
        .listRowBackground(ListCard.fill)
        // Every removal asks first. No `.destructive` role: List would
        // animate the row out while the confirmation is still up.
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

/// The Hosts list's groups (#316), by what each Host needs from the user and
/// in that order: a stopped Host first, next to its Retry.
enum HostHealthGroup: Int, CaseIterable, Comparable {
    case cannotConnect
    case trying
    case connected
    /// Paused while the app is in the background, or retired.
    case notConnected

    var title: String {
        switch self {
        case .cannotConnect: "Can't Connect"
        case .trying: "Trying"
        case .connected: "Connected"
        case .notConnected: "Not Connected"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    private static let collapsedKey = "host-list.collapsed-groups"

    static func collapsed(in defaults: UserDefaults) -> Set<Self> {
        Set((defaults.array(forKey: collapsedKey) as? [Int] ?? []).compactMap(Self.init(rawValue:)))
    }

    static func save(_ collapsed: Set<Self>, in defaults: UserDefaults) {
        defaults.set(collapsed.map(\.rawValue).sorted(), forKey: collapsedKey)
    }
}

/// One Host on the Hosts list, with how its row reads.
struct HostListEntry: Identifiable, Equatable {
    let host: Host
    let presentation: HostRowPresentation

    var id: Host.ID { host.id }

    struct Section: Identifiable, Equatable {
        let group: HostHealthGroup
        let entries: [HostListEntry]

        var id: HostHealthGroup { group }
    }

    /// Non-empty groups in `HostHealthGroup` order, catalog order within.
    static func grouped(_ entries: [HostListEntry]) -> [Section] {
        HostHealthGroup.allCases.compactMap { group in
            let members = entries.filter { $0.presentation.group == group }
            return members.isEmpty ? nil : Section(group: group, entries: members)
        }
    }
}

/// A group's header: its name and count, collapsing the group on tap.
private struct HostGroupHeader: View {
    let group: HostHealthGroup
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text(group.title)
                Text(count, format: .number)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.title), \(count) \(count == 1 ? "Host" : "Hosts")")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Shows these Hosts." : "Hides these Hosts.")
        .accessibilityAddTraits(.isHeader)
    }
}

/// One Hosts list row. A problem is named by its Summary alone; Host
/// detail, a tap away, shows the whole Transport Error Presentation.
struct HostRowPresentation: Equatable {
    let group: HostHealthGroup
    let tone: HostConnectionTone
    /// Under the name: the address while connected, otherwise the state.
    let detail: String
    /// A stopped Host's reason reads in red.
    let isProblem: Bool
    /// Latency while connected.
    let trailing: String?
    let offersRetry: Bool
    /// The user's own retry is dialing: the row stays in Can't Connect with
    /// its button busy, rather than jumping away under the finger.
    let isDialing: Bool

    init(
        host: Host,
        status: EventsSessionStatus?,
        standingFailure: TransportError?,
        latency: Duration?,
        canRetry: Bool = true
    ) {
        let problem = HostConnectionDetailPresentation(
            host: host, status: status, standingFailure: standingFailure)
        let chip = HostConnectionPresentation(
            status: status, standingFailure: standingFailure, latency: latency)
        tone = problem?.tone ?? chip.tone
        isDialing = problem?.isDialing ?? false
        trailing = if case .connected = status { chip.title } else { nil }
        switch status {
        case .failed:
            group = .cannotConnect
            detail = problem?.summary ?? chip.title
            isProblem = true
            offersRetry = canRetry
        case .connecting where problem != nil:
            group = .cannotConnect
            detail = problem?.summary ?? chip.title
            isProblem = false
            offersRetry = canRetry
        case .reconnecting:
            group = .trying
            detail = [problem?.summary, problem?.attempt].compactMap { $0 }.joined(separator: " · ")
            isProblem = false
            offersRetry = false
        case .connecting, nil:
            group = .trying
            detail = chip.title
            isProblem = false
            offersRetry = false
        case .connected:
            group = .connected
            var address = "\(host.username)@\(host.address)"
            if host.port != 22 { address += ":\(host.port)" }
            if case .namedSession(let session) = host.socketLocation {
                address += " · session \(session)"
            }
            detail = address
            isProblem = false
            offersRetry = false
        case .suspended, .ended:
            group = .notConnected
            detail = chip.title
            isProblem = false
            offersRetry = false
        }
    }
}

private struct HostRowLabel: View {
    let host: Host
    let presentation: HostRowPresentation

    var body: some View {
        HStack(spacing: 12) {
            HostStatusGlyph(tone: presentation.tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(presentation.isProblem ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let trailing = presentation.trailing {
                Text(trailing)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Retry on a stopped Host's row: the same Reconnect Request as Host
/// detail's button, busy while it dials.
private struct HostRetryButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Hidden, not removed, while busy: the button keeps its size.
            // Small and light: a stopped Host's reason is the row's point,
            // and three prominent buttons in a row shout over it.
            Image(systemName: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .opacity(isBusy ? 0 : 1)
                .overlay {
                    if isBusy { ProgressView().controlSize(.small) }
                }
                .frame(width: 30, height: 30)
                // Gray on gray: the stopped Host's red reason stays the one
                // color in the row.
                .background(.fill.tertiary, in: Circle())
                // The full 44-point target around the smaller circle.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .allowsHitTesting(!isBusy)
        .accessibilityLabel(isBusy ? "Connecting" : "Retry")
        .accessibilityAddTraits(isBusy ? .updatesFrequently : [])
    }
}

/// A Host's connection state in a word or two: a connected Host's latency,
/// or the state `HostRowPresentation` falls back on when there is no
/// problem to name. It renders Host Connection Status, never a Transport
/// Error Presentation.
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
