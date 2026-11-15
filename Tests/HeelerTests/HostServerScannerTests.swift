import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Host server scanner")
struct HostServerScannerTests {
    private static let sessionsJSON = #"{"sessions":[{"name":"default","default":true,"running":true}]}"#
    private static let defaultTUI = HostServerKey(kind: .herdrTUI, name: "")
    private static let defaultCore = HostServerKey(kind: .herdrCore, name: "")
    private let keyBlob = Data("fake-host-key".utf8)

    /// A Host that runs Herdr TUI and has a core installed.
    private func machine(detectionFailure: TransportError? = nil) -> ScriptedCoreHost {
        ScriptedCoreHost(
            herdrRead: .answers(Self.sessionsJSON), detectionFailure: detectionFailure, channel: .refused)
    }

    private func makeScanner(
        core: ScriptedCoreHost,
        outcome: FakeTransportConnector.Outcome = .connects(pingResult: .failure(.cancelled)),
        presentedKeyBlob: Data? = nil,
        presentedJumpKeyBlob: Data? = nil,
        knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore(),
        fingerprintTimeout: Duration = .seconds(5)
    ) -> (HostServerScanner, FakeTransportConnector) {
        let connector = FakeTransportConnector(
            outcome: outcome, presentedKeyBlob: presentedKeyBlob,
            presentedJumpKeyBlob: presentedJumpKeyBlob, core: core)
        let dependencies = HostOnboardingDependencies(
            connector: connector,
            knownHosts: knownHosts,
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()))
        return (HostServerScanner(dependencies: dependencies, fingerprintTimeout: fingerprintTimeout), connector)
    }

    /// Polls until `condition` holds, yielding the main actor so the look can
    /// progress in between.
    private func waitUntil(_ comment: Comment, condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), comment)
    }

    private func failure(of scanner: HostServerScanner) -> HostServerScanner.Failure? {
        guard case .failed(let failure) = scanner.phase else { return nil }
        return failure
    }

    // MARK: One look

    /// The whole look is one exec on a connection of its own: nothing a Server's
    /// record would dial is opened, and nothing is started.
    @Test func aLookRunsTheOneDetectionExecAndOpensNoTransport() async throws {
        let core = machine()
        let (scanner, connector) = makeScanner(core: core)
        #expect(scanner.phase == .idle)

        let found = try #require(await scanner.look(at: .fixture()))

        #expect(found.servers.map(\.key) == [Self.defaultTUI, Self.defaultCore])
        #expect(scanner.phase == .found(found))
        #expect(!scanner.isLooking)
        #expect(await core.log == ["detection", "close"])
        #expect(await core.scripts.count == 1)
        #expect(await connector.capturedSettings.count == 1)
        #expect(await connector.transports.isEmpty)
    }

    /// A core session the user named is turned on by that name: the look
    /// itself only asks about the default one.
    @Test func aLookAsksAboutTheDefaultSessionWhateverItsRecordTargets() async throws {
        let core = machine()
        let (scanner, _) = makeScanner(core: core)
        let record = Host(address: "host.example", username: "dev", serverKind: .herdrCore, sessionName: "work")

        await scanner.look(at: record)

        let script = try #require(await core.scripts.first)
        #expect(script.contains("__session='default'\n"))
        #expect(!script.contains("__session='work'"))
    }

    /// A look dials as one record of the Host, whose trust every record shares.
    @Test func aLookTrustsTheKeyUnderTheRecordItDialsAs() async throws {
        let host = Host.fixture()
        let (scanner, connector) = makeScanner(core: machine())

        await scanner.look(at: host)

        #expect(await connector.capturedSettings.first?.hostKeyTrust == .host(host.id))
    }

    // MARK: Trusting a key

    @Test func aKeySeenForTheFirstTimeIsAskedAboutAndTheLookGoesOnOnceTrusted() async throws {
        let host = Host.fixture()
        let knownHosts = InMemoryKnownHostsStore()
        let core = machine()
        let (scanner, _) = makeScanner(core: core, presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        let looking = Task { await scanner.look(at: host) }
        try await waitUntil("the key is asked about") { scanner.pendingFingerprint != nil }
        #expect(
            scanner.pendingFingerprint
                == HostKeyCandidate(
                    host: "host.example", port: 22, fingerprint: HostKeyFingerprint(publicKeyBlob: keyBlob)))
        #expect(scanner.isLooking)
        // Nothing runs on a Host whose key is not trusted yet.
        #expect(await core.log.isEmpty)

        scanner.confirmFingerprint(trusted: true)
        let found = await looking.value

        #expect(found?.servers.map(\.key) == [Self.defaultTUI, Self.defaultCore])
        #expect(scanner.pendingFingerprint == nil)
        #expect(await knownHosts.fingerprint(trustedFor: host) == HostKeyFingerprint(publicKeyBlob: keyBlob))
    }

    @Test func aDeclinedKeyIsAnAnswerAndNotAFault() async throws {
        let host = Host.fixture()
        let knownHosts = InMemoryKnownHostsStore()
        let core = machine()
        let (scanner, _) = makeScanner(core: core, presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        let looking = Task { await scanner.look(at: host) }
        try await waitUntil("the key is asked about") { scanner.pendingFingerprint != nil }
        scanner.confirmFingerprint(trusted: false)

        #expect(await looking.value == nil)
        #expect(failure(of: scanner)?.isDeclinedTrust == true)
        #expect(scanner.pendingHostKeyReplacement == nil)
        #expect(await knownHosts.fingerprint(trustedFor: host) == nil)
        #expect(await core.log.isEmpty)
    }

    /// A Jump Host shows its key before the Host does, and declining it is the
    /// same answer.
    @Test func aDeclinedJumpHostKeyIsAnAnswerToo() async throws {
        let host = Host(address: "host.example", username: "dev", jumpAddress: "vps.example")
        let knownHosts = InMemoryKnownHostsStore()
        let jumpKey = Data("fake-jump-key".utf8)
        let (scanner, _) = makeScanner(
            core: machine(), presentedKeyBlob: keyBlob, presentedJumpKeyBlob: jumpKey, knownHosts: knownHosts)

        let looking = Task { await scanner.look(at: host) }
        try await waitUntil("the Jump Host's key is asked about") { scanner.pendingFingerprint != nil }
        #expect(
            scanner.pendingFingerprint
                == HostKeyCandidate(
                    host: "vps.example", port: 22, fingerprint: HostKeyFingerprint(publicKeyBlob: jumpKey)))
        scanner.confirmFingerprint(trusted: false)

        #expect(await looking.value == nil)
        #expect(failure(of: scanner)?.isDeclinedTrust == true)
        #expect(await knownHosts.fingerprint(host: "vps.example", port: 22) == nil)
    }

    /// With several Routes the transport reports every Route's failure, and the
    /// declined key is still the user's answer, whatever stopped the others.
    @Test func aKeyDeclinedOnOneOfSeveralRoutesIsAnAnswerToo() {
        let declined = TransportError.hostKeyRejected(presented: HostKeyFingerprint(publicKeyBlob: keyBlob))
        let failure = HostServerScanner.Failure(
            TransportError.noRouteReached([
                RouteFailure(
                    route: "192.168.1.20", mayNameAnotherMachine: true, error: .sshUnreachable(detail: "timed out")),
                RouteFailure(route: "via vps.example", mayNameAnotherMachine: false, error: .jumpHostFailed(declined)),
            ]),
            host: Host(address: "host.example", username: "dev"))

        #expect(failure.isDeclinedTrust)
        #expect(
            !HostServerScanner.Failure(
                TransportError.noRouteReached([
                    RouteFailure(
                        route: "192.168.1.20", mayNameAnotherMachine: true,
                        error: .sshUnreachable(detail: "timed out"))
                ]),
                host: Host(address: "host.example", username: "dev")
            ).isDeclinedTrust)
    }

    /// Nothing in the background ever puts up a prompt. The timeout is far past
    /// the test's own limit: a look that asked would never come back in time.
    @Test(.timeLimit(.minutes(1)))
    func aLookThatMayNotAskDeclinesAKeyItHasNotSeen() async throws {
        let host = Host.fixture()
        let knownHosts = InMemoryKnownHostsStore()
        let core = machine()
        let (scanner, _) = makeScanner(
            core: core, presentedKeyBlob: keyBlob, knownHosts: knownHosts, fingerprintTimeout: .seconds(3600))

        let found = await scanner.look(at: host, asksToTrust: false)

        #expect(found == nil)
        #expect(scanner.pendingFingerprint == nil)
        #expect(failure(of: scanner)?.isDeclinedTrust == true)
        #expect(await knownHosts.fingerprint(trustedFor: host) == nil)
        #expect(await core.log.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aKeyAlreadyTrustedIsNotAskedAbout() async throws {
        let host = Host.fixture()
        let knownHosts = InMemoryKnownHostsStore()
        let trust = HostKeyTrust.hostKey(host.id)
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: trust.host, port: trust.port)
        let (scanner, _) = makeScanner(
            core: machine(), presentedKeyBlob: keyBlob, knownHosts: knownHosts, fingerprintTimeout: .seconds(3600))

        let found = await scanner.look(at: host, asksToTrust: false)

        #expect(found?.servers.isEmpty == false)
    }

    /// A changed key stops the look. Once the user says so, the new one is
    /// trusted for every record of the Host, which presents one key whichever
    /// Server is asked.
    @Test func aChangedKeyIsOfferedAndReplacedForEveryRecordOfTheHost() async throws {
        let host = Host.fixture()
        let sibling = UUID()
        let knownHosts = InMemoryKnownHostsStore()
        let known = HostKeyFingerprint(publicKeyBlob: Data("old-host-key".utf8))
        let presented = HostKeyFingerprint(publicKeyBlob: keyBlob)
        for id in [host.id, sibling] {
            let trust = HostKeyTrust.hostKey(id)
            await knownHosts.setFingerprint(known, host: trust.host, port: trust.port)
        }
        let core = machine()
        let (scanner, _) = makeScanner(core: core, presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        #expect(await scanner.look(at: host) == nil)
        #expect(scanner.pendingHostKeyReplacement == HostKeyReplacement(known: known, presented: presented))
        #expect(failure(of: scanner)?.isDeclinedTrust == false)
        #expect(await core.log.isEmpty)

        await scanner.trustPresentedHostKey(for: [host.id, sibling])

        #expect(scanner.pendingHostKeyReplacement == nil)
        for id in [host.id, sibling] {
            let trust = HostKeyTrust.hostKey(id)
            #expect(await knownHosts.fingerprint(host: trust.host, port: trust.port) == presented)
        }
        #expect(await scanner.look(at: host) != nil)
    }

    // MARK: A look that found nothing to report

    @Test func aHostOutOfReachGivesAFailureInWords() async throws {
        let host = Host.fixture()
        let error = TransportError.sshUnreachable(detail: "refused")
        let core = machine()
        let (scanner, _) = makeScanner(core: core, outcome: .connectFails(error))

        #expect(await scanner.look(at: host) == nil)

        let failed = try #require(failure(of: scanner))
        #expect(failed.summary == error.presentation.summary)
        #expect(!failed.message.isEmpty)
        #expect(!failed.isDeclinedTrust)
        #expect(failed.overlayLoginURL == nil)
        #expect(!scanner.isLooking)
        #expect(await core.log.isEmpty)
    }

    /// An exec that failed says nothing of what the Host runs, and the
    /// connection it ran on is closed all the same.
    @Test func aFailedExecGivesAFailureAndClosesTheConnection() async throws {
        let core = machine(detectionFailure: .timedOut)
        let (scanner, _) = makeScanner(core: core)

        #expect(await scanner.look(at: .fixture()) == nil)

        #expect(failure(of: scanner)?.summary == TransportError.timedOut.presentation.summary)
        #expect(await core.log == ["detection", "close"])
    }

    /// A Host still being added has its password typed and not stored.
    @Test func aPasswordHostLooksWithTheTypedPasswordAndSaysWhenThereIsNone() async throws {
        let host = Host.fixture(authMethod: .password)
        let (scanner, connector) = makeScanner(core: machine())

        #expect(await scanner.look(at: host) == nil)
        #expect(failure(of: scanner)?.summary == "No password saved")
        #expect(await connector.capturedSettings.isEmpty)

        #expect(await scanner.look(at: host, typedPassword: "hunter2") != nil)
        #expect(await connector.capturedSettings.count == 1)
    }

    // MARK: Stopping a look

    @Test func cancellingALookDeclinesItsOpenPromptAndGoesIdle() async throws {
        let host = Host.fixture()
        let knownHosts = InMemoryKnownHostsStore()
        let (scanner, _) = makeScanner(core: machine(), presentedKeyBlob: keyBlob, knownHosts: knownHosts)
        let looking = Task { await scanner.look(at: host) }
        try await waitUntil("the key is asked about") { scanner.pendingFingerprint != nil }

        scanner.cancel()

        #expect(scanner.pendingFingerprint == nil)
        #expect(scanner.phase == .idle)
        #expect(await looking.value == nil)
        // The look that was cancelled reports nothing afterwards.
        #expect(scanner.phase == .idle)
        #expect(await knownHosts.fingerprint(trustedFor: host) == nil)
    }

    @Test func aNewLookReplacesTheOneUnderWay() async throws {
        let host = Host.fixture()
        let (scanner, _) = makeScanner(core: machine(), presentedKeyBlob: keyBlob)
        let first = Task { await scanner.look(at: host) }
        try await waitUntil("the first look asks about the key") { scanner.pendingFingerprint != nil }

        let second = Task { await scanner.look(at: host) }

        #expect(await first.value == nil)
        try await waitUntil("the second look asks in its turn") { scanner.pendingFingerprint != nil }
        scanner.confirmFingerprint(trusted: true)
        let found = try #require(await second.value)
        #expect(scanner.phase == .found(found))
    }
}
