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
        presentedJumpKeyBlob: Data? = nil,
        knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore(),
        password: String? = nil,
        sessions: [HerdrSession] = [],
        plugin: Result<HeelerPluginInstallation?, TransportError>? = nil,
        pluginSteps: FakePluginSteps = FakePluginSteps(),
        fingerprintTimeout: Duration = .seconds(5)
    ) throws -> (HostOnboardingStore, FakeTransportConnector) {
        let connector = FakeTransportConnector(
            outcome: outcome, presentedKeyBlob: presentedKeyBlob,
            presentedJumpKeyBlob: presentedJumpKeyBlob, sessions: sessions,
            plugin: plugin, pluginSteps: pluginSteps)
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

    private static let outdated = HeelerPluginInstallation(version: "0.5.0")
    private static let current = HeelerPluginInstallation(
        version: HeelerPluginCompatibility.bundled.description)

    /// Checks the Host, then runs its plugin notice's action.
    private func checkThenRunPluginAction(
        _ store: HostOnboardingStore
    ) async throws -> HeelerPluginPresentation.Notice.Action {
        await store.runChecks()
        let action = try #require(store.pluginPresentation.notice?.action)
        await store.runPluginAction(action)
        return action
    }

    @Test func aPluginActionRunsOverItsOwnConnectionAndClearsTheNotice() async throws {
        let (store, connector) = try makeStore(
            plugin: .success(Self.outdated),
            pluginSteps: FakePluginSteps(pluginAfterStep: [0: .success(Self.current)]))

        let action = try await checkThenRunPluginAction(store)

        #expect(action.steps == [.install])
        #expect(store.pluginAction == .idle)
        #expect(store.pluginStatus == .installed(Self.current))
        #expect(store.pluginPresentation.notice == nil)
        let transports = await connector.transports
        #expect(transports.count == 2)
        let transport = try #require(transports.last)
        #expect(await transport.ranPluginSteps == [.install])
        // The plugin is read before the install and after it, over the same
        // connection, then it closes.
        #expect(await transport.pluginReadsWhileOpen == [true, true])
        #expect(await transport.pluginBranchReads == 1)
        #expect(await transport.isClosed)
    }

    /// herdr installs whatever the plugin branch holds, which can be older
    /// than the Host's plugin.
    @Test func anInstallNeverReplacesANewerPlugin() async throws {
        let ahead = HeelerPluginInstallation(version: "0.6.1")
        let (store, connector) = try makeStore(
            plugin: .success(ahead),
            pluginSteps: FakePluginSteps(branchVersion: .success(PluginVersion(0, 6, 0))))

        await store.runChecks()
        await store.runPluginAction(
            HeelerPluginPresentation.Notice.Action(title: "Update Plugin", steps: [.install]))

        let transport = try #require(await connector.transports.last)
        #expect(await transport.ranPluginSteps.isEmpty)
        #expect(await transport.isClosed)
        #expect(store.pluginAction == .failed(HeelerPluginActionFailure(
            message: "The Host has plugin 0.6.1, newer than the published 0.6.0, so Heeler "
                + "did not update it.")))
        #expect(store.pluginStatus == .installed(ahead))
    }

    /// Skipping the update leaves the action's other steps to run.
    @Test func aSkippedUpdateStillTurnsThePluginOn() async throws {
        let disabled = HeelerPluginInstallation(version: "0.6.1", isEnabled: false)
        let enabled = HeelerPluginInstallation(version: "0.6.1")
        let (store, connector) = try makeStore(
            plugin: .success(disabled),
            pluginSteps: FakePluginSteps(
                pluginAfterStep: [0: .success(enabled)],
                branchVersion: .success(PluginVersion(0, 6, 0))))

        let action = try await checkThenRunPluginAction(store)

        #expect(action.steps == [.install, .enable(pluginID: "heeler")])
        #expect(await connector.transports.last?.ranPluginSteps == [.enable(pluginID: "heeler")])
        #expect(store.pluginStatus == .installed(enabled))
        #expect(store.pluginAction == .failed(HeelerPluginActionFailure(
            message: "The Host has plugin 0.6.1, newer than the published 0.6.0, so Heeler "
                + "did not update it.")))
    }

    /// The action rereads the plugin rather than trusting the checks, which
    /// these stores never ran: another device may have changed it since.
    /// Anything the notice would not offer an install over stops it, and
    /// the status stays, so the sheet keeps the action it explains.
    @Test func anInstallStopsWhenTheRereadPluginIsNotOneItReplaces() async throws {
        let changed = HeelerPluginActionFailure(
            message: "The plugin on the Host changed since the checks, so nothing changed. "
                + "Run the checks again.")
        let cases: [(HeelerPluginInstallation, String)] = [
            (HeelerPluginInstallation(version: "dev"), "unknown version"),
            (HeelerPluginInstallation(version: "0.5.0", hasManifestWarning: true), "stale manifest"),
            (HeelerPluginInstallation(version: "0.5.0", repository: "someone/Heeler"), "fork"),
            (HeelerPluginInstallation(version: "0.5.0", repository: nil), "unnamed repository"),
            (HeelerPluginInstallation(version: "0.5.0", source: .local), "linked checkout"),
            (HeelerPluginInstallation(pluginID: "herdr-mobile.pairing", version: "0.3.0"), "legacy id"),
        ]
        for (installation, label) in cases {
            let (store, connector) = try makeStore(plugin: .success(installation))

            await store.runPluginAction(
                HeelerPluginPresentation.Notice.Action(title: "Update Plugin", steps: [.install]))

            let transport = try #require(await connector.transports.last)
            #expect(await transport.ranPluginSteps.isEmpty, "\(label)")
            #expect(await transport.pluginBranchReads == 0, "\(label)")
            #expect(store.pluginAction == .failed(changed), "\(label)")
            #expect(store.pluginStatus == .checking, "\(label)")
        }
    }

    @Test func anInstallStopsWhenThePluginCannotBeReread() async throws {
        let (store, connector) = try makeStore(plugin: .failure(.timedOut))

        await store.runPluginAction(
            HeelerPluginPresentation.Notice.Action(title: "Update Plugin", steps: [.install]))

        #expect(await connector.transports.last?.ranPluginSteps == [])
        #expect(store.pluginAction == .failed(HeelerPluginActionFailure(
            message: "Heeler could not read the Host's plugin before changing it, so nothing "
                + "changed. Run the checks again.")))
    }

    @Test func anInstallStopsWhenTheBranchCannotBeRead() async throws {
        let (store, connector) = try makeStore(
            plugin: .success(Self.outdated),
            pluginSteps: FakePluginSteps(branchVersion: .failure(PluginBranchVersionError(
                exitStatus: 128, output: "fatal: unable to access 'https://github.com/'"))))

        _ = try await checkThenRunPluginAction(store)

        #expect(await connector.transports.last?.ranPluginSteps == [])
        #expect(store.pluginAction == .failed(HeelerPluginActionFailure(
            message: "Heeler could not check which plugin version the Host would install, so "
                + "nothing changed. Check that the Host can reach github.com.",
            detail: "fatal: unable to access 'https://github.com/'")))
    }

    /// Nothing to downgrade, so the branch is not read.
    @Test func aFirstInstallSkipsTheBranchRead() async throws {
        let (store, connector) = try makeStore(
            plugin: .success(nil),
            pluginSteps: FakePluginSteps(
                pluginAfterStep: [0: .success(Self.current)],
                branchVersion: .failure(PluginBranchVersionError(exitStatus: 1, output: ""))))

        let action = try await checkThenRunPluginAction(store)

        #expect(action.steps == [.install])
        let transport = try #require(await connector.transports.last)
        #expect(await transport.ranPluginSteps == [.install])
        #expect(await transport.pluginBranchReads == 0)
        #expect(store.pluginAction == .idle)
    }

    @Test func aFailedStepStopsTheActionAndSaysWhy() async throws {
        let disabled = HeelerPluginInstallation(version: "0.5.0", isEnabled: false)
        let error = HeelerPluginStepError(
            step: .install, exitStatus: 1,
            stderr: Data("error: plugin build failed\nPlugin was not installed.\n".utf8),
            stdout: Data())
        let (store, connector) = try makeStore(
            plugin: .success(disabled), pluginSteps: FakePluginSteps(failures: [0: error]))

        let action = try await checkThenRunPluginAction(store)

        #expect(action.steps == [.install, .enable(pluginID: "heeler")])
        #expect(await connector.transports.last?.ranPluginSteps == [.install])
        #expect(store.pluginAction == .failed(HeelerPluginActionFailure(error)))
        #expect(store.pluginStatus == .installed(disabled))

        // Running the checks again clears the failure.
        await store.runChecks()
        #expect(store.pluginAction == .idle)
    }

    /// A step that timed out may still have finished on the Host.
    @Test func theRereadPluginDecidesAfterATimeout() async throws {
        let (store, _) = try makeStore(
            plugin: .success(Self.outdated),
            pluginSteps: FakePluginSteps(
                pluginAfterStep: [0: .success(Self.current)],
                failures: [0: TransportError.timedOut]))

        _ = try await checkThenRunPluginAction(store)

        #expect(store.pluginAction == .idle)
        #expect(store.pluginStatus == .installed(Self.current))
    }

    /// The plugin branch can lag behind the version this build expects.
    @Test func anInstallThatStaysOutdatedSaysWhichVersionHerdrFound() async throws {
        let (store, _) = try makeStore(
            plugin: .success(Self.outdated),
            pluginSteps: FakePluginSteps(branchVersion: .success(PluginVersion(0, 5, 0))))

        _ = try await checkThenRunPluginAction(store)

        #expect(store.pluginAction == .failed(HeelerPluginActionFailure(
            message: "herdr installed plugin 0.5.0, the newest published, but this app "
                + "expects \(HeelerPluginCompatibility.bundled).")))
        #expect(store.pluginStatus == .installed(Self.outdated))
    }

    @Test func aNoticeThatRemainsIsPointedAt() async throws {
        let leftover = HeelerPluginInstallation(
            version: HeelerPluginCompatibility.bundled.description,
            leftoverLegacyIDs: ["herdr-mobile.pairing"])
        let (store, _) = try makeStore(plugin: .success(leftover))

        let action = try await checkThenRunPluginAction(store)

        #expect(action.title == "Remove Old Copy")
        #expect(store.pluginAction == .failed(HeelerPluginActionFailure(
            message: "The change finished, but the plugin still needs the attention "
                + "described above.")))
    }

    /// The step's connection is gone, so the read back cannot tell.
    @Test func aDroppedConnectionMayStillHaveChangedThePlugin() async throws {
        let (store, _) = try makeStore(
            plugin: .success(Self.outdated),
            pluginSteps: FakePluginSteps(
                pluginAfterStep: [0: .failure(.sshUnreachable(detail: "gone"))],
                failures: [0: TransportError.sshUnreachable(detail: "gone")]))

        _ = try await checkThenRunPluginAction(store)

        #expect(store.pluginAction == .failed(HeelerPluginActionFailure(
            message: "The connection ended during the change, which may still finish on "
                + "the Host. Run the checks again.",
            detail: TransportError.sshUnreachable(detail: "gone").presentation.message)))
        #expect(store.pluginStatus == .installed(Self.outdated))
    }

    @Test func anUnreadablePluginKeepsTheLastStatus() async throws {
        let (store, _) = try makeStore(
            plugin: .success(Self.outdated),
            pluginSteps: FakePluginSteps(pluginAfterStep: [0: .failure(.timedOut)]))

        _ = try await checkThenRunPluginAction(store)

        #expect(store.pluginStatus == .installed(Self.outdated))
        guard case .failed(let failure) = store.pluginAction else {
            Issue.record("expected a failure, got \(store.pluginAction)")
            return
        }
        #expect(failure.message.contains("could not be read back"))
    }

    @Test func aPluginActionThatCannotConnectSaysWhy() async throws {
        let (store, _) = try makeStore(
            outcome: .connectFails(.sshUnreachable(detail: "Connection refused")))

        await store.runPluginAction(
            HeelerPluginPresentation.Notice.Action(title: "Update Plugin", steps: [.install]))

        #expect(store.pluginAction == .failed(HeelerPluginActionFailure(
            message: "Heeler could not connect to the Host, so nothing changed.",
            detail: TransportError.sshUnreachable(detail: "Connection refused")
                .presentation.message)))
    }

    /// A connect that times out sent nothing, unlike a step that times out.
    @Test func aConnectTimeoutSaysNothingChanged() async throws {
        let (store, _) = try makeStore(outcome: .connectFails(.timedOut))

        await store.runPluginAction(
            HeelerPluginPresentation.Notice.Action(title: "Update Plugin", steps: [.install]))

        guard case .failed(let failure) = store.pluginAction else {
            Issue.record("expected a failure, got \(store.pluginAction)")
            return
        }
        #expect(failure.message == "Heeler could not connect to the Host, so nothing changed.")
    }

    @Test func cancellingChecksEndsThemAtOnceWithoutATimeout() async throws {
        let (store, _) = try makeStore(outcome: .hangs(.seconds(1)))

        let running = Task { await store.runChecks() }
        try await waitUntil("checks running") { store.phase == .running }
        store.cancelChecks()
        #expect(store.phase == .finished)
        #expect(store.report == .failure(TransportError.cancelled, authMethod: store.host.authMethod))
        #expect(store.pluginStatus == .unavailable)

        // The abandoned connect times out later; that is never shown.
        await running.value
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(store.report == .failure(TransportError.cancelled, authMethod: store.host.authMethod))
        #expect(store.phase == .finished)
    }

    @Test func checksRunAgainAfterACancel() async throws {
        let (store, _) = try makeStore(outcome: .hangs(.milliseconds(300)))
        let running = Task { await store.runChecks() }
        try await waitUntil("checks running") { store.phase == .running }
        store.cancelChecks()
        await running.value
        #expect(store.phase == .finished)

        // A new run proceeds (and its own outcome, here the timeout, shows).
        await store.runChecks()
        #expect(store.report == .failure(TransportError.timedOut, authMethod: store.host.authMethod))
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
        // Trusted for the Host, not its address, so every route shares it.
        #expect(
            await knownHosts.fingerprint(trustedFor: host)
                == HostKeyFingerprint(publicKeyBlob: keyBlob))
        #expect(await knownHosts.fingerprint(host: "box.example", port: 22) == nil)
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
        // The trust saved before Routes was adopted by the Host, unchanged.
        #expect(await knownHosts.fingerprint(trustedFor: store.host) == trusted)

        await store.trustPresentedHostKey()

        #expect(store.pendingHostKeyReplacement == nil)
        #expect(store.report?.isFullyPassed == true)
        #expect(await knownHosts.fingerprint(trustedFor: store.host) == presented)
    }

    /// Every route reaches the same Host, so a changed key is offered for
    /// replacement only when the routes that reached a server agree on it.
    @Test func aKeyChangedOnEveryRouteThatAnsweredIsOfferedForReplacement() async throws {
        let known = HostKeyFingerprint(digest: Data(repeating: 1, count: 32))
        let presented = HostKeyFingerprint(digest: Data(repeating: 2, count: 32))
        let (store, _) = try makeStore(
            outcome: .connectFails(
                .noRouteReached([
                    RouteFailure(
                        route: "192.168.1.5", mayNameAnotherMachine: true,
                        error: .hostKeyMismatch(known: known, presented: presented)),
                    RouteFailure(route: "100.64.0.5 over Home", mayNameAnotherMachine: false, error: .timedOut),
                    RouteFailure(
                        route: "box.example", mayNameAnotherMachine: false,
                        error: .hostKeyMismatch(known: known, presented: presented)),
                ])))

        await store.runChecks()

        #expect(
            store.pendingHostKeyReplacement
                == HostKeyReplacement(known: known, presented: presented))
    }

    @Test func routesThatSawDifferentKeysOfferNoReplacement() async throws {
        let known = HostKeyFingerprint(digest: Data(repeating: 1, count: 32))
        let (store, _) = try makeStore(
            outcome: .connectFails(
                .noRouteReached([
                    RouteFailure(
                        route: "100.64.0.5 over Home", mayNameAnotherMachine: false,
                        error: .hostKeyMismatch(
                            known: known,
                            presented: HostKeyFingerprint(digest: Data(repeating: 2, count: 32)))),
                    RouteFailure(
                        route: "box.example", mayNameAnotherMachine: false,
                        error: .hostKeyMismatch(
                            known: known,
                            presented: HostKeyFingerprint(digest: Data(repeating: 3, count: 32)))),
                ])))

        await store.runChecks()

        #expect(store.pendingHostKeyReplacement == nil)
        guard case .failed = try #require(store.report)[.connection] else {
            Issue.record("connection check should fail")
            return
        }
    }

    /// A LAN address may be another machine wherever the device is now; an
    /// overlay address is not. The overlay route's key is the one offered.
    @Test func anOverlayRoutesChangedKeyIsOfferedOverALANAddress() async throws {
        let known = HostKeyFingerprint(digest: Data(repeating: 1, count: 32))
        let overlayKey = HostKeyFingerprint(digest: Data(repeating: 3, count: 32))
        let (store, _) = try makeStore(
            outcome: .connectFails(
                .noRouteReached([
                    RouteFailure(
                        route: "192.168.1.5", mayNameAnotherMachine: true,
                        error: .hostKeyMismatch(
                            known: known,
                            presented: HostKeyFingerprint(digest: Data(repeating: 2, count: 32)))),
                    RouteFailure(
                        route: "100.64.0.5 over Home", mayNameAnotherMachine: false,
                        error: .hostKeyMismatch(known: known, presented: overlayKey)),
                ])))

        await store.runChecks()

        #expect(
            store.pendingHostKeyReplacement
                == HostKeyReplacement(known: known, presented: overlayKey))
    }

    /// A Jump Host keeps its trust by endpoint (ADR 0022), so its new key
    /// replaces that entry and leaves the Host's own trust alone.
    @Test func aJumpHostsChangedKeyIsReplacedUnderItsEndpoint() async throws {
        var host = Host.fixture(address: "127.0.0.1")
        host.routes[0].jumpAddress = " vps.example "
        host.routes[0].jumpPort = 2222
        let knownHosts = InMemoryKnownHostsStore()
        let trusted = HostKeyFingerprint(publicKeyBlob: Data("old-jump-key".utf8))
        let presented = HostKeyFingerprint(publicKeyBlob: keyBlob)
        await knownHosts.setFingerprint(trusted, host: "vps.example", port: 2222)
        let (store, _) = try makeStore(
            host: host, presentedJumpKeyBlob: keyBlob, knownHosts: knownHosts)

        await store.runChecks()

        let replacement = try #require(store.pendingHostKeyReplacement)
        #expect(replacement.known == trusted)
        #expect(replacement.presented == presented)
        #expect(replacement.jumpHost?.endpointDescription == "vps.example:2222")

        await store.trustPresentedHostKey()

        #expect(store.pendingHostKeyReplacement == nil)
        #expect(store.report?.isFullyPassed == true)
        #expect(await knownHosts.fingerprint(host: "vps.example", port: 2222) == presented)
        #expect(await knownHosts.fingerprint(trustedFor: host) == nil)
    }

    @Test func aJumpHostsChangedKeyIsOfferedWhenNoRouteReachedTheHost() async throws {
        let direct = HostRoute(address: "192.168.1.5")
        let viaJump = HostRoute(address: "127.0.0.1", port: 2222, jumpAddress: "vps.example")
        let host = Host(username: "dev", routes: [direct, viaJump])
        let known = HostKeyFingerprint(digest: Data(repeating: 1, count: 32))
        let presented = HostKeyFingerprint(digest: Data(repeating: 2, count: 32))
        let (store, _) = try makeStore(
            host: host,
            outcome: .connectFails(
                .noRouteReached([
                    RouteFailure(
                        route: "192.168.1.5", mayNameAnotherMachine: true, error: .timedOut,
                        routeID: direct.id),
                    RouteFailure(
                        route: "127.0.0.1:2222 via vps.example", mayNameAnotherMachine: false,
                        error: .jumpHostFailed(.hostKeyMismatch(known: known, presented: presented)),
                        routeID: viaJump.id),
                ])))

        await store.runChecks()

        #expect(
            store.pendingHostKeyReplacement
                == HostKeyReplacement(
                    known: known, presented: presented,
                    jumpHost: HostKeyReplacement.JumpHost(viaJump)))
    }

    /// The Host's own changed key is asked about first; its Jump Host's
    /// waits for the next checks.
    @Test func theHostsChangedKeyIsOfferedBeforeAJumpHosts() async throws {
        let direct = HostRoute(address: "box.example")
        let viaJump = HostRoute(address: "127.0.0.1", port: 2222, jumpAddress: "vps.example")
        let host = Host(username: "dev", routes: [direct, viaJump])
        let known = HostKeyFingerprint(digest: Data(repeating: 1, count: 32))
        let hostKey = HostKeyFingerprint(digest: Data(repeating: 2, count: 32))
        let jumpKey = HostKeyFingerprint(digest: Data(repeating: 3, count: 32))
        let (store, _) = try makeStore(
            host: host,
            outcome: .connectFails(
                .noRouteReached([
                    RouteFailure(
                        route: "box.example", mayNameAnotherMachine: false,
                        error: .hostKeyMismatch(known: known, presented: hostKey),
                        routeID: direct.id),
                    RouteFailure(
                        route: "127.0.0.1:2222 via vps.example", mayNameAnotherMachine: false,
                        error: .jumpHostFailed(.hostKeyMismatch(known: known, presented: jumpKey)),
                        routeID: viaJump.id),
                ])))

        await store.runChecks()

        #expect(
            store.pendingHostKeyReplacement
                == HostKeyReplacement(known: known, presented: hostKey))
    }

    @Test func settingsCarryTheHostCoordinatesAndStoredPassword() async throws {
        var host = Host.fixture(address: "box.example", username: "dev", authMethod: .password)
        host.routes[0].port = 2222
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

    // MARK: Herdr endpoint (ADR 0023)

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
        ping: Result<ServerInfo, TransportError> = healthyPing,
        probeGate: CancellablePhaseGate? = nil
    ) throws -> (HostOnboardingStore, LauncherProbeTransport) {
        let host = try endpointHost()
        let transport = LauncherProbeTransport(sessions: probe, pingResult: ping, probeGate: probeGate)
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

    @Test func cancellingAnEndpointProbeKeepsTheCancelledReport() async throws {
        let gate = CancellablePhaseGate()
        let (store, transport) = try makeEndpointStore(
            probe: .failure(.timedOut), probeGate: gate)
        let running = Task { await store.runChecks() }
        defer { running.cancel() }
        try await AsyncDeadline.run(for: .seconds(2)) {
            try await gate.waitUntilEntered()
        }

        store.cancelChecks()
        await running.value

        #expect(store.report == .failure(TransportError.cancelled, authMethod: .deviceKey))
        #expect(store.phase == .finished)
        #expect(store.serverInfo == nil)
        #expect(store.pluginStatus == .unavailable)
        #expect(await transport.isClosed)
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
                        + "Check that this launcher exists, is executable, and can start herdr. "
                        + "Pair the Host again if its path changed."))
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

    @Test func endpointPingFailuresPointAtTheConfiguredInstance() async throws {
        let (store, _) = try makeEndpointStore(
            probe: .success([]),
            ping: .failure(.socketNotFound(path: Self.endpointSocketPath)))

        await store.runChecks()

        let report = try #require(store.report)
        #expect(
            report[.herdrInstalled]
                == .failed(
                    hint: "No herdr socket at \(Self.endpointSocketPath). Start the herdr instance "
                        + "configured for this Host and verify its socket path, then run the checks again."))
    }
}

/// Scripted Transport for an endpoint Host's preflight: its session list
/// stands in for the launcher probe, and both calls are counted.
private final actor LauncherProbeTransport: Transport {
    private let sessions: Result<[HerdrSession], TransportError>
    private let pingResult: Result<ServerInfo, TransportError>
    private let probeGate: CancellablePhaseGate?
    private(set) var sessionListCount = 0
    private(set) var pingCount = 0
    private(set) var isClosed = false

    init(
        sessions: Result<[HerdrSession], TransportError>,
        pingResult: Result<ServerInfo, TransportError>,
        probeGate: CancellablePhaseGate? = nil
    ) {
        self.sessions = sessions
        self.pingResult = pingResult
        self.probeGate = probeGate
    }

    func listSessions() async throws -> [HerdrSession] {
        sessionListCount += 1
        await probeGate?.enterAndHold()
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
