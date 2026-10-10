import CHeelerOverlaySupport
import CZeroTier
import Foundation

/// What a `ZeroTierNetworkNode` needs from the process's node; a seam so
/// the node's start/stop bookkeeping can be tested without libzt.
protocol ZeroTierNetworkRuntime: Sendable {
    func startNode(identity: Data?, deadline: OverlayDeadline) async throws -> Data
    /// Joins `networkID`, orbits `moons`, and adds `planet`'s roots as a local
    /// moon for this caller; every join that returns is paired with exactly
    /// one `leave` passing the same moons and planet. Throws (holding
    /// nothing) only when the node refuses the join.
    func join(_ networkID: UInt64, moons: [ZeroTierMoon], planet: ZeroTierPlanet?) async throws
    /// Waits until the joined network has assigned this node an address.
    /// Throws `ZeroTierRuntime.NotReady`; never changes the references.
    func waitUntilReady(_ networkID: UInt64, deadline: OverlayDeadline) async throws
    func leave(_ networkID: UInt64, moons: [ZeroTierMoon], planet: ZeroTierPlanet?) async
    func networkSnapshot(_ networkID: UInt64) async -> ZeroTierRuntime.NetworkSnapshot
    /// The running node's ID, plus the addresses and peers when
    /// `joinedNetwork` is set. Never starts the node.
    func details(joinedNetwork: UInt64?) async -> OverlayNodeDetails
    /// Raw node and network state for troubleshooting. Never starts the node.
    func diagnostics(joinedNetwork: UInt64?, customRoots: Bool) async -> OverlayDiagnostics
}

extension ZeroTierNetworkRuntime {
    func diagnostics(joinedNetwork: UInt64?, customRoots: Bool) async -> OverlayDiagnostics {
        OverlayDiagnostics()
    }
}

/// The one libzt node this process may run.
///
/// libzt keeps a single node per process. Its `zts_node_stop` (libzt 1.16.2,
/// from heeler-overlay-natives 1.0.0) waits for the service and callback
/// threads to end after `ZTS_EVENT_NODE_DOWN`, but Heeler never calls it:
/// the node starts once, with the first identity it is given and ZeroTier's
/// own planet, and stays up for the life of the process. Networks are
/// joined and left on demand, reference-counted across
/// `ZeroTierNetworkNode`s. Moons are reference-counted the same way: a moon
/// is orbited while at least one joined network declares it and deorbited
/// when the last one leaves. So is a network's self-hosted planet, which is
/// added to the node as a local moon (see `ZeroTierPlanet`).
///
/// The node never touches the disk: no storage path is configured and every
/// cache is disabled, so the identity lives only in memory and the app keeps
/// it in the Keychain.
actor ZeroTierRuntime: ZeroTierNetworkRuntime {
    static let shared = ZeroTierRuntime()

    /// The libzt network and moon calls; replaced in tests.
    let control: ZeroTierControl

    init(control: ZeroTierControl = .live) {
        self.control = control
    }

    /// A runtime whose node counts as started with `identity` (tests).
    init(startedWith identity: String, control: ZeroTierControl) {
        self.control = control
        node = .started(identity: identity)
    }

    /// How `bootNode` ended. A node that `zts_node_start` started is never
    /// stopped (see above), so a failure after that point is permanent for
    /// the process.
    enum BootResult: Sendable {
        case started(identity: String)
        case rejected(OverlayError)
        case failedAfterStart(OverlayError)
    }

    private enum NodeState {
        case idle
        case starting(Task<BootResult, Never>, identity: String?)
        /// Started with this `identity.secret` string.
        case started(identity: String)
        case broken(OverlayError)
    }

    private var node: NodeState = .idle
    private var networkReferences: [UInt64: Int] = [:]
    private var moonOrbits = ZeroTierMoonOrbits()
    private(set) var localMoons = ZeroTierLocalMoons()
    /// Whether the node has reported itself online since it booted. libzt's
    /// online flag is only trustworthy for that: built with a 30-second peer
    /// activity timeout against a 60-second root ping, it reads offline for
    /// minutes at a time on an idle node whose networks work fine, so later
    /// starts must not wait on it.
    private(set) var hasBeenOnline = false

    /// Whether the process node has booted (and so answers queries).
    var isStarted: Bool {
        if case .started = node { return true }
        return false
    }

    private static let pollInterval: Duration = .milliseconds(100)
    /// libzt's identity buffer size (`ZT_IDENTITY_STRING_BUFFER_LENGTH`).
    static let identityBufferLength = Int(ZTS_ID_STR_BUF_LEN)

    /// Starts the node if needed and waits until it is online, for at most
    /// the deadline and only while the calling task is not cancelled. The
    /// node's own start keeps running in the background when the wait gives
    /// up, so a later call finds it further along. Returns the node's
    /// identity, which the caller persists when it supplied none.
    func startNode(identity: Data?, deadline: OverlayDeadline) async throws -> Data {
        let requested = try identity.map(Self.identityString)
        if let requested, !Self.isValidIdentity(requested) {
            throw OverlayError.invalidConfiguration("The ZeroTier identity is not valid.")
        }
        let task: Task<BootResult, Never>
        switch node {
        case .broken(let error):
            throw error
        case .started(let current):
            if let conflict = Self.conflict(requestedIdentity: requested, runningIdentity: current) {
                throw OverlayError.startFailed(conflict)
            }
            try await waitUntilOnline(deadline: deadline)
            return Data(current.utf8)
        case .starting(let existing, let startingIdentity):
            if let conflict = Self.conflict(requestedIdentity: requested, runningIdentity: startingIdentity) {
                throw OverlayError.startFailed(conflict)
            }
            task = existing
        case .idle:
            task = Task.detached { [self] in
                let result = await BlockingCall.run(name: "zerotier.start") {
                    Self.bootNode(identity: requested)
                }
                // Recorded even when every waiter has given up.
                await self.bootFinished(result)
                return result
            }
            node = .starting(task, identity: requested)
        }

        let result = try await BlockingCall.wait(for: task, timeout: deadline.remaining)
        bootFinished(result)
        switch result {
        case .started(let running):
            if let requested, requested != running {
                throw OverlayError.startFailed(Self.identityConflict)
            }
            try await waitUntilOnline(deadline: deadline)
            return Data(running.utf8)
        case .rejected(let error), .failedAfterStart(let error):
            throw error
        }
    }

    private func bootFinished(_ result: BootResult) {
        guard case .starting = node else { return }
        switch result {
        case .started(let identity):
            node = .started(identity: identity)
        case .rejected:
            node = .idle
        case .failedAfterStart(let error):
            node = .broken(error)
        }
    }

    /// Waits for the node's first time online after booting; returns at
    /// once ever after (see `hasBeenOnline`).
    private func waitUntilOnline(deadline: OverlayDeadline) async throws {
        let control = control
        while !hasBeenOnline {
            if await Self.call({ control.isOnline() }) {
                hasBeenOnline = true
                return
            }
            try await deadline.pause(Self.pollInterval)
        }
    }

    static let identityConflict =
        "ZeroTier is already running with a different identity in this app session."

    /// Why a start request cannot share the node that is running (or
    /// starting). A nil requested identity accepts whatever the node has.
    /// Roots never conflict: each network's own come and go as local moons.
    static func conflict(requestedIdentity: String?, runningIdentity: String?) -> String? {
        if let requestedIdentity, let runningIdentity, requestedIdentity != runningIdentity {
            return identityConflict
        }
        if requestedIdentity != nil, runningIdentity == nil {
            // The starting node mints its own identity, which cannot match.
            return identityConflict
        }
        return nil
    }

    /// Joins `networkID` (once per caller; see `leave`). The network stays
    /// joined until that leave, whatever its controller says meanwhile: a
    /// node awaiting authorization keeps asking for its configuration, so
    /// an admin's approval takes effect without joining again.
    ///
    /// Every reference change happens before the first suspension, and the
    /// native calls it implies are queued on `controlQueue` in the same step
    /// (`runControl`), so interleaved joins and leaves on this reentrant
    /// actor can neither lose a reference nor reorder a join and a leave.
    func join(_ networkID: UInt64, moons: [ZeroTierMoon], planet: ZeroTierPlanet? = nil) async throws {
        let references = networkReferences[networkID, default: 0]
        networkReferences[networkID] = references + 1
        // The node is online by now (`startNode` waits for it), so moons
        // declared before the start are orbited (and planets added) here,
        // ahead of the join.
        moonOrbits.retain(moons)
        localMoons.retain(planet)
        let status = await runControl(
            moonChanges: pendingMoonChanges(), join: references == 0 ? networkID : nil, leave: nil)
        guard status == ZTS_ERR_OK.rawValue else {
            // Only a node that is not running refuses a join.
            await leave(networkID, moons: moons, planet: planet)
            throw OverlayError.startFailed("Could not join ZeroTier network \(ZeroTierNetworkID.format(networkID)).")
        }
    }

    func leave(_ networkID: UInt64, moons: [ZeroTierMoon], planet: ZeroTierPlanet? = nil) async {
        guard let references = networkReferences[networkID] else { return }
        networkReferences[networkID] = references > 1 ? references - 1 : nil
        moonOrbits.release(moons)
        localMoons.release(planet)
        _ = await runControl(
            moonChanges: pendingMoonChanges(), join: nil, leave: references == 1 ? networkID : nil)
    }

    /// The changes that bring libzt in line with `moonOrbits` and
    /// `localMoons`, recorded as under way. Nothing while the node is not
    /// running; the next join after it starts applies them.
    private func pendingMoonChanges() -> MoonChanges {
        guard case .started = node else { return MoonChanges() }
        let orbits = moonOrbits.reconcile()
        // A moon orbited through a seed keeps its world ID; a local moon
        // never takes it, and moves off it when the orbit comes later.
        let reserved = Set(moonOrbits.orbited.keys)
        return MoonChanges(orbits: orbits, local: localMoons.reconcile(reserved: reserved))
    }

    /// When refused local moons were last tried again outside a join or
    /// leave (see `retryRefusedLocalMoons`).
    private var lastLocalMoonRetry: ContinuousClock.Instant?
    private static let localMoonRetryInterval: Duration = .seconds(5)

    /// Tries refused local moon adds again, at most every few seconds, while
    /// a network is being polled (`networkSnapshot`, `diagnostics`). Joins
    /// and leaves try them again anyway.
    func retryRefusedLocalMoons() async {
        guard !localMoons.failures.isEmpty, case .started = node else { return }
        let now = ContinuousClock.now
        if let last = lastLocalMoonRetry, now - last < Self.localMoonRetryInterval { return }
        lastLocalMoonRetry = now
        _ = await runControl(moonChanges: pendingMoonChanges(), join: nil, leave: nil)
    }

    private struct MoonChanges {
        var orbits: [ZeroTierMoonOrbits.Change] = []
        var local: [ZeroTierLocalMoons.Change] = []
        var isEmpty: Bool { orbits.isEmpty && local.isEmpty }
    }

    /// Local moon IDs currently added (or being added), for tests.
    func localMoonIDs() -> [UInt64] {
        localMoons.added.values.sorted()
    }

    /// Moon IDs currently orbited through a seed, for tests.
    func orbitedMoonIDs() -> [UInt64] {
        moonOrbits.orbited.keys.sorted()
    }

    /// Refused local moon adds awaiting a retry, for tests and diagnostics.
    func localMoonFailures() -> [ZeroTierPlanet: ZeroTierLocalMoons.Failure] {
        localMoons.failures
    }

    /// Queues the moon changes, then a network join or leave, on
    /// `controlQueue` before this actor suspends: native calls run in the
    /// order the bookkeeping changed. Returns the join's status (OK without
    /// one), after recording each local moon add's result. `zts_moon_orbit`
    /// and `zts_moon_deorbit` report success whenever the node runs, so
    /// their results carry nothing to act on. `heeler_zt_add_moon` can be
    /// refused (the node stopping, or a moon it already has under that ID);
    /// such an add is tried again by the next join, leave, or poll.
    private func runControl(
        moonChanges: MoonChanges, join: UInt64?, leave: UInt64?
    ) async -> Int32 {
        if moonChanges.isEmpty, join == nil, leave == nil { return ZTS_ERR_OK.rawValue }
        let result = await queueControl(moonChanges: moonChanges, join: join, leave: leave)
        for add in result.adds {
            localMoons.addFinished(add.planet, moonID: add.moonID, status: add.status)
            if add.status != ZTS_ERR_OK.rawValue {
                ZeroTierEventLog.shared.append(
                    "Adding a network's planet as moon \(ZeroTierNetworkID.format(add.moonID)) failed "
                        + "(\(add.status)); will retry")
            }
        }
        return result.joinStatus
    }

    private struct ControlResult: Sendable {
        var joinStatus = ZTS_ERR_OK.rawValue
        var adds: [(planet: ZeroTierPlanet, moonID: UInt64, status: Int32)] = []
    }

    private func queueControl(
        moonChanges: MoonChanges, join: UInt64?, leave: UInt64?
    ) async -> ControlResult {
        let control = control
        return await withCheckedContinuation { (continuation: CheckedContinuation<ControlResult, Never>) in
            Self.controlQueue.async {
                var result = ControlResult()
                for change in moonChanges.local {
                    if case .remove(let moonID) = change { _ = control.deorbit(moonID) }
                }
                for change in moonChanges.orbits {
                    switch change {
                    case .orbit(let moon): _ = control.orbit(moon.worldID, moon.seed)
                    case .deorbit(let worldID): _ = control.deorbit(worldID)
                    }
                }
                for change in moonChanges.local {
                    if case .add(let planet, let moonID) = change {
                        let status = control.addMoon(planet.data, moonID)
                        result.adds.append((planet, moonID, status))
                    }
                }
                if let join { result.joinStatus = control.joinNetwork(join) }
                if let leave { _ = control.leaveNetwork(leave) }
                continuation.resume(returning: result)
            }
        }
    }

    func references(_ networkID: UInt64) -> Int {
        networkReferences[networkID, default: 0]
    }

    func details(joinedNetwork networkID: UInt64?) async -> OverlayNodeDetails {
        guard case .started = node else { return OverlayNodeDetails() }
        let nodeID = await Self.call { zts_node_get_id() }
        var details = OverlayNodeDetails(nodeID: ZeroTierNodeID.format(nodeID))
        guard let networkID, networkReferences[networkID] != nil else { return details }
        details.addresses = await networkSnapshot(networkID).addresses
        details.peers = ZeroTierPeers.overlayPeers(await Self.call { ZeroTierPeers.read() })
        return details
    }

    func networkSnapshot(_ networkID: UInt64) async -> NetworkSnapshot {
        await retryRefusedLocalMoons()
        let control = control
        return await Self.call { control.snapshot(networkID) }
    }

    func isJoined(_ networkID: UInt64) -> Bool {
        networkReferences[networkID] != nil
    }

    /// Why a joined network is not usable yet.
    enum NotReady: Error, Equatable {
        /// The controller refused this node; it may still authorize it.
        case awaitingAuthorization
        /// The controller's answer cannot change on its own (no such
        /// network, client too old, …).
        case failed(String)
        case timedOut
        case cancelled
    }

    func waitUntilReady(_ networkID: UInt64, deadline: OverlayDeadline) async throws {
        while true {
            let snapshot = await networkSnapshot(networkID)
            if let failure = snapshot.failure {
                throw NotReady.failed(failure)
            }
            if snapshot.isReady { return }
            // Reported at once: the network stays joined, so approval is
            // picked up whenever it comes, without this caller waiting.
            if snapshot.isAwaitingAuthorization { throw NotReady.awaitingAuthorization }
            do {
                try await deadline.pause(Self.pollInterval)
            } catch OverlayError.cancelled {
                throw NotReady.cancelled
            } catch {
                throw NotReady.timedOut
            }
        }
    }

    /// Mints a new identity (`identity.secret` text) without a running node.
    /// Identity generation is deliberately expensive and takes a moment.
    static func generateIdentity() throws -> Data {
        var buffer = [CChar](repeating: 0, count: identityBufferLength)
        var length = UInt32(identityBufferLength)
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return ZTS_ERR_ARG.rawValue }
            return zts_id_new(base, &length)
        }
        guard status == ZTS_ERR_OK.rawValue, length > 0, Int(length) < identityBufferLength else {
            throw OverlayError.startFailed("ZeroTier could not generate an identity.")
        }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        let identity = String(decoding: bytes, as: UTF8.self)
        guard isValidIdentity(identity) else {
            throw OverlayError.startFailed("ZeroTier generated an invalid identity.")
        }
        return Data(identity.utf8)
    }

    // MARK: - Native

    struct NetworkSnapshot: Sendable, Equatable {
        var isReady: Bool
        var addresses: [String]
        /// Why the network cannot be used, when that cannot change on its
        /// own; nil while usable, pending, or awaiting authorization.
        var failure: String?
        /// The controller has refused this node so far (ACCESS_DENIED).
        var isAwaitingAuthorization = false
    }

    /// The live snapshot; blocks briefly, so it runs on `controlQueue`.
    static func networkSnapshot(_ networkID: UInt64) -> NetworkSnapshot {
        let status = zts_net_get_status(networkID)
        let failure = ZeroTierNetworkID.failureMessage(networkStatus: status, networkID: networkID)
        let awaitingAuthorization = status == Int32(ZTS_NETWORK_STATUS_ACCESS_DENIED.rawValue)
        let ready = zts_net_transport_is_ready(networkID) == 1
        var addresses: [String] = []
        for family in [ZTS_AF_INET, ZTS_AF_INET6] {
            guard zts_addr_is_assigned(networkID, UInt32(family)) == 1 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(ZTS_IP_MAX_STR_LEN))
            let result = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                guard let base = pointer.baseAddress else { return ZTS_ERR_ARG.rawValue }
                return zts_addr_get_str(networkID, UInt32(family), base, UInt32(pointer.count))
            }
            if result == ZTS_ERR_OK.rawValue {
                let address = buffer.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress.map { String(cString: $0) } ?? ""
                }
                if !address.isEmpty { addresses.append(address) }
            }
        }
        return NetworkSnapshot(
            isReady: ready && !addresses.isEmpty && !awaitingAuthorization, addresses: addresses,
            failure: failure, isAwaitingAuthorization: awaitingAuthorization)
    }

    /// Runs a prompt libzt control call off the cooperative pool. libzt
    /// serializes these internally.
    static func call<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
        await BlockingCall.run(on: controlQueue, body)
    }

    private static let controlQueue = DispatchQueue(
        label: "dev.bybee.heeler.overlay.zerotier.control", qos: .utility)

    /// Configures and starts the process's node. Runs once.
    private static func bootNode(identity: String?) -> BootResult {
        // No storage path and no caches: nothing is written to disk. The
        // node keeps ZeroTier's own planet; networks add their roots as
        // local moons once it runs.
        _ = zts_init_allow_net_cache(0)
        _ = zts_init_allow_peer_cache(0)
        _ = zts_init_allow_roots_cache(0)
        _ = zts_init_allow_id_cache(0)
        // Recent node, network, and peer events for diagnostics. The
        // handler must return promptly: libzt calls it on its event thread.
        _ = zts_init_set_event_handler { message in
            ZeroTierEventLog.shared.record(message)
        }

        if let identity {
            var buffer = identityBuffer(identity)
            let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                guard let base = pointer.baseAddress else { return ZTS_ERR_ARG.rawValue }
                return zts_init_from_memory(base, UInt32(pointer.count))
            }
            guard status == ZTS_ERR_OK.rawValue else {
                return .rejected(.invalidConfiguration("ZeroTier rejected the stored identity."))
            }
        }
        guard zts_node_start() == ZTS_ERR_OK.rawValue else {
            return .rejected(.startFailed("The ZeroTier node did not start."))
        }

        // The node object (and a freshly minted identity) appears on
        // libzt's service thread shortly after start.
        let giveUp = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < giveUp {
            if let current = currentIdentity() { return .started(identity: current) }
            usleep(50_000)
        }
        return .failedAfterStart(.startFailed("The ZeroTier node did not create its identity."))
    }

    private static func currentIdentity() -> String? {
        var buffer = [CChar](repeating: 0, count: identityBufferLength)
        var length = UInt32(identityBufferLength)
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return ZTS_ERR_ARG.rawValue }
            return zts_node_get_id_pair(base, &length)
        }
        guard status == ZTS_ERR_OK.rawValue, length > 0 else { return nil }
        let identity = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? ""
        }
        return identity.isEmpty ? nil : identity
    }

    /// The identity as libzt's NUL-padded fixed-size buffer. libzt copies
    /// exactly the length it is given, so the buffer is always full-size.
    static func identityBuffer(_ identity: String) -> [CChar] {
        var buffer = [CChar](repeating: 0, count: identityBufferLength)
        let bytes = Array(identity.utf8.prefix(identityBufferLength - 1))
        for (index, byte) in bytes.enumerated() {
            buffer[index] = CChar(bitPattern: byte)
        }
        return buffer
    }

    static func isValidIdentity(_ identity: String) -> Bool {
        var buffer = identityBuffer(identity)
        return buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return zts_id_pair_is_valid(base, UInt32(pointer.count)) == 1
        }
    }

    /// `identity.secret` text from stored bytes: UTF-8, surrounding
    /// whitespace removed, and short enough for libzt's buffer.
    static func identityString(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "\0"))),
            !text.isEmpty,
            text.utf8.count < identityBufferLength
        else {
            throw OverlayError.invalidConfiguration("The ZeroTier identity is not valid.")
        }
        return text
    }
}

/// The libzt calls `ZeroTierRuntime` makes for networks and moons, each
/// prompt and run on its control queue; a seam for the bookkeeping tests.
struct ZeroTierControl: Sendable {
    var joinNetwork: @Sendable (UInt64) -> Int32
    var leaveNetwork: @Sendable (UInt64) -> Int32
    var orbit: @Sendable (_ worldID: UInt64, _ seed: UInt64) -> Int32
    var deorbit: @Sendable (_ worldID: UInt64) -> Int32
    /// Adds a checked planet's roots as local moon `moonID`
    /// (`heeler_zt_add_moon`); `deorbit` removes it.
    var addMoon: @Sendable (_ planet: Data, _ moonID: UInt64) -> Int32 = {
        ZeroTierPlanet.addMoon($0, moonID: $1)
    }
    var snapshot: @Sendable (UInt64) -> ZeroTierRuntime.NetworkSnapshot
    /// libzt's node-online flag (see `ZeroTierRuntime.hasBeenOnline`).
    var isOnline: @Sendable () -> Bool = { zts_node_is_online() == 1 }

    static let live = ZeroTierControl(
        joinNetwork: { zts_net_join($0) },
        leaveNetwork: { zts_net_leave($0) },
        orbit: { zts_moon_orbit($0, $1) },
        deorbit: { zts_moon_deorbit($0) },
        snapshot: { ZeroTierRuntime.networkSnapshot($0) })
}
