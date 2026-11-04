import Foundation
import Synchronization

#if canImport(CEasyTier)
import CEasyTier
#endif

/// One EasyTier network joined in-process through `CEasyTier`: no TUN, no
/// NetworkExtension; TCP streams run over EasyTier's userspace stack.
///
/// The network is either described in full by the configuration (a manual
/// network, rendered to TOML) or pushed by an EasyTier config server the node
/// connects to as a device (`EasyTierConfigServer`), which may assign several
/// networks. The native library runs any number of networks side by side,
/// one per `EasyTierConfiguration.instanceKey`: nodes under different keys
/// never affect each other. Nodes with the same key and configuration share
/// that key's network; starting one with a different configuration replaces
/// it, and the replaced node reports `.stopped` until it is started again.
final class EasyTierNode: OverlayNode, Sendable {
    let kind = OverlayKind.easytier
    private let configuration: EasyTierConfiguration
    private let runtime: EasyTierRuntime

    init(configuration: EasyTierConfiguration, runtime: EasyTierRuntime = .shared) {
        self.configuration = configuration
        self.runtime = runtime
    }

    /// Waits until the network is online. A config server that has not
    /// assigned a usable network yet keeps the node `.waiting`; when the
    /// timeout passes in that state, the wait reason is the error.
    func start(timeout: Duration) async throws {
        let deadline = OverlayDeadline(after: timeout)
        let key = try EasyTierRuntime.Key(configuration)
        try await runtime.start(key, timeout: deadline.remaining)
        while true {
            guard !Task.isCancelled else { throw OverlayError.cancelled }
            let status = await runtime.status(key)
            switch status {
            case .online:
                return
            case .failed(let message):
                throw OverlayError.startFailed(message)
            case .stopped:
                throw OverlayError.startFailed("EasyTier stopped before it joined the network")
            case .starting, .needsLogin, .waiting:
                do {
                    try await deadline.pause(EasyTierRuntime.pollInterval)
                } catch OverlayError.timedOut {
                    if case .waiting(let reason) = status { throw OverlayError.startFailed(reason) }
                    throw OverlayError.timedOut
                }
            }
        }
    }

    /// Dials through this node's own network. A config-server node with
    /// several networks dials through the one the destination fits: the
    /// network with a peer at exactly that address, else the one whose
    /// subnet holds it, or the one with a peer of that name; several fits
    /// fail rather than guess (the native library decides, see
    /// `heeler_et_tcp_connect_fd`).
    func dial(host: String, port: UInt16, timeout: Duration) async throws -> OverlayDialedStream {
        let deadline = OverlayDeadline(after: timeout)
        try await start(timeout: timeout)
        guard !deadline.hasPassed else { throw OverlayError.timedOut }
        let key = try EasyTierRuntime.Key(configuration)
        let descriptor = try await runtime.dial(
            key: key, network: nil, host: host, port: port, timeout: deadline.remaining)
        guard !Task.isCancelled else {
            close(descriptor)
            throw OverlayError.cancelled
        }
        // Closing the descriptor ends the native pump; nothing else to release.
        return OverlayDialedStream(descriptor: descriptor, release: {})
    }

    func status() async -> OverlayNodeStatus {
        do {
            return await runtime.status(try EasyTierRuntime.Key(configuration))
        } catch {
            return .failed(EasyTierTOML.message(for: error))
        }
    }

    func stop() async {
        guard let key = try? EasyTierRuntime.Key(configuration) else { return }
        await runtime.stop(key)
    }

    /// This device's hostname and virtual addresses, the network's name, and
    /// its peers (see `EasyTierStatus.overlayPeers`) while this configuration
    /// owns its key. A config-server node also reports its machine ID as
    /// `nodeID`, the identity the server's console lists the device under,
    /// whenever its session runs, and every network the server assigned in
    /// `assignedNetworks`; its peers carry their network's name. EasyTier's
    /// peer IDs are minted per start, so a manual node reports no node ID.
    func details() async -> OverlayNodeDetails {
        guard let key = try? EasyTierRuntime.Key(configuration) else { return OverlayNodeDetails() }
        return await runtime.details(key)
    }

    /// EasyTier has no account to sign out of (membership is the network
    /// secret, or the config server's assignment), so this is `stop`.
    func logout(timeout: Duration) async throws {
        await stop()
    }
}

// MARK: - Process-wide native runtime

/// Owns the process's native EasyTier instances and every call into them.
///
/// Native calls block, so they run on one concurrent dispatch queue per
/// instance key, never on the cooperative pool. Start and stop are barriers
/// on their key's queue; dials and status reads run concurrently between
/// them, so a dial can never land on a network that replaced its own
/// mid-call, and no key ever waits for another. `active` is written only
/// inside a barrier of the key it changes.
final class EasyTierRuntime: Sendable {
    static let shared = EasyTierRuntime(native: EasyTierNative.live)
    static let pollInterval = Duration.milliseconds(250)

    /// One instance key and what runs under it.
    struct Key: Sendable, Equatable {
        /// What owns the key's native instance: a manual network's TOML, or
        /// a config-server session.
        enum Source: Sendable, Equatable {
            case manual(toml: String, networkName: String)
            case configServer(url: String, machineID: UUID, hostname: String, requireEncryption: Bool)
        }

        let instance: String
        let source: Source

        init(_ configuration: EasyTierConfiguration) throws {
            let instance = configuration.instanceKey
            guard !instance.isEmpty, instance.utf8.count <= 128,
                  !instance.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw OverlayError.invalidConfiguration("The EasyTier instance key is not usable.")
            }
            self.instance = instance
            switch configuration.source {
            case .manual(let networkName, _, _, _):
                source = .manual(
                    toml: try EasyTierTOML.render(configuration),
                    networkName: networkName.trimmingCharacters(in: .whitespacesAndNewlines))
            case .configServer(let server):
                guard let url = EasyTierConfigServer.normalizedURL(server.url) else {
                    // The URL's path is the server token: never echo it.
                    let shown = EasyTierConfigServerURL.redacted(server.url).map { "\"\($0)\"" } ?? "The address"
                    throw OverlayError.invalidConfiguration(
                        "\(shown) is not an EasyTier config server: use a user name or a udp, tcp, ws or wss URL ending in the user name.")
                }
                source = .configServer(
                    url: url, machineID: server.machineID,
                    hostname: configuration.hostname.trimmingCharacters(in: .whitespacesAndNewlines),
                    requireEncryption: server.requireEncryption)
            }
        }
    }

    private let native: EasyTierNative
    private let queues = Mutex<[String: DispatchQueue]>([:])
    /// What each key's native instance runs, as this runtime started it.
    private let active = Mutex<[String: Key.Source]>([:])

    init(native: EasyTierNative) {
        self.native = native
    }

    private func queue(_ instance: String) -> DispatchQueue {
        queues.withLock { queues in
            if let queue = queues[instance] { return queue }
            let queue = DispatchQueue(label: "dev.bybee.heeler.easytier.instance", attributes: .concurrent)
            queues[instance] = queue
            return queue
        }
    }

    private func owns(_ key: Key) -> Bool {
        active.withLock { $0[key.instance] == key.source }
    }

    /// Runs `body` on `key`'s queue, as a barrier when it changes the key.
    private func perform<Value: Sendable>(
        _ key: Key, barrier: Bool = false, _ body: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            queue(key.instance).async(flags: barrier ? .barrier : []) {
                continuation.resume(returning: body())
            }
        }
    }

    /// The key's status, if this runtime started what it runs.
    private func ownedStatus(_ key: Key) -> EasyTierStatus? {
        guard owns(key) else { return nil }
        return native.statusJSON(key.instance).flatMap { try? EasyTierStatus.parse($0) }
    }

    /// Starts `key`'s network or session unless it is already what the key
    /// runs. The check runs concurrently with dials; only a real (re)start
    /// takes the key's barrier, so dials on a running network never queue
    /// behind each other.
    func start(_ key: Key, timeout: Duration) async throws {
        if await isRunning(key) { return }
        let milliseconds = EasyTierStatus.milliseconds(timeout)
        let failure: OverlayError? = await perform(key, barrier: true) {
            let result: (code: Int32, message: String)
            switch key.source {
            case .manual(let toml, _):
                result = self.native.start(key.instance, toml, milliseconds)
            case .configServer(let url, let machineID, let hostname, let requireEncryption):
                result = self.native.webStart(
                    key.instance, url, machineID.uuidString.lowercased(), hostname, requireEncryption)
            }
            if result.code == 0 {
                self.active.withLock { $0[key.instance] = key.source }
                return nil
            }
            // Leave no half-known state behind: whatever the key ran is
            // stopped, so its nodes report `.stopped` until restarted.
            // Other keys are untouched.
            self.native.stop(key.instance)
            self.active.withLock { $0[key.instance] = nil }
            return EasyTierStatus.startError(code: result.code, message: result.message)
        }
        if let failure { throw failure }
    }

    /// Whether `key` owns its instance and the native side still runs it:
    /// the manual network is live, or the config-server session exists.
    private func isRunning(_ key: Key) async -> Bool {
        await perform(key) {
            guard let status = self.ownedStatus(key) else { return false }
            switch key.source {
            case .manual: return status.running && status.web == nil
            case .configServer: return status.web != nil
            }
        }
    }

    /// Stops the key's network (or session) only if `key` still owns it.
    func stop(_ key: Key) async {
        await perform(key, barrier: true) {
            guard self.owns(key) else { return }
            self.native.stop(key.instance)
            self.active.withLock { $0[key.instance] = nil }
        }
    }

    func status(_ key: Key) async -> OverlayNodeStatus {
        await perform(key) {
            guard self.owns(key) else { return .stopped }
            let snapshot = self.native.statusJSON(key.instance).flatMap { try? EasyTierStatus.parse($0) }
            switch key.source {
            case .manual:
                return EasyTierStatus.nodeStatus(snapshot)
            case .configServer(_, let machineID, _, _):
                return EasyTierStatus.configServerStatus(snapshot, machineID: machineID)
            }
        }
    }

    func details(_ key: Key) async -> OverlayNodeDetails {
        await perform(key) {
            guard let status = self.ownedStatus(key) else { return OverlayNodeDetails() }
            switch key.source {
            case .manual(_, let networkName):
                guard status.running else { return OverlayNodeDetails() }
                var details = status.details
                details.networkName = networkName
                return details
            case .configServer(_, let machineID, _, _):
                return status.configServerDetails(machineID: machineID)
            }
        }
    }

    /// Dials through `key`'s instance; `network` names one of a config
    /// server's networks (nil: the one the destination fits).
    func dial(key: Key, network: String?, host: String, port: UInt16, timeout: Duration) async throws -> Int32 {
        let milliseconds = EasyTierStatus.milliseconds(timeout)
        let result: Result<Int32, OverlayError> = await perform(key) {
            guard self.owns(key) else {
                return .failure(.dialFailed("another EasyTier network replaced this one"))
            }
            let result = self.native.connect(key.instance, network, host, port, milliseconds)
            if result.code >= 0 { return .success(result.code) }
            return .failure(EasyTierStatus.dialError(code: result.code, message: result.message))
        }
        return try result.get()
    }
}

/// The C entry points, injectable so the runtime's ownership rules are
/// testable without the native library. Every call names its instance key.
struct EasyTierNative: Sendable {
    /// Key, TOML, timeout in milliseconds.
    var start: @Sendable (String, String, UInt32) -> (code: Int32, message: String)
    /// Stops the key's network or session.
    var stop: @Sendable (String) -> Void
    /// Key, network (nil: unspecified), host, port, timeout in milliseconds.
    var connect: @Sendable (String, String?, String, UInt16, UInt32) -> (code: Int32, message: String)
    var statusJSON: @Sendable (String) -> String?
    /// Key, URL, machine ID, hostname, whether encryption is required.
    var webStart: @Sendable (String, String, String, String, Bool) -> (code: Int32, message: String) = {
        _, _, _, _, _ in (-1, "EasyTier config servers are not available in this build")
    }
}

extension EasyTierNative {
    private static let errorCapacity = 1024

    private static func decode(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads a status, growing the buffer as the native side asks.
    private static func readStatus(_ read: (UnsafeMutablePointer<CChar>, Int) -> Int32) -> String? {
        var capacity = 1024
        while capacity <= 1 << 20 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let length = buffer.withUnsafeMutableBufferPointer { pointer in
                pointer.baseAddress.map { read($0, capacity) } ?? -1
            }
            guard length >= 0 else { return nil }
            if Int(length) < capacity { return decode(buffer) }
            capacity = Int(length) + 1
        }
        return nil
    }

    #if canImport(CEasyTier)
    static let live = EasyTierNative(
        start: { key, toml, milliseconds in
            var error = [CChar](repeating: 0, count: errorCapacity)
            let capacity = error.count
            let code = key.withCString { key in
                toml.withCString { heeler_et_start(key, $0, milliseconds, &error, capacity) }
            }
            return (code, decode(error))
        },
        stop: { key in key.withCString { heeler_et_stop($0) } },
        connect: { key, network, host, port, milliseconds in
            var error = [CChar](repeating: 0, count: errorCapacity)
            let capacity = error.count
            let code = key.withCString { key in
                host.withCString { host in
                    if let network {
                        return network.withCString { network in
                            heeler_et_tcp_connect_fd(key, network, host, port, milliseconds, &error, capacity)
                        }
                    }
                    return heeler_et_tcp_connect_fd(key, nil, host, port, milliseconds, &error, capacity)
                }
            }
            return (code, decode(error))
        },
        statusJSON: { key in
            key.withCString { key in readStatus { heeler_et_status_json(key, $0, $1) } }
        },
        webStart: { key, url, machineID, hostname, requireEncryption in
            var error = [CChar](repeating: 0, count: errorCapacity)
            let capacity = error.count
            let code = key.withCString { key in
                url.withCString { url in
                    machineID.withCString { machineID in
                        hostname.withCString { hostname in
                            heeler_et_web_start(
                                key, url, machineID, hostname, requireEncryption ? 1 : 0, &error, capacity)
                        }
                    }
                }
            }
            return (code, decode(error))
        }
    )
    #else
    static let live = EasyTierNative(
        start: { _, _, _ in (-1, "EasyTier is not available in this build") },
        stop: { _ in },
        connect: { _, _, _, _, _ in (-3, "EasyTier is not available in this build") },
        statusJSON: { _ in nil }
    )
    #endif
}

// MARK: - Pure configuration and status logic

/// Renders the EasyTier TOML for a configuration. Every user-supplied value is
/// emitted as an escaped TOML basic string, so no input can add keys or tables.
enum EasyTierTOML {
    static let instanceName = "heeler"
    /// Transports CEasyTier dials (no QUIC, KCP, or WireGuard). wss:// peers
    /// must present a certificate the system trusts.
    static let supportedPeerSchemes: Set<String> = ["tcp", "udp", "ws", "wss"]

    static func render(_ configuration: EasyTierConfiguration) throws -> String {
        guard case .manual(let rawName, let networkSecret, let rawPeers, let rawIPv4) = configuration.source else {
            throw OverlayError.invalidConfiguration("A config server's network has no local TOML.")
        }
        let networkName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !networkName.isEmpty else {
            throw OverlayError.invalidConfiguration("EasyTier needs a network name.")
        }
        let peers = rawPeers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !peers.isEmpty else {
            throw OverlayError.invalidConfiguration("EasyTier needs at least one peer.")
        }
        for peer in peers {
            try validate(peer: peer)
        }
        guard !networkSecret.isEmpty else {
            throw OverlayError.invalidConfiguration("EasyTier needs a network secret.")
        }
        let hostname = configuration.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let ipv4 = try rawIPv4.flatMap(staticIPv4)

        var lines = ["instance_name = \(quoted(instanceName))"]
        if !hostname.isEmpty {
            lines.append("hostname = \(quoted(hostname))")
        }
        if let ipv4 {
            lines += ["ipv4 = \(quoted(ipv4))", "dhcp = false"]
        } else {
            lines.append("dhcp = true")
        }
        lines += [
            "listeners = []",
            "",
            "[network_identity]",
            "network_name = \(quoted(networkName))",
            "network_secret = \(quoted(networkSecret))",
        ]
        for peer in peers {
            lines += ["", "[[peer]]", "uri = \(quoted(peer))"]
        }
        // Outbound only (heeler_et_start forces the same): no TUN, no relaying
        // of other peers' traffic or of foreign networks, and private mode,
        // which turns away peers of another network without this secret.
        lines += [
            "", "[flags]",
            "no_tun = true",
            "disable_relay_data = true",
            "relay_network_whitelist = \"\"",
            "private_mode = true",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// The canonical form of a fixed virtual address: an IPv4 address in
    /// dotted decimal (no leading zeros) and a prefix length of 1 to 32, as
    /// `10.144.144.7/24`. Unspecified, loopback, multicast, and reserved
    /// addresses are refused. nil when `value` is blank (use DHCP).
    static func staticIPv4(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let invalid = OverlayError.invalidConfiguration(
            "\"\(trimmed)\" is not an IPv4 address with a prefix length, such as 10.144.144.7/24.")
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = decimal(parts[1], maximum: 32), prefix >= 1 else {
            throw invalid
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { throw invalid }
        var values: [Int] = []
        for octet in octets {
            guard let value = decimal(octet, maximum: 255) else { throw invalid }
            values.append(value)
        }
        guard values[0] != 0, values[0] != 127, values[0] < 224 else {
            throw OverlayError.invalidConfiguration(
                "\(parts[0]) cannot be a virtual address; use a private address such as 10.144.144.7/24.")
        }
        return values.map(String.init).joined(separator: ".") + "/\(prefix)"
    }

    /// A decimal number of at most three digits without a leading zero.
    private static func decimal(_ text: Substring, maximum: Int) -> Int? {
        guard (1...3).contains(text.count),
              text.allSatisfy({ $0.isASCII && $0.isNumber }),
              text == "0" || !text.hasPrefix("0"),
              let value = Int(text), value <= maximum
        else { return nil }
        return value
    }

    static func validate(peer: String) throws {
        guard let components = URLComponents(string: peer),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else {
            throw OverlayError.invalidConfiguration("\"\(peer)\" is not a peer URI such as tcp://host:11010.")
        }
        guard supportedPeerSchemes.contains(scheme) else {
            throw OverlayError.invalidConfiguration(
                "EasyTier peers must use tcp://, udp://, ws:// or wss://, not \(scheme)://.")
        }
        guard components.port != nil else {
            throw OverlayError.invalidConfiguration("\"\(peer)\" needs a port, such as tcp://host:11010.")
        }
    }

    /// A TOML basic string: quotes, backslashes, and every control character
    /// are escaped; other Unicode is emitted as-is.
    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\t": result += "\\t"
            case "\n": result += "\\n"
            case "\u{0C}": result += "\\f"
            case "\r": result += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    static func message(for error: any Error) -> String {
        if case OverlayError.invalidConfiguration(let message) = error { return message }
        return String(describing: error)
    }
}

/// The JSON written by `heeler_et_status_json` for one instance key.
struct EasyTierStatus: Decodable, Equatable {
    var running: Bool
    var ipv4: String?
    var hostname: String?
    var peerCount: Int?
    var error: String?
    var peers: [Peer]?
    /// "manual" or "web" while the key holds something; nil without.
    var mode: String?
    /// The config-server session, while one runs.
    var web: Web?

    enum CodingKeys: String, CodingKey {
        case running, ipv4, hostname, error, peers, mode, web
        case peerCount = "peer_count"
    }

    init(
        running: Bool, ipv4: String? = nil, hostname: String? = nil, peerCount: Int? = nil, error: String? = nil,
        peers: [Peer]? = nil, mode: String? = nil, web: Web? = nil
    ) {
        self.running = running
        self.ipv4 = ipv4
        self.hostname = hostname
        self.peerCount = peerCount
        self.error = error
        self.peers = peers
        self.mode = mode
        self.web = web
    }

    /// `heeler_et_status_json`'s `web` object.
    struct Web: Decodable, Equatable {
        var connected: Bool
        var machineID: String?
        /// The networks the server assigned and this device runs (or ran
        /// until EasyTier reported an error), in instance-ID order.
        var networks: [Network]
        /// Networks the server asked for and the device refused or could not run.
        var failures: [Failure]

        enum CodingKeys: String, CodingKey {
            case connected, failures, networks
            case machineID = "machine_id"
        }

        /// One of the session's networks: the manual status fields plus its
        /// instance ID and name.
        struct Network: Decodable, Equatable {
            var instanceID: String
            var networkName: String?
            var running: Bool
            var ipv4: String?
            var ipv4Prefix: Int?
            var hostname: String?
            var peerCount: Int?
            var peers: [Peer]?
            var error: String?

            enum CodingKeys: String, CodingKey {
                case running, ipv4, hostname, peers, error
                case instanceID = "instance_id"
                case networkName = "network_name"
                case ipv4Prefix = "ipv4_prefix"
                case peerCount = "peer_count"
            }

            init(
                instanceID: String, networkName: String? = nil, running: Bool, ipv4: String? = nil,
                ipv4Prefix: Int? = nil, hostname: String? = nil, peerCount: Int? = nil, peers: [Peer]? = nil,
                error: String? = nil
            ) {
                self.instanceID = instanceID
                self.networkName = networkName
                self.running = running
                self.ipv4 = ipv4
                self.ipv4Prefix = ipv4Prefix
                self.hostname = hostname
                self.peerCount = peerCount
                self.peers = peers
                self.error = error
            }

            /// The address, once it has one.
            var address: String? { ipv4.flatMap { $0.isEmpty ? nil : $0 } }

            var displayName: String { networkName.flatMap { $0.isEmpty ? nil : $0 } ?? instanceID }
        }

        struct Failure: Decodable, Equatable {
            var instanceID: String
            var networkName: String?
            var message: String

            enum CodingKeys: String, CodingKey {
                case message
                case instanceID = "instance_id"
                case networkName = "network_name"
            }
        }

        init(connected: Bool, machineID: String? = nil, networks: [Network] = [], failures: [Failure] = []) {
            self.connected = connected
            self.machineID = machineID
            self.networks = networks
            self.failures = failures
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            connected = try container.decode(Bool.self, forKey: .connected)
            machineID = try container.decodeIfPresent(String.self, forKey: .machineID)
            networks = try container.decodeIfPresent([Network].self, forKey: .networks) ?? []
            failures = try container.decodeIfPresent([Failure].self, forKey: .failures) ?? []
        }

        /// The networks that run now.
        var runningNetworks: [Network] { networks.filter(\.running) }
    }

    /// One other node on the network, from EasyTier's route table.
    struct Peer: Decodable, Equatable {
        var peerID: UInt32
        var hostname: String?
        var ipv4: String?
        /// Reached over a connection of its own (route cost 1) rather than
        /// through another peer.
        var direct: Bool
        var cost: Int?
        var latencyMilliseconds: Double?

        enum CodingKeys: String, CodingKey {
            case hostname, ipv4, direct, cost
            case peerID = "peer_id"
            case latencyMilliseconds = "latency_ms"
        }
    }

    /// The detail-screen view of a manual network: this node's hostname and
    /// address, and every peer, sorted by hostname. Peer IDs are EasyTier's
    /// per-start `peer_id`s.
    var details: OverlayNodeDetails {
        OverlayNodeDetails(
            nodeID: nil,
            hostname: hostname.flatMap { $0.isEmpty ? nil : $0 },
            addresses: ipv4.map { $0.isEmpty ? [] : [$0] } ?? [],
            peers: Self.overlayPeers(peers ?? []))
    }

    /// The detail-screen view of a config-server session: the machine ID,
    /// every assigned network (refused ones with the reason), and, from the
    /// networks that run, this device's addresses and their peers. A peer's
    /// ID is its network's instance ID and its `peer_id`, so peers of
    /// different networks never collide; each carries its network's name.
    func configServerDetails(machineID: UUID) -> OverlayNodeDetails {
        var details = OverlayNodeDetails(nodeID: machineID.uuidString.lowercased())
        guard let web else { return details }
        let running = web.runningNetworks
        details.hostname = running.lazy.compactMap { $0.hostname.flatMap { $0.isEmpty ? nil : $0 } }.first
        details.addresses = running.compactMap(\.address)
        if !running.isEmpty {
            details.peers = running.flatMap { network in
                Self.overlayPeers(network.peers ?? []).map { peer in
                    var peer = peer
                    peer.id = "\(network.instanceID)/\(peer.id)"
                    peer.network = network.displayName
                    return peer
                }
            }
            details.networkName = running.map(\.displayName).joined(separator: ", ")
        }
        details.assignedNetworks = web.networks.map { network in
            OverlayAssignedNetwork(
                id: network.instanceID,
                name: network.networkName ?? "",
                isRunning: network.running,
                address: network.address.map { address in
                    network.ipv4Prefix.map { "\(address)/\($0)" } ?? address
                },
                peerCount: network.peers?.count ?? network.peerCount ?? 0,
                error: network.running ? nil : network.error.flatMap { $0.isEmpty ? nil : $0 })
        } + web.failures.map { failure in
            OverlayAssignedNetwork(
                id: failure.instanceID, name: failure.networkName ?? "", isRunning: false,
                error: failure.message)
        }
        return details
    }

    static func overlayPeers(_ peers: [Peer]) -> [OverlayPeer] {
        peers.map { peer in
            OverlayPeer(
                id: String(peer.peerID),
                name: peer.hostname.flatMap { $0.isEmpty ? nil : $0 },
                addresses: peer.ipv4.map { $0.isEmpty ? [] : [$0] } ?? [],
                isOnline: true,
                isDirect: peer.direct,
                latency: peer.latencyMilliseconds.flatMap { milliseconds in
                    milliseconds.isFinite && milliseconds >= 0
                        ? .microseconds(Int64((milliseconds * 1000).rounded())) : nil
                })
        }
        .sorted { ($0.name ?? "").lowercased() < ($1.name ?? "").lowercased() || (
            ($0.name ?? "").lowercased() == ($1.name ?? "").lowercased() && $0.id < $1.id) }
    }

    static func parse(_ json: String) throws -> EasyTierStatus {
        try JSONDecoder().decode(EasyTierStatus.self, from: Data(json.utf8))
    }

    static func nodeStatus(_ status: EasyTierStatus?) -> OverlayNodeStatus {
        guard let status else { return .failed("EasyTier returned an unreadable status") }
        if status.running {
            if let address = status.ipv4, !address.isEmpty {
                return .online(addresses: [address])
            }
            return .starting
        }
        if let error = status.error, !error.isEmpty {
            return .failed(error)
        }
        return .stopped
    }

    /// A config-server node's status. Running networks decide once one
    /// runs, even while the server is unreachable or another assigned
    /// network was refused: online with every running network's address.
    /// Before that the node waits for the server (to answer, or to assign a
    /// network) or has failed because what the server sent was refused or
    /// stopped with an error.
    static func configServerStatus(_ status: EasyTierStatus?, machineID: UUID) -> OverlayNodeStatus {
        guard let status else { return .failed("EasyTier returned an unreadable status") }
        guard let web = status.web else { return .stopped }
        let running = web.runningNetworks
        if !running.isEmpty {
            let addresses = running.compactMap(\.address)
            return addresses.isEmpty ? .starting : .online(addresses: addresses)
        }
        if let failure = web.failures.first {
            let name = failure.networkName.flatMap { $0.isEmpty ? nil : "network \"\($0)\"" } ?? "network"
            return .failed("The config server's \(name) cannot run here: \(failure.message)")
        }
        if let error = web.networks.lazy.compactMap({ $0.error.flatMap { $0.isEmpty ? nil : $0 } }).first {
            return .failed(error)
        }
        guard web.connected else {
            return .waiting("Connecting to the config server")
        }
        if !web.networks.isEmpty {
            return .starting
        }
        return .waiting(
            "Assign a network to this device (machine ID \(machineID.uuidString.lowercased())) in the EasyTier console")
    }

    /// Maps a negative `heeler_et_start` result (`HEELER_ET_ERR_*`).
    static func startError(code: Int32, message: String) -> OverlayError {
        if code == -2 { return .timedOut }
        return .startFailed(message.isEmpty ? "EasyTier could not start" : message)
    }

    /// Maps a negative `heeler_et_tcp_connect_fd` result (`HEELER_ET_ERR_*`):
    /// a timeout, or a dial failure with the native reason (not running,
    /// unresolved, or ambiguous among a config server's networks).
    static func dialError(code: Int32, message: String) -> OverlayError {
        switch code {
        case -2: return .timedOut
        case -3: return .dialFailed(message.isEmpty ? "EasyTier is not running" : message)
        case -5:
            return .dialFailed(
                message.isEmpty ? "The address is on more than one of the config server's networks" : message)
        default: return .dialFailed(message.isEmpty ? "EasyTier could not connect" : message)
        }
    }

    /// A positive millisecond count that fits the C ABI.
    static func milliseconds(_ duration: Duration) -> UInt32 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 1 }
        let total = seconds.multipliedReportingOverflow(by: 1000)
        guard !total.overflow else { return UInt32.max }
        let milliseconds = total.partialValue + attoseconds / 1_000_000_000_000_000
        return UInt32(clamping: max(milliseconds, 1))
    }
}
