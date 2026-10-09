import CryptoKit
import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Host onboarding store")
struct HostOnboardingStoreTests {
    private static let healthyPing = Result<ServerInfo, TransportError>.success(
        ServerInfo(version: "0.7.5", protocolVersion: 17))
    private let keyBlob = Data("fake-host-key".utf8)

    private func makeStore(
        host: Host = .fixture(),
        outcome: FakeTransportConnector.Outcome = .connects(pingResult: healthyPing),
        presentedKeyBlob: Data? = nil,
        knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore(),
        password: String? = nil,
        sessions: [HerdrSession] = [],
        plugin: Result<HeelerPluginInstallation?, TransportError>? = nil,
        fingerprintTimeout: Duration = .seconds(5)
    ) throws -> (HostOnboardingStore, FakeTransportConnector) {
        let connector = FakeTransportConnector(
            outcome: outcome, presentedKeyBlob: presentedKeyBlob, sessions: sessions,
            plugin: plugin)
        let secrets = InMemorySecretStore()
        if let password {
            try secrets.write(
                Data(password.utf8), account: HostStore.passwordAccount(for: host.id))
        }
        let store = HostOnboardingStore(
            host: host,
            connector: connector,
            knownHosts: knownHosts,
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: secrets),
            fingerprintTimeout: fingerprintTimeout)
        return (store, connector)
    }

    /// Polls until `condition` holds, yielding the main actor so the store's
    /// run task can progress in between.
    private func waitUntil(
        _ comment: Comment, condition: () -> Bool
    ) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), comment)
    }

    @Test func healthyHostGoesAllGreen() async throws {
        let (store, connector) = try makeStore()

        await store.runChecks()

        #expect(store.phase == .finished)
        #expect(store.report?.isFullyPassed == true)
        #expect(store.serverInfo == ServerInfo(version: "0.7.5", protocolVersion: 17))
        let transport = try #require(await connector.transports.last)
        #expect(await transport.isClosed)
    }

    @Test func passingPreflightReadsThePluginBeforeClosing() async throws {
        let installation = HeelerPluginInstallation(version: "0.5.0")
        let (store, connector) = try makeStore(plugin: .success(installation))
        #expect(store.pluginStatus == .checking)

        await store.runChecks()

        #expect(store.pluginStatus == .installed(installation))
        let transport = try #require(await connector.transports.last)
        #expect(await transport.pluginReadsWhileOpen == [true])
        #expect(await transport.isClosed)
    }

    @Test func aFailedPluginReadLeavesThePreflightGreen() async throws {
        for (plugin, status) in [
            (nil, HeelerPluginStatus.unavailable),
            (.success(nil), .notInstalled),
            (.failure(.hostFeatureUnavailable(feature: "The Heeler plugin")), .unsupportedPlatform),
        ] as [(Result<HeelerPluginInstallation?, TransportError>?, HeelerPluginStatus)] {
            let (store, _) = try makeStore(plugin: plugin)
            await store.runChecks()
            #expect(store.report?.isFullyPassed == true)
            #expect(store.pluginStatus == status)
        }
    }

    @Test func aFailedPingSkipsThePluginRead() async throws {
        let (store, connector) = try makeStore(
            outcome: .connects(pingResult: .failure(.protocolVersionMismatch(server: 9, supported: 17))),
            plugin: .success(HeelerPluginInstallation(version: "0.6.0")))

        await store.runChecks()

        #expect(store.pluginStatus == .unavailable)
        let transport = try #require(await connector.transports.last)
        #expect(await transport.pluginReadsWhileOpen.isEmpty)
    }

    @Test func sessionDiscoveryPublishesDefaultAndNamedSessions() async throws {
        let sessions = [
            HerdrSession(name: "default", isDefault: true, isRunning: true),
            HerdrSession(name: "work", isDefault: false, isRunning: true),
        ]
        let (store, _) = try makeStore(sessions: sessions)

        await store.runChecks()

        #expect(store.availableSessions == sessions)
    }

    @Test func selectingADiscoveredSessionUpdatesTheCatalogHost() throws {
        let host = Host.fixture()
        let suiteName = "HostOnboardingStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        try catalog.add(host)
        let (store, _) = try makeStore(host: host)

        try store.selectSession(
            HerdrSession(name: "work", isDefault: false, isRunning: true),
            in: catalog)

        #expect(catalog.hosts.first?.sessionName == "work")
    }

    @Test func connectFailureFailsTheConnectionCheck() async throws {
        let (store, _) = try makeStore(
            outcome: .connectFails(.sshUnreachable(detail: "connection refused")))

        await store.runChecks()

        guard case .failed = try #require(store.report)[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(store.serverInfo == nil)
    }

    @Test func corruptDeviceKeyExplainsTheReplacementRecovery() async throws {
        let account = "corrupt-device-key"
        let secrets = InMemorySecretStore()
        try secrets.write(Data("not-an-ed25519-key".utf8), account: account)
        let connector = FakeTransportConnector(outcome: .connects(pingResult: Self.healthyPing))
        let store = HostOnboardingStore(
            host: .fixture(authMethod: .deviceKey),
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: secrets, account: account), secrets: secrets))

        await store.runChecks()

        guard case .failed(let hint) = try #require(store.report)[.connection] else {
            Issue.record("a corrupt Device Key should fail the connection check")
            return
        }
        #expect(hint.contains("Replace Device Key"))
        #expect(hint.contains("authorized_keys"))
        #expect(await connector.capturedSettings.isEmpty)
    }

    @Test func corruptRSAKeyExplainsThatRegistrationMustBeRepaired() async throws {
        let account = "corrupt-rsa-key"
        let secrets = InMemorySecretStore()
        try secrets.write(Data("not-an-rsa-key".utf8), account: account)
        let connector = FakeTransportConnector(outcome: .connects(pingResult: Self.healthyPing))
        let store = HostOnboardingStore(
            host: .fixture(authMethod: .rsaKey),
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                rsaKeys: RSAKeyStore(secrets: secrets, account: account),
                secrets: secrets))

        await store.runChecks()

        guard case .failed(let hint) = try #require(store.report)[.connection] else {
            Issue.record("a corrupt RSA Key should fail the connection check")
            return
        }
        #expect(hint.contains("RSA Key is corrupted"))
        #expect(hint.contains("every Host"))
        #expect(await connector.capturedSettings.isEmpty)
    }

    @Test func pingFailureFailsItsCheckAndStillClosesTheTransport() async throws {
        let (store, connector) = try makeStore(
            outcome: .connects(
                pingResult: .failure(.protocolVersionMismatch(server: 16, supported: 17))))

        await store.runChecks()

        guard case .failed = try #require(store.report)[.protocolCompatible] else {
            Issue.record("protocol check should fail")
            return
        }
        let transport = try #require(await connector.transports.last)
        #expect(await transport.isClosed)
    }

    @Test func firstConnectPublishesTheCandidateAndTrustPersistsTheFingerprint() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let host = Host.fixture(address: "box.example")
        let (store, _) = try makeStore(
            host: host, presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        let run = Task { await store.runChecks() }
        try await waitUntil("candidate should surface") { store.pendingFingerprint != nil }
        let candidate = try #require(store.pendingFingerprint)
        #expect(candidate.host == "box.example")
        #expect(candidate.fingerprint == HostKeyFingerprint(publicKeyBlob: keyBlob))

        store.confirmFingerprint(trusted: true)
        await run.value

        #expect(store.pendingFingerprint == nil)
        #expect(store.report?.isFullyPassed == true)
        #expect(
            await knownHosts.fingerprint(host: "box.example", port: 22)
                == HostKeyFingerprint(publicKeyBlob: keyBlob))
    }

    @Test func decliningTheFingerprintFailsTheRunAndPersistsNothing() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let (store, _) = try makeStore(presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        let run = Task { await store.runChecks() }
        try await waitUntil("candidate should surface") { store.pendingFingerprint != nil }
        store.confirmFingerprint(trusted: false)
        await run.value

        #expect(store.pendingFingerprint == nil)
        guard case .failed = try #require(store.report)[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(await knownHosts.fingerprint(host: "host.example", port: 22) == nil)
    }

    @Test func unansweredFingerprintTimesOutAsDeclined() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let (store, _) = try makeStore(
            presentedKeyBlob: keyBlob, knownHosts: knownHosts,
            fingerprintTimeout: .milliseconds(50))

        await store.runChecks()

        #expect(store.pendingFingerprint == nil)
        guard case .failed = try #require(store.report)[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(await knownHosts.fingerprint(host: "host.example", port: 22) == nil)
    }

    @Test func alreadyTrustedFingerprintNeverPrompts() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: "host.example", port: 22)
        let (store, _) = try makeStore(presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        await store.runChecks()

        #expect(store.pendingFingerprint == nil)
        #expect(store.report?.isFullyPassed == true)
    }

    @Test func explicitTrustReplacesThePresentedHostKeyAndReconnects() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let trusted = HostKeyFingerprint(publicKeyBlob: Data("trusted-host-key".utf8))
        let presented = HostKeyFingerprint(publicKeyBlob: keyBlob)
        await knownHosts.setFingerprint(trusted, host: "host.example", port: 22)
        let (store, _) = try makeStore(presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        await store.runChecks()

        #expect(
            store.pendingHostKeyReplacement
                == HostKeyReplacement(known: trusted, presented: presented))
        #expect(await knownHosts.fingerprint(host: "host.example", port: 22) == trusted)

        await store.trustPresentedHostKey()

        #expect(store.pendingHostKeyReplacement == nil)
        #expect(store.report?.isFullyPassed == true)
        #expect(await knownHosts.fingerprint(host: "host.example", port: 22) == presented)
    }

    @Test func settingsCarryTheHostCoordinatesAndStoredPassword() async throws {
        var host = Host.fixture(address: "box.example", username: "dev", authMethod: .password)
        host.port = 2222
        host.sessionName = " work "
        let (store, connector) = try makeStore(host: host, password: "hunter2")

        await store.runChecks()

        let settings = try #require(await connector.capturedSettings.first)
        #expect(settings.host == "box.example")
        #expect(settings.port == 2222)
        #expect(settings.username == "dev")
        #expect(settings.socket == .namedSession("work"))
        guard case .password("hunter2") = settings.credentials else {
            Issue.record("credentials should be the stored password")
            return
        }
    }

    @Test func deviceKeyHostConnectsWithTheDeviceKey() async throws {
        let (store, connector) = try makeStore(host: .fixture(authMethod: .deviceKey))

        await store.runChecks()

        let settings = try #require(await connector.capturedSettings.first)
        guard case .ed25519 = settings.credentials else {
            Issue.record("credentials should be the device key")
            return
        }
    }

    @Test func rsaKeyHostConnectsWithRSASHA512() async throws {
        let (store, connector) = try makeStore(host: .fixture(authMethod: .rsaKey))

        await store.runChecks()

        let settings = try #require(await connector.capturedSettings.first)
        guard case .rsaSHA512(let key) = settings.credentials else {
            Issue.record("credentials should be the RSA-SHA2-512 key")
            return
        }
        #expect(key.keySizeInBits == 3_072)
    }

    @Test func missingPasswordFailsBeforeConnecting() async throws {
        let (store, connector) = try makeStore(
            host: .fixture(authMethod: .password), password: nil)

        await store.runChecks()

        guard case .failed(let hint) = try #require(store.report)[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(hint.contains("password"))
        #expect(await connector.capturedSettings.isEmpty)
    }

    // MARK: Herdr endpoint (ADR 0021)

    private static let endpointSocketPath =
        "/Users/ada/Library/Application Support/Example/herdr/herdr.sock"
    private static let endpointLauncherPath =
        "/Users/ada/Library/Application Support/Example/bin/herdr"

    private func endpointHost() throws -> Host {
        let endpoint = try #require(
            HerdrEndpoint(
                socketPath: Self.endpointSocketPath,
                executablePath: Self.endpointLauncherPath))
        return Host(address: "mac.example", username: "ada", herdrEndpoint: endpoint)
    }

    /// An endpoint Host whose launcher probe (its session list) and ping
    /// answer as scripted.
    private func makeEndpointStore(
        probe: Result<[HerdrSession], TransportError>,
        ping: Result<ServerInfo, TransportError> = healthyPing
    ) throws -> (HostOnboardingStore, LauncherProbeTransport) {
        let host = try endpointHost()
        let transport = LauncherProbeTransport(sessions: probe, pingResult: ping)
        let store = HostOnboardingStore(
            host: host,
            connector: SingleTransportConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()))
        return (store, transport)
    }

    @Test func endpointHostConnectsThroughItsLauncher() async throws {
        let (store, connector) = try makeStore(host: endpointHost())

        await store.runChecks()

        let settings = try #require(await connector.capturedSettings.first)
        let launcher = try #require(settings.herdrLauncher)
        #expect(settings.socket == .absolutePath(Self.endpointSocketPath))
        #expect(launcher.executablePath == Self.endpointLauncherPath)
        #expect(settings.sessionListCommand == launcher.sessionListCommand)
    }

    /// The probe's sessions are discarded: the endpoint's socket already fixes
    /// the session, so the picker never appears and ping still runs.
    @Test func endpointProbeSuccessKeepsTheSessionSectionEmptyAndStillPings() async throws {
        let (store, _) = try makeStore(
            host: endpointHost(),
            sessions: [
                HerdrSession(name: "default", isDefault: true, isRunning: true),
                HerdrSession(name: "work", isDefault: false, isRunning: true),
            ])

        await store.runChecks()

        #expect(store.availableSessions.isEmpty)
        #expect(store.sessionDiscoveryError == nil)
        #expect(store.serverInfo == ServerInfo(version: "0.7.5", protocolVersion: 17))
        #expect(store.report?.isFullyPassed == true)
    }

    @Test func endpointProbeRunsOnceBeforePing() async throws {
        let (store, transport) = try makeEndpointStore(probe: .success([]))

        await store.runChecks()

        #expect(await transport.sessionListCount == 1)
        #expect(await transport.pingCount == 1)
        #expect(store.report?.isFullyPassed == true)
    }

    @Test func missingLauncherFailsHerdrInstalledWithoutPinging() async throws {
        let (store, transport) = try makeEndpointStore(
            probe: .failure(.herdrLauncherNotFound(path: Self.endpointLauncherPath)))

        await store.runChecks()

        let report = try #require(store.report)
        #expect(report[.remoteEnvironment] == .passed)
        #expect(
            report[.herdrInstalled]
                == .failed(
                    hint: "The herdr launcher at \(Self.endpointLauncherPath) could not run. "
                        + "Open the app that provides herdr on the Host, or pair the Host again."))
        #expect(await transport.pingCount == 0)
        #expect(await transport.isClosed)
        #expect(store.availableSessions.isEmpty)
        #expect(store.sessionDiscoveryError == nil)
        #expect(store.serverInfo == nil)
        #expect(store.pluginStatus == .unavailable)
    }

    @Test func launcherThatDoesNotAnswerLikeHerdrFailsHerdrInstalled() async throws {
        let (store, transport) = try makeEndpointStore(
            probe: .failure(
                .malformedResponse("herdr session list returned invalid JSON: hello")))

        await store.runChecks()

        let report = try #require(store.report)
        #expect(
            report[.herdrInstalled]
                == .failed(
                    hint: "The herdr launcher at \(Self.endpointLauncherPath) did not answer "
                        + "like herdr. (herdr session list returned invalid JSON: hello)"))
        #expect(await transport.pingCount == 0)
        #expect(store.sessionDiscoveryError == nil)
    }

    @Test func otherLauncherProbeFailuresUseTheNormalMapping() async throws {
        let (store, transport) = try makeEndpointStore(probe: .failure(.timedOut))

        await store.runChecks()

        let report = try #require(store.report)
        #expect(
            report[.connection]
                == .failed(
                    hint: "The Host did not answer in time. Check the connection and try again."))
        #expect(await transport.pingCount == 0)
    }

    @Test func endpointPingFailuresPointAtTheProvidingApp() async throws {
        let (store, _) = try makeEndpointStore(
            probe: .success([]),
            ping: .failure(.socketNotFound(path: Self.endpointSocketPath)))

        await store.runChecks()

        let report = try #require(store.report)
        #expect(
            report[.herdrInstalled]
                == .failed(
                    hint: "No herdr socket at \(Self.endpointSocketPath). Open the app that "
                        + "provides herdr on the Host, then run the checks again."))
    }
}

/// Scripted Transport for an endpoint Host's preflight: its session list
/// stands in for the launcher probe, and both calls are counted.
private final actor LauncherProbeTransport: Transport {
    private let sessions: Result<[HerdrSession], TransportError>
    private let pingResult: Result<ServerInfo, TransportError>
    private(set) var sessionListCount = 0
    private(set) var pingCount = 0
    private(set) var isClosed = false

    init(
        sessions: Result<[HerdrSession], TransportError>,
        pingResult: Result<ServerInfo, TransportError>
    ) {
        self.sessions = sessions
        self.pingResult = pingResult
    }

    func listSessions() async throws -> [HerdrSession] {
        sessionListCount += 1
        return try sessions.get()
    }

    func ping() async throws -> ServerInfo {
        pingCount += 1
        return try pingResult.get()
    }

    func listAgents() async throws -> [Agent] {
        []
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        throw Self.unscripted
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        throw Self.unscripted
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        throw Self.unscripted
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        throw Self.unscripted
    }

    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        throw Self.unscripted
    }

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        throw Self.unscripted
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        throw Self.unscripted
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        throw Self.unscripted
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        throw Self.unscripted
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        throw Self.unscripted
    }

    func closePane(_ params: PaneTarget) async throws {
        throw Self.unscripted
    }

    func closeTab(_ params: TabTarget) async throws {
        throw Self.unscripted
    }

    func focusAgent(_ target: AgentTarget) async throws {
        throw Self.unscripted
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        throw Self.unscripted
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        throw Self.unscripted
    }

    var isConnected: Bool {
        !isClosed
    }

    func close() async throws {
        isClosed = true
    }

    private static let unscripted = TransportError.channelFailed(
        detail: "LauncherProbeTransport scripts only the preflight")
}

/// Hands every connect the same scripted transport.
private struct SingleTransportConnector: TransportConnector {
    let transport: LauncherProbeTransport

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        transport
    }
}
