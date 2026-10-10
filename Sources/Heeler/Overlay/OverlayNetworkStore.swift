import Foundation
import HeelerOverlay
import Observation

enum OverlayNetworkPrimaryAction: Equatable {
    case signIn, connect, connecting, disconnect
}

/// What a network offers at the trailing edge of its row and status: a
/// switch that keeps it connected, or, while something is in progress, the
/// button that shows it. A Tailscale network without a login offers Sign In.
enum OverlayNetworkControl: Equatable {
    case signIn
    /// A Connect in progress; Cancel stops it.
    case connecting
    /// A Sign Out in progress; it cannot be stopped.
    case signingOut
    case toggle(isOn: Bool)
}

enum OverlayNetworkStoreError: Error, Equatable {
    /// `update`/`remove` addressed a network the catalog does not contain.
    case unknownNetwork
    /// Persisted bytes could not be decoded; they are left untouched so a
    /// later write cannot turn a recoverable catalog into loss.
    case catalogUnreadable
    /// The chosen file is not a ZeroTier planet (wrong size or type).
    case invalidZeroTierPlanet
    /// The chosen file is a moon definition, which is not a planet.
    case zeroTierPlanetIsMoon
    /// The planet file could not be read.
    case zeroTierPlanetNotSaved

    var message: String {
        switch self {
        case .unknownNetwork:
            "The network no longer exists."
        case .catalogUnreadable:
            "The saved overlay networks could not be read, so nothing can be changed. "
                + "They may have been saved by a newer version of Heeler."
        case .invalidZeroTierPlanet:
            "That file is not a ZeroTier planet. Use the planet file your roots' operator "
                + "provides (as made by mkworld); it is at most 16 KB."
        case .zeroTierPlanetIsMoon:
            "That file defines a moon, not a planet. Add moons to a ZeroTier network by "
                + "world ID and seed instead."
        case .zeroTierPlanetNotSaved:
            "The planet file could not be read."
        }
    }
}

/// Owns the Overlay Network catalog: add/edit/remove, persistence, and the
/// status the Settings screen shows. Settings go to UserDefaults (no secrets
/// in them); auth keys and network secrets go to the injected `SecretStore`
/// (the Keychain under `OverlaySecretAccount.service`).
///
/// Every save publishes the catalog to the `OverlayNetworkRuntime`
/// synchronously and then lets it stop nodes the change made stale.
@MainActor
@Observable
final class OverlayNetworkStore {
    private static let defaultsKey = "overlayNetworks"
    private static let knownLoginsKey = "overlayKnownTailscaleLogins"
    private static let catalogVersion = 1

    /// Decodes each network separately so a kind added by a newer build
    /// hides only that entry here, and survives this build's writes.
    private struct PersistedNetworks: Codable {
        enum Entry {
            case known(OverlayNetwork)
            case unknown(JSONValue)

            var knownNetwork: OverlayNetwork? {
                guard case .known(let network) = self else { return nil }
                return network
            }

            /// The id of an entry this build cannot run, so its state
            /// directory is left alone.
            var unknownID: UUID? {
                guard case .unknown(let raw) = self else { return nil }
                return raw["id"]?.stringValue.flatMap(UUID.init(uuidString:))
            }
        }

        let entries: [Entry]

        init(entries: [Entry]) {
            self.entries = entries
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var entries: [Entry] = []
            while !container.isAtEnd {
                let raw = try container.decode(JSONValue.self)
                guard let kind = raw["kind"]?.stringValue else {
                    throw OverlayNetworkStoreError.catalogUnreadable
                }
                guard OverlayKind(rawValue: kind) != nil else {
                    entries.append(.unknown(raw))
                    continue
                }
                // An EasyTier source a newer build added is kept the same way.
                if kind == OverlayKind.easytier.rawValue,
                    let source = raw["source"]?.stringValue,
                    OverlayNetwork.EasyTierSource(rawValue: source) == nil
                {
                    entries.append(.unknown(raw))
                    continue
                }
                let data = try JSONEncoder().encode(raw)
                entries.append(.known(try JSONDecoder().decode(OverlayNetwork.self, from: data)))
            }
            self.entries = entries
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            for entry in entries {
                switch entry {
                case .known(let network): try container.encode(network)
                case .unknown(let raw): try container.encode(raw)
                }
            }
        }
    }

    private struct PersistedCatalog: Codable {
        let version: Int
        let networks: PersistedNetworks
    }

    private(set) var networks: [OverlayNetwork]
    private(set) var catalogLoadError: OverlayNetworkStoreError?
    /// Last observed node status per network; absent means never started.
    private(set) var statuses: [OverlayNetwork.ID: OverlayNodeStatus] = [:]
    /// The failure of the last explicit Connect, cleared by the next one.
    private(set) var connectFailures: [OverlayNetwork.ID: TransportError] = [:]
    private(set) var connecting: Set<OverlayNetwork.ID> = []
    @ObservationIgnored private var connectAttempts: [OverlayNetwork.ID: Task<(any Error)?, Never>] = [:]
    /// What each network's node last reported about itself and its peers;
    /// absent or empty while it has no node.
    private(set) var details: [OverlayNetwork.ID: OverlayNodeDetails] = [:]
    private(set) var signingOut: Set<OverlayNetwork.ID> = []
    /// The failure of the last Sign Out, cleared by the next one or Connect.
    private(set) var signOutFailures: [OverlayNetwork.ID: TransportError] = [:]
    /// Tailscale networks signed out and not connected again since.
    private(set) var signedOut: Set<OverlayNetwork.ID> = []
    /// A presentation hint, never an authorization decision. Only a live
    /// node can confirm whether a saved login is still usable.
    private var knownTailscaleLogins: Set<OverlayNetwork.ID> = []
    private var pendingBrowserSignIns: Set<OverlayNetwork.ID> = []
    @ObservationIgnored private var signInResumeTask: Task<Void, Never>?
    /// The node ID of the device's ZeroTier identity in the Keychain.
    private(set) var zeroTierIdentityNodeID: String?
    /// No identity could be created ahead of time (the generator failed,
    /// or a node is minting its own); one appears after the first connect.
    private(set) var zeroTierIdentityDeferred = false

    let runtime: OverlayNetworkRuntime
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults?
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var entries: [PersistedNetworks.Entry] = []
    /// In-memory counters per network: settings-or-secret changes rebuild
    /// the node; secret changes also drop a Tailscale login. A rename
    /// bumps neither.
    @ObservationIgnored private var revisions: [OverlayNetwork.ID: Int] = [:]
    @ObservationIgnored private var secretRevisions: [OverlayNetwork.ID: Int] = [:]

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(service: OverlaySecretAccount.service),
        runtime: OverlayNetworkRuntime = .shared
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.runtime = runtime
        networks = []
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                let catalog = try JSONDecoder().decode(PersistedCatalog.self, from: data)
                guard catalog.version == Self.catalogVersion else {
                    throw OverlayNetworkStoreError.catalogUnreadable
                }
                entries = catalog.networks.entries
                networks = entries.compactMap(\.knownNetwork)
            } catch {
                catalogLoadError = .catalogUnreadable
                // The runtime reports its own reason instead of treating
                // every network as removed, and deletes no state.
                runtime.markCatalogUnreadable()
                return
            }
        }
        knownTailscaleLogins = Set(
            (defaults.stringArray(forKey: Self.knownLoginsKey) ?? []).compactMap(UUID.init(uuidString:)))
            .intersection(networks.filter { $0.kind == .tailscale }.map(\.id))
        migrateLegacyZeroTierPlanet()
        publish()
        refreshZeroTierDeviceState()
    }

    /// A process-local catalog for previews and tests that never touches
    /// UserDefaults or the Keychain.
    init(volatileNetworks: [OverlayNetwork], runtime: OverlayNetworkRuntime) {
        defaults = nil
        secrets = VolatileSecretStore()
        self.runtime = runtime
        networks = volatileNetworks
        entries = volatileNetworks.map(PersistedNetworks.Entry.known)
        publish()
        refreshZeroTierDeviceState()
    }

    func network(id: OverlayNetwork.ID) -> OverlayNetwork? {
        networks.first { $0.id == id }
    }

    /// Adds a network, storing `secret` when its kind has one and it is given.
    func add(_ network: OverlayNetwork, secret: String? = nil) throws {
        try ensureCatalogIsWritable()
        try applySecret(secret, to: network)
        networks.append(network)
        entries.append(.known(network))
        try persist()
    }

    /// Replaces the network with the same id. `secret` nil keeps the stored
    /// one, so editing a name never requires re-entering a key.
    func update(_ network: OverlayNetwork, secret: String? = nil) throws {
        try ensureCatalogIsWritable()
        guard let index = networks.firstIndex(where: { $0.id == network.id }) else {
            throw OverlayNetworkStoreError.unknownNetwork
        }
        let previous = networks[index]
        let settingsChanged = previous.settings != network.settings
        let secretChanged = try applySecret(secret, to: network)
        // Switching an EasyTier network's source moves its secret to another
        // account; the old one must not linger in the Keychain.
        if let oldAccount = OverlaySecretAccount.secret(for: previous),
            oldAccount != OverlaySecretAccount.secret(for: network)
        {
            try secrets.removeSecret(account: oldAccount)
        }
        if settingsChanged || secretChanged {
            cancelConnect(network.id)
            revisions[network.id, default: 0] += 1
        }
        let loginChanged: Bool
        switch (previous.settings, network.settings) {
        case (.tailscale(_, let oldServer), .tailscale(_, let newServer)):
            loginChanged = oldServer != newServer || secretChanged
        default:
            loginChanged = previous.kind != network.kind
        }
        if loginChanged {
            setKnownTailscaleLogin(network.id, known: false)
            statuses[network.id] = nil
        }
        if secretChanged {
            secretRevisions[network.id, default: 0] += 1
        }
        networks[index] = network
        if let entryIndex = entries.firstIndex(where: { $0.knownNetwork?.id == network.id }) {
            entries[entryIndex] = .known(network)
        }
        connectFailures[network.id] = nil
        try persist()
    }

    /// Removes the network and its secrets. Hosts that still name it fail
    /// with `.notConfigured` until they are edited.
    func remove(_ id: OverlayNetwork.ID) throws {
        try ensureCatalogIsWritable()
        guard let index = networks.firstIndex(where: { $0.id == id }) else {
            throw OverlayNetworkStoreError.unknownNetwork
        }
        let removed = networks[index]
        if let account = OverlaySecretAccount.secret(for: removed) {
            try secrets.removeSecret(account: account)
        }
        cancelConnect(id)
        setKnownTailscaleLogin(id, known: false)
        networks.remove(at: index)
        entries.removeAll { $0.knownNetwork?.id == id }
        // The ZeroTier identity is the device's, shared by every ZeroTier
        // network; it goes only with the last of them.
        if removed.kind == .zerotier, !networks.contains(where: { $0.kind == .zerotier }) {
            try secrets.removeSecret(account: OverlaySecretAccount.zeroTierIdentity)
            zeroTierIdentityNodeID = nil
            zeroTierIdentityDeferred = false
        }
        statuses[id] = nil
        details[id] = nil
        signedOut.remove(id)
        signOutFailures[id] = nil
        connectFailures[id] = nil
        revisions[id] = nil
        secretRevisions[id] = nil
        try persist()
    }

    /// The stored secret as text, for a form that shows it while editing
    /// (a config server URL); nil when none.
    func secretText(for network: OverlayNetwork) -> String? {
        guard
            let account = OverlaySecretAccount.secret(for: network),
            let data = (try? secrets.read(account: account)) ?? nil, !data.isEmpty
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Gives a config-server network a new machine ID, so its console lists
    /// this device as a new one. Rebuilds the node like any settings change.
    func resetMachineID(_ id: OverlayNetwork.ID, to machineID: UUID = UUID()) throws {
        guard
            var network = network(id: id),
            case .easytierConfigServer(let server, _, let hostname, let requireEncryption) = network.settings
        else { throw OverlayNetworkStoreError.unknownNetwork }
        network.settings = .easytierConfigServer(
            server: server, machineID: machineID, hostname: hostname, requireEncryption: requireEncryption)
        try update(network)
    }

    /// Whether a typed secret (auth key, network secret) is stored.
    func hasSecret(for network: OverlayNetwork) -> Bool {
        guard let account = OverlaySecretAccount.secret(for: network) else { return false }
        return ((try? secrets.read(account: account)) ?? nil).map { !$0.isEmpty } ?? false
    }

    // MARK: Node status

    func primaryAction(for network: OverlayNetwork) -> OverlayNetworkPrimaryAction {
        if connecting.contains(network.id) { return .connecting }
        if statuses[network.id]?.isOnline == true { return .disconnect }
        return needsSignIn(network) ? .signIn : .connect
    }

    func control(for network: OverlayNetwork) -> OverlayNetworkControl {
        let id = network.id
        if signingOut.contains(id) { return .signingOut }
        if connecting.contains(id) { return .connecting }
        if needsSignIn(network) { return .signIn }
        return .toggle(isOn: statuses[id]?.isRunning ?? false)
    }

    /// Whether a Tailscale network has no usable login, so starting it
    /// means a browser sign-in; false while it is online. Unlike
    /// `primaryAction`, it holds while a Connect is in progress.
    func needsSignIn(_ network: OverlayNetwork) -> Bool {
        let id = network.id
        guard network.kind == .tailscale, statuses[id]?.isOnline != true else { return false }
        if case .needsLogin = statuses[id] { return true }
        if connectFailures[id]?.overlayLoginURL != nil || signedOut.contains(id) { return true }
        return !knownTailscaleLogins.contains(id) && !hasSecret(for: network)
    }

    /// One user action both starts the node and obtains its current login
    /// link. Starting again also replaces links left by a suspended node.
    /// The view opens the result only while its initiating task is alive.
    func signIn(_ id: OverlayNetwork.ID, timeout: Duration = .seconds(30)) async -> URL? {
        guard let network = network(id: id), network.kind == .tailscale,
            !signingOut.contains(id)
        else { return nil }
        let revision = revisions[id]
        guard await connect(id, timeout: timeout), !Task.isCancelled,
            revisions[id] == revision, self.network(id: id) != nil,
            statuses[id]?.isOnline != true
        else { return nil }
        let candidate: URL?
        if case .needsLogin(let url) = statuses[id] {
            candidate = url
        } else {
            candidate = connectFailures[id]?.overlayLoginURL
        }
        guard let url = candidate, network.acceptsLoginURL(url) else { return nil }
        pendingBrowserSignIns.insert(id)
        return url
    }

    /// Called after app suspension has finished and the app is active again.
    /// Resume only an explicit browser sign-in, once, without opening a URL.
    func resumePendingSignIns() async {
        let pending = pendingBrowserSignIns
        for id in pending {
            guard !Task.isCancelled else { return }
            guard pendingBrowserSignIns.contains(id), network(id: id) != nil,
                !signingOut.contains(id)
            else { continue }
            await refreshStatus(id)
            guard !Task.isCancelled else { return }
            if pendingBrowserSignIns.contains(id), !signedOut.contains(id), statuses[id] == .stopped {
                await connect(id)
            }
            if !Task.isCancelled { pendingBrowserSignIns.remove(id) }
        }
    }

    /// Do not hold the app activity event loop while the network answers.
    /// The next suspension cancels this work before stopping the nodes.
    func resumeBrowserSignInAfterActivation() {
        let previous = signInResumeTask
        previous?.cancel()
        signInResumeTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await resumePendingSignIns()
        }
    }

    func suspend() async {
        let resuming = signInResumeTask
        resuming?.cancel()
        signInResumeTask = nil
        await resuming?.value
        await runtime.suspend()
    }

    /// Brings the network's node up, then records what it reports.
    /// `cancelConnect` (or cancelling the calling task) ends it at once; a
    /// cancelled Connect records no failure.
    @discardableResult
    func connect(_ id: OverlayNetwork.ID, timeout: Duration = .seconds(30)) async -> Bool {
        guard !connecting.contains(id), !signingOut.contains(id) else { return false }
        connecting.insert(id)
        connectFailures[id] = nil
        signOutFailures[id] = nil
        let runtime = runtime
        let attempt = Task { () -> (any Error)? in
            do {
                try await runtime.start(networkID: id, timeout: timeout)
                return nil
            } catch {
                return error
            }
        }
        connectAttempts[id] = attempt
        let failure = await withTaskCancellationHandler {
            await attempt.value
        } onCancel: {
            attempt.cancel()
        }
        // Cancelled meanwhile: `cancelConnect` already settled the state,
        // and a newer Connect may own it now.
        guard connectAttempts[id] == attempt else { return false }
        connectAttempts[id] = nil
        connecting.remove(id)
        switch failure {
        case nil, TransportError.cancelled?, is CancellationError:
            break
        case let error as TransportError:
            connectFailures[id] = error
        case let error?:
            connectFailures[id] = .channelFailed(detail: String(describing: error))
        }
        await refreshStatus(id)
        if Task.isCancelled { return false }
        switch failure {
        case TransportError.cancelled?, is CancellationError: return false
        default: return true
        }
    }

    /// Stops waiting for a Connect in progress: Settings is usable again at
    /// once, and no failure is shown. The runtime stops a node that never
    /// came up (a ZeroTier network stays joined; see
    /// `OverlayNetworkRuntime.start`).
    func cancelConnect(_ id: OverlayNetwork.ID) {
        pendingBrowserSignIns.remove(id)
        guard let attempt = connectAttempts.removeValue(forKey: id) else { return }
        attempt.cancel()
        connecting.remove(id)
        connectFailures[id] = nil
        Task { await self.refreshStatus(id) }
    }

    func disconnect(_ id: OverlayNetwork.ID) async {
        cancelConnect(id)
        connectFailures[id] = nil
        await runtime.stop(networkID: id)
        await refreshStatus(id)
    }

    /// Signs a Tailscale network's device out of its tailnet (see
    /// `OverlayNetworkRuntime.logout`). Hosts using the network lose their
    /// connections; the next Connect signs in again.
    func signOut(_ id: OverlayNetwork.ID, timeout: Duration = .seconds(15)) async {
        guard !signingOut.contains(id) else { return }
        cancelConnect(id)
        setKnownTailscaleLogin(id, known: false)
        signingOut.insert(id)
        signOutFailures[id] = nil
        connectFailures[id] = nil
        defer { signingOut.remove(id) }
        do {
            try await runtime.logout(networkID: id, timeout: timeout)
        } catch let error as TransportError {
            signOutFailures[id] = error
        } catch {
            signOutFailures[id] = .channelFailed(detail: String(describing: error))
        }
        await refreshStatus(id)
    }

    /// The network's node's raw state, for the Diagnostics screen; empty
    /// while it has no node.
    func diagnostics(_ id: OverlayNetwork.ID) async -> OverlayDiagnostics {
        await runtime.diagnostics(networkID: id)
    }

    /// Status and details together, as the detail screen polls them.
    func refreshStatus(_ id: OverlayNetwork.ID) async {
        await refreshNodeStatus(id)
        details[id] = await runtime.details(networkID: id)
        if network(id: id)?.kind == .zerotier {
            refreshZeroTierDeviceState()
        }
    }

    /// Every network's status, and the details of those online, as the
    /// network list polls them (its rows count peers).
    func refreshStatuses() async {
        for network in networks {
            await refreshNodeStatus(network.id)
            if statuses[network.id]?.isOnline == true {
                details[network.id] = await runtime.details(networkID: network.id)
            }
        }
        refreshZeroTierDeviceState()
    }

    private func refreshNodeStatus(_ id: OverlayNetwork.ID) async {
        guard network(id: id) != nil else { return }
        let revision = revisions[id]
        let status = await runtime.status(networkID: id)
        guard network(id: id) != nil, revisions[id] == revision else { return }
        statuses[id] = status
        // Browser sign-in or controller approval can finish after Connect
        // returned an error. The live node supersedes that failed attempt.
        if status.isOnline {
            connectFailures[id] = nil
            pendingBrowserSignIns.remove(id)
            if network(id: id)?.kind == .tailscale {
                setKnownTailscaleLogin(id, known: true)
            }
        } else if case .needsLogin = status {
            setKnownTailscaleLogin(id, known: false)
        } else if connectFailures[id]?.overlayLoginURL != nil {
            setKnownTailscaleLogin(id, known: false)
        }
        await refreshSignedOut(id)
    }

    private func refreshSignedOut(_ id: OverlayNetwork.ID) async {
        if await runtime.isSignedOut(id) {
            signedOut.insert(id)
            setKnownTailscaleLogin(id, known: false)
        } else {
            signedOut.remove(id)
        }
    }

    private func setKnownTailscaleLogin(_ id: OverlayNetwork.ID, known: Bool) {
        let changed: Bool
        if known {
            changed = knownTailscaleLogins.insert(id).inserted
        } else {
            changed = knownTailscaleLogins.remove(id) != nil
        }
        if changed {
            defaults?.set(knownTailscaleLogins.map(\.uuidString).sorted(), forKey: Self.knownLoginsKey)
        }
    }

    // MARK: ZeroTier device state

    /// This device's ZeroTier node ID: from the Keychain identity, or what
    /// a running ZeroTier node reports when the identity is not saved yet.
    var zeroTierNodeID: String? {
        zeroTierIdentityNodeID
            ?? networks.lazy
                .filter { $0.kind == .zerotier }
                .compactMap { self.details[$0.id]?.nodeID }
                .first
    }

    /// Makes sure the device has a ZeroTier identity before it first joins,
    /// so its node ID can be authorized up front. On failure the node
    /// mints one on first connect, as before.
    func prepareZeroTierIdentity() async {
        do {
            let identity = try await runtime.ensureZeroTierIdentity()
            zeroTierIdentityNodeID = identity.flatMap(ZeroTierIdentity.nodeID(of:))
            zeroTierIdentityDeferred = zeroTierIdentityNodeID == nil
        } catch {
            zeroTierIdentityNodeID = nil
            zeroTierIdentityDeferred = true
        }
    }

    /// An identity no ZeroTier network uses, as an earlier build's Add form
    /// made before any network was added (deleting the last network forgets
    /// it): it may already be authorized by an admin, so it stays until the
    /// user forgets it in the Add form.
    var hasUnusedZeroTierIdentity: Bool {
        zeroTierIdentityNodeID != nil && !networks.contains { $0.kind == .zerotier }
    }

    /// Forgets a pre-generated identity no ZeroTier network uses yet.
    func removeUnusedZeroTierIdentity() throws {
        guard hasUnusedZeroTierIdentity else { return }
        try secrets.removeSecret(account: OverlaySecretAccount.zeroTierIdentity)
        zeroTierIdentityNodeID = nil
        zeroTierIdentityDeferred = false
    }

    /// Reads a planet chosen in Files for a network's form, checked like
    /// any planet (`validateZeroTierPlanet`).
    nonisolated static func readZeroTierPlanet(from url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            !OverlayNetworkRuntime.zeroTierPlanetSizeLimit.contains(size)
        {
            throw OverlayNetworkStoreError.invalidZeroTierPlanet
        }
        let planet: Data
        do {
            planet = try Data(contentsOf: url)
        } catch {
            throw OverlayNetworkStoreError.zeroTierPlanetNotSaved
        }
        try validateZeroTierPlanet(planet)
        return planet
    }

    /// ZeroTier's World serialization (`World::serialize`): a type byte
    /// (1 planet, 127 moon), the world ID and timestamp (8 bytes each), the
    /// update-signing public key (64), its signature (96), and a root
    /// count. Anything shorter or of another type is not a planet.
    nonisolated static let zeroTierWorldHeaderLength = 1 + 8 + 8 + 64 + 96 + 1

    nonisolated static func validateZeroTierPlanet(_ planet: Data) throws {
        guard
            OverlayNetworkRuntime.zeroTierPlanetSizeLimit.contains(planet.count),
            let type = planet.first
        else { throw OverlayNetworkStoreError.invalidZeroTierPlanet }
        if type == 127 { throw OverlayNetworkStoreError.zeroTierPlanetIsMoon }
        guard type == 1, planet.count >= zeroTierWorldHeaderLength else {
            throw OverlayNetworkStoreError.invalidZeroTierPlanet
        }
    }

    /// Builds before per-network planets kept one custom planet for the
    /// device. It moves into every ZeroTier network that has none — the
    /// planet they all used — and the device-wide file goes. A file that is
    /// not a planet is dropped; one that cannot be saved into the catalog
    /// stays for the next launch.
    private func migrateLegacyZeroTierPlanet() {
        guard let planet = runtime.legacyZeroTierPlanet() else { return }
        if (try? Self.validateZeroTierPlanet(planet)) != nil {
            var migrated = false
            for index in networks.indices {
                guard case .zerotier(let networkID, let moons, .none) = networks[index].settings else {
                    continue
                }
                let network = OverlayNetwork(
                    id: networks[index].id, name: networks[index].name,
                    settings: .zerotier(networkID: networkID, moons: moons, planet: planet))
                networks[index] = network
                if let entryIndex = entries.firstIndex(where: { $0.knownNetwork?.id == network.id }) {
                    entries[entryIndex] = .known(network)
                }
                migrated = true
            }
            if migrated {
                do {
                    try persist()
                } catch {
                    return
                }
            }
        }
        runtime.removeLegacyZeroTierPlanet()
    }

    /// Re-reads the device-wide ZeroTier state: the identity a node may
    /// have minted and saved since.
    private func refreshZeroTierDeviceState() {
        if zeroTierIdentityNodeID == nil,
            let identity = (try? secrets.read(account: OverlaySecretAccount.zeroTierIdentity)) ?? nil,
            let nodeID = ZeroTierIdentity.nodeID(of: identity)
        {
            zeroTierIdentityNodeID = nodeID
            zeroTierIdentityDeferred = false
        }
    }

    // MARK: Persistence

    /// Writes a new secret; returns whether it differs from the stored one.
    @discardableResult
    private func applySecret(_ secret: String?, to network: OverlayNetwork) throws -> Bool {
        guard let account = OverlaySecretAccount.secret(for: network), let secret else {
            return false
        }
        let data = Data(secret.utf8)
        guard (try? secrets.read(account: account)) != data else { return false }
        try secrets.write(data, account: account)
        return true
    }

    private func ensureCatalogIsWritable() throws {
        if catalogLoadError != nil {
            throw OverlayNetworkStoreError.catalogUnreadable
        }
    }

    private func persist() throws {
        defer { publish() }
        try defaults?.set(
            JSONEncoder().encode(
                PersistedCatalog(
                    version: Self.catalogVersion,
                    networks: PersistedNetworks(entries: entries))),
            forKey: Self.defaultsKey)
    }

    private func publish() {
        runtime.publish(
            networks.map {
                OverlayNetworkRuntime.Published(
                    network: $0,
                    revision: revisions[$0.id] ?? 0,
                    secretRevision: secretRevisions[$0.id] ?? 0)
            },
            reserving: Set(entries.compactMap(\.unknownID)))
        let runtime = runtime
        Task { await runtime.reconcile() }
    }
}
