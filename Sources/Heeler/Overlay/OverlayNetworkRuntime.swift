import Foundation
import HeelerOverlay
import Synchronization

extension OverlayError {
    fileprivate var isDialFailure: Bool {
        if case .dialFailed = self { true } else { false }
    }
}

/// What one overlay node is built from: the package configuration with its
/// secrets resolved. The seam tests replace through `NodeFactory`.
enum OverlayNodeSpec: Sendable, Equatable {
    case tailscale(TailscaleConfiguration)
    case zerotier(ZeroTierConfiguration)
    case easytier(EasyTierConfiguration)
}

/// The app's running Overlay Network nodes (ADR 0021): at most one per
/// configured network, created on the first dial or explicit start, shared
/// by every Host and reconnect that uses that network.
///
/// `OverlayNetworkStore` publishes the catalog synchronously, so a Host can
/// dial before any actor hop has happened. Each published network carries a
/// revision; a node built from an older revision is retired and replaced on
/// its next use, and `reconcile()` retires it eagerly. Retiring is one
/// `stop()` task per network that every replacement awaits, so an old and a
/// new node never share a Tailscale state directory or the EasyTier instance
/// keyed by the network's id. Every EasyTier network runs as an instance of
/// its own, beside the others. Nodes are discarded on suspension and rebuilt lazily
/// by the next dial, so this type never has to know how a backend treats a
/// stopped node.
actor OverlayNetworkRuntime {
    typealias NodeFactory = @Sendable (
        _ spec: OverlayNodeSpec,
        _ identityGenerated: @escaping @Sendable (Data) -> Void
    ) -> any OverlayNode

    /// One catalog entry as the store last saved it.
    struct Published: Sendable, Equatable {
        let network: OverlayNetwork
        /// Bumped when the settings or the secret change — not on a rename.
        let revision: Int
        /// Bumped when the secret changes. A Tailscale login made with one
        /// auth key is not kept under another.
        let secretRevision: Int

        init(network: OverlayNetwork, revision: Int = 0, secretRevision: Int = 0) {
            self.network = network
            self.revision = revision
            self.secretRevision = secretRevision
        }
    }

    private enum CatalogState: Sendable {
        /// Until the store's first publish an empty catalog means "not
        /// loaded", never "every network was removed".
        case unpublished
        case published
        /// The store could not decode its catalog; nothing resolves.
        case unreadable
    }

    private struct Catalog: Sendable {
        var networks: [UUID: Published] = [:]
        /// Ids of entries a newer build wrote (unknown kinds): not ours to
        /// run, but their state directories are not ours to delete either.
        var reservedIDs: Set<UUID> = []
        var state = CatalogState.unpublished
    }

    private struct Entry {
        let node: any OverlayNode
        let published: Published
        let spec: OverlayNodeSpec
    }

    private struct Retirement {
        let task: Task<Void, Never>
    }

    /// What this process's single libzt node was given. libzt keeps the
    /// identity of its first start until the app exits, so later ZeroTier
    /// nodes must match it (ADR 0021). Planets are per network and need no
    /// such bookkeeping.
    private struct ZeroTierSession: Sendable {
        /// The identity the process node runs with, when known: the one it
        /// was given, or the one it minted.
        var identity: Data?
        /// A node was built without an identity and is starting; it may
        /// mint one, so generating another now would conflict. Cleared when
        /// it reports the identity or fails.
        var mintPending = false
    }

    static let shared = OverlayNetworkRuntime()

    /// Consecutive start failures of one network revision reported as the
    /// retryable `.notReady` before they become the terminal `.startFailed`.
    /// With the Console's backoff this covers a few minutes — long enough
    /// for an admin to approve the device, short enough that a rejected key
    /// stops instead of retrying forever behind a summary.
    static let startFailureLimit = 5

    /// `Application Support/Overlay`: one private directory per Tailscale
    /// network holding its tsnet state.
    static var defaultStateRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Overlay", isDirectory: true)
    }

    /// Planet files larger than this are not ZeroTier roots definitions;
    /// libzt rejects them too.
    static let zeroTierPlanetSizeLimit = 1...16_384

    /// Where builds before per-network planets kept the device-wide custom
    /// ZeroTier planet, beside the per-network state directories (whose
    /// names are UUIDs, so orphan cleanup skips it). Read once, to migrate.
    static let legacyZeroTierPlanetFileName = "zerotier-planet"

    static let liveNode: NodeFactory = { spec, identityGenerated in
        switch spec {
        case .tailscale(let configuration):
            OverlayNodes.tailscale(configuration)
        case .zerotier(let configuration):
            OverlayNodes.zerotier(configuration, identityGenerated: identityGenerated)
        case .easytier(let configuration):
            OverlayNodes.easytier(configuration)
        }
    }

    private let catalog = Mutex(Catalog())
    private let secrets: any SecretStore
    private let stateRoot: URL?
    private let makeNode: NodeFactory
    private let generateZeroTierIdentity: @Sendable () throws -> Data
    private let zeroTierSession = Mutex(ZeroTierSession())
    /// The identity generation in flight, shared by concurrent callers.
    /// It finishes on this actor having saved the identity, so a waiter
    /// that resumes finds it in the Keychain.
    private var identityGeneration: Task<Data?, any Error>?
    /// Tailscale networks signed out this session; also marked on disk
    /// (`signedOutMarker`) so a relaunch does not sign them in again.
    private var signedOut: Set<UUID> = []
    private var nodes: [UUID: Entry] = [:]
    private var retirements: [UUID: Retirement] = [:]
    /// The catalog entry each network's on-disk state was last validated
    /// against. A change that invalidates a Tailscale login (new auth key,
    /// new coordination server) deletes the state before the next node,
    /// whether or not a node was running when the change was saved.
    private var stateOwners: [UUID: Published] = [:]
    private var startFailures: [UUID: (revision: Int, count: Int)] = [:]
    /// Starts and dials in progress per network, so a cancelled one only
    /// gives up a node nobody else is still waiting for.
    private var users: [UUID: Set<UUID>] = [:]
    /// Networks whose current node has come up (a start or dial succeeded)
    /// and may carry streams; cleared when a new node is built.
    private var cameUp: Set<UUID> = []

    init(
        secrets: any SecretStore = KeychainSecretStore(service: OverlaySecretAccount.service),
        stateRoot: URL? = OverlayNetworkRuntime.defaultStateRoot,
        makeNode: @escaping NodeFactory = OverlayNetworkRuntime.liveNode,
        generateZeroTierIdentity: @escaping @Sendable () throws -> Data = {
            try ZeroTierIdentity.generate()
        }
    ) {
        self.secrets = secrets
        self.stateRoot = stateRoot
        self.makeNode = makeNode
        self.generateZeroTierIdentity = generateZeroTierIdentity
    }

    // MARK: Catalog

    /// Replaces the catalog the next dial resolves against. Synchronous so a
    /// save is visible to the very next connection attempt; follow with
    /// `reconcile()` to retire nodes the change made stale.
    nonisolated func publish(_ networks: [Published], reserving reservedIDs: Set<UUID> = []) {
        catalog.withLock { catalog in
            catalog.networks = Dictionary(
                networks.map { ($0.network.id, $0) },
                uniquingKeysWith: { _, latest in latest })
            catalog.reservedIDs = reservedIDs
            catalog.state = .published
        }
    }

    /// The store's catalog could not be decoded: every dial fails with
    /// `.catalogUnreadable` and no state directory is touched.
    nonisolated func markCatalogUnreadable() {
        catalog.withLock { catalog in
            catalog.networks = [:]
            catalog.state = .unreadable
        }
    }

    /// The route a Host's first hop takes through `networkID`. Resolution
    /// happens at dial time, so a route built before the network was removed
    /// fails with `.notConfigured` instead of reaching a stale node.
    nonisolated func route(for networkID: UUID) -> OverlayRoute {
        let name = catalog.withLock { $0.networks[networkID]?.network.displayName }
        return OverlayRoute(networkName: name ?? "Overlay network") { host, port, timeout in
            try await self.dial(networkID: networkID, host: host, port: port, timeout: timeout)
        }
    }

    /// Retires nodes whose network was removed or re-saved, then deletes
    /// state directories nothing owns. Every decision reads the catalog as
    /// it is after the preceding await, never a snapshot from before it.
    func reconcile() async {
        while true {
            let current = catalog.withLock { $0 }
            guard case .published = current.state else { return }
            guard
                let (id, entry) = nodes.first(where: { id, entry in
                    current.networks[id]?.revision != entry.published.revision
                })
            else { break }
            await retire(id, entry)
        }
        let current = catalog.withLock { $0 }
        guard case .published = current.state else { return }
        // Networks with no node now (or none ever this session): validate
        // their state here. Ones with a node were validated when it was built.
        for (id, published) in current.networks where nodes[id] == nil && retirements[id] == nil {
            validateState(of: id, against: published)
        }
        removeOrphanedState(
            keeping: Set(current.networks.keys)
                .union(current.reservedIDs)
                .union(nodes.keys)
                .union(retirements.keys))
    }

    // MARK: Nodes

    /// Opens one TCP stream to `host:port` on the network, bringing its node
    /// up first. Throws `TransportError`.
    ///
    /// Returns as soon as the calling task is cancelled, with
    /// `TransportError.cancelled`, whatever the node is blocked in; a stream
    /// the node opens afterwards is closed. Cancellation is not a start
    /// failure: it neither counts towards `startFailureLimit` nor resets it.
    func dial(
        networkID: UUID, host: String, port: UInt16, timeout: Duration
    ) async throws -> OverlayDialedStream {
        try await Self.returningOnCancellation(abandon: Self.closeAbandonedStream) {
            try await self.performDial(networkID: networkID, host: host, port: port, timeout: timeout)
        }
    }

    private func performDial(
        networkID: UUID, host: String, port: UInt16, timeout: Duration
    ) async throws -> OverlayDialedStream {
        let published = try publishedNetwork(networkID)
        if published.network.kind == .tailscale, isSignedOut(networkID) {
            throw TransportError.overlayFailed(
                network: published.network.displayName, reason: .signedOut)
        }
        let entry = try await entry(for: networkID)
        try checkCancellation()
        let use = beginUse(networkID)
        do {
            let stream = try await withTaskCancellationHandler {
                try await entry.node.dial(host: host, port: port, timeout: timeout)
            } onCancel: {
                Task { await self.abandonUse(use, of: networkID, entry) }
            }
            endUse(use, of: networkID, cameUp: true)
            // A stream that arrives after the caller was cancelled goes to
            // `closeAbandonedStream` through `returningOnCancellation`.
            startFailures[networkID] = nil
            recordStartOutcome(of: entry, booted: true)
            return stream
        } catch {
            if Task.isCancelled {
                abandonUse(use, of: networkID, entry)
                throw TransportError.cancelled
            }
            endUse(use, of: networkID, cameUp: false)
            let waiting = await waitingDetail(of: entry)
            // A refused peer, or one waiting on its network, means the node
            // itself came up.
            recordStartOutcome(
                of: entry, booted: waiting != nil || ((error as? OverlayError)?.isDialFailure ?? false))
            if let waiting { throw waitingFailure(waiting, published: entry.published) }
            throw transportError(error, networkID: networkID, published: entry.published)
        }
    }

    /// Brings the network's node up without dialling anything, as the
    /// Settings Connect button does. An explicit Connect starts a fresh run
    /// of retryable start failures. Throws `TransportError`.
    /// It is also the only way back in after Sign Out.
    ///
    /// Cancelling the calling task (Cancel while connecting) returns at once
    /// with `TransportError.cancelled`, without counting a start failure. A
    /// Tailscale or EasyTier node that never came up and that no other
    /// start or dial is waiting for is then stopped and discarded in the
    /// background, so nothing keeps connecting unseen and the next Connect
    /// builds afresh once it has stopped. A ZeroTier network stays joined:
    /// an authorization or address that arrives later still applies.
    func start(networkID: UUID, timeout: Duration) async throws {
        try await Self.returningOnCancellation {
            try await self.performStart(networkID: networkID, timeout: timeout)
        }
    }

    private func performStart(networkID: UUID, timeout: Duration) async throws {
        startFailures[networkID] = nil
        clearSignedOut(networkID)
        let entry = try await entry(for: networkID)
        try checkCancellation()
        let use = beginUse(networkID)
        do {
            try await withTaskCancellationHandler {
                try await entry.node.start(timeout: timeout)
            } onCancel: {
                Task { await self.abandonUse(use, of: networkID, entry) }
            }
            endUse(use, of: networkID, cameUp: true)
            startFailures[networkID] = nil
            recordStartOutcome(of: entry, booted: true)
        } catch {
            if Task.isCancelled {
                abandonUse(use, of: networkID, entry)
                throw TransportError.cancelled
            }
            endUse(use, of: networkID, cameUp: false)
            let waiting = await waitingDetail(of: entry)
            recordStartOutcome(of: entry, booted: waiting != nil)
            if let waiting { throw waitingFailure(waiting, published: entry.published) }
            throw transportError(error, networkID: networkID, published: entry.published)
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw TransportError.cancelled }
    }

    private func beginUse(_ networkID: UUID) -> UUID {
        let use = UUID()
        users[networkID, default: []].insert(use)
        return use
    }

    /// Ends one start or dial; false when it had already ended.
    @discardableResult
    private func endUse(_ use: UUID, of networkID: UUID, cameUp: Bool) -> Bool {
        guard users[networkID]?.remove(use) != nil else { return false }
        if users[networkID]?.isEmpty == true { users[networkID] = nil }
        if cameUp, nodes[networkID] != nil { self.cameUp.insert(networkID) }
        return true
    }

    /// A start or dial whose caller was cancelled, as soon as it is (not
    /// when the node notices): stops and discards the network's node when
    /// it is still the one the caller used, never came up, and nothing else
    /// waits for it. Not awaited — the next start or dial waits for the
    /// stop as for any retirement. ZeroTier is left joined.
    private func abandonUse(_ use: UUID, of networkID: UUID, _ entry: Entry) {
        guard endUse(use, of: networkID, cameUp: false),
            entry.published.network.kind != .zerotier,
            users[networkID] == nil,
            !cameUp.contains(networkID),
            let current = nodes[networkID], current.node === entry.node
        else { return }
        _ = beginRetirement(networkID, current)
    }

    /// A dialled stream nobody will use: closed, then released.
    private static let closeAbandonedStream: @Sendable (OverlayDialedStream) -> Void = { stream in
        Darwin.close(stream.descriptor)
        stream.release()
    }

    /// Runs `operation` in a task of its own and returns as soon as the
    /// calling task is cancelled, throwing `TransportError.cancelled`
    /// instead of waiting for it: a node's native call may notice the
    /// cancellation only much later. The operation is cancelled too, and a
    /// value it produces after the caller left goes to `abandon`.
    static func returningOnCancellation<Value: Sendable>(
        abandon: @escaping @Sendable (Value) -> Void = { _ in },
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = CancellableWait<Value>(abandon: abandon)
        let task = Task {
            do {
                race.finish(.success(try await operation()))
            } catch {
                race.finish(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        } onCancel: {
            task.cancel()
            race.cancel()
        }
    }

    /// Why a node that is up is waiting on something outside the app (a
    /// ZeroTier controller that has not authorized the device, an EasyTier
    /// config server that has not assigned a network), if it is.
    private func waitingDetail(of entry: Entry) async -> String? {
        guard case .waiting(let detail) = await entry.node.status() else { return nil }
        return detail
    }

    /// A start or dial of a waiting node failed for that reason, whatever it
    /// reported. It stays retryable however often it repeats: unlike a
    /// rejected key, an admin can still act, and the node keeps asking.
    /// The run of start failures is neither counted nor reset.
    private func waitingFailure(_ detail: String, published: Published) -> TransportError {
        .overlayFailed(network: published.network.displayName, reason: .notReady(detail))
    }

    /// Whether the network was signed out and not connected again from
    /// Settings since. Dials fail with `.signedOut` meanwhile.
    func isSignedOut(_ networkID: UUID) -> Bool {
        if signedOut.contains(networkID) { return true }
        guard let marker = signedOutMarker(for: networkID) else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private func markSignedOut(_ networkID: UUID) {
        signedOut.insert(networkID)
        // Best effort: without the marker only a relaunch forgets it.
        guard (try? stateDirectory(for: networkID)) != nil,
            let marker = signedOutMarker(for: networkID)
        else { return }
        try? Data().write(to: marker, options: .completeFileProtectionUntilFirstUserAuthentication)
    }

    private func clearSignedOut(_ networkID: UUID) {
        signedOut.remove(networkID)
        if let marker = signedOutMarker(for: networkID) {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    /// A file tsnet does not use, inside the network's state directory so
    /// it goes with the network.
    private func signedOutMarker(for networkID: UUID) -> URL? {
        stateRoot?
            .appendingPathComponent(networkID.uuidString, isDirectory: true)
            .appendingPathComponent(".heeler-signed-out", isDirectory: false)
    }

    /// `.stopped` for a network whose node was never built or was discarded.
    func status(networkID: UUID) async -> OverlayNodeStatus {
        guard let entry = nodes[networkID],
            catalog.withLock({ $0.networks[networkID]?.revision }) == entry.published.revision
        else { return .stopped }
        let status = await entry.node.status()
        guard nodes[networkID]?.node === entry.node,
            catalog.withLock({ $0.networks[networkID]?.revision }) == entry.published.revision
        else { return .stopped }
        return status
    }

    /// What the network's node reports about itself and its peers; empty
    /// for a network without a node. Never builds or starts one.
    func details(networkID: UUID) async -> OverlayNodeDetails {
        guard let entry = nodes[networkID] else { return OverlayNodeDetails() }
        return await entry.node.details()
    }

    /// The network's node's raw state for troubleshooting; empty for a
    /// network without a node. Never builds or starts one.
    func diagnostics(networkID: UUID) async -> OverlayDiagnostics {
        guard let entry = nodes[networkID] else { return OverlayDiagnostics() }
        return await entry.node.diagnostics()
    }

    /// The peers the network's node reports once it is online, for choosing
    /// a Host from the network. A node that is not online is started first
    /// when `startIfNeeded` (bounded by `timeout`), as the Settings Connect
    /// button does — except a signed-out Tailscale network, which only
    /// Connect in Settings may sign in again. Throws `TransportError`:
    /// `.notReady` when the node is not online and may not be started, or
    /// came up without being usable yet (sign-in, approval, assignment).
    func peers(
        networkID: UUID, startIfNeeded: Bool, timeout: Duration = .seconds(30)
    ) async throws -> [OverlayPeer] {
        let published = try publishedNetwork(networkID)
        let network = published.network
        let isOnline = await status(networkID: networkID).isOnline
        if !isOnline {
            if network.kind == .tailscale, isSignedOut(networkID) {
                throw TransportError.overlayFailed(network: network.displayName, reason: .signedOut)
            }
            guard startIfNeeded else {
                throw TransportError.overlayFailed(
                    network: network.displayName, reason: .notReady("The network is not connected"))
            }
            try await start(networkID: networkID, timeout: timeout)
            try checkCancellation()
            switch await status(networkID: networkID) {
            case .online:
                break
            case .needsLogin(let url):
                throw transportError(
                    OverlayError.loginRequired(url), networkID: networkID, published: published)
            case .waiting(let detail), .failed(let detail):
                throw TransportError.overlayFailed(
                    network: network.displayName,
                    reason: .notReady(detail.isEmpty ? "The network is not ready yet" : detail))
            case .stopped, .starting:
                throw TransportError.overlayFailed(
                    network: network.displayName, reason: .notReady("The network is still connecting"))
            }
        }
        return await details(networkID: networkID).peers ?? []
    }

    /// Signs a Tailscale network's device out of its tailnet and forgets
    /// the login. A network without a node gets one built from its settings
    /// (never started) so the backend can clear what its saved state holds.
    /// The node is discarded and the state directory deleted even when the
    /// coordination server could not be told (tsnet marks itself logged out
    /// before asking the server). The network then stays signed out: Host
    /// dials fail with `.signedOut` instead of registering again with a
    /// saved auth key, until the user connects it from Settings (`start`).
    /// The revision is unchanged: the settings still apply. Throws
    /// `TransportError` when the server-side logout failed.
    func logout(networkID: UUID, timeout: Duration) async throws {
        let (node, published) = try await logoutTarget(networkID)
        // Registered as a retirement, so a dial meanwhile waits for the
        // logout and then builds a fresh node on clean state.
        nodes[networkID] = nil
        let previous = retirements[networkID]?.task
        let logout = Task { () -> (any Error)? in
            await previous?.value
            var failure: (any Error)?
            do {
                try await node.logout(timeout: timeout)
            } catch {
                failure = error
                await node.stop()
            }
            Self.removeState(for: networkID, in: self.stateRoot)
            return failure
        }
        let task = Task { _ = await logout.value }
        retirements[networkID] = Retirement(task: task)
        let failure = await logout.value
        await task.value
        if retirements[networkID]?.task == task {
            retirements[networkID] = nil
        }
        startFailures[networkID] = nil
        markSignedOut(networkID)
        if let failure {
            throw transportError(failure, networkID: networkID, published: published)
        }
    }

    /// The node to sign out with: the running one, or one built (never
    /// started) from the network's settings once earlier stops finished.
    private func logoutTarget(_ networkID: UUID) async throws -> (any OverlayNode, Published) {
        while true {
            let published = try publishedNetwork(networkID)
            guard published.network.kind == .tailscale else {
                throw TransportError.overlayFailed(
                    network: published.network.displayName,
                    reason: .misconfigured("Only Tailscale networks have a sign-in to sign out of"))
            }
            if let existing = nodes[networkID] {
                return (existing.node, published)
            }
            if await awaitRetirements(blocking: networkID) {
                continue
            }
            validateState(of: networkID, against: published)
            return (makeNode(try spec(for: published.network)) { _ in }, published)
        }
    }

    /// Stops and discards one network's node; the next dial rebuilds it.
    func stop(networkID: UUID) async {
        guard let entry = nodes[networkID] else { return }
        await retire(networkID, entry)
    }

    /// App suspension: retire every node and wait for them all. Live SSH
    /// connections are already torn down by then, and the next dial after
    /// reactivation rebuilds.
    func suspend() async {
        let retiring = nodes
        let tasks = retiring.map { id, entry in beginRetirement(id, entry) }
        for task in tasks {
            await task.value
        }
        for (id, retirement) in retirements where tasks.contains(retirement.task) {
            retirements[id] = nil
        }
    }

    /// Ids of networks that currently hold a node, for tests.
    var activeNetworkIDs: Set<UUID> { Set(nodes.keys) }

    private func entry(for networkID: UUID) async throws -> Entry {
        while true {
            let published = try publishedNetwork(networkID)
            if let existing = nodes[networkID] {
                if existing.published.revision == published.revision {
                    // A rename reuses the node; only copy the new name.
                    let current = Entry(
                        node: existing.node, published: published, spec: existing.spec)
                    nodes[networkID] = current
                    return current
                }
                await retire(networkID, existing)
                continue
            }
            // A node of this network is still stopping: wait, then look
            // again from the top.
            if await awaitRetirements(blocking: networkID) {
                continue
            }
            validateState(of: networkID, against: published)
            // A ZeroTier node built while an identity is being generated
            // would mint a second one: wait for it, then look again.
            if published.network.kind == .zerotier, let generation = identityGeneration {
                _ = try? await generation.value
                continue
            }
            let spec = try spec(for: published.network)
            if case .zerotier(let configuration) = spec, configuration.identity == nil {
                zeroTierSession.withLock { $0.mintPending = true }
            }
            let entry = Entry(
                node: makeNode(spec) { [secrets] identity in
                    // Best effort: an unsaved identity is regenerated on
                    // the next launch, which only costs a re-authorization.
                    try? secrets.write(identity, account: OverlaySecretAccount.zeroTierIdentity)
                    self.recordZeroTierBoot(identity: identity)
                },
                published: published,
                spec: spec)
            nodes[networkID] = entry
            cameUp.remove(networkID)
            return entry
        }
    }

    private func publishedNetwork(_ networkID: UUID) throws -> Published {
        let (published, state) = catalog.withLock { ($0.networks[networkID], $0.state) }
        if let published { return published }
        if case .unreadable = state {
            throw TransportError.overlayFailed(
                network: "Overlay network", reason: .catalogUnreadable)
        }
        throw TransportError.overlayFailed(network: "Overlay network", reason: .notConfigured)
    }

    // MARK: ZeroTier device state

    /// The device's ZeroTier identity, creating one before any node runs so
    /// its node ID can be shown and authorized ahead of the first connect.
    /// When the process node already runs with an identity the Keychain no
    /// longer holds (the last ZeroTier network was deleted meanwhile), that
    /// identity is saved again rather than minting one that would conflict.
    /// nil while a node is still minting its own. Throws when the Keychain
    /// or the generator fails; the node then mints one on first connect.
    func ensureZeroTierIdentity() async throws -> Data? {
        if let known = try knownZeroTierIdentity() { return known }
        if zeroTierSession.withLock({ $0.mintPending }) { return nil }
        if let generation = identityGeneration {
            return try await generation.value
        }
        // libzt derives the key deliberately slowly (up to a second): off
        // this actor, so dials and status polls are not held up.
        let generate = generateZeroTierIdentity
        let generation = Task { () throws -> Data? in
            let minted = await Task.detached { Result { try generate() } }.value
            self.identityGeneration = nil
            return try self.adoptGeneratedZeroTierIdentity(minted.get())
        }
        identityGeneration = generation
        return try await generation.value
    }

    /// The saved identity, or the running node's re-saved; nil if neither.
    private func knownZeroTierIdentity() throws -> Data? {
        if let stored = try secrets.read(account: OverlaySecretAccount.zeroTierIdentity),
            !stored.isEmpty
        {
            return stored
        }
        if let identity = zeroTierSession.withLock({ $0.identity }) {
            try secrets.write(identity, account: OverlaySecretAccount.zeroTierIdentity)
            return identity
        }
        return nil
    }

    /// Saves a freshly generated identity unless one appeared meanwhile.
    private func adoptGeneratedZeroTierIdentity(_ minted: Data) throws -> Data {
        if let known = try knownZeroTierIdentity() { return known }
        guard ZeroTierIdentity.nodeID(of: minted) != nil else {
            throw OverlayError.invalidConfiguration("The generated identity is malformed")
        }
        try secrets.write(minted, account: OverlaySecretAccount.zeroTierIdentity)
        return minted
    }

    /// Records how a ZeroTier node's start went. Only a boot fixes the
    /// process node's identity; a failure before it releases a pending
    /// mint, so an identity can be generated up front again.
    private func recordStartOutcome(of entry: Entry, booted: Bool) {
        guard case .zerotier(let configuration) = entry.spec else { return }
        if booted {
            recordZeroTierBoot(identity: configuration.identity)
        } else {
            zeroTierSession.withLock { $0.mintPending = false }
        }
    }

    private nonisolated func recordZeroTierBoot(identity: Data?) {
        zeroTierSession.withLock { session in
            if session.identity == nil, let identity {
                session.identity = identity
                session.mintPending = false
            }
        }
    }

    nonisolated var legacyZeroTierPlanetURL: URL? {
        stateRoot?.appendingPathComponent(Self.legacyZeroTierPlanetFileName, isDirectory: false)
    }

    /// The device-wide planet an earlier build saved, if one is left to
    /// migrate (`OverlayNetworkStore`); nil when none or unreadable.
    nonisolated func legacyZeroTierPlanet() -> Data? {
        guard let url = legacyZeroTierPlanetURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Deletes the device-wide planet once it has been migrated.
    nonisolated func removeLegacyZeroTierPlanet() {
        guard let url = legacyZeroTierPlanetURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Retirement

    /// Removes the node and waits until it has stopped — and, when the
    /// network is gone or its login no longer applies, until its state
    /// directory is deleted.
    private func retire(_ networkID: UUID, _ entry: Entry) async {
        let task = beginRetirement(networkID, entry)
        await task.value
        if retirements[networkID]?.task == task {
            retirements[networkID] = nil
        }
    }

    /// Starts the stop chained behind any earlier one for the same network.
    /// A replacement is built only after this task, so it never shares the
    /// old node's state; `validateState` then decides whether that state
    /// still applies. A removed network's state goes inside the task, after
    /// `stop()`, against the catalog as it is by then.
    private func beginRetirement(_ networkID: UUID, _ entry: Entry) -> Task<Void, Never> {
        nodes[networkID] = nil
        let previous = retirements[networkID]?.task
        let task = Task {
            await previous?.value
            await entry.node.stop()
            let isRemoved = self.catalog.withLock { catalog in
                if case .published = catalog.state {
                    return catalog.networks[networkID] == nil
                }
                return false
            }
            if isRemoved {
                Self.removeState(for: networkID, in: self.stateRoot)
            }
        }
        retirements[networkID] = Retirement(task: task)
        return task
    }

    /// Awaits the retirement of `networkID`'s previous node, which must
    /// finish before a new one may start. Networks never wait for each
    /// other: every EasyTier network is an instance of its own. Returns
    /// whether it waited, so the caller re-reads every decision.
    private func awaitRetirements(blocking networkID: UUID) async -> Bool {
        guard let retirement = retirements[networkID] else { return false }
        await retirement.task.value
        if retirements[networkID]?.task == retirement.task {
            retirements[networkID] = nil
        }
        return true
    }

    // MARK: Errors

    private func transportError(
        _ error: any Error, networkID: UUID, published: Published
    ) -> any Error {
        let network = published.network
        switch error {
        // The package refuses a second identity for the one libzt node of a
        // process ("… in this app session."). Retrying cannot help; only a
        // relaunch can.
        case OverlayError.startFailed(let detail)
        where network.kind == .zerotier && detail.hasSuffix("in this app session."):
            return TransportError.overlayFailed(
                network: network.displayName,
                reason: .misconfigured(detail + " " + Self.zeroTierRestartAdvice))
        case OverlayError.startFailed(let detail):
            let previous = startFailures[networkID]
            let count = (previous?.revision == published.revision ? previous?.count ?? 0 : 0) + 1
            startFailures[networkID] = (published.revision, count)
            return TransportError(
                overlay: .startFailed(detail),
                network: network.displayName,
                isPersistent: count >= Self.startFailureLimit)
        case OverlayError.loginRequired(let url) where !network.acceptsLoginURL(url):
            return TransportError.overlayFailed(
                network: network.displayName,
                reason: .misconfigured("The coordination server sent a sign-in link that is not https"))
        case let error as OverlayError:
            return TransportError(overlay: error, network: network.displayName)
        case is CancellationError:
            return TransportError.cancelled
        default:
            return error
        }
    }

    // MARK: Specs

    private func spec(for network: OverlayNetwork) throws -> OverlayNodeSpec {
        let name = network.displayName
        func misconfigured(_ detail: String) -> TransportError {
            .overlayFailed(network: name, reason: .misconfigured(detail))
        }
        func secret(_ account: String?) throws -> String? {
            guard let account else { return nil }
            do {
                guard let data = try secrets.read(account: account), !data.isEmpty else {
                    return nil
                }
                return String(decoding: data, as: UTF8.self)
            } catch {
                throw misconfigured("Its secret could not be read from the Keychain")
            }
        }

        switch network.settings {
        case .tailscale(let hostname, let controlURL):
            let directory: URL
            do {
                directory = try stateDirectory(for: network.id)
            } catch {
                throw TransportError.overlayFailed(
                    network: name,
                    reason: .startFailed("Its state directory could not be created"))
            }
            return .tailscale(
                TailscaleConfiguration(
                    stateDirectory: directory,
                    hostname: hostname,
                    authKey: try secret(OverlaySecretAccount.secret(for: network)),
                    controlURL: controlURL))
        case .zerotier(let networkIDText, let moons, let planet):
            guard let networkID = OverlayNetwork.zeroTierNetworkID(networkIDText) else {
                throw misconfigured("The network ID must be 16 hexadecimal digits")
            }
            let identity: Data?
            do {
                identity = try secrets.read(account: OverlaySecretAccount.zeroTierIdentity)
            } catch {
                throw misconfigured("Its identity could not be read from the Keychain")
            }
            return .zerotier(
                ZeroTierConfiguration(
                    networkID: networkID, identity: identity, roots: planet, moons: moons))
        case .easytier(let networkName, let peers, let hostname, let ipv4):
            guard let networkSecret = try secret(OverlaySecretAccount.secret(for: network)) else {
                throw misconfigured("The network secret is missing")
            }
            return .easytier(
                EasyTierConfiguration(
                    networkName: networkName,
                    networkSecret: networkSecret,
                    peers: peers,
                    hostname: hostname,
                    ipv4: ipv4,
                    instanceKey: network.id.uuidString))
        case .easytierConfigServer(_, let machineID, let hostname, let requireEncryption):
            guard let url = try secret(OverlaySecretAccount.secret(for: network)) else {
                throw misconfigured("The config server address is missing")
            }
            return .easytier(
                EasyTierConfiguration(
                    source: .configServer(
                        EasyTierConfigServer(url: url, machineID: machineID, requireEncryption: requireEncryption)),
                    hostname: hostname,
                    instanceKey: network.id.uuidString))
        }
    }

    static let zeroTierRestartAdvice = "Quit and reopen Heeler to apply it."

    // MARK: State directories

    /// Deletes the network's state when `published` invalidates the entry it
    /// was last validated against, then records `published` as its owner.
    /// Only called while no node of the network exists or is stopping.
    private func validateState(of networkID: UUID, against published: Published) {
        if let owner = stateOwners[networkID], Self.invalidatesState(from: owner, to: published) {
            // A new auth key or server is a new login; Sign Out went with
            // the old one.
            Self.removeState(for: networkID, in: stateRoot)
            signedOut.remove(networkID)
        }
        stateOwners[networkID] = published
    }

    /// A Tailscale login belongs to one coordination server and was made
    /// with one auth key; changing either starts from a clean state.
    private static func invalidatesState(from old: Published, to new: Published) -> Bool {
        switch (old.network.settings, new.network.settings) {
        case (.tailscale(_, let oldControl), .tailscale(_, let newControl)):
            oldControl != newControl || old.secretRevision != new.secretRevision
        default:
            old.network.kind != new.network.kind
        }
    }

    /// Creates `<root>/<id>/`, readable after first unlock (the node may
    /// start from a background reconnect) and excluded from backups: the
    /// state is a device credential, like the Keychain items beside it.
    private func stateDirectory(for id: UUID) throws -> URL {
        guard var root = stateRoot else { throw CocoaError(.fileNoSuchFile) }
        var directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        try directory.setResourceValues(values)
        return directory
    }

    private static func removeState(for id: UUID, in stateRoot: URL?) {
        guard let stateRoot else { return }
        try? FileManager.default.removeItem(
            at: stateRoot.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    private func removeOrphanedState(keeping ids: Set<UUID>) {
        guard
            let stateRoot,
            let names = try? FileManager.default.contentsOfDirectory(atPath: stateRoot.path)
        else { return }
        for name in names {
            guard let id = UUID(uuidString: name), !ids.contains(id) else { continue }
            Self.removeState(for: id, in: stateRoot)
        }
    }
}

/// One wait of `OverlayNetworkRuntime.returningOnCancellation`: the first of
/// the operation's result and the caller's cancellation wins; a value that
/// loses goes to `abandon`. Either may come before the continuation exists.
private final class CancellableWait<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var pending: Result<Value, any Error>?
        var cancelled = false
        var resumed = false
    }

    private enum Action {
        case none
        case resume(CheckedContinuation<Value, any Error>, Result<Value, any Error>)
        case abandon(Value)
    }

    private let state = Mutex(State())
    private let abandon: @Sendable (Value) -> Void

    init(abandon: @escaping @Sendable (Value) -> Void) {
        self.abandon = abandon
    }

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        perform(
            state.withLock { state -> Action in
                if state.cancelled {
                    state.resumed = true
                    return .resume(continuation, .failure(TransportError.cancelled))
                }
                if let pending = state.pending {
                    state.resumed = true
                    state.pending = nil
                    return .resume(continuation, pending)
                }
                state.continuation = continuation
                return .none
            })
    }

    func finish(_ result: Result<Value, any Error>) {
        perform(
            state.withLock { state -> Action in
                if state.resumed || state.cancelled {
                    if case .success(let value) = result { return .abandon(value) }
                    return .none
                }
                guard let continuation = state.continuation else {
                    state.pending = result
                    return .none
                }
                state.continuation = nil
                state.resumed = true
                return .resume(continuation, result)
            })
    }

    func cancel() {
        perform(
            state.withLock { state -> Action in
                guard !state.resumed, !state.cancelled else { return .none }
                state.cancelled = true
                if let continuation = state.continuation {
                    state.continuation = nil
                    state.resumed = true
                    return .resume(continuation, .failure(TransportError.cancelled))
                }
                if case .success(let value) = state.pending {
                    state.pending = nil
                    return .abandon(value)
                }
                return .none
            })
    }

    private func perform(_ action: Action) {
        switch action {
        case .none:
            break
        case .resume(let continuation, let result):
            continuation.resume(with: result)
        case .abandon(let value):
            abandon(value)
        }
    }
}
