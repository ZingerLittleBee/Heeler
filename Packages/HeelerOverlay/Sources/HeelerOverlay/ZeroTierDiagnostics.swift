import CZeroTier
import Foundation

/// The most recent libzt node, network, and peer events, for diagnostics.
/// libzt delivers them on its own event thread through the handler
/// `ZeroTierRuntime.bootNode` installs.
final class ZeroTierEventLog: @unchecked Sendable {
    static let shared = ZeroTierEventLog()
    static let capacity = 50

    private let lock = NSLock()
    private var events: [OverlayDiagnostics.Event] = []

    var recent: [OverlayDiagnostics.Event] {
        lock.withLock { events }
    }

    /// Records one `zts_event_msg_t`. Returns promptly: it only formats the
    /// event and appends it.
    func record(_ message: UnsafeMutableRawPointer?) {
        guard let message = message?.assumingMemoryBound(to: zts_event_msg_t.self).pointee,
              let text = Self.describe(
                code: Int32(message.event_code),
                networkID: message.network?.pointee.net_id,
                // The line names the peer only; Diagnostics lists its
                // paths from `heeler_zt_peers` (see heeler_zerotier.h).
                peerID: message.peer?.pointee.peer_id)
        else { return }
        append(text)
    }

    func append(_ text: String, at date: Date = Date()) {
        lock.withLock {
            events.append(OverlayDiagnostics.Event(date: date, message: text))
            if events.count > Self.capacity {
                events.removeFirst(events.count - Self.capacity)
            }
        }
    }

    /// One line for an event worth keeping; nil for the rest (stack,
    /// interface, route, address, and storage events, and config updates,
    /// which are frequent and say nothing the status entries do not).
    static func describe(code: Int32, networkID: UInt64?, peerID: UInt64?) -> String? {
        let network = networkID.map { " " + ZeroTierNetworkID.format($0) } ?? ""
        let peer = peerID.flatMap(ZeroTierNodeID.format).map { " " + $0 } ?? ""
        switch code {
        case Int32(ZTS_EVENT_NODE_UP.rawValue): return "Node up"
        case Int32(ZTS_EVENT_NODE_ONLINE.rawValue): return "Node online"
        case Int32(ZTS_EVENT_NODE_OFFLINE.rawValue): return "Node offline (no recent root contact)"
        case Int32(ZTS_EVENT_NODE_DOWN.rawValue): return "Node down"
        case Int32(ZTS_EVENT_NODE_FATAL_ERROR.rawValue): return "Node fatal error"
        case Int32(ZTS_EVENT_NETWORK_NOT_FOUND.rawValue): return "Network\(network) not found"
        case Int32(ZTS_EVENT_NETWORK_CLIENT_TOO_OLD.rawValue): return "Network\(network) needs a newer client"
        case Int32(ZTS_EVENT_NETWORK_REQ_CONFIG.rawValue): return "Network\(network) requesting configuration"
        case Int32(ZTS_EVENT_NETWORK_OK.rawValue): return "Network\(network) OK"
        case Int32(ZTS_EVENT_NETWORK_ACCESS_DENIED.rawValue): return "Network\(network) access denied"
        case Int32(ZTS_EVENT_NETWORK_READY_IP4.rawValue): return "Network\(network) ready (IPv4)"
        case Int32(ZTS_EVENT_NETWORK_READY_IP6.rawValue): return "Network\(network) ready (IPv6)"
        case Int32(ZTS_EVENT_NETWORK_READY_IP4_IP6.rawValue): return "Network\(network) ready (IPv4 and IPv6)"
        case Int32(ZTS_EVENT_NETWORK_DOWN.rawValue): return "Network\(network) down"
        case Int32(ZTS_EVENT_PEER_DIRECT.rawValue): return "Peer\(peer) direct"
        case Int32(ZTS_EVENT_PEER_RELAY.rawValue): return "Peer\(peer) relayed"
        case Int32(ZTS_EVENT_PEER_UNREACHABLE.rawValue): return "Peer\(peer) unreachable"
        case Int32(ZTS_EVENT_PEER_PATH_DISCOVERED.rawValue): return "Peer\(peer) path discovered"
        case Int32(ZTS_EVENT_PEER_PATH_DEAD.rawValue): return "Peer\(peer) path dead"
        default: return nil
        }
    }
}

extension ZeroTierRuntime {
    /// One route of a joined network, as libzt's core query reports it.
    struct Route: Sendable, Equatable {
        /// The target network address; libzt's query leaves out the prefix
        /// length.
        var target: String
        /// The gateway, or nil for a route on the network itself.
        var via: String?
        var flags: UInt16
        var metric: UInt16
    }

    /// Raw state of the network for `diagnostics`; blocks briefly, so it
    /// runs on the control queue.
    struct NetworkDiagnostics: Sendable, Equatable {
        var status: Int32
        var transportReady: Bool
        var addresses: [String]
        var routes: [Route]
    }

    func diagnostics(joinedNetwork networkID: UInt64?, customRoots: Bool) async -> OverlayDiagnostics {
        var entries: [OverlayDiagnostics.Entry] = []
        guard isStarted else {
            entries.append(.init(label: "Node", value: "Not running"))
            return OverlayDiagnostics(entries: entries, events: ZeroTierEventLog.shared.recent)
        }
        let control = control
        let nodeID = await Self.call { zts_node_get_id() }
        entries.append(.init(label: "Node ID", value: ZeroTierNodeID.format(nodeID) ?? "Unknown"))
        let online = await Self.call { control.isOnline() }
        entries.append(.init(
            label: "Node online (libzt flag, unreliable)",
            value: (online ? "Yes" : "No") + (hasBeenOnline ? "; has been online" : "; never online yet")))
        entries.append(.init(
            label: "Planet",
            value: customRoots
                ? "ZeroTier default + this network's own (as a local moon)" : "ZeroTier default"))
        await retryRefusedLocalMoons()
        entries.append(contentsOf: localMoonEntries())

        if let networkID {
            let network = await Self.call { Self.networkDiagnostics(networkID) }
            entries.append(.init(label: "Network status", value: Self.statusName(network.status)))
            entries.append(.init(label: "Transport ready", value: network.transportReady ? "Yes" : "No"))
            entries.append(.init(
                label: "Assigned addresses",
                value: network.addresses.isEmpty ? "None" : network.addresses.joined(separator: ", ")))
            if network.routes.isEmpty {
                entries.append(.init(label: "Routes", value: "None"))
            }
            for (index, route) in network.routes.enumerated() {
                entries.append(.init(label: "Route \(index + 1)", value: Self.describe(route)))
            }
        }

        let peers = await Self.call { ZeroTierPeers.read() }
        for root in peers where root.role != ZeroTierPeers.leafRole {
            let id = ZeroTierNodeID.format(root.peerID) ?? String(root.peerID, radix: 16)
            entries.append(.init(
                label: "Root \(id) (\(ZeroTierPeers.roleName(root.role)))",
                value: Self.describePaths(root)))
        }
        for peer in peers where peer.role == ZeroTierPeers.leafRole {
            guard let id = ZeroTierNodeID.format(peer.peerID) else { continue }
            entries.append(.init(label: "Peer \(id)", value: Self.describePaths(peer)))
        }
        return OverlayDiagnostics(entries: entries, events: ZeroTierEventLog.shared.recent)
    }

    /// One entry per self-hosted planet the node carries (or is trying to)
    /// as a local moon, across all joined networks.
    func localMoonEntries() -> [OverlayDiagnostics.Entry] {
        let planets = localMoons.references.keys.sorted { lhs, rhs in
            lhs.worldID != rhs.worldID
                ? lhs.worldID < rhs.worldID : lhs.data.lexicographicallyPrecedes(rhs.data)
        }
        return planets.map { planet in
            let label = "Planet \(planet.worldID) as local moon"
            if let failure = localMoons.failures[planet] {
                return .init(
                    label: label,
                    value: "Not added: moon \(ZeroTierNetworkID.format(failure.moonID)) refused "
                        + "(\(failure.status)); retrying")
            }
            if let moonID = localMoons.added[planet] {
                return .init(label: label, value: "Moon \(ZeroTierNetworkID.format(moonID))")
            }
            return .init(label: label, value: "Pending")
        }
    }

    static func describePaths(_ peer: ZeroTierPeers.Raw) -> String {
        let latency = peer.latency >= 0 ? "\(peer.latency) ms" : "latency unknown"
        guard peer.pathCount > 0 else { return "Relayed, \(latency)" }
        return "Direct, \(latency), \(peer.pathCount) path(s): \(peer.paths)"
    }

    static func describe(_ route: Route) -> String {
        var text = route.target
        if let via = route.via {
            text += " via \(via) (through a gateway member)"
        } else {
            text += " (on the network)"
        }
        return text + ", flags \(route.flags), metric \(route.metric)"
    }

    static func statusName(_ status: Int32) -> String {
        let name: String
        switch status {
        case Int32(ZTS_NETWORK_STATUS_REQUESTING_CONFIGURATION.rawValue): name = "Requesting configuration"
        case Int32(ZTS_NETWORK_STATUS_OK.rawValue): name = "OK"
        case Int32(ZTS_NETWORK_STATUS_ACCESS_DENIED.rawValue): name = "Access denied"
        case Int32(ZTS_NETWORK_STATUS_NOT_FOUND.rawValue): name = "Not found"
        case Int32(ZTS_NETWORK_STATUS_PORT_ERROR.rawValue): name = "Port error"
        case Int32(ZTS_NETWORK_STATUS_CLIENT_TOO_OLD.rawValue): name = "Client too old"
        case Int32(ZTS_ERR_NO_RESULT.rawValue): name = "Not joined"
        default: name = "Unknown"
        }
        return "\(name) (\(status))"
    }

    /// The live network state. The address and route queries read libzt's
    /// network table, so they run under its core lock.
    static func networkDiagnostics(_ networkID: UInt64) -> NetworkDiagnostics {
        let status = zts_net_get_status(networkID)
        let ready = zts_net_transport_is_ready(networkID) == 1
        var addresses: [String] = []
        var routes: [Route] = []
        guard zts_core_lock_obtain() == ZTS_ERR_OK.rawValue else {
            return NetworkDiagnostics(status: status, transportReady: ready, addresses: [], routes: [])
        }
        let length = Int(ZTS_IP_MAX_STR_LEN)
        let addressCount = zts_core_query_addr_count(networkID)
        for index in 0..<max(0, addressCount) {
            var buffer = [CChar](repeating: 0, count: length)
            if zts_core_query_addr(networkID, UInt32(index), &buffer, UInt32(length)) == ZTS_ERR_OK.rawValue {
                addresses.append(Self.string(buffer))
            }
        }
        let routeCount = zts_core_query_route_count(networkID)
        for index in 0..<max(0, routeCount) {
            var target = [CChar](repeating: 0, count: length)
            var via = [CChar](repeating: 0, count: length)
            var flags: UInt16 = 0
            var metric: UInt16 = 0
            let result = zts_core_query_route(
                networkID, UInt32(index), &target, &via, UInt32(length), &flags, &metric)
            guard result == ZTS_ERR_OK.rawValue else { continue }
            let gateway = Self.string(via)
            // libzt reports a route without a gateway as via 0.0.0.0.
            routes.append(Route(
                target: Self.string(target),
                via: gateway.isEmpty || gateway == "0.0.0.0" || gateway == "::" ? nil : gateway,
                flags: flags, metric: metric))
        }
        _ = zts_core_lock_release()
        return NetworkDiagnostics(status: status, transportReady: ready, addresses: addresses, routes: routes)
    }

    private static func string(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? ""
        }
    }
}
