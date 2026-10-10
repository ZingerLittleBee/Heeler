import Foundation

/// The part of tsnet's `ipnstate.Status` JSON (`tailscale_status_json`) the
/// node acts on. Unknown fields are ignored.
struct TailscaleStatus: Equatable, Sendable {
    enum BackendState: Equatable, Sendable {
        case noState
        case starting
        case needsLogin
        case needsMachineAuth
        case stopped
        case running
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "NoState": self = .noState
            case "Starting": self = .starting
            case "NeedsLogin": self = .needsLogin
            case "NeedsMachineAuth": self = .needsMachineAuth
            case "Stopped": self = .stopped
            case "Running": self = .running
            default: self = .other(raw)
            }
        }
    }

    var backendState: BackendState
    var authURL: URL?
    var addresses: [String]
    var health: [String]
    /// This node and its peers, for the detail screen.
    var details = OverlayNodeDetails()
    /// The addresses this node's network map routes into the tailnet.
    var routes = TailnetRoutes()

    /// Whether a dial to the IP literal `ip` can reach anything on this
    /// tailnet, or nil when the status cannot tell: only a running node has
    /// the network map to judge by. tsnet does not refuse an address no peer
    /// owns; such a dial hangs until its caller gives up.
    func canRoute(to ip: String) -> Bool? {
        guard backendState == .running, routes.hasNetworkMap else { return nil }
        return routes.contains(ip)
    }

    /// What `start` should do next with this status.
    enum Progress: Equatable, Sendable {
        case online(addresses: [String])
        case needsLogin(URL)
        case failed(String)
        case waiting
    }

    var progress: Progress {
        switch backendState {
        case .running:
            // Running without an address is transient right after login.
            return addresses.isEmpty ? .waiting : .online(addresses: addresses)
        case .needsLogin:
            if let authURL { return .needsLogin(authURL) }
            return .waiting
        case .needsMachineAuth:
            return .failed("This device is waiting for approval by a tailnet admin.")
        case .noState, .starting, .stopped, .other:
            return .waiting
        }
    }

    /// A device awaiting an admin's approval is up and keeps asking, so it
    /// reports `.waiting` (approval can still arrive) even though `start`
    /// stops waiting for it at once.
    var nodeStatus: OverlayNodeStatus {
        switch progress {
        case .online(let addresses): .online(addresses: addresses)
        case .needsLogin(let url): .needsLogin(url)
        case .failed(let message) where backendState == .needsMachineAuth: .waiting(message)
        case .failed(let message): .failed(message)
        case .waiting: .starting
        }
    }

    private struct Wire: Decodable {
        let BackendState: String?
        let AuthURL: String?
        let TailscaleIPs: [String]?
        let Health: [String]?
        let SelfNode: PeerWire?
        let Peer: [String: PeerWire]?
        /// Present while an exit node is selected.
        let ExitNodeStatus: PresenceWire?
        /// Present once the node has a network map.
        let CurrentTailnet: PresenceWire?

        enum CodingKeys: String, CodingKey {
            case BackendState, AuthURL, TailscaleIPs, Health, Peer, ExitNodeStatus, CurrentTailnet
            case SelfNode = "Self"
        }
    }

    /// An object whose fields do not matter, only whether it is there.
    private struct PresenceWire: Decodable {}

    /// `ipnstate.PeerStatus`, as far as the detail screen uses it.
    private struct PeerWire: Decodable {
        let ID: String?
        let HostName: String?
        let DNSName: String?
        let TailscaleIPs: [String]?
        let Online: Bool?
        let Active: Bool?
        let CurAddr: String?
        let Relay: String?
        let PeerRelay: String?
        /// Prefixes routed to this peer: its own addresses, approved subnet
        /// routes (4via6 included), and an offered exit node's default routes.
        let AllowedIPs: [String]?
        /// Subnet routes this peer is the primary router for.
        let PrimaryRoutes: [String]?
        /// Whether this peer is the selected exit node.
        let ExitNode: Bool?
    }

    static func decode(_ data: Data) throws -> TailscaleStatus {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let authURL = wire.AuthURL
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
            .flatMap { url in
                // Only ever surface a web URL as something to open.
                ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? url : nil
            }
        let addresses = orderedAddresses(wire.TailscaleIPs ?? [])
        return TailscaleStatus(
            backendState: BackendState(wire.BackendState ?? "NoState"),
            authURL: authURL,
            addresses: addresses,
            health: wire.Health ?? [],
            details: details(node: wire.SelfNode, peers: wire.Peer, addresses: addresses),
            routes: tailnetRoutes(wire: wire))
    }

    private static func tailnetRoutes(wire: Wire) -> TailnetRoutes {
        let peers = Array((wire.Peer ?? [:]).values)
        let addresses = (wire.TailscaleIPs ?? []) + (wire.SelfNode?.TailscaleIPs ?? [])
            + peers.flatMap { $0.TailscaleIPs ?? [] }
        let prefixes = peers.flatMap { ($0.AllowedIPs ?? []) + ($0.PrimaryRoutes ?? []) }
        return TailnetRoutes(
            hasNetworkMap: wire.CurrentTailnet != nil,
            addresses: addresses.compactMap(IPAddressBytes.init),
            // A default route only means "everything" through the selected
            // exit node, which `usesExitNode` covers; an exit node that is
            // merely offered lists 0.0.0.0/0 and ::/0 as well.
            prefixes: prefixes.compactMap(IPPrefix.init).filter { $0.length > 0 },
            usesExitNode: wire.ExitNodeStatus != nil || peers.contains { $0.ExitNode == true })
    }

    /// The node's stable ID and MagicDNS name (nil until the network map
    /// arrives), and one `OverlayPeer` per
    /// peer, sorted by name. A peer is direct when tsnet has a direct UDP
    /// address for it (`CurAddr`) and relayed (DERP or a peer relay) when it
    /// is active without one; an idle peer has no path to judge, so
    /// `isDirect` is nil, as `tailscale status` shows "idle". tsnet's status
    /// carries no latency.
    private static func details(
        node: PeerWire?, peers: [String: PeerWire]?, addresses: [String]
    ) -> OverlayNodeDetails {
        let peers = (peers ?? [:]).sorted { $0.key < $1.key }.map { key, peer in
            OverlayPeer(
                id: nonEmpty(peer.ID) ?? key,
                name: firstLabel(peer.DNSName) ?? nonEmpty(peer.HostName),
                addresses: orderedAddresses(peer.TailscaleIPs ?? []),
                isOnline: peer.Online,
                isDirect: isDirect(peer),
                latency: nil)
        }
        return OverlayNodeDetails(
            nodeID: nonEmpty(node?.ID),
            // Only the network map names this device. Before one arrives,
            // tsnet reports the OS host name as `HostName`, which is not the
            // name the tailnet will know it by.
            hostname: dnsName(node?.DNSName),
            addresses: addresses,
            peers: peers.sorted { ($0.name ?? $0.id).lowercased() < ($1.name ?? $1.id).lowercased() })
    }

    private static func isDirect(_ peer: PeerWire) -> Bool? {
        if nonEmpty(peer.CurAddr) != nil { return true }
        guard peer.Active == true else { return nil }
        return nonEmpty(peer.Relay) != nil || nonEmpty(peer.PeerRelay) != nil ? false : nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A MagicDNS name without its trailing dot.
    private static func dnsName(_ value: String?) -> String? {
        guard let name = nonEmpty(value) else { return nil }
        return nonEmpty(name.hasSuffix(".") ? String(name.dropLast()) : name)
    }

    /// The machine name: a MagicDNS name's first label.
    private static func firstLabel(_ value: String?) -> String? {
        nonEmpty(dnsName(value)?.split(separator: ".", omittingEmptySubsequences: true).first.map(String.init))
    }

    /// IPv4 first, then IPv6, keeping upstream order within each family.
    static func orderedAddresses(_ addresses: [String]) -> [String] {
        let trimmed = addresses
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return trimmed.filter { !$0.contains(":") } + trimmed.filter { $0.contains(":") }
    }
}

/// What a Tailscale node's network map routes into the tailnet: its own and
/// its peers' addresses, peers' subnet routes, and whether an exit node takes
/// everything else.
struct TailnetRoutes: Equatable, Sendable {
    /// Whether tsnet has a network map; without one nothing can be judged.
    var hasNetworkMap = false
    var addresses: [IPAddressBytes] = []
    var prefixes: [IPPrefix] = []
    var usesExitNode = false

    func contains(_ ip: String) -> Bool {
        if usesExitNode { return true }
        guard let address = IPAddressBytes(ip) else { return false }
        return addresses.contains(address) || prefixes.contains { $0.contains(address) }
    }
}

/// An IPv4 (4 bytes) or IPv6 (16 bytes) address; IPv4-mapped IPv6 is IPv4.
struct IPAddressBytes: Equatable, Sendable {
    let bytes: [UInt8]

    init?(_ text: String) {
        let bare = OverlayAddress.unbracketed(text)
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_pton(AF_INET, bare, &ipv4) == 1 {
            bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
        } else if inet_pton(AF_INET6, bare, &ipv6) == 1 {
            let raw = withUnsafeBytes(of: &ipv6) { Array($0) }
            let mapped = raw[0..<10].allSatisfy { $0 == 0 } && raw[10] == 0xff && raw[11] == 0xff
            bytes = mapped ? Array(raw[12...]) : raw
        } else {
            return nil
        }
    }
}

/// A CIDR prefix such as `10.0.0.0/24` or `fd7a:115c:a1e0:b1a::/64`.
struct IPPrefix: Equatable, Sendable {
    let address: IPAddressBytes
    let length: Int

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let address = IPAddressBytes(String(parts[0])),
              let length = Int(parts[1]), length >= 0, length <= address.bytes.count * 8
        else { return nil }
        self.address = address
        self.length = length
    }

    func contains(_ candidate: IPAddressBytes) -> Bool {
        guard candidate.bytes.count == address.bytes.count else { return false }
        var remaining = length
        for (a, b) in zip(address.bytes, candidate.bytes) where remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xff << (8 - bits))
            guard a & mask == b & mask else { return false }
            remaining -= bits
        }
        return true
    }
}

enum OverlayAddress {
    /// `host:port` for Go's `net.Dial`; IPv6 literals are bracketed.
    static func hostPort(host: String, port: UInt16) -> String {
        let bare = unbracketed(host)
        return bare.contains(":") ? "[\(bare)]:\(port)" : "\(bare):\(port)"
    }

    static func unbracketed(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// The literal IP address in `host`, or nil when `host` is a name.
    static func ipLiteral(_ host: String) -> String? {
        let bare = unbracketed(host)
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_pton(AF_INET, bare, &ipv4) == 1 || inet_pton(AF_INET6, bare, &ipv6) == 1 {
            return bare
        }
        return nil
    }
}
