import Foundation
import Testing

@testable import HerdrMobile

@MainActor
@Suite("Pairing scan store")
struct PairingScanStoreTests {
    /// A canonical config-only code from the shared vectors, so the store
    /// tests ride on the same source of truth as the decoder tests.
    private static let configOnlyCode = PairingCodeVectorFile.shared.valid[0].code
    /// The shared vector carrying a Bootstrap Key (expires 1753305600).
    private static let bootstrapVector = PairingCodeVectorFile.shared.valid.first {
        $0.payload.bootstrapSeed != nil
    }!
    /// A moment safely inside the bootstrap vector's TTL.
    private static let insideTTL = Date(timeIntervalSince1970: 1_753_305_500)

    /// What the fake ceremony proves; the vector's Host answered on its
    /// only address.
    private static let pairedResult = PairingResult(
        address: "10.0.0.7", port: 22, username: "lin",
        hostKeyFingerprint: HostKeyFingerprint(publicKeyBlob: Data("host-public-key".utf8)))

    private struct Env {
        let store: PairingScanStore
        let connector: FakePairingConnector
        let catalog: HostStore
        let knownHosts: InMemoryKnownHostsStore
        let cleanup: () -> Void
    }

    private func makeEnv(
        outcomes: [FakePairingConnector.Outcome] = [.succeeds(pairedResult)],
        now: Date = insideTTL,
        credentials: HostCredentialsProvider? = nil,
        corruptCatalog: Bool = false
    ) throws -> Env {
        let suiteName = "hm-pairing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        if corruptCatalog {
            defaults.set(Data("not a catalog".utf8), forKey: "hosts")
        }
        let catalog = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let connector = FakePairingConnector(outcomes: outcomes)
        let knownHosts = InMemoryKnownHostsStore()
        let store = PairingScanStore(
            catalog: catalog,
            connector: connector,
            knownHosts: knownHosts,
            credentials: credentials
                ?? HostCredentialsProvider(
                    deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                    secrets: InMemorySecretStore()),
            now: { now })
        return Env(
            store: store, connector: connector, catalog: catalog, knownHosts: knownHosts,
            cleanup: { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// Polls until `condition` holds, yielding the main actor so the store's
    /// ceremony task can progress in between.
    private func waitUntil(_ comment: Comment, condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), comment)
    }

    // MARK: Scanning (the parse step)

    @Test func parsesAScannedPairingCode() throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        env.store.submit(scannedCode: Self.configOnlyCode)

        let code = try #require(env.store.pairingCode)
        #expect(code == (try PairingCode.decode(Self.configOnlyCode)))
        #expect(env.store.scanFailureMessage == nil)
    }

    @Test func foreignQRCodesAskForTheHerdrPairingCode() throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        env.store.submit(scannedCode: "https://example.com/some-other-qr")

        #expect(env.store.pairingCode == nil)
        #expect(env.store.scanFailureMessage?.contains("not a herdr Pairing Code") == true)
    }

    @Test func unsupportedVersionsNameTheVersionAndAskForAnUpdate() throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        env.store.submit(scannedCode: "HERDR-PAIR:2:eyJhZGRycyI6WyIxOTIuMTY4LjEuNDIiXX0")

        #expect(env.store.pairingCode == nil)
        let message = env.store.scanFailureMessage
        #expect(message?.contains("version 2") == true)
        #expect(message?.contains("Update") == true)
    }

    @Test func corruptCodesAskForRegeneration() throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        env.store.submit(scannedCode: "HERDR-PAIR:1:!!!corrupt!!!")

        #expect(env.store.pairingCode == nil)
        #expect(env.store.scanFailureMessage?.contains("Regenerate") == true)
    }

    @Test func aGoodScanClearsAnEarlierFailure() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        env.store.submit(scannedCode: "HERDR-PAIR:1:!!!corrupt!!!")

        env.store.submit(scannedCode: Self.configOnlyCode)

        #expect(env.store.pairingCode != nil)
        #expect(env.store.scanFailureMessage == nil)
    }

    @Test func furtherScansAreIgnoredOnceACodeParsed() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.configOnlyCode)
        let first = try #require(env.store.pairingCode)

        env.store.submit(scannedCode: "HERDR-PAIR:1:!!!corrupt!!!")

        #expect(env.store.pairingCode == first)
        #expect(env.store.scanFailureMessage == nil)
    }

    @Test func rescanReturnsToAFreshScanningState() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.configOnlyCode)

        env.store.rescan()

        #expect(env.store.pairingCode == nil)
        #expect(env.store.scanFailureMessage == nil)
    }

    @Test func rescanAfterACeremonyFailureClearsTheFailure() async throws {
        let env = try makeEnv(outcomes: [.fails(.bootstrapRejected)])
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)
        await env.store.pair()
        #expect(env.store.failure != nil)

        env.store.rescan()

        #expect(env.store.pairingCode == nil)
        #expect(env.store.failure == nil)
    }

    // MARK: Ceremony success

    @Test func successfulCeremonyPersistsTheHostAndPinsTheFingerprint() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)

        await env.store.pair()

        let paired = try #require(env.store.pairedHost)
        #expect(env.catalog.hosts == [paired])
        #expect(paired.address == "10.0.0.7")
        #expect(paired.port == 22)
        #expect(paired.username == "lin")
        #expect(paired.authMethod == .deviceKey)
        // Session selection stays with preflight discovery (ADR 0007).
        #expect(paired.sessionName.isEmpty)
        #expect(paired.displayName == "lin@10.0.0.7")
        // The pinned fingerprint means preflight never TOFU-prompts.
        #expect(
            await env.knownHosts.fingerprint(host: "10.0.0.7", port: 22)
                == Self.pairedResult.hostKeyFingerprint)
        #expect(env.store.failure == nil)
        #expect(env.store.isPairing == false)
        #expect(env.store.step == nil)
    }

    @Test func pairingAgainAfterSuccessIsIgnored() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)
        await env.store.pair()

        await env.store.pair()

        #expect(await env.connector.capturedCodes.count == 1)
        #expect(env.catalog.hosts.count == 1)
    }

    @Test func hostIsPersistedOnlyAfterTheVerifiedReconnect() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        await env.connector.hold()
        env.store.submit(scannedCode: Self.bootstrapVector.code)

        let run = Task { await env.store.pair() }
        try await waitUntil("the ceremony should reach the verify step") {
            env.store.step == .verify
        }
        #expect(env.store.isPairing)
        #expect(env.store.pairedHost == nil)
        #expect(env.catalog.hosts.isEmpty)

        await env.connector.release()
        await run.value

        #expect(env.store.pairedHost != nil)
        #expect(env.catalog.hosts.count == 1)
    }

    // MARK: Ceremony failures

    @Test(arguments: [
        PairingCeremonyError.hostUnreachable(detail: "x"),
        .bootstrapRejected,
        .enrollmentRefused(.unknownPairing),
        .enrollmentRefused(.expired),
        .enrollmentRefused(.invalidKey),
        .enrollmentRefused(.noInput),
        .enrollmentRefused(.unrecognized(code: "quota_exceeded")),
        .enrollmentFailed(detail: "x"),
        .verificationFailed(detail: "x"),
    ])
    func everyStepFailureLeavesNoHostResidue(error: PairingCeremonyError) async throws {
        let env = try makeEnv(outcomes: [.fails(error)])
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)

        await env.store.pair()

        #expect(env.store.pairedHost == nil)
        #expect(env.catalog.hosts.isEmpty)
        #expect(await env.knownHosts.fingerprint(host: "10.0.0.7", port: 22) == nil)
        let failure = try #require(env.store.failure)
        #expect(failure.step == error.step)
        #expect(env.store.isPairing == false)
        #expect(env.store.step == nil)
    }

    @Test(arguments: [
        (PairingCeremonyError.hostUnreachable(detail: "x"), true, "same network"),
        (.bootstrapRejected, false, "Generate a new Pairing Code"),
        (.enrollmentRefused(.unknownPairing), false, "Generate a new Pairing Code"),
        (.enrollmentRefused(.expired), false, "expired"),
        (.enrollmentRefused(.invalidKey), true, "Try again"),
        (.enrollmentRefused(.noInput), true, "Try again"),
        (.enrollmentRefused(.unrecognized(code: "quota_exceeded")), false, "quota_exceeded"),
        (.enrollmentFailed(detail: "x"), true, "Try again"),
        (.verificationFailed(detail: "x"), true, "Try again"),
    ])
    func failureCopyGuidesRecoveryPerStep(
        error: PairingCeremonyError, canRetry: Bool, phrase: String
    ) async throws {
        let env = try makeEnv(outcomes: [.fails(error)])
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)

        await env.store.pair()

        let failure = try #require(env.store.failure)
        #expect(failure.canRetry == canRetry)
        #expect(failure.message.contains(phrase), "copy was: \(failure.message)")
    }

    @Test func expiredCodeIsReportedWithoutConnecting() async throws {
        let env = try makeEnv(now: Date(timeIntervalSince1970: 1_753_305_601))
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)

        await env.store.pair()

        let failure = try #require(env.store.failure)
        #expect(failure.canRetry == false)
        #expect(failure.message.contains("expired"))
        #expect(failure.message.contains("computer"))
        #expect(await env.connector.capturedCodes.isEmpty)
        #expect(env.catalog.hosts.isEmpty)
    }

    @Test func transientFailureRetriesWithTheSameCodeWithoutRescanning() async throws {
        let env = try makeEnv(outcomes: [
            .fails(.hostUnreachable(detail: "no route")),
            .succeeds(Self.pairedResult),
        ])
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)

        await env.store.pair()
        let failure = try #require(env.store.failure)
        #expect(failure.canRetry)
        #expect(env.store.pairingCode != nil, "a retry must not require a rescan")

        await env.store.pair()

        #expect(env.store.pairedHost != nil)
        let scanned = try PairingCode.decode(Self.bootstrapVector.code)
        #expect(await env.connector.capturedCodes == [scanned, scanned])
    }

    @Test func verifyFailureRetriesWithoutTheBootstrapKey() async throws {
        let env = try makeEnv(outcomes: [
            .fails(.verificationFailed(detail: "timeout")),
            .succeeds(Self.pairedResult),
        ])
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)

        await env.store.pair()
        #expect(try #require(env.store.failure).canRetry)

        await env.store.pair()

        #expect(env.store.pairedHost != nil)
        let codes = await env.connector.capturedCodes
        #expect(codes.count == 2)
        // Enrollment already landed on the Host; the retry repeats only the
        // Device Key reconnect instead of burning the spent Bootstrap Key.
        #expect(codes.first?.bootstrap != nil)
        #expect(codes.last?.bootstrap == nil)
        #expect(codes.last?.addresses == codes.first?.addresses)
        #expect(codes.last?.username == codes.first?.username)
    }

    @Test func configOnlyVerifyFailurePointsAtManualAuthorization() async throws {
        let env = try makeEnv(outcomes: [.fails(.verificationFailed(detail: "auth failed"))])
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.configOnlyCode)

        await env.store.pair()

        let failure = try #require(env.store.failure)
        #expect(failure.canRetry == false)
        #expect(failure.message.contains("authorized_keys"))
    }

    @Test func corruptDeviceKeyFailsBeforeTheCeremony() async throws {
        let account = "device-ed25519-private-key"
        let secrets = InMemorySecretStore()
        try secrets.write(Data("not-an-ed25519-key".utf8), account: account)
        let env = try makeEnv(
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: secrets, account: account), secrets: secrets))
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)

        await env.store.pair()

        let failure = try #require(env.store.failure)
        #expect(failure.canRetry == false)
        #expect(failure.message.contains("Device Key"))
        #expect(await env.connector.capturedCodes.isEmpty)
        #expect(env.catalog.hosts.isEmpty)
    }

    @Test func unwritableCatalogSurfacesTheSaveFailureAndPinsNothing() async throws {
        let env = try makeEnv(corruptCatalog: true)
        defer { env.cleanup() }
        env.store.submit(scannedCode: Self.bootstrapVector.code)

        await env.store.pair()

        #expect(env.store.pairedHost == nil)
        let failure = try #require(env.store.failure)
        #expect(failure.canRetry == false)
        #expect(failure.message.contains("could not be saved"))
        #expect(await env.knownHosts.fingerprint(host: "10.0.0.7", port: 22) == nil)
    }
}
