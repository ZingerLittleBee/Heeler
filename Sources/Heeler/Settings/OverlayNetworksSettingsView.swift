import HeelerOverlay
import SwiftUI
import UIKit

/// Settings › Overlay Networks: the in-app Tailscale, ZeroTier, and EasyTier
/// networks a Host can be reached through (ADR 0021). Each row has the
/// network's status and a switch that keeps it connected; signing in,
/// editing, and the network's machines are on its own screen.
struct OverlayNetworksSettingsView: View {
    let store: OverlayNetworkStore
    let onHostAdded: (Host.ID) -> Void
    @State private var isAdding = false
    @State private var deleteError: String?
    @State private var pendingDeletion: OverlayNetwork?
    /// A network just added, opened once its form has closed.
    @State private var addedNetworkID: OverlayNetwork.ID?
    @State private var opened: OpenedNetwork?

    /// A network's screen pushed from here rather than by its row's tap: one
    /// just added, or a Sign In from the list, starts at once.
    struct OpenedNetwork: Hashable {
        let id: OverlayNetwork.ID
        var startsOnAppear = false
    }

    var body: some View {
        List {
            if let loadError = store.catalogLoadError {
                Section {
                    Label(loadError.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            if store.networks.isEmpty {
                if store.catalogLoadError == nil {
                    emptyState
                }
            } else {
                Section {
                    ForEach(store.networks) { network in
                        OverlayNetworkRow(
                            network: network, store: store,
                            onOpen: { opened = OpenedNetwork(id: network.id) },
                            onSignIn: { opened = OpenedNetwork(id: network.id, startsOnAppear: true) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = network
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text(
                        "Hosts connect their network on their own; the switch keeps one "
                            + "connected. Heeler joins without turning on a VPN, and a network "
                            + "stays connected only while Heeler is open.")
                }
            }
        }
        .navigationTitle("Overlay Networks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAdding = true
                } label: {
                    Label("Add Network", systemImage: "plus")
                }
                .disabled(store.catalogLoadError != nil)
            }
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { network in
            Button("Delete Network", role: .destructive) { delete(network) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(OverlayNetworkCopy.deleteMessage)
        }
        .alert(
            "Could not delete the network",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: $isAdding, onDismiss: {
            // Push only after the sheet has gone, or the push is dropped.
            guard let id = addedNetworkID else { return }
            addedNetworkID = nil
            opened = OpenedNetwork(id: id, startsOnAppear: true)
        }) {
            OverlayNetworkFormView(store: store) { addedNetworkID = $0 }
        }
        .navigationDestination(item: $opened) { opened in
            // A Tailscale network started here goes straight to sign-in
            // instead of waiting for another tap on its screen.
            OverlayNetworkDetailView(
                store: store, networkID: opened.id, onHostAdded: onHostAdded,
                startsOnAppear: opened.startsOnAppear)
        }
        .task {
            // Node status changes on its own (sign-in completes, peers come
            // and go); poll only while this screen is visible.
            while !Task.isCancelled {
                await store.refreshStatuses()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label("No Networks", systemImage: OverlayKind.glyphSymbol)
            } description: {
                Text(
                    "Reach a Mac outside your local network through Tailscale, ZeroTier, or "
                        + "EasyTier. Heeler joins on its own, without a VPN.")
            } actions: {
                Button("Add Network") { isAdding = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .listRowBackground(Color.clear)
    }

    private func delete(_ network: OverlayNetwork) {
        do {
            try store.remove(network.id)
        } catch {
            deleteError = (error as? OverlayNetworkStoreError)?.message
                ?? "The network could not be deleted."
        }
    }
}

/// A network in the list: its kind, name, and status, and the switch (or
/// the step in progress) at the trailing edge. The row opens the network.
private struct OverlayNetworkRow: View {
    let network: OverlayNetwork
    let store: OverlayNetworkStore
    let onOpen: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        let headline = OverlayNetworkHeadline(network: network, store: store)
        // Tailscale's own glyph says the kind; the others name it.
        let summary = network.kind == .tailscale
            ? headline.rowSummary : "\(network.kind.displayName) · \(headline.rowSummary)"
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    OverlayKindGlyph(kind: network.kind)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(network.displayName)
                            .foregroundStyle(.primary)
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(headline.tone.textColor)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows the network's status and machines")
            OverlayNetworkControlView(network: network, store: store, onSignIn: onSignIn)
        }
    }
}

/// The trailing control of a network's row and status: a switch that keeps
/// it connected, or the native loading button of the step in progress.
struct OverlayNetworkControlView: View {
    let network: OverlayNetwork
    let store: OverlayNetworkStore
    /// Where Sign In goes; nil shows nothing for a network without a login
    /// (its screen has its own Sign In).
    var onSignIn: (() -> Void)?
    /// Cancel while connecting; stops the Connect by default.
    var onCancel: (() -> Void)?

    var body: some View {
        let id = network.id
        switch store.control(for: network) {
        case .signIn:
            if let onSignIn {
                Button("Sign In", action: onSignIn)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fontWeight(.semibold)
                    .accessibilityLabel("Sign in to \(network.displayName)")
            }
        case .connecting:
            OverlayActivityButton(
                title: "Cancel", isLoading: true,
                accessibilityLabel: "Cancel connecting \(network.displayName)"
            ) {
                if let onCancel { onCancel() } else { store.cancelConnect(id) }
            }
            .fixedSize()
        case .signingOut:
            OverlayActivityButton(title: "Signing Out", isLoading: true) {}
                .fixedSize()
                .disabled(true)
        case .toggle(let isOn):
            Toggle(
                network.displayName,
                isOn: Binding(
                    get: { isOn },
                    set: { connect in
                        Task {
                            if connect {
                                await store.connect(id)
                            } else {
                                await store.disconnect(id)
                            }
                        }
                    })
            )
            .labelsHidden()
            .accessibilityHint(isOn ? "Disconnects the network" : "Connects the network")
        }
    }
}

/// The kind's colored tile, as Settings shows an app or a service.
struct OverlayKindGlyph: View {
    let kind: OverlayKind
    @ScaledMetric(relativeTo: .body) private var size = 30.0

    var body: some View {
        Image(systemName: OverlayKind.glyphSymbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind.tint.gradient, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension OverlayKind {
    static let glyphSymbol = "point.3.filled.connected.trianglepath.dotted"

    var tint: Color {
        switch self {
        case .tailscale: .blue
        case .zerotier: .orange
        case .easytier: .indigo
        }
    }
}

/// A network's status in words: the title and line under it at the top of
/// its screen, the few words of its row, and the badge beside them.
/// Progress (connecting, signing out) changes the words but not the badge,
/// which keeps the state the network is coming from.
@MainActor
struct OverlayNetworkHeadline: Equatable {
    var title: String
    var subtitle: String?
    var rowSummary: String
    var symbol: String
    var tone: OverlayStatusTone
    /// A Tailscale device an admin has yet to approve.
    var isAwaitingApproval = false

    /// `isStartingSignIn`: the network's screen is getting a login page to
    /// open in the browser.
    init(network: OverlayNetwork, store: OverlayNetworkStore, isStartingSignIn: Bool = false) {
        let id = network.id
        let status = store.statuses[id] ?? .stopped
        let failure = store.connectFailures[id]
        let signedOut = store.signedOut.contains(id)
        let needsSignIn = store.needsSignIn(network)
        let waitReason = OverlayWaitReason(network: network, status: status, failure: failure)
        let summary = OverlayStatusCopy.summary(
            status, failure: failure, signedOut: signedOut, needsSignIn: needsSignIn)
        symbol = OverlayStatusCopy.symbol(
            status, failure: failure, signedOut: signedOut, needsSignIn: needsSignIn)
        tone = OverlayStatusCopy.tone(
            status, failure: failure, signedOut: signedOut, needsSignIn: needsSignIn)
        if network.kind == .tailscale, case .waiting = status {
            isAwaitingApproval = true
        }
        let deviceName = network.deviceName ?? "this device"

        if store.signingOut.contains(id) {
            title = "Signing out…"
            subtitle = "Leaving the tailnet"
            rowSummary = title
        } else if isStartingSignIn {
            title = "Preparing sign-in…"
            subtitle = "Your browser opens when it is ready."
            rowSummary = title
        } else if let waitReason, waitReason != .configServerConnection {
            // Shown while a Connect still runs, too: the wait is for
            // someone else, and the step it needs is known already.
            switch waitReason {
            case .zeroTierAuthorization:
                title = "Waiting for authorization"
                subtitle = "An admin must authorize this device on \(network.zeroTierNetworkID ?? "the network")."
            case .configServerAssignment, .configServerConnection:
                title = "Waiting for a network"
                subtitle = "Assign one to this device in the EasyTier console."
            }
            rowSummary = title
            symbol = "hourglass"
            tone = .attention
        } else if store.connecting.contains(id) || status == .starting || waitReason != nil {
            title = "Connecting…"
            if let server = network.configServerHost {
                subtitle = server
            } else {
                subtitle = network.deviceName.map { "Joining as \($0)" }
            }
            rowSummary = title
            if waitReason != nil {
                // Still reaching the config server: nothing to do yet.
                symbol = "pause.fill"
                tone = .busy
            }
        } else if isAwaitingApproval {
            title = "Waiting for approval"
            subtitle = "An admin must approve \(deviceName) before it joins."
            rowSummary = title
            symbol = "hourglass"
            tone = .attention
        } else if needsSignIn {
            if signedOut {
                title = "Signed out"
                subtitle =
                    "Hosts on \(network.displayName) stay disconnected until you sign in again."
            } else {
                title = "Sign in to \(network.tailscaleControlURL?.host() ?? "Tailscale")"
                subtitle = "Use the account your Mac is signed in with."
            }
            rowSummary = summary
        } else {
            let peers = status.isOnline ? store.details[id]?.peers : nil
            title = summary
            subtitle = OverlayStatusCopy.explanation(status, failure: failure)
                ?? peers.flatMap { OverlayStatusCopy.peerCount($0, kind: network.kind) }
                ?? (status == .stopped && failure == nil ? "Connects when a Host needs it." : nil)
            rowSummary = peers
                .flatMap { OverlayStatusCopy.shortPeerCount($0, kind: network.kind) }
                .map { "\(summary) · \($0)" } ?? summary
            let assigned = status.isOnline ? store.details[id]?.assignedNetworks ?? [] : []
            let refused = assigned.filter { $0.error != nil }
            if !refused.isEmpty {
                title = "\(assigned.count - refused.count) of \(assigned.count) networks running"
                let names = refused.map(OverlayStatusCopy.assignedNetworkName).formatted(.list(type: .and))
                subtitle = "\(names) can't run here."
                rowSummary = title
                symbol = "exclamationmark"
                tone = .attention
            } else if assigned.count > 1 {
                subtitle = ["\(assigned.count) networks", subtitle].compactMap { $0 }.joined(separator: " · ")
            }
        }
    }
}

/// What a ZeroTier or EasyTier config-server node waits for: its waiting
/// status, or the not-ready failure a Connect ended with while it waited.
enum OverlayWaitReason: Equatable {
    /// An admin has yet to authorize this ZeroTier node on the network.
    case zeroTierAuthorization
    /// The EasyTier node is still reaching its config server.
    case configServerConnection
    /// The config server has not assigned this device a network.
    case configServerAssignment

    /// What `EasyTierNode` reports while it reaches the config server.
    static let configServerConnectionDetail = "Connecting to the config server"

    init?(network: OverlayNetwork, status: OverlayNodeStatus, failure: TransportError?) {
        let detail: String
        if case .waiting(let waiting) = status {
            detail = waiting
        } else if !status.isOnline, case .overlayFailed(_, .notReady(let notReady))? = failure {
            detail = notReady
        } else {
            return nil
        }
        switch network.settings {
        case .zerotier:
            self = .zeroTierAuthorization
        case .easytierConfigServer:
            self = detail.hasPrefix(Self.configServerConnectionDetail)
                ? .configServerConnection : .configServerAssignment
        case .tailscale, .easytier:
            return nil
        }
    }
}

extension OverlayNetwork {
    /// The ZeroTier network ID, 16 lowercase hex digits.
    var zeroTierNetworkID: String? {
        guard case .zerotier(let networkID, _, _) = settings else { return nil }
        return networkID
    }

    /// The network in ZeroTier Central, where its admin authorizes members.
    /// nil on a custom planet, whose controller is self-hosted.
    var zeroTierCentralURL: URL? {
        guard case .zerotier(let networkID, _, .none) = settings else { return nil }
        return URL(string: "https://my.zerotier.com/network/\(networkID)")
    }

    /// The config server's host, without the account token the URL ends in.
    var configServerHost: String? {
        guard case .easytierConfigServer(let server, _, _, _) = settings else { return nil }
        return URLComponents(string: server)?.host ?? server
    }
}

/// Wording the list and a network's screen share.
enum OverlayNetworkCopy {
    static let deleteMessage =
        "Hosts that use this network stop connecting until you choose another network for them."
}

extension OverlayNodeStatus {
    var isOnline: Bool {
        if case .online = self { true } else { false }
    }

    /// Whether the node is up, even if not online yet: what a network's
    /// switch shows. A stopped or failed node is off.
    var isRunning: Bool {
        switch self {
        case .starting, .needsLogin, .waiting, .online: true
        case .stopped, .failed: false
        }
    }
}

/// How a network's status reads at a glance: its badge's color, and the
/// color of its row's status.
enum OverlayStatusTone: Equatable {
    case idle, busy, ok, attention, failed

    var color: Color {
        switch self {
        case .ok: .green
        case .attention: .orange
        case .failed: .red
        case .idle, .busy: .secondary
        }
    }

    /// For status text, where system orange is too light to read on white.
    var textColor: Color {
        switch self {
        case .attention: Self.attentionText
        case .failed: .red
        case .idle, .busy, .ok: .secondary
        }
    }

    private static let attentionText = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? .systemOrange : UIColor(red: 0.78, green: 0.43, blue: 0, alpha: 1)
        })
}

/// One status vocabulary for the list row and the detail screen.
enum OverlayStatusCopy {
    /// The tone of `summary`: whether the network is up, needs the user
    /// (sign-in, approval), or failed.
    static func tone(
        _ status: OverlayNodeStatus?, failure: TransportError?, signedOut: Bool = false,
        needsSignIn: Bool = false
    ) -> OverlayStatusTone {
        if let failure {
            guard case .overlayFailed(_, let reason) = failure else { return .failed }
            switch reason {
            case .loginRequired, .signedOut, .notReady: return .attention
            default: return .failed
            }
        }
        switch status ?? .stopped {
        case .stopped: return signedOut || needsSignIn ? .attention : .idle
        case .starting: return .busy
        case .needsLogin, .waiting: return .attention
        case .online: return .ok
        case .failed: return .failed
        }
    }

    /// The status badge's symbol: what kind of state, where the tone
    /// only says how urgent.
    static func symbol(
        _ status: OverlayNodeStatus?, failure: TransportError?, signedOut: Bool = false,
        needsSignIn: Bool = false
    ) -> String {
        let signIn = "person.fill", waiting = "hourglass", failed = "exclamationmark"
        if let failure {
            guard case .overlayFailed(_, let reason) = failure else { return failed }
            switch reason {
            case .loginRequired, .signedOut: return signIn
            case .notReady: return waiting
            default: return failed
            }
        }
        switch status ?? .stopped {
        // Starting keeps the badge of a stopped network: progress shows
        // in the network's button, not here.
        case .stopped, .starting: return signedOut || needsSignIn ? signIn : "pause.fill"
        case .needsLogin: return signIn
        case .waiting: return waiting
        case .online: return "checkmark"
        case .failed: return failed
        }
    }

    /// "2 of 9 machines online" (a tailnet's peers are its machines), or
    /// "9 peers" where the overlay does not say who is online. ZeroTier
    /// roots are infrastructure, not peers.
    static func peerCount(_ peers: [OverlayPeer], kind: OverlayKind) -> String? {
        let members = members(peers, kind: kind)
        guard !members.isEmpty else {
            return "No other \(peerNoun(2, kind: kind)) yet"
        }
        let noun = peerNoun(members.count, kind: kind)
        guard let online = onlineCount(members) else { return "\(members.count) \(noun)" }
        return "\(online) of \(members.count) \(noun) online"
    }

    /// `peerCount` for a row beside "Connected": "2 of 9 online"; nil
    /// without peers.
    static func shortPeerCount(_ peers: [OverlayPeer], kind: OverlayKind) -> String? {
        let members = members(peers, kind: kind)
        guard !members.isEmpty else { return nil }
        guard let online = onlineCount(members) else {
            return "\(members.count) \(peerNoun(members.count, kind: kind))"
        }
        return "\(online) of \(members.count) online"
    }

    private static func members(_ peers: [OverlayPeer], kind: OverlayKind) -> [OverlayPeer] {
        kind == .zerotier ? peers.filter { !isZeroTierRoot($0) } : peers
    }

    /// A ZeroTier planet or moon: infrastructure, not a member.
    static func isZeroTierRoot(_ peer: OverlayPeer) -> Bool {
        peer.role == "planet" || peer.role == "moon"
    }

    /// A ZeroTier peer's paths, each once: the node reports one per
    /// network it shares with the peer.
    static func uniquePaths(_ peer: OverlayPeer) -> [String] {
        var seen = Set<String>()
        return peer.addresses.filter { seen.insert($0).inserted }
    }

    private static func peerNoun(_ count: Int, kind: OverlayKind) -> String {
        let noun = switch kind {
        case .tailscale: "machine"
        case .zerotier: "member"
        case .easytier: "peer"
        }
        return count == 1 ? noun : noun + "s"
    }

    /// nil when the overlay does not say who is online.
    private static func onlineCount(_ peers: [OverlayPeer]) -> Int? {
        guard peers.allSatisfy({ $0.isOnline != nil }) else { return nil }
        return peers.filter { $0.isOnline == true }.count
    }

    /// A few words for the list row and the Status row; the network's name
    /// is already beside it. `explanation` carries the reason.
    /// `needsSignIn`: a stopped Tailscale network has no login to start
    /// with (`OverlayNetworkStore.primaryAction` is Sign In).
    static func summary(
        _ status: OverlayNodeStatus?, failure: TransportError?, signedOut: Bool = false,
        needsSignIn: Bool = false
    ) -> String {
        if let failure {
            guard case .overlayFailed(_, let reason) = failure else { return "Failed" }
            switch reason {
            case .notConfigured: return "Removed"
            case .catalogUnreadable: return "Unreadable"
            case .misconfigured: return "Misconfigured"
            case .loginRequired: return "Needs sign-in"
            case .signedOut: return "Signed out"
            case .notReady: return "Not ready"
            case .startFailed: return "Failed"
            case .unreachable: return "Unreachable"
            case .timedOut: return "Timed out"
            }
        }
        switch status ?? .stopped {
        case .stopped:
            if signedOut { return "Signed out" }
            return needsSignIn ? "Not signed in" : "Not connected"
        case .starting: return "Connecting…"
        case .needsLogin: return "Needs sign-in"
        case .waiting: return "Waiting"
        case .online: return "Connected"
        case .failed: return "Failed"
        }
    }

    /// The reason behind `summary`, for a line of its own under Status.
    /// Worded for the network's own screen, so it never points back at
    /// Settings › Overlay Networks the way a Host's error does.
    static func explanation(_ status: OverlayNodeStatus?, failure: TransportError?) -> String? {
        if let failure {
            guard case .overlayFailed(_, let reason) = failure else {
                return failure.presentation.detail ?? failure.presentation.summary
            }
            switch reason {
            case .notConfigured, .catalogUnreadable:
                return failure.presentation.summary
            case .loginRequired:
                return "Sign in to add this device to the tailnet."
            case .signedOut:
                return "Sign in to add this device to the tailnet again."
            case .notReady(let detail):
                return sentence(detail) + " If an admin must approve this device, authorize it "
                    + "in the network's admin console."
            case .misconfigured(let detail):
                return sentence(detail) + " Edit the network to fix it."
            case .startFailed(let detail):
                return sentence(detail) + " Check the network's settings."
            case .unreachable(let detail):
                return detail
            case .timedOut:
                return "The network did not answer in time."
            }
        }
        switch status ?? .stopped {
        case .failed(let detail) where !detail.isEmpty, .waiting(let detail) where !detail.isEmpty:
            return sentence(detail)
        default:
            return nil
        }
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }

    /// "Online · Direct · 12 ms": whatever the overlay reports, in order.
    static func peerSummary(_ peer: OverlayPeer) -> String {
        var parts: [String] = []
        if let isOnline = peer.isOnline {
            parts.append(isOnline ? "Online" : "Offline")
        }
        if let isDirect = peer.isDirect {
            parts.append(isDirect ? "Direct" : "Relayed")
        }
        if let latency = peer.latency {
            parts.append(latencyText(latency))
        }
        return parts.joined(separator: " · ")
    }

    /// How a machine is reached, after its address: "Direct · 12 ms", or
    /// "Offline"; empty when the overlay does not say.
    static func peerReachability(_ peer: OverlayPeer) -> String {
        if peer.isOnline == false { return "Offline" }
        var parts: [String] = []
        if let isDirect = peer.isDirect {
            parts.append(isDirect ? "Direct" : "Relayed")
        }
        if let latency = peer.latency {
            parts.append(latencyText(latency))
        }
        return parts.joined(separator: " · ")
    }

    /// An assigned network's name, or its instance ID when it has none.
    static func assignedNetworkName(_ network: OverlayAssignedNetwork) -> String {
        network.name.isEmpty ? network.id : network.name
    }

    /// "IPv4" / "IPv6" where there are both, so two addresses do not both
    /// read "Address".
    static func addressTitle(_ address: String, among addresses: [String]) -> String {
        let isIPv6: (String) -> Bool = { $0.contains(":") }
        guard addresses.contains(where: isIPv6), addresses.contains(where: { !isIPv6($0) }) else {
            return "Address"
        }
        return isIPv6(address) ? "IPv6" : "IPv4"
    }

    static func latencyText(_ latency: Duration) -> String {
        let milliseconds = latency / .milliseconds(1)
        return milliseconds < 1 ? "<1 ms" : "\(Int(milliseconds.rounded())) ms"
    }
}

/// A value the user may need elsewhere (an address, a node ID): tap to
/// copy, with a checkmark and a VoiceOver announcement as confirmation.
struct OverlayCopyableRow: View {
    let title: String
    let value: String
    /// Smaller type on one line, the middle elided, for a long value (a
    /// machine ID); the copy is whole.
    var isCompact = false
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            AccessibilityNotification.Announcement("Copied").post()
        } label: {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(value)
                        .font(isCompact ? .footnote.monospaced() : .body.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(isCompact ? 1 : nil)
                        .truncationMode(.middle)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(copied ? Color.green : Color.accentColor)
                }
            } label: {
                Text(title)
                    .foregroundStyle(.primary)
            }
            .contentShape(.rect)
        }
        // A list row, not a tinted button: only the copy symbol is accented.
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value)")
        .accessibilityHint(copied ? "Copied" : "Copies to the clipboard")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

enum ZeroTierNodeIDCopy {
    static let authorizationHint =
        "On a private network, an admin authorizes this node ID before it can join."
}
