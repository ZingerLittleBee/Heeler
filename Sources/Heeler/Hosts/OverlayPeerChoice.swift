import Foundation
import HeelerOverlay
import Observation

/// One peer of an Overlay Network offered as a Host (or Jump Host) address.
/// Only Tailscale and EasyTier report overlay addresses for their peers;
/// ZeroTier reports physical paths, which no Host can use (ADR 0021).
struct OverlayPeerCandidate: Identifiable, Equatable, Sendable {
    /// How a picked Tailscale peer is addressed. EasyTier peers only have
    /// their virtual IPv4 address.
    enum AddressStyle: String, CaseIterable, Identifiable, Sendable {
        /// The peer's overlay IPv4 (Tailscale 100.x, EasyTier virtual IP).
        case ipAddress
        /// The Tailscale machine name, resolved through MagicDNS.
        case machineName

        var id: Self { self }

        var title: String {
            switch self {
            case .ipAddress: "IP Address"
            case .machineName: "Machine Name"
            }
        }
    }

    let id: String
    /// The peer's name on the network, or its id when it reports none.
    let displayName: String
    /// What the peer reported as its name; nil when it has none.
    let name: String?
    /// Overlay addresses, IPv4 first, without any prefix length.
    let addresses: [String]
    /// nil when the overlay does not say; treated as reachable.
    let isOnline: Bool?
    /// The network the peer is on, when the node runs several (an EasyTier
    /// config server's assignments).
    let network: String?
    let peer: OverlayPeer

    init(peer: OverlayPeer) {
        self.peer = peer
        id = peer.id
        let trimmedName = peer.name?.trimmingCharacters(in: .whitespaces)
        name = trimmedName.flatMap { $0.isEmpty ? nil : $0 }
        displayName = name ?? peer.id
        addresses = Self.orderedAddresses(peer.addresses)
        isOnline = peer.isOnline
        network = peer.network
    }

    var isOffline: Bool { isOnline == false }

    var ipv4: String? { addresses.first { !$0.contains(":") } }

    /// The address a Host should use in `style`: the IPv4 address (any
    /// overlay address when the peer has none), or the machine name when
    /// asked and known.
    func address(_ style: AddressStyle) -> String? {
        switch style {
        case .machineName:
            name ?? ipv4 ?? addresses.first
        case .ipAddress:
            ipv4 ?? addresses.first
        }
    }

    /// `10.0.0.2/24` → `10.0.0.2`; IPv4 before IPv6; blanks dropped.
    static func orderedAddresses(_ addresses: [String]) -> [String] {
        let bare = addresses.compactMap { address -> String? in
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            let host = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return host.isEmpty ? nil : host
        }
        return bare.filter { !$0.contains(":") } + bare.filter { $0.contains(":") }
    }
}

/// The peer list of the "Choose from …" sheet: which overlays offer one,
/// which peers can be a Host, their order, and search.
enum OverlayPeerList {
    /// Whether peers of `kind` carry addresses a Host can dial. ZeroTier's
    /// are physical paths across all of its networks.
    static func offersPeers(_ kind: OverlayKind) -> Bool {
        kind != .zerotier
    }

    /// Whether `kind`'s peers can also be addressed by machine name.
    static func offersMachineNames(_ kind: OverlayKind) -> Bool {
        kind == .tailscale
    }

    /// The sheet's entry point label: "Choose from Tailnet…".
    static func chooseTitle(for kind: OverlayKind) -> String {
        kind == .tailscale ? "Choose from Tailnet…" : "Choose from Network…"
    }

    /// Peers with at least one overlay address, online (or unknown) before
    /// offline, then by name.
    static func candidates(from peers: [OverlayPeer]) -> [OverlayPeerCandidate] {
        sorted(peers.map(OverlayPeerCandidate.init).filter { !$0.addresses.isEmpty })
    }

    /// Online (or unknown) before offline, then by name.
    static func sorted(_ candidates: [OverlayPeerCandidate]) -> [OverlayPeerCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.isOffline != rhs.isOffline { return !lhs.isOffline }
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// Peers grouped by the network they are on, in order of first
    /// appearance; one group with a nil network for a node that runs one.
    static func groupedByNetwork(_ peers: [OverlayPeer]) -> [(network: String?, peers: [OverlayPeer])] {
        var groups: [(network: String?, peers: [OverlayPeer])] = []
        for peer in peers {
            if let index = groups.firstIndex(where: { $0.network == peer.network }) {
                groups[index].peers.append(peer)
            } else {
                groups.append((peer.network, [peer]))
            }
        }
        return groups
    }

    /// A config server's peers by the network it assigned them on, in the
    /// server's order and with each network's state, then any peers on a
    /// network it did not list.
    static func assignedGroups(
        _ peers: [OverlayPeer], assigned: [OverlayAssignedNetwork]
    ) -> [OverlayAssignedPeerGroup] {
        var remaining = peers
        var groups = assigned.map { network in
            let onNetwork = remaining.filter { $0.network == network.name }
            remaining.removeAll { $0.network == network.name }
            return OverlayAssignedPeerGroup(
                id: network.id, name: OverlayStatusCopy.assignedNetworkName(network),
                subnet: network.error == nil ? network.address.flatMap(ipv4Subnet) : nil,
                error: network.error, isRunning: network.isRunning, peers: onNetwork)
        }
        for group in groupedByNetwork(remaining) {
            groups.append(
                OverlayAssignedPeerGroup(
                    id: "peers/" + (group.network ?? ""), name: group.network ?? "Peers",
                    subnet: nil, error: nil, isRunning: true, peers: group.peers))
        }
        return groups
    }

    /// `10.144.144.9/24` → `10.144.144.0/24`; nil for anything else.
    static func ipv4Subnet(_ cidr: String) -> String? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else {
            return nil
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false).compactMap {
            UInt32($0)
        }
        guard octets.count == 4, octets.allSatisfy({ $0 < 256 }) else { return nil }
        let address = octets.reduce(UInt32(0)) { $0 << 8 | $1 }
        let mask = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        let network = address & mask
        let dotted = [24, 16, 8, 0].map { String(network >> UInt32($0) & 255) }.joined(separator: ".")
        return "\(dotted)/\(prefix)"
    }

    /// The Host already reached at `candidate` over `networkID`: one whose
    /// first hop (its Jump Host when it has one) is one of the peer's
    /// addresses or its machine name, bare or as a MagicDNS name.
    static func host(
        for candidate: OverlayPeerCandidate, networkID: UUID, among hosts: [Host]
    ) -> Host? {
        hosts.first { host in
            host.overlayNetworkID == networkID
                && style(dialing: host.usesJumpHost ? host.jumpAddress : host.address, candidate) != nil
        }
    }

    /// The peer a Host form's first hop already dials, so "Choose from …"
    /// shows it as chosen: the first of `candidates` whose address or
    /// machine name `address` is.
    static func chosen(
        among candidates: [OverlayPeerCandidate], address: String
    ) -> OverlayPeerCandidate? {
        candidates.first { style(dialing: address, $0) != nil }
    }

    /// How `address` reaches `candidate`: one of its addresses, or its
    /// machine name, bare or as a MagicDNS name; nil when it is neither.
    static func style(
        dialing address: String, _ candidate: OverlayPeerCandidate
    ) -> OverlayPeerCandidate.AddressStyle? {
        let firstHop = normalizedAddress(address)
        guard !firstHop.isEmpty else { return nil }
        if candidate.addresses.map(normalizedAddress).contains(firstHop) { return .ipAddress }
        guard let name = candidate.name.map(normalizedAddress), !name.isEmpty else { return nil }
        return firstHop == name || firstHop.hasPrefix(name + ".") ? .machineName : nil
    }

    /// Lowercased, without brackets, a prefix length, or a trailing dot.
    private static func normalizedAddress(_ address: String) -> String {
        var trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        trimmed = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    /// Candidates whose name, network, or any address contains `query`,
    /// ignoring case and diacritics; all of them for a blank query.
    static func filter(_ candidates: [OverlayPeerCandidate], query: String) -> [OverlayPeerCandidate] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { candidate in
            ([candidate.displayName] + candidate.addresses + [candidate.network].compactMap { $0 }).contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}

extension HostDraft {
    /// Which address a peer chosen from the draft's Overlay Network fills:
    /// the network carries the first hop, which is the Jump Host when one
    /// is set (ADR 0021).
    var overlayPeerTarget: OverlayPeerTarget {
        usesJumpHost ? .jumpHost : .host
    }

    /// The address a peer chosen from the Overlay Network fills.
    var overlayPeerAddress: String {
        usesJumpHost ? jumpAddress : address
    }

    /// Fills the first hop's address from `candidate`, and a blank Host
    /// name with the peer's name when the peer is the Host itself.
    mutating func applyOverlayPeer(
        _ candidate: OverlayPeerCandidate, style: OverlayPeerCandidate.AddressStyle = .ipAddress
    ) {
        guard let address = candidate.address(style) else { return }
        switch overlayPeerTarget {
        case .host:
            self.address = address
            if name.trimmingCharacters(in: .whitespaces).isEmpty, let peerName = candidate.name {
                name = peerName
            }
        case .jumpHost:
            jumpAddress = address
        }
    }

    /// A new Host on `networkID` reaching `candidate`, as Settings' Add
    /// Host… on a peer prefills it.
    init(
        overlayPeer candidate: OverlayPeerCandidate, networkID: UUID,
        style: OverlayPeerCandidate.AddressStyle = .ipAddress
    ) {
        self.init()
        overlayNetworkID = networkID
        applyOverlayPeer(candidate, style: style)
    }
}

/// One network a config server assigned, with its peers, for the
/// network's screen.
struct OverlayAssignedPeerGroup: Identifiable, Equatable {
    let id: String
    let name: String
    /// The network's subnet from this device's address, while it runs.
    let subnet: String?
    /// Why the network does not run.
    let error: String?
    let isRunning: Bool
    let peers: [OverlayPeer]

    /// "home · 10.144.144.0/24".
    var header: String {
        subnet.map { "\(name) · \($0)" } ?? name
    }
}

enum OverlayPeerTarget: Equatable, Sendable {
    case host
    case jumpHost
}

/// Loads a network's peers for the "Choose from …" sheet, starting its node
/// when needed, and keeps the outcome for the view.
@MainActor
@Observable
final class OverlayPeerPickerModel {
    enum Phase: Equatable {
        case loading
        case loaded([OverlayPeerCandidate])
        case failed(TransportError)
        /// The user stopped waiting for the network to connect.
        case cancelled
    }

    typealias Loader = @MainActor (_ startIfNeeded: Bool) async throws -> [OverlayPeer]

    private(set) var phase = Phase.loading
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    /// Reads the peers, starting the node first if it is not online. A
    /// load still running is replaced; `cancel()` or cancelling the caller
    /// ends it at once.
    func load() async {
        loading?.cancel()
        if case .loaded = phase {} else { phase = .loading }
        let task = Task { await self.performLoad() }
        loading = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if loading == task { loading = nil }
    }

    /// Stops waiting for the network: the sheet is usable again at once and
    /// says Cancelled instead of an error. Peers already shown stay.
    func cancel() {
        guard let loading else { return }
        loading.cancel()
        self.loading = nil
        if case .loading = phase { phase = .cancelled }
    }

    private func performLoad() async {
        do {
            let peers = try await loader(true)
            guard !Task.isCancelled else { return }
            phase = .loaded(OverlayPeerList.candidates(from: peers))
        } catch let error as TransportError {
            guard !Task.isCancelled else { return }
            if error != .cancelled { phase = .failed(error) }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(.channelFailed(detail: String(describing: error)))
        }
    }

    /// The loaded candidates matching `query`; empty while not loaded.
    func candidates(matching query: String) -> [OverlayPeerCandidate] {
        guard case .loaded(let candidates) = phase else { return [] }
        return OverlayPeerList.filter(candidates, query: query)
    }
}

extension OverlayPeerPickerModel {
    /// The live loader: the store's runtime starts the node and reports its
    /// peers, then the store refreshes so Settings shows the same status.
    convenience init(store: OverlayNetworkStore, networkID: OverlayNetwork.ID) {
        self.init { [store] startIfNeeded in
            do {
                let peers = try await store.runtime.peers(
                    networkID: networkID, startIfNeeded: startIfNeeded)
                await store.refreshStatus(networkID)
                return peers
            } catch {
                await store.refreshStatus(networkID)
                throw error
            }
        }
    }
}

/// One Add Host… from a peer in Settings › Overlay Networks, identified per
/// request so adding the same peer again presents a fresh form.
struct OverlayPeerHostRequest: Identifiable {
    let id = UUID()
    let draft: HostDraft
}
