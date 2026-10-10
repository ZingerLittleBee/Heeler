import Foundation
import HeelerOverlay
import Synchronization
import Testing

@testable import Heeler

/// Events from every node of one factory, in order.
private final class EventLog: Sendable {
    let lines = Mutex<[String]>([])

    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

/// Holds a captured node status until the test changes the catalog.
private final class OverlayStatusReadGate: Sendable {
    private struct State {
        var released = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var isWaiting: Bool { state.withLock { !$0.waiters.isEmpty } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                guard !state.released else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiters = state.withLock { state in
            state.released = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A scripted overlay node: records calls and fails as told.
private final class FakeOverlayNode: OverlayNode, Sendable {
    struct State {
        var starts = 0
        var stops = 0
        var dials: [String] = []
        var status: OverlayNodeStatus = .stopped
        var statusReadGate: OverlayStatusReadGate?
        var failure: OverlayError?
        var details = OverlayNodeDetails()
        var logouts = 0
        var logoutFailure: OverlayError?
    }

    let kind: OverlayKind
    let spec: OverlayNodeSpec
    let state = Mutex(State())
    /// "n<index>.<event>" lines shared by every node of one factory, so a
    /// test can assert ordering across an old and a new node.
    let index: Int
    let events: EventLog?
    let stopDelay: Duration?

    init(
        spec: OverlayNodeSpec, index: Int = 0, events: EventLog? = nil,
        stopDelay: Duration? = nil
    ) {
        self.spec = spec
        self.index = index
        self.events = events
        self.stopDelay = stopDelay
        switch spec {
        case .tailscale: kind = .tailscale
        case .zerotier: kind = .zerotier
        case .easytier: kind = .easytier
        }
    }

    func start(timeout: Duration) async throws {
        let failure = state.withLock { state -> OverlayError? in
            state.starts += 1
            if state.failure == nil { state.status = .online(addresses: ["100.64.0.2"]) }
            return state.failure
        }
        if let failure { throw failure }
    }

    func dial(host: String, port: UInt16, timeout: Duration) async throws -> OverlayDialedStream {
        log("dial")
        let failure = state.withLock { state -> OverlayError? in
            state.dials.append("\(host):\(port)")
            return state.failure
        }
        if let failure { throw failure }
        return OverlayDialedStream(descriptor: -1, release: {})
    }

    func status() async -> OverlayNodeStatus {
        let (status, gate) = state.withLock { ($0.status, $0.statusReadGate) }
        await gate?.wait()
        return status
    }

    func stop() async {
        log("stop.begin")
        if let stopDelay { try? await Task.sleep(for: stopDelay) }
        state.withLock {
            $0.stops += 1
            $0.status = .stopped
        }
        log("stop.end")
    }

    func details() async -> OverlayNodeDetails {
        state.withLock { $0.details }
    }

    func logout(timeout: Duration) async throws {
        log("logout")
        let failure = state.withLock { state -> OverlayError? in
            state.logouts += 1
            state.status = .stopped
            return state.logoutFailure
        }
        if let failure { throw failure }
    }

    private func log(_ event: String) {
        events?.append("n\(index).\(event)")
    }
}

/// Builds fake nodes and keeps them for inspection, plus the ZeroTier
/// identity callback the runtime handed over.
private final class FakeNodeFactory: Sendable {
    let nodes = Mutex<[FakeOverlayNode]>([])
    let identityCallbacks = Mutex<[@Sendable (Data) -> Void]>([])
    /// Applied to each node as it is built.
    let failure = Mutex<OverlayError?>(nil)
    let events = EventLog()
    let stopDelay: Duration?

    init(stopDelay: Duration? = nil) {
        self.stopDelay = stopDelay
    }

    var make: OverlayNetworkRuntime.NodeFactory {
        { spec, identityGenerated in
            let index = self.nodes.withLock { $0.count }
            let node = FakeOverlayNode(
                spec: spec, index: index, events: self.events, stopDelay: self.stopDelay)
            let failure = self.failure.withLock { $0 }
            node.state.withLock { $0.failure = failure }
            self.nodes.withLock { $0.append(node) }
            self.identityCallbacks.withLock { $0.append(identityGenerated) }
            return node
        }
    }

    var built: [FakeOverlayNode] { nodes.withLock { $0 } }
}

private func temporaryStateRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("overlay-tests-\(UUID().uuidString)", isDirectory: true)
}

private let tailnet = OverlayNetwork(
    name: "Home", settings: .tailscale(hostname: "heeler", controlURL: nil))

@Suite("Overlay Network on Host")
struct HostOverlayNetworkTests {
    @Test func hostsSavedBeforeOverlayNetworksDecodeAsDirect() throws {
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"Old","address":"old.example","port":22,
             "username":"dev","authMethod":"deviceKey","jumpAddress":"","jumpPort":22,
             "jumpUsername":""}
            """

        let host = try JSONDecoder().decode(Host.self, from: Data(legacy.utf8))

        #expect(host.overlayNetworkID == nil)
    }

    @Test func overlayNetworkIDRoundTripsThroughCoding() throws {
        let host = Host(
            address: "box.tailnet.ts.net", username: "dev", overlayNetworkID: UUID())

        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))

        #expect(decoded == host)
        #expect(decoded.overlayNetworkID == host.overlayNetworkID)
    }

    @Test func draftPrefillsAndRebuildsTheOverlayChoice() throws {
        let host = Host(
            address: "100.64.0.7", username: "dev", jumpAddress: "jump.ts.net",
            overlayNetworkID: UUID())

        var draft = HostDraft(host: host)
        #expect(draft.overlayNetworkID == host.overlayNetworkID)
        #expect(try #require(draft.makeHost(id: host.id)) == host)

        draft.overlayNetworkID = nil
        #expect(try #require(draft.makeHost(id: host.id)).overlayNetworkID == nil)
    }

    @Test func transportSettingsRouteOnlyHostsThatNameANetwork() async throws {
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: FakeNodeFactory().make)
        runtime.publish([.init(network: tailnet, revision: 0)])
        let policy = HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false }

        let direct = SSHTransportSettings(
            host: Host(address: "box", username: "dev"),
            credentials: .password("x"), hostKeyPolicy: policy, overlays: runtime)
        #expect(direct.overlay == nil)

        let routed = SSHTransportSettings(
            host: Host(address: "box", username: "dev", overlayNetworkID: tailnet.id),
            credentials: .password("x"), hostKeyPolicy: policy, overlays: runtime)
        #expect(routed.overlay?.networkName == "Home")
    }
}

@Suite("Overlay Network draft")
struct OverlayNetworkDraftTests {
    @Test func zeroTierNeedsExactlySixteenHexDigits() {
        var draft = OverlayNetworkDraft()
        draft.kind = .zerotier
        draft.networkID = "8056c2e21c00000"
        #expect(!draft.isValid)
        draft.networkID = "8056c2e21c000001"
        #expect(draft.isValid)
        draft.networkID = "8056c2e21c00000g"
        #expect(!draft.isValid)
    }

    @Test func tailscaleControlURLIsOptionalButMustBeAWebURL() throws {
        var draft = OverlayNetworkDraft()
        #expect(draft.isValid)
        draft.controlURL = "not a url"
        #expect(!draft.isValid)
        draft.controlURL = "https://headscale.example"
        let network = try #require(draft.makeNetwork())
        #expect(
            network.settings
                == .tailscale(
                    hostname: "heeler", controlURL: URL(string: "https://headscale.example")))
    }

    @Test func easyTierRequiresASecretUnlessOneIsStored() {
        var draft = OverlayNetworkDraft()
        draft.kind = .easytier
        draft.networkName = "lab"
        draft.peers = "tcp://a.example:11010,\n tcp://b.example:11010 "
        #expect(draft.peerList == ["tcp://a.example:11010", "tcp://b.example:11010"])
        #expect(!draft.canSave(hasStoredSecret: false))
        #expect(draft.canSave(hasStoredSecret: true))
        draft.secret = "  s3cret "
        #expect(draft.canSave(hasStoredSecret: false))
        #expect(draft.secretUpdate == "s3cret")
    }

    @Test func prefillRoundTripsEveryKind() throws {
        let networks = [
            tailnet,
            OverlayNetwork(name: "ZT", settings: .zerotier(networkID: "8056c2e21c000001")),
            OverlayNetwork(
                name: "ET",
                settings: .easytier(
                    networkName: "lab", peers: ["tcp://a.example:11010"], hostname: "phone")),
        ]
        for network in networks {
            let rebuilt = try #require(OverlayNetworkDraft(network: network).makeNetwork(id: network.id))
            #expect(rebuilt == network)
        }
    }
}

@MainActor
@Suite("Overlay Network store")
struct OverlayNetworkStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "overlay-network-store-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func makeRuntime(_ factory: FakeNodeFactory = FakeNodeFactory()) -> OverlayNetworkRuntime {
        OverlayNetworkRuntime(secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
    }

    @Test func networksAndSecretsPersistAcrossInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = VolatileSecretStore()
        let store = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: makeRuntime())
        let easyTier = OverlayNetwork(
            name: "Lab", settings: .easytier(networkName: "lab", peers: ["tcp://p:1"], hostname: "h"))

        try store.add(tailnet, secret: "tskey-auth-1")
        try store.add(easyTier, secret: "shared")

        let reloaded = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: makeRuntime())
        #expect(reloaded.networks == [tailnet, easyTier])
        #expect(reloaded.hasSecret(for: tailnet))
        #expect(
            try secrets.read(account: "overlay-easytier-secret-\(easyTier.id.uuidString)")
                == Data("shared".utf8))
    }

    @Test func updateWithoutASecretKeepsTheStoredOne() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = VolatileSecretStore()
        let store = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: makeRuntime())
        try store.add(tailnet, secret: "tskey-auth-1")

        var renamed = tailnet
        renamed.name = "Office"
        try store.update(renamed)

        #expect(store.networks == [renamed])
        #expect(
            try secrets.read(account: "overlay-tailscale-authkey-\(tailnet.id.uuidString)")
                == Data("tskey-auth-1".utf8))
    }

    @Test func unknownKindIsHiddenButSurvivesWrites() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let futureID = UUID()
        let stored = """
            {"version":1,"networks":[
              {"id":"\(futureID.uuidString)","name":"Future","kind":"netbird","setupKey":"k"}
            ]}
            """
        defaults.set(Data(stored.utf8), forKey: "overlayNetworks")

        let store = OverlayNetworkStore(
            defaults: defaults, secrets: VolatileSecretStore(), runtime: makeRuntime())
        #expect(store.networks.isEmpty)
        #expect(store.catalogLoadError == nil)
        try store.add(tailnet)

        let data = try #require(defaults.data(forKey: "overlayNetworks"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("netbird"))
        #expect(text.contains("setupKey"))
        #expect(text.contains(tailnet.id.uuidString))
    }

    @Test func corruptCatalogIsNotOverwritten() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(Data("{not json".utf8), forKey: "overlayNetworks")

        let store = OverlayNetworkStore(
            defaults: defaults, secrets: VolatileSecretStore(), runtime: makeRuntime())

        #expect(store.catalogLoadError == .catalogUnreadable)
        #expect(throws: OverlayNetworkStoreError.catalogUnreadable) { try store.add(tailnet) }
        #expect(defaults.data(forKey: "overlayNetworks") == Data("{not json".utf8))
    }

    @Test func removalDeletesSecretsAndTheLastZeroTierTakesTheIdentity() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = VolatileSecretStore()
        let store = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: makeRuntime())
        let first = OverlayNetwork(name: "A", settings: .zerotier(networkID: "8056c2e21c000001"))
        let second = OverlayNetwork(name: "B", settings: .zerotier(networkID: "8056c2e21c000002"))
        try store.add(tailnet, secret: "tskey")
        try store.add(first)
        try store.add(second)
        try secrets.write(Data("identity".utf8), account: OverlaySecretAccount.zeroTierIdentity)

        try store.remove(tailnet.id)
        try store.remove(first.id)
        #expect(!store.hasSecret(for: tailnet))
        #expect(try secrets.read(account: OverlaySecretAccount.zeroTierIdentity) != nil)

        try store.remove(second.id)
        #expect(try secrets.read(account: OverlaySecretAccount.zeroTierIdentity) == nil)
        #expect(throws: OverlayNetworkStoreError.unknownNetwork) { try store.remove(second.id) }
    }

    @Test(arguments: [false, true])
    func interactiveLoginRecoveryClearsFailure(refreshList: Bool) async throws {
        let factory = FakeNodeFactory()
        let login = try #require(URL(string: "https://login.tailscale.com/a/1"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: makeRuntime(factory))

        await store.connect(tailnet.id)
        let node = try #require(factory.built.first)
        node.state.withLock { $0.status = .needsLogin(login) }
        if refreshList { await store.refreshStatuses() } else { await store.refreshStatus(tailnet.id) }
        #expect(store.connectFailures[tailnet.id]?.overlayLoginURL == login)
        #expect(
            OverlayStatusCopy.summary(store.statuses[tailnet.id], failure: store.connectFailures[tailnet.id])
                == "Needs sign-in")

        // Browser authorization completes on the existing node without another Connect.
        node.state.withLock { $0.status = .online(addresses: ["100.64.0.2"]) }
        if refreshList { await store.refreshStatuses() } else { await store.refreshStatus(tailnet.id) }
        #expect(store.connectFailures[tailnet.id] == nil)
        #expect(store.connectFailures[tailnet.id]?.overlayLoginURL == nil)
        #expect(
            OverlayStatusCopy.summary(store.statuses[tailnet.id], failure: store.connectFailures[tailnet.id])
                == "Connected")
        #expect(
            OverlayStatusCopy.explanation(store.statuses[tailnet.id], failure: store.connectFailures[tailnet.id])
                == nil)
        #expect(node.state.withLock { $0.starts } == 1)
    }

    @Test func connectRecordsTheNodeStatusOrItsFailure() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: makeRuntime(factory))

        await store.connect(tailnet.id)
        #expect(store.statuses[tailnet.id] == .online(addresses: ["100.64.0.2"]))
        #expect(store.connectFailures[tailnet.id] == nil)

        await store.disconnect(tailnet.id)
        #expect(store.statuses[tailnet.id] == .stopped)

        let login = try #require(URL(string: "https://login.tailscale.com/a/1"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        await store.connect(tailnet.id)
        #expect(
            store.connectFailures[tailnet.id]
                == .overlayFailed(network: "Home", reason: .loginRequired(login)))
    }
}

@MainActor
@Suite("Overlay Network sign-in")
struct OverlayNetworkSignInTests {
    private func makeRuntime(
        _ factory: FakeNodeFactory,
        secrets: any SecretStore = VolatileSecretStore(),
        stateRoot: URL = temporaryStateRoot()
    ) -> OverlayNetworkRuntime {
        OverlayNetworkRuntime(secrets: secrets, stateRoot: stateRoot, makeNode: factory.make)
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "overlay-network-sign-in-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func firstSignInReturnsTheLoginAndLaterReconnectUsesTheSavedSession() async throws {
        let factory = FakeNodeFactory()
        let login = try #require(URL(string: "https://login.tailscale.com/a/sign-in"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: makeRuntime(factory))

        #expect(store.primaryAction(for: tailnet) == .signIn)
        #expect(await store.signIn(tailnet.id) == login)
        #expect(store.primaryAction(for: tailnet) == .signIn)

        let node = try #require(factory.built.first)
        node.state.withLock { $0.status = .online(addresses: ["100.64.0.2"]) }
        await store.refreshStatus(tailnet.id)
        #expect(store.primaryAction(for: tailnet) == .disconnect)
        #expect(store.connectFailures[tailnet.id] == nil)

        await store.disconnect(tailnet.id)
        #expect(store.primaryAction(for: tailnet) == .connect)
        factory.failure.withLock { $0 = nil }
        await store.connect(tailnet.id)
        #expect(store.primaryAction(for: tailnet) == .disconnect)
        #expect(factory.built.count == 2)
    }

    @Test func storedNativeLoginCanConnectWithoutAnInterfaceHintOrBrowserURL() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: makeRuntime(factory))

        // An upgrade may have native login state without the new UI hint.
        #expect(store.primaryAction(for: tailnet) == .signIn)
        #expect(await store.signIn(tailnet.id) == nil)
        #expect(store.primaryAction(for: tailnet) == .disconnect)
        #expect(factory.built.first?.state.withLock { $0.starts } == 1)
    }

    @Test func authKeyUsesConnectUntilTheNodeActuallyRequiresSignIn() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [], runtime: makeRuntime(factory))
        try store.add(tailnet, secret: "tskey-auth-test")
        #expect(store.primaryAction(for: tailnet) == .connect)

        let login = try #require(URL(string: "https://login.tailscale.com/a/expired-key"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        await store.connect(tailnet.id)
        let node = try #require(factory.built.first)
        node.state.withLock { $0.status = .needsLogin(login) }
        await store.refreshStatus(tailnet.id)

        #expect(store.hasSecret(for: tailnet))
        #expect(store.primaryAction(for: tailnet) == .signIn)
    }

    @Test func theSwitchFollowsWhetherTheNodeIsUp() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [], runtime: makeRuntime(factory))
        try store.add(tailnet, secret: "tskey-auth-test")
        #expect(store.control(for: tailnet) == .toggle(isOn: false))

        await store.connect(tailnet.id)
        #expect(store.control(for: tailnet) == .toggle(isOn: true))

        let node = try #require(factory.built.first)
        node.state.withLock { $0.status = .failed("boom") }
        await store.refreshStatus(tailnet.id)
        #expect(store.control(for: tailnet) == .toggle(isOn: false))
    }

    @Test func withoutALoginTheNetworkOffersSignInUntilItIsOnline() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: makeRuntime(factory))
        #expect(store.control(for: tailnet) == .signIn)
        let headline = OverlayNetworkHeadline(network: tailnet, store: store)
        #expect(headline.title == "Sign in to Tailscale")
        #expect(headline.rowSummary == "Not signed in")
        #expect(headline.tone == .attention)

        #expect(await store.signIn(tailnet.id) == nil)
        #expect(store.control(for: tailnet) == .toggle(isOn: true))
        #expect(OverlayNetworkHeadline(network: tailnet, store: store).title == "Connected")
    }

    @Test func aTailscaleDeviceAwaitingApprovalWaitsWithItsSwitchOn() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [], runtime: makeRuntime(factory))
        try store.add(tailnet, secret: "tskey-auth-test")
        await store.connect(tailnet.id)
        let node = try #require(factory.built.first)
        node.state.withLock {
            $0.status = .waiting("This device is waiting for approval by a tailnet admin.")
        }
        await store.refreshStatus(tailnet.id)

        #expect(store.control(for: tailnet) == .toggle(isOn: true))
        let headline = OverlayNetworkHeadline(network: tailnet, store: store)
        #expect(headline.isAwaitingApproval)
        #expect(headline.title == "Waiting for approval")
        #expect(headline.rowSummary == "Waiting for approval")
        #expect(headline.subtitle == "An admin must approve heeler before it joins.")
        #expect(headline.tone == .attention)
        #expect(headline.symbol == "hourglass")
    }

    @Test func aZeroTierNodeAwaitingAuthorizationSaysWhoMustActAndWhere() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [zeroTierLab], runtime: makeRuntime(factory))
        await store.connect(zeroTierLab.id)
        let node = try #require(factory.built.first)
        node.state.withLock {
            $0.status = .waiting("Waiting for authorization of node e2f4a91c07 on ZeroTier network 8056c2e21c000001")
        }
        await store.refreshStatus(zeroTierLab.id)

        #expect(store.control(for: zeroTierLab) == .toggle(isOn: true))
        let headline = OverlayNetworkHeadline(network: zeroTierLab, store: store)
        #expect(headline.title == "Waiting for authorization")
        #expect(headline.rowSummary == "Waiting for authorization")
        #expect(headline.subtitle == "An admin must authorize this device on 8056c2e21c000001.")
        #expect(headline.symbol == "hourglass")
        #expect(headline.tone == .attention)
        #expect(
            zeroTierLab.zeroTierCentralURL?.absoluteString
                == "https://my.zerotier.com/network/8056c2e21c000001")
        // A custom planet's controller is self-hosted, not in Central.
        var custom = zeroTierLab
        custom.settings = .zerotier(networkID: "8056c2e21c000001", planet: Data([1]))
        #expect(custom.zeroTierCentralURL == nil)
    }

    @Test func aConfigServerNodeSaysWhetherItReachesTheServerOrWaitsForANetwork() async throws {
        let cloud = OverlayNetwork(
            name: "Cloud",
            settings: .easytierConfigServer(
                server: "udp://config-server.easytier.cn:22020", machineID: UUID(), hostname: "phone"))
        let factory = FakeNodeFactory()
        let secrets = VolatileSecretStore()
        try secrets.write(
            Data("udp://config-server.easytier.cn:22020/alice".utf8),
            account: try #require(OverlaySecretAccount.secret(for: cloud)))
        let store = OverlayNetworkStore(
            volatileNetworks: [cloud], runtime: makeRuntime(factory, secrets: secrets))
        await store.connect(cloud.id)
        let node = try #require(factory.built.first)
        node.state.withLock {
            $0.failure = .startFailed("still waiting")
            $0.status = .waiting(OverlayWaitReason.configServerConnectionDetail)
        }
        // A Connect that ended while the node still reaches the server.
        await store.connect(cloud.id)
        #expect(store.connectFailures[cloud.id] != nil)
        var headline = OverlayNetworkHeadline(network: cloud, store: store)
        #expect(headline.title == "Connecting…")
        #expect(headline.subtitle == "config-server.easytier.cn")
        #expect(headline.symbol == "pause.fill")
        #expect(headline.tone == .busy)

        node.state.withLock {
            $0.status = .waiting(
                "Assign a network to this device (machine ID x) in the EasyTier console")
        }
        await store.refreshStatus(cloud.id)
        headline = OverlayNetworkHeadline(network: cloud, store: store)
        #expect(headline.title == "Waiting for a network")
        #expect(headline.rowSummary == "Waiting for a network")
        #expect(headline.subtitle == "Assign one to this device in the EasyTier console.")
        #expect(headline.tone == .attention)
    }

    @Test func aConfigServerWithARefusedNetworkCountsTheRunningOnes() async throws {
        let cloud = OverlayNetwork(
            name: "Cloud",
            settings: .easytierConfigServer(
                server: "udp://config-server.easytier.cn:22020", machineID: UUID(), hostname: "phone"))
        let factory = FakeNodeFactory()
        let secrets = VolatileSecretStore()
        try secrets.write(
            Data("udp://config-server.easytier.cn:22020/alice".utf8),
            account: try #require(OverlaySecretAccount.secret(for: cloud)))
        let store = OverlayNetworkStore(
            volatileNetworks: [cloud], runtime: makeRuntime(factory, secrets: secrets))
        await store.connect(cloud.id)
        let node = try #require(factory.built.first)
        let home = OverlayAssignedNetwork(
            id: "i1", name: "home", isRunning: true, address: "10.144.144.3/24", peerCount: 1)
        let peer = OverlayPeer(id: "p", name: "mac", addresses: ["10.144.144.2"], isOnline: true, network: "home")
        node.state.withLock {
            $0.details = OverlayNodeDetails(
                hostname: "phone", addresses: ["10.144.144.3"], peers: [peer],
                assignedNetworks: [
                    home, OverlayAssignedNetwork(id: "i2", name: "lab", isRunning: false, error: "overlaps home"),
                ])
        }
        await store.refreshStatus(cloud.id)
        var headline = OverlayNetworkHeadline(network: cloud, store: store)
        #expect(headline.title == "1 of 2 networks running")
        #expect(headline.rowSummary == "1 of 2 networks running")
        #expect(headline.subtitle == "lab can't run here.")
        #expect(headline.tone == .attention)

        node.state.withLock {
            $0.details.assignedNetworks[1] = OverlayAssignedNetwork(
                id: "i2", name: "lab", isRunning: true, address: "10.126.0.4/24")
        }
        await store.refreshStatus(cloud.id)
        headline = OverlayNetworkHeadline(network: cloud, store: store)
        #expect(headline.title == "Connected")
        #expect(headline.subtitle == "2 networks · 1 of 1 peer online")
        #expect(headline.tone == .ok)
    }

    @Test func aConnectedRowCountsTheOnlineMachines() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [], runtime: makeRuntime(factory))
        try store.add(tailnet, secret: "tskey-auth-test")
        await store.connect(tailnet.id)
        let node = try #require(factory.built.first)
        node.state.withLock {
            $0.details = OverlayNodeDetails(
                addresses: ["100.64.0.2"],
                peers: [
                    OverlayPeer(id: "a", name: "mac", addresses: ["100.64.0.7"], isOnline: true),
                    OverlayPeer(id: "b", name: "pi", addresses: ["100.64.0.8"], isOnline: false),
                ])
        }
        // The list's poll refreshes the details of online networks too.
        await store.refreshStatuses()

        let headline = OverlayNetworkHeadline(network: tailnet, store: store)
        #expect(headline.rowSummary == "Connected · 1 of 2 online")
        #expect(headline.subtitle == "1 of 2 machines online")
    }

    @Test func otherBackendsKeepTheirConnectAction() throws {
        let easyTier = OverlayNetwork(
            name: "Lab", settings: .easytier(networkName: "lab", peers: ["tcp://p:1"], hostname: "h"))
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(
            volatileNetworks: [zeroTierLab, easyTier], runtime: makeRuntime(factory))

        #expect(store.primaryAction(for: zeroTierLab) == .connect)
        #expect(store.primaryAction(for: easyTier) == .connect)
        #expect(factory.built.isEmpty)
    }

    @Test func successfulLoginHintSurvivesReloadRenameAndHostnameChanges() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = VolatileSecretStore()
        let factory = FakeNodeFactory()
        let runtime = makeRuntime(factory, secrets: secrets)
        let store = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: runtime)
        try store.add(tailnet)
        await store.connect(tailnet.id)
        await store.disconnect(tailnet.id)

        let reloaded = OverlayNetworkStore(
            defaults: defaults, secrets: secrets, runtime: makeRuntime(FakeNodeFactory(), secrets: secrets))
        #expect(reloaded.primaryAction(for: tailnet) == .connect)

        var renamed = tailnet
        renamed.name = "Office"
        renamed.settings = .tailscale(hostname: "heeler-iphone", controlURL: nil)
        try reloaded.update(renamed)
        await reloaded.runtime.reconcile()
        #expect(reloaded.primaryAction(for: renamed) == .connect)

        let renamedReload = OverlayNetworkStore(
            defaults: defaults, secrets: secrets, runtime: makeRuntime(FakeNodeFactory(), secrets: secrets))
        #expect(renamedReload.primaryAction(for: renamed) == .connect)
    }

    @Test func aDifferentCoordinationServerClearsTheSavedLoginHint() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = VolatileSecretStore()
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(
            defaults: defaults, secrets: secrets, runtime: makeRuntime(factory, secrets: secrets))
        try store.add(tailnet)
        await store.connect(tailnet.id)
        await store.disconnect(tailnet.id)
        #expect(store.primaryAction(for: tailnet) == .connect)

        var changed = tailnet
        let server = try #require(URL(string: "https://headscale.example"))
        changed.settings = .tailscale(hostname: "heeler", controlURL: server)
        try store.update(changed)
        await store.runtime.reconcile()
        #expect(store.primaryAction(for: changed) == .signIn)

        let reloaded = OverlayNetworkStore(
            defaults: defaults, secrets: secrets, runtime: makeRuntime(FakeNodeFactory(), secrets: secrets))
        #expect(reloaded.primaryAction(for: changed) == .signIn)
    }

    @Test func clearingAnAuthKeyAlsoClearsTheLoginHint() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [], runtime: makeRuntime(factory))
        try store.add(tailnet, secret: "tskey-auth-test")
        await store.connect(tailnet.id)
        await store.disconnect(tailnet.id)

        try store.update(tailnet, secret: "")
        await store.runtime.reconcile()
        #expect(!store.hasSecret(for: tailnet))
        #expect(store.primaryAction(for: tailnet) == .signIn)
    }

    @Test func expiredLoginClearsTheRememberedHintAcrossReload() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = VolatileSecretStore()
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(
            defaults: defaults, secrets: secrets, runtime: makeRuntime(factory, secrets: secrets))
        try store.add(tailnet)
        await store.connect(tailnet.id)

        let node = try #require(factory.built.first)
        let login = try #require(URL(string: "https://login.tailscale.com/a/expired-session"))
        node.state.withLock { $0.status = .needsLogin(login) }
        await store.refreshStatus(tailnet.id)
        #expect(store.primaryAction(for: tailnet) == .signIn)
        await store.disconnect(tailnet.id)

        let reloaded = OverlayNetworkStore(
            defaults: defaults, secrets: secrets, runtime: makeRuntime(FakeNodeFactory(), secrets: secrets))
        #expect(reloaded.primaryAction(for: tailnet) == .signIn)
    }

    @Test(arguments: [false, true])
    func explicitSignOutRequiresSignInEvenWithAnAuthKey(hasAuthKey: Bool) async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [], runtime: makeRuntime(factory))
        try store.add(tailnet, secret: hasAuthKey ? "tskey-auth-test" : nil)
        await store.connect(tailnet.id)

        await store.signOut(tailnet.id)

        #expect(store.primaryAction(for: tailnet) == .signIn)
        #expect(store.signedOut.contains(tailnet.id))
    }

    @Test func removingAndReaddingTheNetworkDoesNotKeepItsLoginHint() async throws {
        let factory = FakeNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: makeRuntime(factory))
        await store.connect(tailnet.id)
        await store.disconnect(tailnet.id)
        try store.remove(tailnet.id)
        await store.runtime.reconcile()

        try store.add(tailnet)

        #expect(store.primaryAction(for: tailnet) == .signIn)
    }

    @Test func returningFromBrowserRestartsASuspendedSignInOnlyOnce() async throws {
        let factory = FakeNodeFactory()
        let login = try #require(URL(string: "https://login.tailscale.com/a/browser-return"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        let runtime = makeRuntime(factory)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)
        #expect(await store.signIn(tailnet.id) == login)

        await runtime.suspend()
        factory.failure.withLock { $0 = nil }
        await store.resumePendingSignIns()
        #expect(store.primaryAction(for: tailnet) == .disconnect)
        #expect(factory.built.count == 2)

        // The browser-return intent must not become a general auto-connect policy.
        await runtime.suspend()
        await store.resumePendingSignIns()
        #expect(factory.built.count == 2)
        #expect(await runtime.activeNetworkIDs.isEmpty)
    }

    @Test func returningWithALiveNodeRefreshesItWithoutAnotherStart() async throws {
        let factory = FakeNodeFactory()
        let login = try #require(URL(string: "https://login.tailscale.com/a/live-return"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        let runtime = makeRuntime(factory)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)
        #expect(await store.signIn(tailnet.id) == login)
        let node = try #require(factory.built.first)
        node.state.withLock { $0.status = .online(addresses: ["100.64.0.2"]) }

        await store.resumePendingSignIns()

        #expect(store.primaryAction(for: tailnet) == .disconnect)
        #expect(node.state.withLock { $0.starts } == 1)
        #expect(factory.built.count == 1)
        await runtime.suspend()
        await store.resumePendingSignIns()
        #expect(factory.built.count == 1)
    }

    @Test func rejectedLoginURLDoesNotCreateABrowserReturnIntent() async throws {
        let factory = FakeNodeFactory()
        let login = try #require(URL(string: "http://login.tailscale.com/a/insecure"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        let runtime = makeRuntime(factory)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)

        #expect(await store.signIn(tailnet.id) == nil)
        await runtime.suspend()
        factory.failure.withLock { $0 = nil }
        await store.resumePendingSignIns()

        #expect(factory.built.count == 1)
        #expect(await runtime.activeNetworkIDs.isEmpty)
    }

    @Test(arguments: ["disconnect", "signOut", "remove"])
    func anExplicitStopDiscardsThePendingBrowserReturn(action: String) async throws {
        let factory = FakeNodeFactory()
        let login = try #require(URL(string: "https://login.tailscale.com/a/abandoned"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        let runtime = makeRuntime(factory)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)
        #expect(await store.signIn(tailnet.id) == login)

        switch action {
        case "disconnect": await store.disconnect(tailnet.id)
        case "signOut": await store.signOut(tailnet.id)
        case "remove":
            try store.remove(tailnet.id)
            await runtime.reconcile()
        default: Issue.record("Unexpected stop action")
        }
        let countAfterStop = factory.built.count
        factory.failure.withLock { $0 = nil }
        await store.resumePendingSignIns()

        #expect(factory.built.count == countAfterStop)
        #expect(await runtime.activeNetworkIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellingSignInNeverReturnsALateURLOrCreatesAResumeIntent(cancelCaller: Bool) async throws {
        let factory = BlockingNodeFactory()
        factory.hang.withLock { $0 = .milliseconds(400) }
        let login = try #require(URL(string: "https://login.tailscale.com/a/cancelled"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)

        let signingIn = Task { await store.signIn(tailnet.id) }
        let started = await eventually { factory.built.first?.state.withLock { $0.starts > 0 } == true }
        #expect(started)
        #expect(store.primaryAction(for: tailnet) == .connecting)
        if cancelCaller { signingIn.cancel() } else { store.cancelConnect(tailnet.id) }

        #expect(await signingIn.value == nil)
        #expect(store.connectFailures[tailnet.id] == nil)
        let stopped = await eventually { await runtime.activeNetworkIDs.isEmpty }
        #expect(stopped)
        await store.resumePendingSignIns()
        #expect(factory.built.count == 1)
        #expect(store.primaryAction(for: tailnet) == .signIn)
    }

    @Test func aNetworkWithoutALoginStillNeedsSignInWhileItsFirstSignInRuns() async throws {
        let factory = BlockingNodeFactory()
        factory.hang.withLock { $0 = .milliseconds(400) }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet, zeroTierLab], runtime: runtime)
        #expect(store.needsSignIn(tailnet))
        #expect(!store.needsSignIn(zeroTierLab))

        // The screen offers no Sign Out while there is no login to forget,
        // even though the action has turned to Connecting.
        let signingIn = Task { await store.signIn(tailnet.id) }
        let started = await eventually { factory.built.first?.state.withLock { $0.starts > 0 } == true }
        #expect(started)
        #expect(store.primaryAction(for: tailnet) == .connecting)
        #expect(store.needsSignIn(tailnet))
        // The switch's place shows the Connect in progress, not Sign In.
        #expect(store.control(for: tailnet) == .connecting)

        #expect(await signingIn.value == nil)
        #expect(store.primaryAction(for: tailnet) == .disconnect)
        #expect(!store.needsSignIn(tailnet))
        await store.disconnect(tailnet.id)
        #expect(!store.needsSignIn(tailnet))
    }

    @Test func suspensionCancelsABlockingBrowserReturnWithoutWaitingForItsTimeout() async throws {
        let factory = BlockingNodeFactory()
        factory.hang.withLock { $0 = nil }
        let login = try #require(URL(string: "https://login.tailscale.com/a/resume-cancelled"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)
        #expect(await store.signIn(tailnet.id) == login)
        await store.suspend()

        factory.hang.withLock { $0 = .seconds(2) }
        factory.failure.withLock { $0 = nil }
        store.resumeBrowserSignInAfterActivation()
        let restarted = await eventually {
            factory.built.count == 2 && factory.built.last?.state.withLock { $0.starts > 0 } == true
        }
        #expect(restarted)
        #expect(store.primaryAction(for: tailnet) == .connecting)

        let suspending = ContinuousClock.now
        await store.suspend()
        #expect(ContinuousClock.now - suspending < .milliseconds(800))
        let settled = await eventually { !store.connecting.contains(tailnet.id) }
        #expect(settled)
        #expect(store.connectFailures[tailnet.id] == nil)
        #expect(await runtime.activeNetworkIDs.isEmpty)

        // A second foreground can finish the interrupted browser return.
        factory.hang.withLock { $0 = nil }
        await store.resumePendingSignIns()
        #expect(factory.built.count == 3)
        #expect(store.primaryAction(for: tailnet) == .disconnect)

        await store.suspend()
        await store.resumePendingSignIns()
        #expect(factory.built.count == 3)
        #expect(await runtime.activeNetworkIDs.isEmpty)
    }

    @Test func overlappingActivationsFinishThePendingSignInAfterCancellingTheFirstResume() async throws {
        let factory = BlockingNodeFactory()
        factory.hang.withLock { $0 = nil }
        let login = try #require(URL(string: "https://login.tailscale.com/a/overlapping-activation"))
        factory.failure.withLock { $0 = .loginRequired(login) }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)
        #expect(await store.signIn(tailnet.id) == login)
        await store.suspend()

        factory.hang.withLock { $0 = .seconds(2) }
        factory.failure.withLock { $0 = nil }
        store.resumeBrowserSignInAfterActivation()
        let restarting = await eventually {
            factory.built.count == 2 && factory.built.last?.state.withLock { $0.starts > 0 } == true
        }
        #expect(restarting)
        #expect(store.connecting.contains(tailnet.id))

        // Reactivate before the first resume has cleared its connecting state.
        factory.hang.withLock { $0 = nil }
        store.resumeBrowserSignInAfterActivation()
        let connected = await eventually {
            !store.connecting.contains(tailnet.id) && store.statuses[tailnet.id]?.isOnline == true
        }

        #expect(connected)
        #expect(factory.built.count == 3)
        #expect(store.primaryAction(for: tailnet) == .disconnect)
        #expect(store.connectFailures[tailnet.id] == nil)
        await store.suspend()
        await store.resumePendingSignIns()
        #expect(factory.built.count == 3)
    }

    @Test(arguments: ["controlURL", "secret"])
    func anOldStatusReadCannotRestoreLoginAfterAuthenticationSettingsChange(change: String) async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = VolatileSecretStore()
        let factory = FakeNodeFactory()
        let runtime = makeRuntime(factory, secrets: secrets)
        let store = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: runtime)
        try store.add(tailnet, secret: change == "secret" ? "tskey-auth-test" : nil)
        await store.connect(tailnet.id)
        let node = try #require(factory.built.first)
        let server = try #require(URL(string: "https://headscale.example"))
        let gate = OverlayStatusReadGate()
        defer { gate.release() }
        node.state.withLock { $0.statusReadGate = gate }
        let refreshing = Task { await store.refreshStatus(tailnet.id) }
        let capturedOldStatus = await eventually { gate.isWaiting }
        #expect(capturedOldStatus)

        var changed = tailnet
        if change == "controlURL" {
            changed.settings = .tailscale(hostname: "heeler", controlURL: server)
            try store.update(changed)
        } else {
            try store.update(changed, secret: "")
        }
        await runtime.reconcile()
        gate.release()
        await refreshing.value

        #expect(store.primaryAction(for: changed) == .signIn)
        let reloaded = OverlayNetworkStore(
            defaults: defaults, secrets: secrets, runtime: makeRuntime(FakeNodeFactory(), secrets: secrets))
        #expect(reloaded.primaryAction(for: changed) == .signIn)
    }
}

@Suite("Overlay Network runtime")
struct OverlayNetworkRuntimeTests {
    @Test func dialsShareOneNodePerNetwork() async throws {
        let factory = FakeNodeFactory()
        let secrets = VolatileSecretStore()
        try secrets.write(
            Data("tskey-auth-1".utf8),
            account: "overlay-tailscale-authkey-\(tailnet.id.uuidString)")
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = OverlayNetworkRuntime(secrets: secrets, stateRoot: root, makeNode: factory.make)
        runtime.publish([.init(network: tailnet, revision: 0)])

        let route = runtime.route(for: tailnet.id)
        _ = try await route.dial("box.tailnet.ts.net", 22, .seconds(5))
        _ = try await route.dial("100.64.0.9", 2222, .seconds(5))

        let node = try #require(factory.built.first)
        #expect(factory.built.count == 1)
        #expect(node.state.withLock { $0.dials } == ["box.tailnet.ts.net:22", "100.64.0.9:2222"])
        guard case .tailscale(let configuration) = node.spec else {
            Issue.record("Expected a Tailscale node")
            return
        }
        #expect(configuration.authKey == "tskey-auth-1")
        #expect(configuration.hostname == "heeler")
        #expect(configuration.stateDirectory.lastPathComponent == tailnet.id.uuidString)
        let values = try configuration.stateDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func aResavedNetworkStopsItsNodeAndTheNextDialRebuildsIt() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(),
            makeNode: factory.make)
        let zeroTier = OverlayNetwork(name: "ZT", settings: .zerotier(networkID: "8056c2e21c000001"))
        runtime.publish([.init(network: zeroTier, revision: 0)])
        _ = try await runtime.dial(networkID: zeroTier.id, host: "10.0.0.2", port: 22, timeout: .seconds(1))

        runtime.publish([.init(network: zeroTier, revision: 1)])
        await runtime.reconcile()
        #expect(await runtime.activeNetworkIDs.isEmpty)
        #expect(factory.built.first?.state.withLock { $0.stops } == 1)

        _ = try await runtime.dial(networkID: zeroTier.id, host: "10.0.0.2", port: 22, timeout: .seconds(1))
        #expect(factory.built.count == 2)
    }

    @Test func aRemovedNetworkFailsAsNotConfigured() async throws {
        let factory = FakeNodeFactory()
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: root, makeNode: factory.make)
        runtime.publish([.init(network: tailnet, revision: 0)])
        let route = runtime.route(for: tailnet.id)
        _ = try await route.dial("box", 22, .seconds(1))
        let stateDirectory = root.appendingPathComponent(tailnet.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: stateDirectory.path))

        runtime.publish([])
        await runtime.reconcile()

        #expect(factory.built.first?.state.withLock { $0.stops } == 1)
        #expect(!FileManager.default.fileExists(atPath: stateDirectory.path))
        await #expect(
            throws: TransportError.overlayFailed(network: "Overlay network", reason: .notConfigured)
        ) {
            _ = try await route.dial("box", 22, .seconds(1))
        }
    }

    @Test func nodeFailuresMapIntoTheTransportTaxonomy() async throws {
        let cases: [(OverlayError, TransportError)] = [
            (.dialFailed("refused"), .overlayFailed(network: "Home", reason: .unreachable("refused"))),
            (.startFailed("bad key"), .overlayFailed(network: "Home", reason: .notReady("bad key"))),
            (.timedOut, .overlayFailed(network: "Home", reason: .timedOut)),
            (.invalidConfiguration("x"), .overlayFailed(network: "Home", reason: .misconfigured("x"))),
            (.cancelled, .cancelled),
        ]
        for (nodeError, expected) in cases {
            let factory = FakeNodeFactory()
            factory.failure.withLock { $0 = nodeError }
            let runtime = OverlayNetworkRuntime(
                secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
            runtime.publish([.init(network: tailnet, revision: 0)])
            await #expect(throws: expected) {
                _ = try await runtime.dial(
                    networkID: tailnet.id, host: "box", port: 22, timeout: .seconds(1))
            }
        }
    }

    @Test func easyTierWithoutASecretIsMisconfigured() async {
        let easyTier = OverlayNetwork(
            name: "Lab", settings: .easytier(networkName: "lab", peers: ["tcp://p:1"], hostname: "h"))
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: easyTier, revision: 0)])

        await #expect(
            throws: TransportError.overlayFailed(
                network: "Lab", reason: .misconfigured("The network secret is missing"))
        ) {
            try await runtime.start(networkID: easyTier.id, timeout: .seconds(1))
        }
        #expect(factory.built.isEmpty)
    }

    @Test func zeroTierIdentityIsReadAndAGeneratedOneIsSaved() async throws {
        let secrets = VolatileSecretStore()
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let zeroTier = OverlayNetwork(name: "ZT", settings: .zerotier(networkID: "8056C2E21C000001"))
        runtime.publish([.init(network: zeroTier, revision: 0)])

        try await runtime.start(networkID: zeroTier.id, timeout: .seconds(1))
        let node = try #require(factory.built.first)
        #expect(
            node.spec
                == .zerotier(ZeroTierConfiguration(networkID: 0x8056_c2e2_1c00_0001, identity: nil)))

        let firstCallback = factory.identityCallbacks.withLock { $0.first }
        let callback = try #require(firstCallback)
        callback(Data("minted".utf8))
        #expect(
            try secrets.read(account: OverlaySecretAccount.zeroTierIdentity) == Data("minted".utf8))
    }

    @Test func suspensionStopsEveryNodeAndTheNextDialRestarts() async throws {
        let factory = FakeNodeFactory()
        let zeroTier = OverlayNetwork(name: "ZT", settings: .zerotier(networkID: "8056c2e21c000001"))
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: tailnet, revision: 0), .init(network: zeroTier, revision: 0)])
        try await runtime.start(networkID: tailnet.id, timeout: .seconds(1))
        try await runtime.start(networkID: zeroTier.id, timeout: .seconds(1))

        await runtime.suspend()

        #expect(factory.built.allSatisfy { node in node.state.withLock { $0.stops } == 1 })
        #expect(await runtime.status(networkID: tailnet.id) == .stopped)
        _ = try await runtime.dial(networkID: tailnet.id, host: "box", port: 22, timeout: .seconds(1))
        #expect(factory.built.count == 3)
    }
}

@Suite("Overlay failure presentation")
struct OverlayFailurePresentationTests {
    @Test func onlyTransientOverlayFailuresRetryAutomatically() throws {
        let login = try #require(URL(string: "https://login.tailscale.com/a/1"))
        let retryable: [OverlayFailure] = [.unreachable("refused"), .timedOut, .notReady("approval")]
        let stopping: [OverlayFailure] = [
            .notConfigured, .catalogUnreadable, .misconfigured("x"), .loginRequired(login),
            .startFailed("bad key"),
        ]
        for reason in retryable {
            #expect(TransportError.overlayFailed(network: "Home", reason: reason).isRetryable)
        }
        for reason in stopping {
            #expect(!TransportError.overlayFailed(network: "Home", reason: reason).isRetryable)
        }
    }

    @Test func presentationNamesTheNetworkAndPointsAtSettings() throws {
        let login = try #require(URL(string: "https://login.tailscale.com/a/1"))
        let presentation = TransportError.overlayFailed(
            network: "Home", reason: .loginRequired(login)).presentation
        #expect(presentation.summary == "Overlay network “Home” needs sign-in")
        #expect(presentation.recoverySuggestion == "Sign in from Settings › Overlay Networks.")
        #expect(
            TransportError.overlayFailed(network: "Home", reason: .loginRequired(login))
                .overlayLoginURL == login)

        let unreachable = TransportError.overlayFailed(
            network: "Home", reason: .unreachable("connection refused")).presentation
        #expect(unreachable.summary == "Unreachable over overlay network “Home”")
        #expect(unreachable.detail == "connection refused")

        let timedOut = TransportError.overlayFailed(network: "Home", reason: .timedOut).presentation
        #expect(timedOut.recoverySuggestion == nil)
    }

    @Test func preflightBlamesTheOverlayOnTheConnectionCheck() {
        let report = PreflightReport.failure(
            .overlayFailed(network: "Home", reason: .startFailed("invalid key")),
            authMethod: .deviceKey)

        guard case .failed(let hint) = report[.connection] else {
            Issue.record("Expected the connection check to fail")
            return
        }
        #expect(hint.contains("“Home” could not start"))
        #expect(hint.contains("invalid key"))
        #expect(report[.herdrInstalled] == .blocked)
    }
}

@Suite("Overlay Network runtime lifecycle")
struct OverlayNetworkRuntimeLifecycleTests {
    private let zeroTier = OverlayNetwork(
        name: "ZT", settings: .zerotier(networkID: "8056c2e21c000001"))

    @Test func aReplacementWaitsForItsPredecessorToStop() async throws {
        let factory = FakeNodeFactory(stopDelay: .milliseconds(200))
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: zeroTier)])
        _ = try await runtime.dial(networkID: zeroTier.id, host: "box", port: 22, timeout: .seconds(1))

        runtime.publish([.init(network: zeroTier, revision: 1)])
        async let reconciled: Void = runtime.reconcile()
        async let dialled = runtime.dial(
            networkID: zeroTier.id, host: "box", port: 22, timeout: .seconds(1))
        _ = try await dialled
        await reconciled

        #expect(factory.built.count == 2)
        #expect(
            factory.events.all
                == ["n0.dial", "n0.stop.begin", "n0.stop.end", "n1.dial"])
    }

    @Test func aDialDuringAnExplicitStopWaitsForIt() async throws {
        let factory = FakeNodeFactory(stopDelay: .milliseconds(200))
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: zeroTier)])
        _ = try await runtime.dial(networkID: zeroTier.id, host: "box", port: 22, timeout: .seconds(1))

        async let stopped: Void = runtime.stop(networkID: zeroTier.id)
        try await Task.sleep(for: .milliseconds(20))
        async let dialled = runtime.dial(
            networkID: zeroTier.id, host: "box", port: 22, timeout: .seconds(1))
        _ = try await dialled
        await stopped

        #expect(
            factory.events.all
                == ["n0.dial", "n0.stop.begin", "n0.stop.end", "n1.dial"])
    }

    @Test func aRenameKeepsTheNode() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: zeroTier)])
        _ = try await runtime.dial(networkID: zeroTier.id, host: "box", port: 22, timeout: .seconds(1))

        var renamed = zeroTier
        renamed.name = "Lab"
        runtime.publish([.init(network: renamed)])
        await runtime.reconcile()
        _ = try await runtime.dial(networkID: zeroTier.id, host: "box", port: 22, timeout: .seconds(1))

        #expect(factory.built.count == 1)
        #expect(factory.built.first?.state.withLock { $0.stops } == 0)
        #expect(runtime.route(for: zeroTier.id).networkName == "Lab")
    }

    @Test func aNewTailscaleAuthKeyStartsFromCleanState() async throws {
        let factory = FakeNodeFactory()
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: root, makeNode: factory.make)
        runtime.publish([.init(network: tailnet)])
        _ = try await runtime.dial(networkID: tailnet.id, host: "box", port: 22, timeout: .seconds(1))
        let login = root.appendingPathComponent(tailnet.id.uuidString)
            .appendingPathComponent("tailscaled.state")
        try Data("logged in".utf8).write(to: login)

        // A settings-only change keeps the login.
        var renamedHost = tailnet
        renamedHost.settings = .tailscale(hostname: "phone", controlURL: nil)
        runtime.publish([.init(network: renamedHost, revision: 1)])
        await runtime.reconcile()
        #expect(FileManager.default.fileExists(atPath: login.path))

        // No node is running now; the new key must still drop the login.
        #expect(await runtime.activeNetworkIDs.isEmpty)
        runtime.publish([.init(network: renamedHost, revision: 2, secretRevision: 1)])
        await runtime.reconcile()
        #expect(!FileManager.default.fileExists(atPath: login.path))
    }

    @Test func stateOfANetworkFromANewerBuildIsKept() async throws {
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reserved = UUID()
        let orphan = UUID()
        for id in [reserved, orphan] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: root, makeNode: FakeNodeFactory().make)

        runtime.publish([], reserving: [reserved])
        await runtime.reconcile()

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(reserved.uuidString).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan.uuidString).path))
    }

    @Test func easyTierNetworksRunSideBySideUnderTheirOwnKeys() async throws {
        let secrets = VolatileSecretStore()
        let first = OverlayNetwork(
            name: "A", settings: .easytier(networkName: "a", peers: ["tcp://p:1"], hostname: "h"))
        let second = OverlayNetwork(
            name: "B", settings: .easytier(networkName: "b", peers: ["tcp://p:1"], hostname: "h"))
        let server = OverlayNetwork(
            name: "C",
            settings: .easytierConfigServer(
                server: "udp://console.lab:22020", machineID: UUID(), hostname: "h"))
        for network in [first, second] {
            let account = try #require(OverlaySecretAccount.secret(for: network))
            try secrets.write(Data("s".utf8), account: account)
        }
        try secrets.write(
            Data("udp://console.lab:22020/alice".utf8),
            account: try #require(OverlaySecretAccount.secret(for: server)))
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([
            .init(network: first), .init(network: second, revision: 3), .init(network: server),
        ])
        // Hosts on each network (their routes), the same address on two of
        // them: each dial goes through its own network's node.
        for (network, host) in [(first, "10.0.0.2"), (second, "10.0.0.2"), (server, "10.0.0.9")] {
            let route = runtime.route(for: network.id)
            #expect(route.networkName == network.name)
            _ = try await route.dial(host, 22, .seconds(1))
        }
        #expect(await runtime.activeNetworkIDs == [first.id, second.id, server.id])
        let nodes = factory.built
        #expect(nodes.count == 3)
        // Every node runs under its network's id as the instance key.
        let keys = nodes.compactMap { node -> String? in
            guard case .easytier(let configuration) = node.spec else { return nil }
            return configuration.instanceKey
        }
        #expect(keys == [first.id.uuidString, second.id.uuidString, server.id.uuidString])
        #expect(nodes.map { $0.state.withLock { $0.dials } } == [["10.0.0.2:22"], ["10.0.0.2:22"], ["10.0.0.9:22"]])
        #expect(nodes.allSatisfy { $0.state.withLock { $0.stops } == 0 })

        // Each stops on its own.
        await runtime.stop(networkID: first.id)
        #expect(nodes[0].state.withLock { $0.stops } == 1)
        #expect(await runtime.status(networkID: first.id) == .stopped)
        #expect(await runtime.activeNetworkIDs == [second.id, server.id])
        _ = try await runtime.dial(networkID: second.id, host: "10.0.0.2", port: 22, timeout: .seconds(1))
        #expect(factory.built.count == 3)
        #expect(nodes[1].state.withLock { $0.dials.count } == 2)

        // A re-saved network is rebuilt alone, at its new revision.
        runtime.publish([
            .init(network: first), .init(network: second, revision: 4), .init(network: server),
        ])
        await runtime.reconcile()
        #expect(nodes[1].state.withLock { $0.stops } == 1)
        #expect(nodes[2].state.withLock { $0.stops } == 0)
        _ = try await runtime.dial(networkID: second.id, host: "10.0.0.2", port: 22, timeout: .seconds(1))
        #expect(factory.built.count == 4)

        // Suspension stops every one of them.
        await runtime.suspend()
        #expect(await runtime.activeNetworkIDs.isEmpty)
        #expect(factory.built.allSatisfy { $0.state.withLock { $0.stops } == 1 })
    }

    @Test func aStoppingEasyTierNetworkHoldsUpNoOtherNetwork() async throws {
        let secrets = VolatileSecretStore()
        let first = OverlayNetwork(
            name: "A", settings: .easytier(networkName: "a", peers: ["tcp://p:1"], hostname: "h"))
        let second = OverlayNetwork(
            name: "B", settings: .easytier(networkName: "b", peers: ["tcp://p:1"], hostname: "h"))
        for network in [first, second] {
            try secrets.write(Data("s".utf8), account: try #require(OverlaySecretAccount.secret(for: network)))
        }
        let factory = FakeNodeFactory(stopDelay: .milliseconds(500))
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: first), .init(network: second)])
        _ = try await runtime.dial(networkID: first.id, host: "10.0.0.2", port: 22, timeout: .seconds(1))
        // A re-save retires A's node (slowly); B starts meanwhile.
        runtime.publish([.init(network: first, revision: 1), .init(network: second)])
        let retiring = Task { await runtime.reconcile() }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await runtime.dial(networkID: second.id, host: "10.0.0.3", port: 22, timeout: .seconds(1))
        await retiring.value
        let events = factory.events.all
        let secondDial = try #require(events.firstIndex(of: "n1.dial"))
        let firstStopped = try #require(events.firstIndex(of: "n0.stop.end"))
        #expect(secondDial < firstStopped, "\(events)")
    }

    @Test func startFailuresRetryUntilTheLimitThenStop() async throws {
        let factory = FakeNodeFactory()
        factory.failure.withLock { $0 = .startFailed("ACCESS_DENIED") }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: zeroTier)])

        func dialFailure() async -> TransportError? {
            do {
                _ = try await runtime.dial(
                    networkID: zeroTier.id, host: "box", port: 22, timeout: .seconds(1))
                return nil
            } catch {
                return error as? TransportError
            }
        }
        for _ in 1..<OverlayNetworkRuntime.startFailureLimit {
            let failure = await dialFailure()
            #expect(failure == .overlayFailed(network: "ZT", reason: .notReady("ACCESS_DENIED")))
            #expect(failure?.isRetryable == true)
        }
        let last = await dialFailure()
        #expect(last == .overlayFailed(network: "ZT", reason: .startFailed("ACCESS_DENIED")))
        #expect(last?.isRetryable == false)

        // An explicit Connect starts a fresh run of retries.
        await #expect(
            throws: TransportError.overlayFailed(network: "ZT", reason: .notReady("ACCESS_DENIED"))
        ) {
            try await runtime.start(networkID: zeroTier.id, timeout: .seconds(1))
        }
    }

    @Test func aNodeAwaitingAuthorizationStaysRetryable() async throws {
        let waiting = "Waiting for authorization of node abcdef0123 on ZeroTier network 8056c2e21c000001"
        let factory = FakeNodeFactory()
        factory.failure.withLock { $0 = .startFailed(waiting) }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: zeroTier)])

        func dialFailure() async -> TransportError? {
            do {
                _ = try await runtime.dial(
                    networkID: zeroTier.id, host: "10.0.0.2", port: 22, timeout: .seconds(1))
                return nil
            } catch {
                return error as? TransportError
            }
        }
        _ = await dialFailure()
        factory.built.first?.state.withLock { $0.status = .waiting(waiting) }
        // However long the admin takes, the network is retried.
        for _ in 0...OverlayNetworkRuntime.startFailureLimit {
            let failure = await dialFailure()
            #expect(failure == .overlayFailed(network: "ZT", reason: .notReady(waiting)))
            #expect(failure?.isRetryable == true)
        }
        // Waiting counted toward no run of start failures: one more is the
        // second (the first came before the node reported waiting).
        factory.built.first?.state.withLock { $0.status = .stopped }
        #expect(await dialFailure() == .overlayFailed(network: "ZT", reason: .notReady(waiting)))
    }

    @Test func aSignInLinkThatIsNotHTTPSIsRefused() async throws {
        let factory = FakeNodeFactory()
        let insecure = try #require(URL(string: "http://login.example/a/1"))
        factory.failure.withLock { $0 = .loginRequired(insecure) }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: tailnet)])

        await #expect(
            throws: TransportError.overlayFailed(
                network: "Home",
                reason: .misconfigured("The coordination server sent a sign-in link that is not https"))
        ) {
            try await runtime.start(networkID: tailnet.id, timeout: .seconds(1))
        }
    }

    @Test func loginLinksMustBeHTTPSUnlessTheServerItselfIsHTTP() throws {
        let https = try #require(URL(string: "https://login.tailscale.com/a/1"))
        let http = try #require(URL(string: "http://headscale.lan:8080/register/1"))
        #expect(tailnet.acceptsLoginURL(https))
        #expect(!tailnet.acceptsLoginURL(http))
        let local = OverlayNetwork(
            name: "Lab",
            settings: .tailscale(
                hostname: "h", controlURL: URL(string: "http://headscale.lan:8080")))
        #expect(local.acceptsLoginURL(http))
        #expect(!local.acceptsLoginURL(try #require(URL(string: "http://other.lan/register/1"))))
        #expect(!tailnet.acceptsLoginURL(try #require(URL(string: "javascript:alert(1)"))))
    }

    @Test func anUnreadableCatalogHasItsOwnReason() async {
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(),
            makeNode: FakeNodeFactory().make)
        runtime.markCatalogUnreadable()

        await #expect(
            throws: TransportError.overlayFailed(network: "Overlay network", reason: .catalogUnreadable)
        ) {
            _ = try await runtime.route(for: tailnet.id).dial("box", 22, .seconds(1))
        }
        #expect(
            !TransportError.overlayFailed(network: "Overlay network", reason: .catalogUnreadable)
                .isRetryable)
    }
}

@MainActor
@Suite("Overlay Network store revisions")
struct OverlayNetworkStoreRevisionTests {
    @Test func onlySettingsOrSecretChangesRebuildTheNode() async throws {
        let suite = "overlay-network-store-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // One secret store, as the store and runtime share one Keychain service.
        let secrets = VolatileSecretStore()
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: runtime)
        try store.add(tailnet, secret: "tskey-a")
        await store.connect(tailnet.id)

        var renamed = tailnet
        renamed.name = "Office"
        try store.update(renamed)
        try store.update(renamed, secret: "tskey-a")
        await runtime.reconcile()
        await store.connect(tailnet.id)
        #expect(factory.built.count == 1)

        try store.update(renamed, secret: "tskey-b")
        await runtime.reconcile()
        await store.connect(tailnet.id)
        #expect(factory.built.count == 2)
        guard case .tailscale(let configuration) = factory.built.last?.spec else {
            Issue.record("Expected a Tailscale node")
            return
        }
        #expect(configuration.authKey == "tskey-b")
    }

    @Test func theCatalogHoldsSeveralEasyTierNetworks() throws {
        let store = OverlayNetworkStore(
            volatileNetworks: [],
            runtime: OverlayNetworkRuntime(
                secrets: VolatileSecretStore(), stateRoot: nil, makeNode: FakeNodeFactory().make))
        let first = OverlayNetwork(
            name: "A", settings: .easytier(networkName: "a", peers: ["tcp://p:1"], hostname: "h"))
        let second = OverlayNetwork(
            name: "B", settings: .easytier(networkName: "b", peers: ["tcp://p:1"], hostname: "h"))
        let server = OverlayNetwork(
            name: "C",
            settings: .easytierConfigServer(server: "udp://console.lab:22020", machineID: UUID(), hostname: "h"))
        try store.add(first, secret: "s")
        try store.add(second, secret: "s")
        try store.add(server, secret: "udp://console.lab:22020/alice")
        #expect(store.networks == [first, second, server])
        var renamed = second
        renamed.name = "B2"
        try store.update(renamed)
        #expect(store.networks.map(\.name) == ["A", "B2", "C"])
    }

    @Test func aCorruptCatalogReachesTheRuntimeAsUnreadable() async throws {
        let suite = "overlay-network-store-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{not json".utf8), forKey: "overlayNetworks")
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(),
            makeNode: FakeNodeFactory().make)

        _ = OverlayNetworkStore(defaults: defaults, secrets: VolatileSecretStore(), runtime: runtime)

        await #expect(
            throws: TransportError.overlayFailed(network: "Overlay network", reason: .catalogUnreadable)
        ) {
            _ = try await runtime.dial(networkID: tailnet.id, host: "box", port: 22, timeout: .seconds(1))
        }
    }
}

@Suite("Overlay Network form rules")
struct OverlayNetworkFormRuleTests {
    @Test func coordinationServerMustBeHTTPS() {
        var draft = OverlayNetworkDraft()
        draft.controlURL = "http://headscale.example"
        #expect(!draft.isValid)
        draft.controlURL = "https://headscale.example"
        #expect(draft.isValid)
    }

    @Test func easyTierPeersNeedATransportHostAndPort() {
        #expect(OverlayNetworkDraft.isValidPeer("tcp://public.easytier.top:11010"))
        #expect(OverlayNetworkDraft.isValidPeer("udp://10.0.0.1:11010"))
        #expect(!OverlayNetworkDraft.isValidPeer("wss://relay.example:443"))
        #expect(!OverlayNetworkDraft.isValidPeer("tcp://relay.example"))
        #expect(!OverlayNetworkDraft.isValidPeer("relay.example:11010"))

        var draft = OverlayNetworkDraft()
        draft.kind = .easytier
        draft.networkName = "lab"
        draft.secret = "s"
        draft.peers = "tcp://a.example:11010\nrelay.example"
        #expect(draft.invalidPeers == ["relay.example"])
        #expect(!draft.isValid)
    }
}

/// The overlay route as `HeelerSSHTransport` uses it, with no SSH server:
/// failures must surface unwrapped and every dialled stream released once.
@Suite("Overlay route in the SSH transport")
struct OverlayTransportRouteTests {
    private static func settings(jump: SSHJumpSettings?, overlay: OverlayRoute) -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: "100.64.0.7",
            port: 22,
            username: "dev",
            credentials: .password("x"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
            socket: .defaultSession,
            jump: jump,
            overlay: overlay)
        settings.requestTimeout = .seconds(3)
        return settings
    }

    @Test func anOverlayFailureBeforeTheJumpHostIsNotBlamedOnIt() async {
        let failure = TransportError.overlayFailed(network: "Home", reason: .notReady("approval"))
        let route = OverlayRoute(networkName: "Home") { _, _, _ in throw failure }
        let settings = Self.settings(
            jump: SSHJumpSettings(host: "jump.tailnet.ts.net", username: "dev", credentials: .password("x")),
            overlay: route)

        await #expect(throws: failure) {
            _ = try await HeelerSSHTransport.connect(settings: settings)
        }
    }

    @Test func everyDialledStreamIsReleasedExactlyOnce() async throws {
        let releases = Mutex<[Int]>([])
        let route = OverlayRoute(networkName: "Home") { _, _, _ in
            var descriptors: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw TransportError.channelFailed(detail: "socketpair")
            }
            // The peer hangs up at once, so the handshake fails after the
            // stream was handed over.
            close(descriptors[1])
            let index = releases.withLock { releases in
                releases.append(0)
                return releases.count - 1
            }
            return OverlayDialedStream(descriptor: descriptors[0]) {
                releases.withLock { $0[index] += 1 }
            }
        }

        await #expect(throws: TransportError.self) {
            _ = try await HeelerSSHTransport.connect(settings: Self.settings(jump: nil, overlay: route))
        }

        let counts = releases.withLock { $0 }
        #expect(!counts.isEmpty)
        #expect(counts.allSatisfy { $0 == 1 })
    }
}

private let zeroTierLab = OverlayNetwork(
    name: "ZT", settings: .zerotier(networkID: "8056c2e21c000001"))

/// A minimal ZeroTier World blob of `type` (1 planet, 127 moon).
private func zeroTierWorld(type: UInt8 = 1, size: Int = 200, marker: UInt8 = 0) -> Data {
    var data = Data(repeating: marker, count: size)
    data[0] = type
    return data
}

/// A ZeroTier `identity.secret` whose address field is `nodeID`.
private func zeroTierIdentity(_ nodeID: String) -> Data {
    Data("\(nodeID):0:public:private".utf8)
}

/// Counts generator calls and hands out fixed identities.
private final class IdentityGenerator: Sendable {
    let calls = Mutex(0)
    let failure: OverlayError?
    /// Blocks the calling thread like libzt's key derivation.
    let delay: TimeInterval

    init(failure: OverlayError? = nil, delay: TimeInterval = 0) {
        self.failure = failure
        self.delay = delay
    }

    var generate: @Sendable () throws -> Data {
        {
            self.calls.withLock { $0 += 1 }
            if self.delay > 0 { Thread.sleep(forTimeInterval: self.delay) }
            if let failure = self.failure { throw failure }
            return zeroTierIdentity("a1b2c3d4e5")
        }
    }

    var count: Int { calls.withLock { $0 } }
}

@Suite("Overlay Network moons and fixed addresses")
struct OverlayNetworkSettingsCodingTests {
    @Test func networksSavedBeforeMoonsAndFixedAddressesDecode() throws {
        let zeroTier = """
            {"id":"\(UUID().uuidString)","name":"ZT","kind":"zerotier","networkID":"8056c2e21c000001"}
            """
        let easyTier = """
            {"id":"\(UUID().uuidString)","name":"ET","kind":"easytier","networkName":"lab",
             "peers":["tcp://p:1"],"hostname":"h"}
            """

        let decodedZeroTier = try JSONDecoder().decode(OverlayNetwork.self, from: Data(zeroTier.utf8))
        let decodedEasyTier = try JSONDecoder().decode(OverlayNetwork.self, from: Data(easyTier.utf8))

        #expect(decodedZeroTier.settings == .zerotier(networkID: "8056c2e21c000001", moons: []))
        #expect(
            decodedEasyTier.settings
                == .easytier(networkName: "lab", peers: ["tcp://p:1"], hostname: "h", ipv4: nil))
    }

    @MainActor
    @Test func moonsPersistAsHexSoAFullWorldIDSurvivesTheCatalog() throws {
        let suite = "overlay-network-store-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let moon = ZeroTierMoon(worldID: 0xffff_ffff_ffff_fff1, seed: 0x00_1122_3344)
        let network = OverlayNetwork(
            name: "ZT", settings: .zerotier(networkID: "8056c2e21c000001", moons: [moon]))
        let easyTier = OverlayNetwork(
            name: "ET",
            settings: .easytier(
                networkName: "lab", peers: ["tcp://p:1"], hostname: "h", ipv4: "10.144.144.7/24"))
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: nil, makeNode: FakeNodeFactory().make)
        let store = OverlayNetworkStore(defaults: defaults, secrets: VolatileSecretStore(), runtime: runtime)
        try store.add(network)
        try store.add(easyTier, secret: "s")

        let text = String(decoding: try #require(defaults.data(forKey: "overlayNetworks")), as: UTF8.self)
        #expect(text.contains("fffffffffffffff1"))
        #expect(text.contains("0011223344"))
        let reloaded = OverlayNetworkStore(
            defaults: defaults, secrets: VolatileSecretStore(), runtime: runtime)
        #expect(reloaded.networks == [network, easyTier])
    }

    @Test func moonWorldIDsAreTenToSixteenAndSeedsTenHexDigits() {
        #expect(OverlayNetwork.zeroTierMoonWorldID("abcdef0123") == 0xab_cdef_0123)
        #expect(OverlayNetwork.zeroTierMoonWorldID(" 000000abcdef0123 ") == 0xab_cdef_0123)
        #expect(OverlayNetwork.zeroTierMoonWorldID("abcdef012") == nil)
        #expect(OverlayNetwork.zeroTierMoonWorldID("abcdef01234567890") == nil)
        #expect(OverlayNetwork.zeroTierMoonWorldID("abcdef012g") == nil)
        #expect(OverlayNetwork.zeroTierMoonWorldID("0000000000") == nil)
        #expect(OverlayNetwork.zeroTierMoonSeed("abcdef0123") == 0xab_cdef_0123)
        #expect(OverlayNetwork.zeroTierMoonSeed("000000abcdef0123") == nil)
        #expect(OverlayNetwork.zeroTierMoonSeed("abcdef012") == nil)
        #expect(OverlayNetwork.zeroTierMoonSeed("0000000000") == nil)
    }

    @Test func draftKeepsValidMoonsAndRefusesHalfTypedOnes() throws {
        var draft = OverlayNetworkDraft()
        draft.kind = .zerotier
        draft.networkID = "8056c2e21c000001"
        draft.moons = [
            .init(worldID: "000000abcdef0123", seed: "abcdef0123"),
            .init(),
            .init(worldID: "abcdef0123", seed: "abcdef0123"),
        ]
        draft.moons.append(.init(worldID: "abcdef0123", seed: "000000abcdef0123"))
        #expect(!draft.isValid)
        draft.moons.removeLast()
        #expect(draft.isValid)
        let moon = ZeroTierMoon(worldID: 0xab_cdef_0123, seed: 0xab_cdef_0123)
        #expect(try #require(draft.makeNetwork()).settings == .zerotier(
            networkID: "8056c2e21c000001", moons: [moon]))

        draft.moons.append(.init(worldID: "abcdef0123", seed: ""))
        #expect(draft.invalidMoons.count == 1)
        #expect(!draft.isValid)

        let rebuilt = OverlayNetworkDraft(
            network: OverlayNetwork(
                name: "ZT", settings: .zerotier(networkID: "8056c2e21c000001", moons: [moon])))
        #expect(rebuilt.moons.map(\.worldID) == ["000000abcdef0123"])
        #expect(rebuilt.moons.map(\.seed) == ["abcdef0123"])
    }

    @Test func easyTierFixedAddressIsAnIPv4CIDR() {
        #expect(OverlayNetwork.easyTierIPv4("10.144.144.7/24") == "10.144.144.7/24")
        #expect(OverlayNetwork.easyTierIPv4(" 10.0.0.1/32 ") == "10.0.0.1/32")
        #expect(OverlayNetwork.easyTierIPv4("192.168.0.9/32") == "192.168.0.9/32")
        for invalid in [
            "10.0.0.1", "10.0.0.1/0", "10.0.0.1/33", "256.0.0.1/24", "10.0.0/24", "10.0.0.1/",
            "10.0.0.1/2a", "fd00::1/64", "a.b.c.d/24", "10..0.1/24", "010.0.0.1/8",
            "10.0.0.01/24", "10.0.0.1/024", "0.1.2.3/8", "127.0.0.2/8", "224.0.0.1/24",
            "255.255.255.255/32",
        ] {
            #expect(OverlayNetwork.easyTierIPv4(invalid) == nil, "\(invalid)")
        }

        var draft = OverlayNetworkDraft()
        draft.kind = .easytier
        draft.networkName = "lab"
        draft.peers = "tcp://p:11010"
        draft.secret = "s"
        #expect(draft.isValid)
        #expect(draft.ipv4Value == nil)
        draft.ipv4 = "10.144.144.7/40"
        #expect(!draft.isValid)
        draft.ipv4 = "10.144.144.7/32"
        #expect(draft.isValid && draft.ipv4IsHostPrefix)
        draft.ipv4 = "10.144.144.7/24"
        #expect(!draft.ipv4IsHostPrefix)
        guard case .easytier(_, _, _, let ipv4) = draft.makeNetwork()?.settings else {
            Issue.record("Expected an EasyTier network")
            return
        }
        #expect(ipv4 == "10.144.144.7/24")
    }
}

@Suite("Overlay Network runtime configuration")
struct OverlayNetworkRuntimeConfigurationTests {
    @Test func zeroTierNodesGetTheirOwnPlanetAndMoons() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let planet = zeroTierWorld(size: 300, marker: 7)
        let moon = ZeroTierMoon(worldID: 0xab_cdef_0123, seed: 0xab_cdef_0123)
        let network = OverlayNetwork(
            name: "ZT",
            settings: .zerotier(networkID: "8056c2e21c000001", moons: [moon], planet: planet))
        let official = OverlayNetwork(name: "Official", settings: .zerotier(networkID: "8056c2e21c000002"))
        runtime.publish([.init(network: network), .init(network: official)])

        try await runtime.start(networkID: network.id, timeout: .seconds(1))
        try await runtime.start(networkID: official.id, timeout: .seconds(1))

        #expect(
            factory.built.first?.spec
                == .zerotier(
                    ZeroTierConfiguration(
                        networkID: 0x8056_c2e2_1c00_0001, identity: nil, roots: planet,
                        moons: [moon])))
        // A network without a planet of its own uses ZeroTier's, side by side.
        #expect(
            factory.built.last?.spec
                == .zerotier(ZeroTierConfiguration(networkID: 0x8056_c2e2_1c00_0002, identity: nil)))
    }

    @Test func easyTierNodesGetTheFixedAddress() async throws {
        let secrets = VolatileSecretStore()
        let network = OverlayNetwork(
            name: "ET",
            settings: .easytier(
                networkName: "lab", peers: ["tcp://p:1"], hostname: "h", ipv4: "10.144.144.7/24"))
        try secrets.write(Data("s".utf8), account: try #require(OverlaySecretAccount.secret(for: network)))
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: network)])

        try await runtime.start(networkID: network.id, timeout: .seconds(1))

        guard case .easytier(let configuration) = factory.built.first?.spec else {
            Issue.record("Expected an EasyTier node")
            return
        }
        guard case .manual(_, _, _, let ipv4) = configuration.source else {
            Issue.record("Expected a manual EasyTier network")
            return
        }
        #expect(ipv4 == "10.144.144.7/24")
    }

    @Test func aPlanetChangeRebuildsOnlyItsNetwork() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let other = OverlayNetwork(name: "Other", settings: .zerotier(networkID: "8056c2e21c000002"))
        runtime.publish([.init(network: zeroTierLab), .init(network: other)])
        try await runtime.start(networkID: zeroTierLab.id, timeout: .seconds(1))
        try await runtime.start(networkID: other.id, timeout: .seconds(1))

        // No relaunch: the edited network's node is rebuilt with the planet.
        var custom = zeroTierLab
        custom.settings = .zerotier(networkID: "8056c2e21c000001", planet: zeroTierWorld())
        runtime.publish([.init(network: custom, revision: 1), .init(network: other)])
        await runtime.reconcile()
        try await runtime.start(networkID: custom.id, timeout: .seconds(1))

        #expect(factory.built.count == 3)
        guard case .zerotier(let configuration) = factory.built.last?.spec else {
            Issue.record("Expected a ZeroTier node")
            return
        }
        #expect(configuration.roots == zeroTierWorld())
        #expect(factory.built[1].state.withLock { $0.stops } == 0)
    }

    @Test func aProcessNodeConflictIsNotRetried() async throws {
        let factory = FakeNodeFactory()
        factory.failure.withLock {
            $0 = .startFailed("ZeroTier is already running with a different identity in this app session.")
        }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: zeroTierLab)])

        do {
            try await runtime.start(networkID: zeroTierLab.id, timeout: .seconds(1))
            Issue.record("Expected a failure")
        } catch let error as TransportError {
            guard case .overlayFailed(_, .misconfigured(let detail)) = error else {
                Issue.record("Expected misconfigured, got \(error)")
                return
            }
            #expect(detail.hasSuffix(OverlayNetworkRuntime.zeroTierRestartAdvice))
            #expect(!error.isRetryable)
        }
    }
}

/// What a network's state directory holds after Sign Out: only the
/// signed-out marker, never tsnet's login.
private func stateContents(_ root: URL, _ id: UUID) -> [String] {
    (try? FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent(id.uuidString).path)) ?? []
}

@Suite("Overlay Network Tailscale sign-out")
struct OverlayNetworkLogoutTests {
    @Test func signingOutARunningNodeDiscardsItAndItsLogin() async throws {
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: root, makeNode: factory.make)
        runtime.publish([.init(network: tailnet, revision: 3)])
        try await runtime.start(networkID: tailnet.id, timeout: .seconds(1))
        let login = root.appendingPathComponent(tailnet.id.uuidString)
            .appendingPathComponent("tailscaled.state")
        try Data("logged in".utf8).write(to: login)

        try await runtime.logout(networkID: tailnet.id, timeout: .seconds(1))

        let node = try #require(factory.built.first)
        #expect(node.state.withLock { $0.logouts } == 1)
        #expect(await runtime.activeNetworkIDs.isEmpty)
        #expect(await runtime.status(networkID: tailnet.id) == .stopped)
        #expect(!FileManager.default.fileExists(atPath: login.path))
        #expect(stateContents(root, tailnet.id) == [".heeler-signed-out"])

        // The next Connect builds a fresh node on clean state.
        try await runtime.start(networkID: tailnet.id, timeout: .seconds(1))
        #expect(factory.built.count == 2)
    }

    @Test func signingOutWithoutANodeBuildsOneToClearTheState() async throws {
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: root, makeNode: factory.make)
        runtime.publish([.init(network: tailnet)])

        try await runtime.logout(networkID: tailnet.id, timeout: .seconds(1))

        let node = try #require(factory.built.first)
        #expect(factory.built.count == 1)
        #expect(node.state.withLock { ($0.logouts, $0.starts) } == (1, 0))
        #expect(await runtime.activeNetworkIDs.isEmpty)
        #expect(stateContents(root, tailnet.id) == [".heeler-signed-out"])
    }

    @Test func aFailedServerLogoutStillForgetsTheLogin() async throws {
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: root, makeNode: factory.make)
        runtime.publish([.init(network: tailnet)])
        try await runtime.start(networkID: tailnet.id, timeout: .seconds(1))
        let node = try #require(factory.built.first)
        node.state.withLock { $0.logoutFailure = .timedOut }

        await #expect(throws: TransportError.overlayFailed(network: "Home", reason: .timedOut)) {
            try await runtime.logout(networkID: tailnet.id, timeout: .seconds(1))
        }
        #expect(node.state.withLock { $0.stops } == 1)
        #expect(await runtime.activeNetworkIDs.isEmpty)
        #expect(stateContents(root, tailnet.id) == [".heeler-signed-out"])
    }

    @Test func onlyTailscaleSignsOut() async {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: zeroTierLab)])

        await #expect(throws: TransportError.self) {
            try await runtime.logout(networkID: zeroTierLab.id, timeout: .seconds(1))
        }
        #expect(factory.built.isEmpty)
    }

    @MainActor
    @Test func theStoreReportsSignOutAndItsFailure() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)
        await store.connect(tailnet.id)
        #expect(store.statuses[tailnet.id] == .online(addresses: ["100.64.0.2"]))

        await store.signOut(tailnet.id)
        #expect(store.statuses[tailnet.id] == .stopped)
        #expect(store.signOutFailures[tailnet.id] == nil)
        #expect(store.signingOut.isEmpty)

        await store.connect(tailnet.id)
        factory.built.last?.state.withLock { $0.logoutFailure = .dialFailed("offline") }
        await store.signOut(tailnet.id)
        #expect(
            store.signOutFailures[tailnet.id]
                == .overlayFailed(network: "Home", reason: .unreachable("offline")))
    }
}

@Suite("Overlay Network ZeroTier identity")
struct OverlayNetworkZeroTierIdentityTests {
    @Test func anIdentityIsGeneratedOnceAndSaved() async throws {
        let secrets = VolatileSecretStore()
        let generator = IdentityGenerator()
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: FakeNodeFactory().make,
            generateZeroTierIdentity: generator.generate)

        let identity = try await runtime.ensureZeroTierIdentity()
        _ = try await runtime.ensureZeroTierIdentity()

        #expect(identity == zeroTierIdentity("a1b2c3d4e5"))
        #expect(generator.count == 1)
        #expect(try secrets.read(account: OverlaySecretAccount.zeroTierIdentity) == identity)
    }

    @Test func theRunningNodesIdentityIsSavedAgainInsteadOfANewOne() async throws {
        let secrets = VolatileSecretStore()
        let generator = IdentityGenerator()
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make,
            generateZeroTierIdentity: generator.generate)
        let running = zeroTierIdentity("0011223344")
        try secrets.write(running, account: OverlaySecretAccount.zeroTierIdentity)
        runtime.publish([.init(network: zeroTierLab)])
        try await runtime.start(networkID: zeroTierLab.id, timeout: .seconds(1))

        // Deleting the last ZeroTier network removes the saved identity,
        // while the process node keeps running with it.
        try secrets.removeSecret(account: OverlaySecretAccount.zeroTierIdentity)

        #expect(try await runtime.ensureZeroTierIdentity() == running)
        #expect(generator.count == 0)
        #expect(try secrets.read(account: OverlaySecretAccount.zeroTierIdentity) == running)
    }

    @Test func noneIsGeneratedWhileANodeMintsItsOwn() async throws {
        let secrets = VolatileSecretStore()
        let generator = IdentityGenerator()
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make,
            generateZeroTierIdentity: generator.generate)
        runtime.publish([.init(network: zeroTierLab)])
        try await runtime.start(networkID: zeroTierLab.id, timeout: .seconds(1))

        #expect(try await runtime.ensureZeroTierIdentity() == nil)
        #expect(generator.count == 0)

        let minted = zeroTierIdentity("5566778899")
        let callback = try #require(factory.identityCallbacks.withLock { $0.first })
        callback(minted)
        #expect(try await runtime.ensureZeroTierIdentity() == minted)
    }

    @MainActor
    @Test func theStoreShowsTheIdentityNodeIDOrFallsBackToTheNode() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make,
            generateZeroTierIdentity: IdentityGenerator().generate)
        let store = OverlayNetworkStore(volatileNetworks: [zeroTierLab], runtime: runtime)

        await store.prepareZeroTierIdentity()
        #expect(store.zeroTierNodeID == "a1b2c3d4e5")
        #expect(!store.zeroTierIdentityDeferred)
    }

    @MainActor
    @Test func aFailedGenerationDefersToTheFirstConnect() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make,
            generateZeroTierIdentity: IdentityGenerator(failure: .startFailed("unavailable")).generate)
        let store = OverlayNetworkStore(volatileNetworks: [zeroTierLab], runtime: runtime)

        await store.prepareZeroTierIdentity()
        #expect(store.zeroTierIdentityDeferred)
        #expect(store.zeroTierNodeID == nil)

        // The running node's own report fills in.
        await store.connect(zeroTierLab.id)
        factory.built.first?.state.withLock { $0.details = OverlayNodeDetails(nodeID: "99aabbccdd") }
        await store.refreshStatus(zeroTierLab.id)
        #expect(store.zeroTierNodeID == "99aabbccdd")
    }
}

@Suite("Overlay Network planet and details")
struct OverlayNetworkPlanetAndDetailsTests {
    @Test func planetFilesAreCheckedBeforeAFormTakesThem() throws {
        #expect(throws: OverlayNetworkStoreError.invalidZeroTierPlanet) {
            try OverlayNetworkStore.validateZeroTierPlanet(Data())
        }
        #expect(throws: OverlayNetworkStoreError.invalidZeroTierPlanet) {
            try OverlayNetworkStore.validateZeroTierPlanet(zeroTierWorld(size: 16_385))
        }
        #expect(throws: OverlayNetworkStoreError.invalidZeroTierPlanet) {
            try OverlayNetworkStore.validateZeroTierPlanet(
                zeroTierWorld(size: OverlayNetworkStore.zeroTierWorldHeaderLength - 1))
        }
        #expect(throws: OverlayNetworkStoreError.invalidZeroTierPlanet) {
            try OverlayNetworkStore.validateZeroTierPlanet(zeroTierWorld(type: 0))
        }
        #expect(throws: OverlayNetworkStoreError.zeroTierPlanetIsMoon) {
            try OverlayNetworkStore.validateZeroTierPlanet(zeroTierWorld(type: 127))
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("planet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try zeroTierWorld(size: 16_384).write(to: file)
        #expect(try OverlayNetworkStore.readZeroTierPlanet(from: file).count == 16_384)
        try zeroTierWorld(size: 20_000).write(to: file)
        #expect(throws: OverlayNetworkStoreError.invalidZeroTierPlanet) {
            _ = try OverlayNetworkStore.readZeroTierPlanet(from: file)
        }
        try zeroTierWorld(type: 127).write(to: file)
        #expect(throws: OverlayNetworkStoreError.zeroTierPlanetIsMoon) {
            _ = try OverlayNetworkStore.readZeroTierPlanet(from: file)
        }

        // The form keeps the planet with the network's settings.
        var draft = OverlayNetworkDraft(network: zeroTierLab)
        draft.planet = zeroTierWorld()
        #expect(draft.makeNetwork(id: zeroTierLab.id)?.settings
            == .zerotier(networkID: "8056c2e21c000001", planet: zeroTierWorld()))
        #expect(OverlayNetworkDraft(network: try #require(draft.makeNetwork())).planet == zeroTierWorld())
    }

    @Test func aNetworksPlanetRoundTripsThroughTheCatalog() throws {
        let network = OverlayNetwork(
            name: "ZT", settings: .zerotier(networkID: "8056c2e21c000001", planet: zeroTierWorld()))
        let decoded = try JSONDecoder().decode(
            OverlayNetwork.self, from: JSONEncoder().encode(network))
        #expect(decoded == network)
        // Networks saved without one have none.
        let plain = try JSONDecoder().decode(
            OverlayNetwork.self, from: JSONEncoder().encode(zeroTierLab))
        #expect(plain.settings == .zerotier(networkID: "8056c2e21c000001", moons: [], planet: nil))
    }

    @MainActor
    @Test func planetAndMoonChangesRebuildTheNode() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(volatileNetworks: [zeroTierLab], runtime: runtime)
        await store.connect(zeroTierLab.id)

        var custom = zeroTierLab
        custom.settings = .zerotier(networkID: "8056c2e21c000001", planet: zeroTierWorld())
        try store.update(custom)
        await runtime.reconcile()
        await store.connect(zeroTierLab.id)
        #expect(factory.built.count == 2)
        #expect(factory.built.first?.state.withLock { $0.stops } == 1)

        let moon = ZeroTierMoon(worldID: 0xab_cdef_0123, seed: 0xab_cdef_0123)
        var orbiting = zeroTierLab
        orbiting.settings = .zerotier(networkID: "8056c2e21c000001", moons: [moon])
        try store.update(orbiting)
        await runtime.reconcile()
        await store.connect(zeroTierLab.id)
        #expect(factory.built.count == 3)
        guard case .zerotier(let configuration) = factory.built.last?.spec else {
            Issue.record("Expected a ZeroTier node")
            return
        }
        #expect(configuration.moons == [moon])
        #expect(configuration.roots == nil)
    }

    @MainActor
    @Test func theDeviceWidePlanetMovesIntoEveryZeroTierNetwork() throws {
        let suite = "overlay-planet-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = VolatileSecretStore()
        let own = zeroTierWorld(marker: 5)
        let withOwn = OverlayNetwork(
            name: "Own", settings: .zerotier(networkID: "8056c2e21c000002", planet: own))
        do {
            let runtime = OverlayNetworkRuntime(
                secrets: secrets, stateRoot: root, makeNode: FakeNodeFactory().make)
            let store = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: runtime)
            try store.add(zeroTierLab)
            try store.add(withOwn)
            try store.add(tailnet)
        }
        // What an earlier build left: one planet for the whole device.
        let legacy = zeroTierWorld(marker: 9)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyFile = root.appendingPathComponent(OverlayNetworkRuntime.legacyZeroTierPlanetFileName)
        try legacy.write(to: legacyFile)

        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: root, makeNode: FakeNodeFactory().make)
        let store = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: runtime)
        #expect(store.network(id: zeroTierLab.id)?.settings
            == .zerotier(networkID: "8056c2e21c000001", planet: legacy))
        // A network with a planet of its own keeps it.
        #expect(store.network(id: withOwn.id)?.settings == withOwn.settings)
        #expect(store.network(id: tailnet.id)?.settings == tailnet.settings)
        #expect(!FileManager.default.fileExists(atPath: legacyFile.path))

        // Saved, so the next launch sees the same.
        let reopened = OverlayNetworkStore(
            defaults: defaults, secrets: secrets,
            runtime: OverlayNetworkRuntime(secrets: secrets, stateRoot: root, makeNode: FakeNodeFactory().make))
        #expect(reopened.network(id: zeroTierLab.id)?.settings
            == .zerotier(networkID: "8056c2e21c000001", planet: legacy))
    }

    @MainActor
    @Test func detailsAreRefreshedWithTheStatus() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)
        await store.refreshStatus(tailnet.id)
        #expect(store.details[tailnet.id] == OverlayNodeDetails())

        await store.connect(tailnet.id)
        let peer = OverlayPeer(id: "n1", name: "box", addresses: ["100.64.0.7"], isOnline: true)
        let details = OverlayNodeDetails(
            nodeID: "nStable", hostname: "heeler", addresses: ["100.64.0.2"], peers: [peer])
        factory.built.first?.state.withLock { $0.details = details }
        await store.refreshStatus(tailnet.id)
        #expect(store.details[tailnet.id] == details)

        await store.disconnect(tailnet.id)
        #expect(store.details[tailnet.id] == OverlayNodeDetails())
    }

    @Test func theStatusLineCountsPeersButNotZeroTierRoots() {
        let online = OverlayPeer(id: "a", name: "mac", addresses: ["100.64.0.1"], isOnline: true)
        let offline = OverlayPeer(id: "b", name: "pi", addresses: ["100.64.0.2"], isOnline: false)
        let root = OverlayPeer(id: "c", isOnline: true, role: "planet")
        let unknown = OverlayPeer(id: "d", name: "lab", addresses: ["10.0.0.4"], isOnline: nil)

        #expect(
            OverlayStatusCopy.peerCount([online, offline], kind: .tailscale)
                == "1 of 2 machines online")
        #expect(OverlayStatusCopy.peerCount([], kind: .tailscale) == "No other machines yet")
        #expect(OverlayStatusCopy.shortPeerCount([online, offline], kind: .tailscale) == "1 of 2 online")
        #expect(OverlayStatusCopy.shortPeerCount([online, unknown], kind: .easytier) == "2 peers")
        #expect(OverlayStatusCopy.shortPeerCount([root], kind: .zerotier) == nil)
        #expect(OverlayStatusCopy.peerCount([online, root], kind: .zerotier) == "1 of 1 member online")
        #expect(OverlayStatusCopy.peerCount([root], kind: .zerotier) == "No other members yet")
        #expect(OverlayStatusCopy.peerCount([], kind: .easytier) == "No other peers yet")
        #expect(OverlayStatusCopy.peerCount([online, unknown], kind: .easytier) == "2 peers")
    }

    @Test func aTailscaleNetworkWithoutALoginReadsAsNeedingTheUser() throws {
        #expect(OverlayStatusCopy.summary(.stopped, failure: nil) == "Not connected")
        #expect(OverlayStatusCopy.tone(.stopped, failure: nil) == .idle)
        #expect(OverlayStatusCopy.summary(.stopped, failure: nil, needsSignIn: true) == "Not signed in")
        #expect(OverlayStatusCopy.tone(.stopped, failure: nil, needsSignIn: true) == .attention)
        // A sign-out says so, whatever else is known.
        #expect(
            OverlayStatusCopy.summary(.stopped, failure: nil, signedOut: true, needsSignIn: true)
                == "Signed out")
        #expect(OverlayStatusCopy.tone(.online(addresses: []), failure: nil) == .ok)
        let timedOut = TransportError.overlayFailed(network: "T", reason: .timedOut)
        #expect(OverlayStatusCopy.tone(.stopped, failure: timedOut) == .failed)
    }

    @Test func statusIsShortAndTheReasonGoesUnderIt() throws {
        let notReady = TransportError.overlayFailed(network: "ZT", reason: .notReady("ACCESS_DENIED"))
        #expect(OverlayStatusCopy.summary(.stopped, failure: notReady) == "Not ready")
        let explanation = try #require(OverlayStatusCopy.explanation(.stopped, failure: notReady))
        #expect(explanation.hasPrefix("ACCESS_DENIED. "))
        #expect(!explanation.contains("“ZT”"))

        let login = try #require(URL(string: "https://login.tailscale.com/a/1"))
        #expect(OverlayStatusCopy.summary(.needsLogin(login), failure: nil) == "Needs sign-in")
        #expect(
            OverlayStatusCopy.summary(.online(addresses: ["100.64.0.2"]), failure: nil) == "Connected")
        #expect(OverlayStatusCopy.explanation(.online(addresses: []), failure: nil) == nil)
        #expect(OverlayStatusCopy.summary(.failed("boom"), failure: nil) == "Failed")
        #expect(OverlayStatusCopy.explanation(.failed("boom"), failure: nil) == "boom.")
        #expect(
            OverlayStatusCopy.summary(
                .stopped, failure: .overlayFailed(network: "ZT", reason: .timedOut)) == "Timed out")
        #expect(
            OverlayStatusCopy.explanation(
                .stopped, failure: .overlayFailed(network: "ZT", reason: .timedOut))
                == "The network did not answer in time.")
        let signIn = OverlayStatusCopy.explanation(
            .needsLogin(login), failure: .overlayFailed(network: "TS", reason: .loginRequired(login)))
        #expect(signIn?.contains("Settings") == false)
    }

    @Test func peerSummaryListsWhatTheOverlayKnows() {
        #expect(
            OverlayStatusCopy.peerSummary(
                OverlayPeer(id: "a", isOnline: true, isDirect: false, latency: .milliseconds(12.4)))
                == "Online · Relayed · 12 ms")
        #expect(OverlayStatusCopy.peerSummary(OverlayPeer(id: "a", isOnline: false)) == "Offline")
        #expect(OverlayStatusCopy.peerSummary(OverlayPeer(id: "a")) == "")
        #expect(OverlayStatusCopy.latencyText(.microseconds(300)) == "<1 ms")
    }
}

@Suite("Overlay Network sign-out and identity lifecycle")
struct OverlayNetworkSignedOutTests {
    @Test func aSignedOutNetworkRefusesDialsUntilConnectedFromSettings() async throws {
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = VolatileSecretStore()
        try secrets.write(
            Data("tskey-auth-1".utf8), account: "overlay-tailscale-authkey-\(tailnet.id.uuidString)")
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(secrets: secrets, stateRoot: root, makeNode: factory.make)
        runtime.publish([.init(network: tailnet)])
        try await runtime.start(networkID: tailnet.id, timeout: .seconds(1))

        try await runtime.logout(networkID: tailnet.id, timeout: .seconds(1))

        let signedOut = TransportError.overlayFailed(network: "Home", reason: .signedOut)
        #expect(!signedOut.isRetryable)
        await #expect(throws: signedOut) {
            _ = try await runtime.dial(networkID: tailnet.id, host: "box", port: 22, timeout: .seconds(1))
        }
        #expect(factory.built.count == 1)

        // A relaunch remembers it.
        let relaunched = OverlayNetworkRuntime(secrets: secrets, stateRoot: root, makeNode: factory.make)
        relaunched.publish([.init(network: tailnet)])
        #expect(await relaunched.isSignedOut(tailnet.id))
        await #expect(throws: signedOut) {
            _ = try await relaunched.dial(networkID: tailnet.id, host: "box", port: 22, timeout: .seconds(1))
        }

        // Connect in Settings is the way back.
        try await relaunched.start(networkID: tailnet.id, timeout: .seconds(1))
        #expect(!(await relaunched.isSignedOut(tailnet.id)))
        _ = try await relaunched.dial(networkID: tailnet.id, host: "box", port: 22, timeout: .seconds(1))
        #expect(factory.built.count == 2)
    }

    @MainActor
    @Test func theStoreShowsSignedOutUntilConnect() async throws {
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: runtime)
        await store.connect(tailnet.id)
        await store.signOut(tailnet.id)
        #expect(store.signedOut == [tailnet.id])
        #expect(
            OverlayStatusCopy.summary(store.statuses[tailnet.id], failure: nil, signedOut: true)
                == "Signed out")

        await store.connect(tailnet.id)
        #expect(store.signedOut.isEmpty)
    }

    @Test func concurrentRequestsShareOneGenerationAndANodeWaitsForIt() async throws {
        let secrets = VolatileSecretStore()
        let generator = IdentityGenerator(delay: 0.2)
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make,
            generateZeroTierIdentity: generator.generate)
        runtime.publish([.init(network: zeroTierLab)])

        async let first = runtime.ensureZeroTierIdentity()
        async let second = runtime.ensureZeroTierIdentity()
        try await Task.sleep(for: .milliseconds(50))
        // The actor stays free while the key is derived.
        #expect(await runtime.status(networkID: zeroTierLab.id) == .stopped)
        try await runtime.start(networkID: zeroTierLab.id, timeout: .seconds(1))
        let identities = try await [first, second]

        let minted = zeroTierIdentity("a1b2c3d4e5")
        #expect(identities == [minted, minted])
        #expect(generator.count == 1)
        guard case .zerotier(let configuration) = factory.built.first?.spec else {
            Issue.record("Expected a ZeroTier node")
            return
        }
        #expect(configuration.identity == minted)
    }

    @Test func aStartThatFailsBeforeBootingLeavesNoPendingMint() async throws {
        let root = temporaryStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generator = IdentityGenerator()
        let factory = FakeNodeFactory()
        factory.failure.withLock { $0 = .startFailed("no route") }
        let runtime = OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: root, makeNode: factory.make,
            generateZeroTierIdentity: generator.generate)
        runtime.publish([.init(network: zeroTierLab)])

        await #expect(throws: TransportError.self) {
            try await runtime.start(networkID: zeroTierLab.id, timeout: .seconds(1))
        }
        #expect(try await runtime.ensureZeroTierIdentity() == zeroTierIdentity("a1b2c3d4e5"))
        #expect(generator.count == 1)
    }

    @MainActor
    @Test func aPreGeneratedIdentityIsKeptUntilForgotten() async throws {
        let secrets = VolatileSecretStore()
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: FakeNodeFactory().make,
            generateZeroTierIdentity: IdentityGenerator().generate)
        let store = OverlayNetworkStore(volatileNetworks: [], runtime: runtime)

        // The Add form generated one, then was cancelled.
        await store.prepareZeroTierIdentity()
        #expect(store.hasUnusedZeroTierIdentity)
        try store.add(zeroTierLab)
        #expect(!store.hasUnusedZeroTierIdentity)
        try store.remove(zeroTierLab.id)
        #expect(store.zeroTierNodeID == nil)

        await store.prepareZeroTierIdentity()
        try store.removeUnusedZeroTierIdentity()
        #expect(store.zeroTierNodeID == nil)
        #expect(!store.hasUnusedZeroTierIdentity)
    }
}

private let officialServer = "udp://config-server.easytier.cn:22020"

/// Stands in for the package's rules: a bare name is the official server's.
private let testNormalizer = OverlayNetworkDraft.ConfigServerNormalizer { text in
    if text.allSatisfy({ $0.isLetter || $0.isNumber }) { return "\(officialServer)/\(text)" }
    return text.hasPrefix("udp://") || text.hasPrefix("tcp://") ? text : nil
}

@Suite("Overlay Network EasyTier config server")
struct OverlayNetworkConfigServerTests {
    private let machineID: UUID
    private let configured: OverlayNetwork

    init() {
        let machineID = UUID()
        self.machineID = machineID
        configured = OverlayNetwork(
            name: "Console",
            settings: .easytierConfigServer(
                server: officialServer, machineID: machineID, hostname: "phone"))
    }

    @Test func configServerNetworksRoundTripWithoutTheirToken() throws {
        let data = try JSONEncoder().encode(configured)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"source\":\"configServer\""))
        #expect(!text.contains("alice"))
        #expect(try JSONDecoder().decode(OverlayNetwork.self, from: data) == configured)
        #expect(configured.kind == .easytier)
        #expect(
            OverlaySecretAccount.secret(for: configured)
                == "overlay-easytier-configserver-\(configured.id.uuidString)")
    }

    @MainActor
    @Test func anUnknownSourceIsHiddenButSurvivesWrites() throws {
        let suite = "overlay-network-store-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = """
            {"version":1,"networks":[
              {"id":"\(UUID().uuidString)","name":"Future","kind":"easytier","source":"cloud","x":1}
            ]}
            """
        defaults.set(Data(stored.utf8), forKey: "overlayNetworks")
        let store = OverlayNetworkStore(
            defaults: defaults, secrets: VolatileSecretStore(),
            runtime: OverlayNetworkRuntime(
                secrets: VolatileSecretStore(), stateRoot: nil, makeNode: FakeNodeFactory().make))

        #expect(store.catalogLoadError == nil)
        #expect(store.networks.isEmpty)
        try store.add(tailnet)
        let text = String(decoding: try #require(defaults.data(forKey: "overlayNetworks")), as: UTF8.self)
        #expect(text.contains("\"cloud\""))
    }

    @Test func theDraftNormalizesTheServerAndKeepsTheTokenAsTheSecret() throws {
        var draft = OverlayNetworkDraft(normalizer: testNormalizer)
        draft.kind = .easytier
        draft.easyTierSource = .configServer
        #expect(!draft.isValid)
        draft.configServer = "http://host:1/x"
        #expect(draft.configServerURL == nil)
        #expect(!draft.isValid)
        draft.configServer = " alice "
        #expect(draft.configServerURL == "\(officialServer)/alice")
        #expect(draft.canSave(hasStoredSecret: false))
        #expect(draft.secretUpdate == "\(officialServer)/alice")
        let network = try #require(draft.makeNetwork())
        #expect(
            network.settings
                == .easytierConfigServer(
                    server: officialServer, machineID: draft.machineID, hostname: "heeler"))

        // Editing prefills the full URL and keeps the machine ID.
        let edited = OverlayNetworkDraft(
            network: network, configServerURL: "\(officialServer)/alice", normalizer: testNormalizer)
        #expect(edited.configServer == "\(officialServer)/alice")
        #expect(edited.machineID == draft.machineID)
        #expect(try #require(edited.makeNetwork(id: network.id)) == network)

        // Switching to manual needs a network secret of its own.
        var manual = edited
        manual.easyTierSource = .manual
        manual.networkName = "lab"
        manual.peers = "tcp://p:11010"
        #expect(!manual.canSave(hasStoredSecret: true))
        manual.secret = "s"
        #expect(manual.canSave(hasStoredSecret: true))
    }

    @Test func theTokenIsMaskedAndTheOriginKept() {
        #expect(
            OverlayNetwork.easyTierConfigServerOrigin("tcp://console.lab:22020/alice")
                == "tcp://console.lab:22020")
        #expect(OverlayNetwork.maskedConfigServerToken("udp://h:1/alice") == "al•••")
        #expect(OverlayNetwork.maskedConfigServerToken("udp://h:1/ab") == "ab•••")
        #expect(OverlayNetwork.maskedConfigServerToken("udp://h:1") == nil)
    }

    @Test func configServerTransportsCarryTheirRisk() throws {
        let ws = try #require(EasyTierConfigServerCopy.transportWarning(for: "ws://console.lab:8080/alice"))
        #expect(ws.contains("clear text") && ws.contains("wss://"))
        for url in ["udp://config-server.easytier.cn:22020/alice", "tcp://console.lab:22020/alice"] {
            let warning = try #require(EasyTierConfigServerCopy.transportWarning(for: url))
            #expect(warning.contains("do not verify the server"))
        }
        #expect(EasyTierConfigServerCopy.transportWarning(for: "wss://console.lab/api/alice") == nil)
    }

    @MainActor
    @Test func theStoreKeepsTheURLInTheKeychainAndResetsTheMachineID() async throws {
        let suite = "overlay-network-store-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = VolatileSecretStore()
        let factory = FakeNodeFactory()
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make)
        let store = OverlayNetworkStore(defaults: defaults, secrets: secrets, runtime: runtime)
        let manual = OverlayNetwork(
            id: configured.id, name: "Console",
            settings: .easytier(networkName: "lab", peers: ["tcp://p:1"], hostname: "phone"))
        try store.add(manual, secret: "s")

        // Switching the source moves the secret to the config server's account.
        try store.update(configured, secret: "\(officialServer)/alice")
        #expect(store.secretText(for: configured) == "\(officialServer)/alice")
        #expect(
            try secrets.read(account: "overlay-easytier-secret-\(configured.id.uuidString)") == nil)
        let defaultsText = String(
            decoding: try #require(defaults.data(forKey: "overlayNetworks")), as: UTF8.self)
        #expect(!defaultsText.contains("alice"))

        await store.connect(configured.id)
        guard case .easytier(let configuration) = factory.built.last?.spec else {
            Issue.record("Expected an EasyTier node")
            return
        }
        #expect(
            configuration
                == EasyTierConfiguration(
                    source: .configServer(
                        EasyTierConfigServer(url: "\(officialServer)/alice", machineID: machineID)),
                    hostname: "phone", instanceKey: configured.id.uuidString))

        let newID = UUID()
        try store.resetMachineID(configured.id, to: newID)
        await runtime.reconcile()
        await store.connect(configured.id)
        #expect(factory.built.count == 2)
        guard
            case .easytier(let rebuilt) = factory.built.last?.spec,
            case .configServer(let server) = rebuilt.source
        else {
            Issue.record("Expected a config-server node")
            return
        }
        #expect(server.machineID == newID)
        #expect(server.requireEncryption)

        // Turning required encryption off is a settings change: a new
        // revision, a rebuilt node, and a machine ID reset keeps it off.
        let open = OverlayNetwork(
            id: configured.id, name: "Console",
            settings: .easytierConfigServer(
                server: officialServer, machineID: newID, hostname: "phone", requireEncryption: false))
        try store.update(open)
        await runtime.reconcile()
        await store.connect(configured.id)
        #expect(factory.built.count == 3)
        guard
            case .easytier(let reopened) = factory.built.last?.spec,
            case .configServer(let openServer) = reopened.source
        else {
            Issue.record("Expected a config-server node")
            return
        }
        #expect(!openServer.requireEncryption)
        try store.resetMachineID(configured.id)
        guard case .easytierConfigServer(_, _, _, let stillOpen) = store.network(id: configured.id)?.settings
        else {
            Issue.record("Expected a config-server network")
            return
        }
        #expect(!stillOpen)
    }

    @Test func encryptionIsRequiredUnlessTurnedOff() throws {
        // Saved before the setting existed: required.
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"Console","kind":"easytier","source":"configServer",
             "server":"\(officialServer)","machineID":"\(machineID.uuidString)","hostname":"phone"}
            """
        let decoded = try JSONDecoder().decode(OverlayNetwork.self, from: Data(legacy.utf8))
        guard case .easytierConfigServer(_, _, _, let required) = decoded.settings else {
            Issue.record("Expected a config-server network")
            return
        }
        #expect(required)

        let open = OverlayNetwork(
            name: "Console",
            settings: .easytierConfigServer(
                server: officialServer, machineID: machineID, hostname: "phone", requireEncryption: false))
        let data = try JSONEncoder().encode(open)
        #expect(String(decoding: data, as: UTF8.self).contains("\"requireEncryption\":false"))
        #expect(try JSONDecoder().decode(OverlayNetwork.self, from: data) == open)

        // The draft starts with it on and carries an edit through.
        var draft = OverlayNetworkDraft(network: open, configServerURL: "\(officialServer)/alice", normalizer: testNormalizer)
        #expect(!draft.requireEncryption)
        #expect(try #require(draft.makeNetwork(id: open.id)) == open)
        draft.requireEncryption = true
        guard case .easytierConfigServer(_, _, _, let on) = try #require(draft.makeNetwork(id: open.id)).settings else {
            Issue.record("Expected a config-server network")
            return
        }
        #expect(on)
        #expect(OverlayNetworkDraft(normalizer: testNormalizer).requireEncryption)
        let warning = EasyTierConfigServerCopy.encryptionOffWarning
        #expect(warning.contains("clear text") && warning.contains("network secret") && warning.contains("pose as the server"))
    }

    @Test func aNodeWaitingForAnAssignmentIsNotReady() async throws {
        let secrets = VolatileSecretStore()
        try secrets.write(
            Data("\(officialServer)/alice".utf8),
            account: try #require(OverlaySecretAccount.secret(for: configured)))
        let factory = FakeNodeFactory()
        factory.failure.withLock { $0 = .dialFailed("no route") }
        let runtime = OverlayNetworkRuntime(
            secrets: secrets, stateRoot: temporaryStateRoot(), makeNode: factory.make)
        runtime.publish([.init(network: configured)])
        _ = try? await runtime.dial(networkID: configured.id, host: "10.0.0.2", port: 22, timeout: .seconds(1))
        factory.built.first?.state.withLock { $0.status = .waiting("No network is assigned") }

        do {
            _ = try await runtime.dial(
                networkID: configured.id, host: "10.0.0.2", port: 22, timeout: .seconds(1))
            Issue.record("Expected a failure")
        } catch let error as TransportError {
            #expect(error == .overlayFailed(network: "Console", reason: .notReady("No network is assigned")))
            #expect(error.isRetryable)
        }
        #expect(OverlayStatusCopy.summary(.waiting("x"), failure: nil) == "Waiting")
        #expect(OverlayStatusCopy.explanation(.waiting("No network is assigned"), failure: nil)
            == "No network is assigned.")
    }
}

// MARK: Cancelling while connecting

/// A node whose native work ignores cancellation for `hang`, as a blocking
/// tsnet, libzt or EasyTier call does, and whose dial then hands back a
/// real descriptor.
private final class BlockingOverlayNode: OverlayNode, Sendable {
    struct State {
        var hang: Duration?
        var failure: OverlayError?
        var starts = 0
        var stops = 0
        var online = false
        var lateDescriptor: Int32?
        var releases = 0
    }

    let kind: OverlayKind
    let state: Mutex<State>

    init(kind: OverlayKind, hang: Duration?, failure: OverlayError? = nil) {
        self.kind = kind
        state = Mutex(State(hang: hang, failure: failure))
    }

    /// Sleeps in a task of its own, so cancelling the caller does not end it.
    private func block() async {
        guard let hang = state.withLock({ $0.hang }) else { return }
        await Task.detached { try? await Task.sleep(for: hang) }.value
    }

    func start(timeout: Duration) async throws {
        state.withLock { $0.starts += 1 }
        await block()
        if let failure = state.withLock({ $0.failure }) { throw failure }
        state.withLock { $0.online = true }
    }

    func dial(host: String, port: UInt16, timeout: Duration) async throws -> OverlayDialedStream {
        try await start(timeout: timeout)
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw OverlayError.dialFailed("socketpair")
        }
        Darwin.close(pair[1])
        state.withLock { $0.lateDescriptor = pair[0] }
        return OverlayDialedStream(descriptor: pair[0]) {
            self.state.withLock { $0.releases += 1 }
        }
    }

    func status() async -> OverlayNodeStatus {
        state.withLock { $0.online } ? .online(addresses: ["100.64.0.2"]) : .starting
    }

    func stop() async {
        state.withLock {
            $0.stops += 1
            $0.online = false
        }
    }

    func details() async -> OverlayNodeDetails { OverlayNodeDetails() }
    func logout(timeout: Duration) async throws {}
}

private final class BlockingNodeFactory: Sendable {
    let nodes = Mutex<[BlockingOverlayNode]>([])
    /// Applied to each node as it is built.
    let hang = Mutex<Duration?>(.seconds(2))
    let failure = Mutex<OverlayError?>(nil)

    var make: OverlayNetworkRuntime.NodeFactory {
        { spec, _ in
            let kind: OverlayKind =
                switch spec {
                case .tailscale: .tailscale
                case .zerotier: .zerotier
                case .easytier: .easytier
                }
            let node = BlockingOverlayNode(
                kind: kind, hang: self.hang.withLock { $0 },
                failure: self.failure.withLock { $0 })
            self.nodes.withLock { $0.append(node) }
            return node
        }
    }

    var built: [BlockingOverlayNode] { nodes.withLock { $0 } }
}

/// Polls `condition` for up to two seconds.
private func eventually(
    isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("Overlay Network cancellation")
struct OverlayNetworkCancellationTests {
    private let zeroTier = OverlayNetwork(
        name: "ZT", settings: .zerotier(networkID: "8056c2e21c000001"))

    private func makeRuntime(_ factory: BlockingNodeFactory) -> OverlayNetworkRuntime {
        OverlayNetworkRuntime(
            secrets: VolatileSecretStore(), stateRoot: temporaryStateRoot(), makeNode: factory.make)
    }

    @Test func aCancelledStartReturnsAtOnceAndAFreshConnectWorks() async throws {
        let factory = BlockingNodeFactory()
        let runtime = makeRuntime(factory)
        runtime.publish([.init(network: tailnet)])

        let starting = Task { try await runtime.start(networkID: tailnet.id, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = ContinuousClock.now
        starting.cancel()
        await #expect(throws: TransportError.cancelled) { try await starting.value }
        // Not the node's two seconds, let alone the 30 s timeout.
        #expect(ContinuousClock.now - cancelled < .milliseconds(800))

        // The node that never came up is stopped and discarded; the next
        // Connect builds a new one instead of joining the abandoned start.
        let settled1 = await eventually { await runtime.activeNetworkIDs.isEmpty }
        #expect(settled1)
        factory.hang.withLock { $0 = nil }
        try await runtime.start(networkID: tailnet.id, timeout: .seconds(5))
        #expect(factory.built.count == 2)
        #expect(await runtime.status(networkID: tailnet.id) == .online(addresses: ["100.64.0.2"]))
        // The old node stops before the new one is used.
        #expect(factory.built.first?.state.withLock { $0.stops } == 1)
    }

    @Test func aCancelledZeroTierStartKeepsItsNode() async throws {
        let factory = BlockingNodeFactory()
        let runtime = makeRuntime(factory)
        runtime.publish([.init(network: zeroTier)])

        let starting = Task { try await runtime.start(networkID: zeroTier.id, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        starting.cancel()
        await #expect(throws: TransportError.cancelled) { try await starting.value }
        try await Task.sleep(for: .milliseconds(100))
        // Joined networks stay joined, so a later authorization applies.
        #expect(await runtime.activeNetworkIDs == [zeroTier.id])
        #expect(factory.built.first?.state.withLock { $0.stops } == 0)
    }

    @Test func aCancelledStartKeepsANodeAnotherDialWaitsFor() async throws {
        let factory = BlockingNodeFactory()
        factory.hang.withLock { $0 = .milliseconds(500) }
        let runtime = makeRuntime(factory)
        runtime.publish([.init(network: tailnet)])

        let dialling = Task {
            try await runtime.dial(networkID: tailnet.id, host: "box", port: 22, timeout: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        let starting = Task { try await runtime.start(networkID: tailnet.id, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(50))
        starting.cancel()
        await #expect(throws: TransportError.cancelled) { try await starting.value }

        let stream = try await dialling.value
        Darwin.close(stream.descriptor)
        stream.release()
        #expect(factory.built.count == 1)
        #expect(factory.built.first?.state.withLock { $0.stops } == 0)
    }

    @Test func cancellationNeitherCountsNorResetsStartFailures() async throws {
        let factory = BlockingNodeFactory()
        factory.hang.withLock { $0 = nil }
        factory.failure.withLock { $0 = .startFailed("ACCESS_DENIED") }
        let runtime = makeRuntime(factory)
        runtime.publish([.init(network: zeroTier)])

        func dialFailure() async -> TransportError? {
            do {
                _ = try await runtime.dial(
                    networkID: zeroTier.id, host: "10.0.0.2", port: 22, timeout: .seconds(1))
                return nil
            } catch {
                return error as? TransportError
            }
        }
        for _ in 1..<(OverlayNetworkRuntime.startFailureLimit - 1) {
            #expect(await dialFailure() == .overlayFailed(network: "ZT", reason: .notReady("ACCESS_DENIED")))
        }
        let node = try #require(factory.built.first)
        node.state.withLock { $0.hang = .seconds(1) }
        let dialling = Task {
            try await runtime.dial(networkID: zeroTier.id, host: "10.0.0.2", port: 22, timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(50))
        dialling.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await dialling.value }
        node.state.withLock { $0.hang = nil }

        // Not counted: one failure short of the limit is still retryable…
        #expect(await dialFailure() == .overlayFailed(network: "ZT", reason: .notReady("ACCESS_DENIED")))
        // …and not reset: the next one reaches it.
        #expect(await dialFailure() == .overlayFailed(network: "ZT", reason: .startFailed("ACCESS_DENIED")))
    }

    @Test func aStreamThatArrivesAfterCancellationIsClosedAndReleased() async throws {
        let factory = BlockingNodeFactory()
        factory.hang.withLock { $0 = .milliseconds(300) }
        let runtime = makeRuntime(factory)
        runtime.publish([.init(network: zeroTier)])

        let dialling = Task {
            try await runtime.dial(networkID: zeroTier.id, host: "10.0.0.2", port: 22, timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(50))
        dialling.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await dialling.value }

        let node = try #require(factory.built.first)
        let settled2 = await eventually { node.state.withLock { $0.releases } == 1 }
        #expect(settled2)
        let descriptor = try #require(node.state.withLock { $0.lateDescriptor })
        // Closed: the descriptor no longer names an open file.
        errno = 0
        #expect(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF)
    }

    @MainActor
    @Test func theStoreCancelsAConnectAtOnceWithoutAFailure() async throws {
        let factory = BlockingNodeFactory()
        let store = OverlayNetworkStore(volatileNetworks: [tailnet], runtime: makeRuntime(factory))

        let connecting = Task { await store.connect(tailnet.id, timeout: .seconds(30)) }
        let settled3 = await eventually { store.connecting.contains(tailnet.id) }
        #expect(settled3)
        try await Task.sleep(for: .milliseconds(50))
        store.cancelConnect(tailnet.id)
        #expect(!store.connecting.contains(tailnet.id))
        #expect(store.connectFailures[tailnet.id] == nil)
        await connecting.value
        #expect(store.connectFailures[tailnet.id] == nil)
        let stopped = await eventually {
            await store.refreshStatus(tailnet.id)
            return store.statuses[tailnet.id] == .stopped
        }
        #expect(stopped)

        factory.hang.withLock { $0 = nil }
        await store.connect(tailnet.id)
        #expect(store.connectFailures[tailnet.id] == nil)
        #expect(store.statuses[tailnet.id] == .online(addresses: ["100.64.0.2"]))
    }
}
