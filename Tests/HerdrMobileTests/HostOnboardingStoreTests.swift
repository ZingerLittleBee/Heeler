import CryptoKit
import Foundation
import Testing

@testable import HerdrMobile

@MainActor
@Suite("Host onboarding store")
struct HostOnboardingStoreTests {
    private static let healthyPing = Result<ServerInfo, TransportError>.success(
        ServerInfo(version: "0.7.4", protocolVersion: 16))
    private let keyBlob = Data("fake-host-key".utf8)

    private func makeStore(
        host: Host = .fixture(),
        outcome: FakeTransportConnector.Outcome = .connects(pingResult: healthyPing),
        presentedKeyBlob: Data? = nil,
        knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore(),
        password: String? = nil,
        fingerprintTimeout: Duration = .seconds(5)
    ) throws -> (HostOnboardingStore, FakeTransportConnector) {
        let connector = FakeTransportConnector(
            outcome: outcome, presentedKeyBlob: presentedKeyBlob)
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
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()), secrets: secrets),
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
        #expect(store.serverInfo == ServerInfo(version: "0.7.4", protocolVersion: 16))
        let transport = try #require(await connector.transports.last)
        #expect(await transport.isClosed)
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

    @Test func pingFailureFailsItsCheckAndStillClosesTheTransport() async throws {
        let (store, connector) = try makeStore(
            outcome: .connects(
                pingResult: .failure(.protocolVersionMismatch(server: 17, supported: 16))))

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
        host.socatPath = "/opt/homebrew/bin/socat"
        let (store, connector) = try makeStore(host: host, password: "hunter2")

        await store.runChecks()

        let settings = try #require(await connector.capturedSettings.first)
        #expect(settings.host == "box.example")
        #expect(settings.port == 2222)
        #expect(settings.username == "dev")
        #expect(settings.socket == .namedSession("work"))
        #expect(settings.socatPath == "/opt/homebrew/bin/socat")
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
}
