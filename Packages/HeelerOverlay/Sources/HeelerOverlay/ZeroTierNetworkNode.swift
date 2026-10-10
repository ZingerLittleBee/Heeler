import CHeelerOverlaySupport
import CZeroTier
import Foundation

/// One joined ZeroTier network on the process-wide libzt node.
///
/// `identityGenerated` reports the node identity whenever this network's
/// configuration carried none, so the caller can persist it. The first such
/// start in a process mints the identity; later ones report the identity the
/// running node already has, which is the identity this network will see.
actor ZeroTierNetworkNode: OverlayNode {
    nonisolated let kind = OverlayKind.zerotier
    private let configuration: ZeroTierConfiguration
    private let identityGenerated: @Sendable (Data) -> Void
    private let runtime: any ZeroTierNetworkRuntime

    private var joined = false
    /// Bumped by `stop`, so a start that was in flight at the time can tell
    /// and give back the network reference it took.
    private var generation = 0
    private var reportedIdentity = false
    private var lastFailure: String?
    /// The running node's ID, once a start has reached it.
    private var nodeID: String?

    init(
        configuration: ZeroTierConfiguration,
        identityGenerated: @escaping @Sendable (Data) -> Void,
        runtime: any ZeroTierNetworkRuntime = ZeroTierRuntime.shared
    ) {
        self.configuration = configuration
        self.identityGenerated = identityGenerated
        self.runtime = runtime
    }

    /// Brings the network up: starts the process node, joins, and waits
    /// for an address. A network whose controller has not authorized this
    /// node stays joined and reports `.waiting`, so the approval takes
    /// effect by itself; only `stop` (or a definitive refusal such as an
    /// unknown network) leaves it.
    func start(timeout: Duration) async throws {
        guard configuration.networkID != 0 else {
            throw OverlayError.invalidConfiguration("A ZeroTier network ID is required.")
        }
        let deadline = OverlayDeadline(after: timeout)
        let generation = self.generation
        lastFailure = nil
        do {
            if !joined {
                try await join(deadline: deadline, generation: generation)
            }
            try await waitUntilReady(deadline: deadline, generation: generation)
        } catch let error as OverlayError {
            switch error {
            case .startFailed(let message), .invalidConfiguration(let message):
                // A network still joined reports its state live instead.
                if !joined { lastFailure = message }
            case .timedOut, .cancelled, .loginRequired, .dialFailed:
                break
            }
            throw error
        }
    }

    private func join(deadline: OverlayDeadline, generation: Int) async throws {
        guard configuration.moons.allSatisfy(\.isValid) else {
            throw OverlayError.invalidConfiguration(
                "A ZeroTier moon needs a world ID and a seed of at most 10 hexadecimal digits.")
        }
        let planet = try configuration.roots.map(ZeroTierPlanet.init)
        let identity = try await runtime.startNode(
            identity: configuration.identity,
            deadline: deadline)
        nodeID = ZeroTierIdentity.nodeID(of: identity)
        if configuration.identity == nil, !reportedIdentity {
            reportedIdentity = true
            identityGenerated(identity)
        }
        guard generation == self.generation else { throw OverlayError.cancelled }
        if joined { return }
        try await runtime.join(configuration.networkID, moons: configuration.moons, planet: planet)
        guard generation == self.generation else {
            // Stopped while joining: give back the reference this start
            // took, or the network would stay joined with no owner.
            await runtime.leave(configuration.networkID, moons: configuration.moons, planet: planet)
            throw OverlayError.cancelled
        }
        if joined {
            // A concurrent start joined first; keep one reference.
            await runtime.leave(configuration.networkID, moons: configuration.moons, planet: planet)
        }
        joined = true
    }

    private func waitUntilReady(deadline: OverlayDeadline, generation: Int) async throws {
        do {
            try await runtime.waitUntilReady(configuration.networkID, deadline: deadline)
        } catch let notReady as ZeroTierRuntime.NotReady {
            guard generation == self.generation else { throw OverlayError.cancelled }
            switch notReady {
            case .awaitingAuthorization:
                throw OverlayError.startFailed(awaitingAuthorizationMessage)
            case .failed(let message):
                // Nothing to wait for: give the network back, so a later
                // start (after the settings are fixed) joins afresh.
                if joined {
                    joined = false
                    await leaveNetwork()
                }
                throw OverlayError.startFailed(message)
            case .timedOut:
                throw OverlayError.timedOut
            case .cancelled:
                throw OverlayError.cancelled
            }
        }
        guard generation == self.generation else { throw OverlayError.cancelled }
    }

    /// What `.waiting` says while the controller has not authorized this
    /// node, naming the node ID an admin looks for.
    var awaitingAuthorizationMessage: String {
        let network = ZeroTierNetworkID.format(configuration.networkID)
        let node = nodeID ?? configuration.identity.flatMap(ZeroTierIdentity.nodeID(of:))
        guard let node else {
            return "Waiting for this device to be authorized on ZeroTier network \(network)"
        }
        return "Waiting for authorization of node \(node) on ZeroTier network \(network)"
    }

    func dial(host: String, port: UInt16, timeout: Duration) async throws -> OverlayDialedStream {
        guard let address = OverlayAddress.ipLiteral(host) else {
            throw OverlayError.invalidConfiguration(
                "ZeroTier hosts must be IP addresses on the network, not names.")
        }
        guard port != 0 else {
            throw OverlayError.invalidConfiguration("A ZeroTier dial needs a port.")
        }
        let deadline = OverlayDeadline(after: timeout)
        try await start(timeout: deadline.remaining)

        let cancel = ZeroTierCancelToken()
        let timeoutMilliseconds = max(1, deadline.remaining.milliseconds)
        // The connection is bound to this network's address and interface,
        // so only this network carries it, even when another joined network
        // assigned this device the same address; an IPv4 address the network
        // cannot reach fails at once rather than at the timeout.
        let networkID = configuration.networkID
        let connected = try await BlockingCall.run(
            name: "zerotier.dial",
            timeout: deadline.remaining + .seconds(1),
            onGiveUp: { cancel.set() },
            abandon: { result in
                if case .success(let descriptor) = result { zts_bsd_close(descriptor) }
            }
        ) { () -> Result<Int32, OverlayError> in
            var descriptor: Int32 = -1
            let status = cancel.withPointer { token in
                heeler_zt_connect(address, port, networkID, Int32(timeoutMilliseconds), token, &descriptor)
            }
            if status == Int32(HEELER_OVERLAY_OK), descriptor >= 0 { return .success(descriptor) }
            return .failure(Self.dialError(status: status, address: address, networkID: networkID))
        }
        let overlayDescriptor = try connected.get()

        let pump = OverlayPump()
        let descriptor = pump.startZeroTier(overlayDescriptor)
        guard descriptor >= 0 else {
            throw OverlayError.dialFailed("Could not start the ZeroTier stream pump.")
        }
        return OverlayDialedStream(descriptor: descriptor, release: { pump.release() })
    }

    /// The error a failed `heeler_zt_connect` result stands for.
    static func dialError(status: Int32, address: String, networkID: UInt64) -> OverlayError {
        let network = ZeroTierNetworkID.format(networkID)
        switch status {
        case Int32(HEELER_OVERLAY_ERR_NO_SOURCE):
            let family = address.contains(":") ? "IPv6" : "IPv4"
            return .dialFailed(
                "This device has no \(family) address on ZeroTier network \(network) to reach \(address) from.")
        case Int32(HEELER_OVERLAY_ERR_NO_ROUTE):
            return .dialFailed("\(address) is not reachable on ZeroTier network \(network)")
        case Int32(HEELER_OVERLAY_ERR_TIMEOUT):
            return .timedOut
        case Int32(HEELER_OVERLAY_ERR_CANCELLED):
            return .cancelled
        case Int32(HEELER_OVERLAY_ERR_REFUSED):
            return .dialFailed("The peer refused or reset the connection.")
        default:
            return .dialFailed("Could not open a ZeroTier connection (\(status)).")
        }
    }

    func status() async -> OverlayNodeStatus {
        if joined {
            let snapshot = await runtime.networkSnapshot(configuration.networkID)
            if let failure = snapshot.failure { return .failed(failure) }
            if snapshot.isAwaitingAuthorization { return .waiting(awaitingAuthorizationMessage) }
            return snapshot.isReady ? .online(addresses: snapshot.addresses) : .starting
        }
        if let lastFailure { return .failed(lastFailure) }
        return .stopped
    }

    /// Leaves the network and gives back its moons. The process's libzt node
    /// keeps running, because it cannot be started again once stopped.
    func stop() async {
        generation += 1
        lastFailure = nil
        guard joined else { return }
        joined = false
        await leaveNetwork()
    }

    /// Gives back the network, moons, and planet a join took. The planet
    /// was checked when the network joined, so it reads the same again.
    private func leaveNetwork() async {
        let planet = configuration.roots.flatMap { try? ZeroTierPlanet($0) }
        await runtime.leave(configuration.networkID, moons: configuration.moons, planet: planet)
    }

    /// The node ID this network sees, plus its addresses and the node's peers
    /// while joined (see `ZeroTierPeers.overlayPeers`). Before a join the ID
    /// comes from the configured identity, or from the running node, whose
    /// identity a network without one would use.
    func details() async -> OverlayNodeDetails {
        var details = await runtime.details(joinedNetwork: joined ? configuration.networkID : nil)
        if !joined, let identity = configuration.identity,
           let nodeID = ZeroTierIdentity.nodeID(of: identity) {
            details.nodeID = nodeID
        }
        return details
    }

    func diagnostics() async -> OverlayDiagnostics {
        var diagnostics = await runtime.diagnostics(
            joinedNetwork: joined ? configuration.networkID : nil,
            customRoots: configuration.roots != nil)
        diagnostics.entries.insert(contentsOf: [
            .init(label: "Network ID", value: ZeroTierNetworkID.format(configuration.networkID)),
            .init(label: "Joined", value: joined ? "Yes" : "No"),
        ], at: 0)
        return diagnostics
    }

    /// ZeroTier has no sign-out: a node's identity is its membership, and
    /// only the network's controller can deauthorize it. So logging out
    /// leaves the network exactly like `stop`; the caller forgets the
    /// identity if it wants a fresh node ID next time.
    func logout(timeout: Duration) async throws {
        await stop()
    }
}

/// Owns a native cancellation flag shared with a blocking libzt connect.
final class ZeroTierCancelToken: @unchecked Sendable {
    // Written once in init; the native flag is atomic.
    private let token: OpaquePointer?

    init() {
        token = heeler_overlay_cancel_create()
    }

    func set() {
        heeler_overlay_cancel_set(token)
    }

    func withPointer<Result>(_ body: (OpaquePointer?) -> Result) -> Result {
        withExtendedLifetime(self) { body(token) }
    }

    deinit {
        heeler_overlay_cancel_destroy(token)
    }
}

/// The Swift owner of one native pump; `release` is idempotent.
final class OverlayPump: @unchecked Sendable {
    private let lock = NSLock()
    private var pump: OpaquePointer?

    /// Starts pumping a connected libzt descriptor, taking ownership of it.
    /// Returns the caller's descriptor, or a negative result code.
    func startZeroTier(_ overlayDescriptor: Int32) -> Int32 {
        start { heeler_zt_pump_start(overlayDescriptor, &$0) }
    }

    /// Starts pumping an ordinary connected socket (tests).
    func startPOSIX(_ remoteDescriptor: Int32) -> Int32 {
        start { heeler_posix_pump_start(remoteDescriptor, &$0) }
    }

    /// Like `startPOSIX`, but sends to the remote report would-block for
    /// `stallMilliseconds` despite readiness (tests).
    func startPOSIXStallingSends(_ remoteDescriptor: Int32, stallMilliseconds: Int32) -> Int32 {
        start { heeler_posix_pump_start_stalling_sends(remoteDescriptor, stallMilliseconds, &$0) }
    }

    private func start(_ body: (inout OpaquePointer?) -> Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        var created: OpaquePointer?
        let descriptor = body(&created)
        if descriptor >= 0 { pump = created }
        return descriptor
    }

    func release() {
        lock.lock()
        let pump = self.pump
        self.pump = nil
        lock.unlock()
        if let pump { heeler_overlay_pump_release(pump) }
    }

    deinit {
        release()
    }

    static var liveCount: Int {
        Int(heeler_overlay_pump_live_count())
    }
}

/// ZeroTier network IDs: 16 hexadecimal digits for a 64-bit value.
public enum ZeroTierNetworkID {
    /// Parses a network ID typed or pasted by the user. Accepts exactly 16
    /// hexadecimal digits (either case), ignoring surrounding whitespace.
    public static func parse(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 16,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
              let value = UInt64(trimmed, radix: 16),
              value != 0
        else { return nil }
        return value
    }

    /// The canonical form: 16 lowercase hexadecimal digits.
    public static func format(_ networkID: UInt64) -> String {
        let digits = String(networkID, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    /// A user-facing reason the network cannot be used, from libzt's
    /// `zts_net_get_status`; nil while the network is usable, pending, or
    /// awaiting authorization (which an admin may still grant).
    static func failureMessage(networkStatus: Int32, networkID: UInt64) -> String? {
        let name = format(networkID)
        switch networkStatus {
        case Int32(ZTS_NETWORK_STATUS_NOT_FOUND.rawValue):
            return "ZeroTier network \(name) does not exist."
        case Int32(ZTS_NETWORK_STATUS_PORT_ERROR.rawValue):
            return "ZeroTier could not open its network port."
        case Int32(ZTS_NETWORK_STATUS_CLIENT_TOO_OLD.rawValue):
            return "ZeroTier network \(name) needs a newer client."
        default:
            return nil
        }
    }
}
