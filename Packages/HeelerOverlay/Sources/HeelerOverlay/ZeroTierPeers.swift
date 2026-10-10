import CZeroTier
import Foundation

/// ZeroTier node IDs: 40-bit addresses shown as 10 lowercase hex digits.
enum ZeroTierNodeID {
    /// nil for 0 and for anything wider than 40 bits (libzt returns an
    /// error code cast to `UInt64` when the node is not running).
    static func format(_ nodeID: UInt64) -> String? {
        guard nodeID != 0, nodeID <= 0xff_ffff_ffff else { return nil }
        let digits = String(nodeID, radix: 16)
        return String(repeating: "0", count: 10 - digits.count) + digits
    }
}

/// A moon's seed is a node ID: 40 bits, 10 hex digits. libzt does not check.
extension ZeroTierMoon {
    var isValid: Bool {
        worldID != 0 && seed != 0 && seed <= 0xff_ffff_ffff
    }
}

/// Which moons the process node should orbit: reference counts across the
/// joined networks that declare them, and what has actually been orbited.
/// `ZeroTierRuntime` applies the changes `reconcile` returns.
struct ZeroTierMoonOrbits: Sendable, Equatable {
    enum Change: Sendable, Equatable {
        case orbit(ZeroTierMoon)
        case deorbit(worldID: UInt64)
    }

    private(set) var references: [ZeroTierMoon: Int] = [:]
    /// World ID to the seed it was orbited through.
    private(set) var orbited: [UInt64: UInt64] = [:]

    /// One network's moons; duplicates within one network count once.
    mutating func retain(_ moons: [ZeroTierMoon]) {
        for moon in Set(moons) {
            references[moon, default: 0] += 1
        }
    }

    /// Gives back what one `retain` with the same moons took.
    mutating func release(_ moons: [ZeroTierMoon]) {
        for moon in Set(moons) {
            guard let count = references[moon] else { continue }
            references[moon] = count > 1 ? count - 1 : nil
        }
    }

    /// The orbits and deorbits that bring `orbited` in line with
    /// `references`, recorded as done. A world declared with several seeds is
    /// orbited once, through the seed it already uses or else the lowest.
    mutating func reconcile() -> [Change] {
        var wanted: [UInt64: UInt64] = [:]
        for moon in references.keys {
            if let seed = wanted[moon.worldID] {
                wanted[moon.worldID] = min(seed, moon.seed)
            } else {
                wanted[moon.worldID] = moon.seed
            }
        }
        var changes: [Change] = []
        for worldID in orbited.keys.sorted() where wanted[worldID] == nil {
            orbited[worldID] = nil
            changes.append(.deorbit(worldID: worldID))
        }
        for (worldID, seed) in wanted.sorted(by: { $0.key < $1.key }) where orbited[worldID] == nil {
            orbited[worldID] = seed
            changes.append(.orbit(ZeroTierMoon(worldID: worldID, seed: seed)))
        }
        return changes
    }
}

/// The node's peer list through `heeler_zt_peers` (Heeler's libzt addition;
/// libzt itself cannot enumerate peers).
enum ZeroTierPeers {
    /// One entry of `heeler_zt_peers`, copied out of the C struct.
    struct Raw: Sendable, Equatable {
        var peerID: UInt64
        /// Milliseconds, or -1 when unknown.
        var latency: Int32
        /// `zts_peer_role_t`: 0 leaf, 1 moon, 2 planet.
        var role: Int32
        var pathCount: UInt32
        /// "ip/port" entries, comma-separated, the preferred path first.
        var paths: String
    }

    static let leafRole = Int32(ZTS_PEER_ROLE_LEAF.rawValue)

    /// `OverlayPeer.role` for a `zts_peer_role_t`.
    static func roleName(_ role: Int32) -> String {
        switch role {
        case Int32(ZTS_PEER_ROLE_LEAF.rawValue): "leaf"
        case Int32(ZTS_PEER_ROLE_MOON.rawValue): "moon"
        case Int32(ZTS_PEER_ROLE_PLANET.rawValue): "planet"
        default: "unknown"
        }
    }

    /// Every peer in `raw`, for display, with its role: the planet and moon
    /// roots every node talks to as well as ordinary nodes. On a self-hosted
    /// planet the root is often the network's controller too. The list is
    /// node-wide; libzt does not say which joined network a peer belongs to,
    /// and an ordinary node appears only once traffic has gone its way.
    static func overlayPeers(_ raw: [Raw]) -> [OverlayPeer] {
        raw.compactMap { peer in
            guard let id = ZeroTierNodeID.format(peer.peerID) else { return nil }
            let addresses = peer.paths.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            return OverlayPeer(
                id: id,
                addresses: addresses,
                isDirect: peer.pathCount > 0,
                latency: peer.latency >= 0 ? .milliseconds(Int(peer.latency)) : nil,
                role: roleName(peer.role))
        }
    }

    /// Reads every peer of the running node; empty when it is not running.
    /// Blocks briefly on libzt's service lock, so it runs on the control queue.
    static func read() -> [Raw] {
        var capacity = max(16, Int(heeler_zt_peers(nil, 0)) + 8)
        for _ in 0..<4 {
            var buffer = [heeler_zt_peer](repeating: heeler_zt_peer(), count: capacity)
            let total = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                heeler_zt_peers(pointer.baseAddress, UInt32(pointer.count))
            }
            guard total >= 0 else { return [] }
            if Int(total) <= capacity {
                return buffer.prefix(Int(total)).map(raw)
            }
            capacity = Int(total) + 8
        }
        return []
    }

    private static func raw(_ peer: heeler_zt_peer) -> Raw {
        let paths = withUnsafeBytes(of: peer.paths) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Raw(
            peerID: peer.peer_id, latency: peer.latency_ms, role: peer.role,
            pathCount: peer.path_count, paths: paths)
    }
}
