import Foundation

/// The overlay networks Heeler can join in-process. Each runs a userspace
/// network stack inside the app — no NetworkExtension, no system VPN — and
/// exists only to dial SSH to a peer on that network.
public enum OverlayKind: String, Codable, Sendable, CaseIterable {
    case tailscale
    case zerotier
    case easytier
}

/// A TCP stream to an overlay peer, surfaced as one connected OS descriptor
/// (a socketpair end, or the provider's own socketpair). The receiver takes
/// ownership of `descriptor` and must call `release` exactly once after the
/// descriptor is closed, so the node can stop pumping the other end.
public struct OverlayDialedStream: Sendable {
    public let descriptor: Int32
    public let release: @Sendable () -> Void

    public init(descriptor: Int32, release: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor
        self.release = release
    }
}

public enum OverlayNodeStatus: Sendable, Equatable {
    case stopped
    case starting
    /// Tailscale interactive login: the user must open this URL.
    case needsLogin(URL)
    /// Running but not yet usable for a reason the user can act on outside
    /// the app — e.g. an EasyTier config server has not assigned a network.
    case waiting(String)
    /// Joined, with this node's own overlay addresses.
    case online(addresses: [String])
    case failed(String)
}

public enum OverlayError: Error, Sendable, Equatable {
    /// The node could not start or join (bad key, unreachable controller…).
    case startFailed(String)
    /// The node needs an interactive login before it can come online.
    case loginRequired(URL)
    /// The node is up, but the peer did not accept the connection.
    case dialFailed(String)
    case timedOut
    case cancelled
    /// The configuration is incomplete or malformed.
    case invalidConfiguration(String)
}

/// One running overlay node. Implementations are safe to call from any task;
/// `start` is idempotent and every `dial` brings the node up first.
public protocol OverlayNode: AnyObject, Sendable {
    var kind: OverlayKind { get }
    func start(timeout: Duration) async throws
    func dial(host: String, port: UInt16, timeout: Duration) async throws -> OverlayDialedStream
    func status() async -> OverlayNodeStatus
    /// Stops the node. Streams already dialled may fail afterwards.
    func stop() async
    /// What the node knows about itself and its peers right now, for the
    /// network's detail screen. Never starts the node.
    func details() async -> OverlayNodeDetails
    /// Signs this device out of the network where the overlay has a notion of
    /// it (Tailscale: logs out at the coordination server and forgets the
    /// node key), then stops. The next start registers afresh.
    func logout(timeout: Duration) async throws
    /// Raw state for troubleshooting, shown read-only and copied as text.
    /// Never starts the node; empty where an overlay offers none (the
    /// default, see `OverlayDiagnostics`).
    func diagnostics() async -> OverlayDiagnostics
}

/// A point-in-time view of a node for display. Every field is optional
/// because each overlay only knows some of them, and a stopped node none.
public struct OverlayNodeDetails: Sendable, Equatable {
    /// ZeroTier node ID (10 hex digits), Tailscale stable node ID, or the
    /// machine ID (a lowercase UUID) an EasyTier config server lists this
    /// device under.
    public var nodeID: String?
    /// This device's name on the network.
    public var hostname: String?
    /// This device's overlay addresses.
    public var addresses: [String]
    /// nil when the overlay does not report peers.
    public var peers: [OverlayPeer]?
    /// The joined network's name where the overlay has one the user does not
    /// type themselves: an EasyTier network (the manual one, or the running
    /// ones a config server assigned, comma-separated). nil for other overlays.
    public var networkName: String?
    /// The networks an EasyTier config server assigned this device, running
    /// or refused, in instance-ID order. Empty for every other node.
    public var assignedNetworks: [OverlayAssignedNetwork]

    public init(
        nodeID: String? = nil,
        hostname: String? = nil,
        addresses: [String] = [],
        peers: [OverlayPeer]? = nil,
        networkName: String? = nil,
        assignedNetworks: [OverlayAssignedNetwork] = []
    ) {
        self.nodeID = nodeID
        self.hostname = hostname
        self.addresses = addresses
        self.peers = peers
        self.networkName = networkName
        self.assignedNetworks = assignedNetworks
    }
}

/// One network an EasyTier config server assigned this device. Each runs as
/// an EasyTier instance of its own; the node's dials pick one per
/// destination (see `EasyTierNode.dial`).
public struct OverlayAssignedNetwork: Sendable, Equatable, Identifiable {
    /// The instance ID the server gave the network.
    public var id: String
    /// The EasyTier network name; empty when the server sent none.
    public var name: String
    public var isRunning: Bool
    /// This device's virtual address with its prefix length
    /// (`10.144.144.9/24`), once it has one.
    public var address: String?
    public var peerCount: Int
    /// Why the network does not run: the device refused it, or EasyTier
    /// reported an error.
    public var error: String?

    public init(
        id: String, name: String, isRunning: Bool, address: String? = nil, peerCount: Int = 0,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
        self.address = address
        self.peerCount = peerCount
        self.error = error
    }
}

public struct OverlayPeer: Sendable, Equatable, Identifiable {
    /// Stable within one snapshot: a node ID, or the address when none.
    public var id: String
    public var name: String?
    public var addresses: [String]
    public var isOnline: Bool?
    /// Whether traffic reaches this peer directly rather than via a relay.
    public var isDirect: Bool?
    public var latency: Duration?
    /// The peer's part in the overlay where it has one: ZeroTier reports
    /// `"leaf"` for an ordinary node and `"moon"` or `"planet"` for a root.
    /// nil for overlays without roles.
    public var role: String?
    /// The network the peer is on, for a node that runs several: the
    /// EasyTier network name of a config server's assignment. nil otherwise.
    public var network: String?

    public init(
        id: String,
        name: String? = nil,
        addresses: [String] = [],
        isOnline: Bool? = nil,
        isDirect: Bool? = nil,
        latency: Duration? = nil,
        role: String? = nil,
        network: String? = nil
    ) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.isOnline = isOnline
        self.isDirect = isDirect
        self.latency = latency
        self.role = role
        self.network = network
    }
}

public struct TailscaleConfiguration: Sendable, Equatable {
    /// Private, persistent per-network directory for tsnet state.
    public var stateDirectory: URL
    /// This device's machine name on the tailnet.
    public var hostname: String
    /// Optional auth key; without one the node reports `.needsLogin`.
    public var authKey: String?
    /// Custom coordination server (Headscale); nil uses Tailscale's.
    public var controlURL: URL?

    public init(stateDirectory: URL, hostname: String, authKey: String?, controlURL: URL?) {
        self.stateDirectory = stateDirectory
        self.hostname = hostname
        self.authKey = authKey
        self.controlURL = controlURL
    }
}

public struct ZeroTierConfiguration: Sendable, Equatable {
    /// 16 hex digits.
    public var networkID: UInt64
    /// The node identity (`identity.secret` contents) the app keeps in the
    /// Keychain; nil generates one, reported through `identityGenerated`.
    public var identity: Data?
    /// This network's self-hosted planet file (from ZeroTier's `mkworld`),
    /// or nil for a network on ZeroTier's own roots. The process node always
    /// keeps ZeroTier's planet; while this network is joined the planet's
    /// roots are added beside it as a local moon, so networks on different
    /// roots run side by side and a change needs no relaunch.
    public var roots: Data?
    /// Moons this network's node orbits in addition to the planet.
    public var moons: [ZeroTierMoon]

    public init(networkID: UInt64, identity: Data?, roots: Data? = nil, moons: [ZeroTierMoon] = []) {
        self.networkID = networkID
        self.identity = identity
        self.roots = roots
        self.moons = moons
    }
}

/// A moon to orbit: its world ID and the node ID of one of its roots (the
/// seed), as in `zerotier-cli orbit <worldID> <seed>`.
public struct ZeroTierMoon: Sendable, Equatable, Hashable, Codable {
    public var worldID: UInt64
    public var seed: UInt64

    public init(worldID: UInt64, seed: UInt64) {
        self.worldID = worldID
        self.seed = seed
    }
}

/// Identity helpers that need no running node.
public enum ZeroTierIdentity {
    /// Mints a new `identity.secret` without starting a node, so the device's
    /// node ID can be shown (and authorized) before it first joins.
    /// Blocks while libzt derives the key (deliberately expensive, up to a
    /// second); call it off the main actor.
    public static func generate() throws -> Data {
        try ZeroTierRuntime.generateIdentity()
    }

    /// The 10-hex-digit node ID an identity's address field carries, or nil
    /// when `identity` is not a ZeroTier identity string.
    public static func nodeID(of identity: Data) -> String? {
        guard
            let text = String(data: identity, encoding: .utf8),
            let field = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first,
            field.count == 10,
            field.allSatisfy(\.isHexDigit)
        else { return nil }
        return field.lowercased()
    }
}

public struct EasyTierConfiguration: Sendable, Equatable {
    /// Where the network definition comes from.
    public enum Source: Sendable, Equatable {
        /// The app holds the whole definition.
        case manual(networkName: String, networkSecret: String, peers: [String], ipv4: String?)
        /// An EasyTier config server (`easytier-core --config-server`) pushes
        /// the network; the app only identifies the device to it.
        case configServer(EasyTierConfigServer)
    }

    public var source: Source
    /// This device's name on the network; a config server's own hostname,
    /// when it sends one, wins.
    public var hostname: String
    /// The in-process EasyTier instance that runs this configuration. Every
    /// key runs its own network (or config-server session) beside the
    /// others; a different configuration under the same key replaces it.
    /// The app uses the Overlay Network's UUID.
    public var instanceKey: String

    public init(source: Source, hostname: String, instanceKey: String) {
        self.source = source
        self.hostname = hostname
        self.instanceKey = instanceKey
    }

    /// A manual network. `ipv4` is a fixed virtual address in CIDR form
    /// (`10.144.144.7/24`); nil asks the network's DHCP for one.
    public init(
        networkName: String,
        networkSecret: String,
        peers: [String],
        hostname: String,
        ipv4: String? = nil,
        instanceKey: String
    ) {
        self.init(
            source: .manual(networkName: networkName, networkSecret: networkSecret, peers: peers, ipv4: ipv4),
            hostname: hostname, instanceKey: instanceKey)
    }
}

public struct EasyTierConfigServer: Sendable, Equatable {
    /// `udp|tcp|ws|wss://host[:port]/…/<token>`; see `normalizedURL(_:)`.
    public var url: String
    /// The stable identity the server lists this device under. The app keeps
    /// it; iOS has no machine-id file for EasyTier to fall back to.
    public var machineID: UUID
    /// Whether the session must run over EasyTier's encrypted web tunnel
    /// (Noise NN, which encrypts but does not authenticate the server).
    /// true: a server that does not offer it, or a path that strips the
    /// offer, is never used; the node keeps waiting for the server. false:
    /// the session upgrades when the server offers it and otherwise runs in
    /// clear text, where the token and the network configuration the server
    /// sends (secrets included) can be read and changed on the path. ws://
    /// sends the token in clear text either way.
    public var requireEncryption: Bool

    public init(url: String, machineID: UUID, requireEncryption: Bool = true) {
        self.url = url
        self.machineID = machineID
        self.requireEncryption = requireEncryption
    }

    /// The official server's address for a bare user name, as EasyTier's own
    /// GUI expands it (`udp://config-server.easytier.cn:22020/<name>`), or a
    /// `udp`/`tcp` URL with a host, port and token or a `ws`/`wss` URL with a
    /// host and token (the token is the last path segment; ws/wss keep their
    /// path), with the scheme and host lowercased. nil for anything else.
    /// wss:// servers must present a certificate the system trusts.
    public static func normalizedURL(_ text: String) -> String? {
        EasyTierConfigServerURL.normalize(text)
    }
}

/// Builds the concrete nodes. The app keeps at most one node per configured
/// overlay network and reuses it across Hosts and reconnects.
public enum OverlayNodes {
    public static func tailscale(_ configuration: TailscaleConfiguration) -> any OverlayNode {
        TailscaleNode(configuration: configuration)
    }

    /// libzt runs one node per process: every ZeroTier network shares it and
    /// differs only in the network it joins. `identityGenerated` fires once if
    /// the node had to mint an identity, so the caller can persist it.
    public static func zerotier(
        _ configuration: ZeroTierConfiguration,
        identityGenerated: @escaping @Sendable (Data) -> Void
    ) -> any OverlayNode {
        ZeroTierNetworkNode(configuration: configuration, identityGenerated: identityGenerated)
    }

    /// Each configuration's `instanceKey` is an EasyTier instance of its
    /// own: networks under different keys run side by side.
    public static func easytier(_ configuration: EasyTierConfiguration) -> any OverlayNode {
        EasyTierNode(configuration: configuration)
    }
}
