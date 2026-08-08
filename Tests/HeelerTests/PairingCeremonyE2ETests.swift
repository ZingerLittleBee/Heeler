import CryptoKit
import Foundation
import HeelerSSH
import Synchronization
import Testing

@testable import Heeler

// The pairing ceremony (#65) against the real localhost sshd, with the real
// plugin accept script (`plugin/src/pair-accept.js`) wired as the Bootstrap
// Key's forced command — exactly what `pairing-session.js` mints, except the
// line is composed here because the simulator cannot shell out to Node. The
// suite temporarily rewrites the host user's real `~/.ssh/authorized_keys`
// and restores it byte-exactly, hash-verified (acceptance criterion).
@Suite(
    "Pairing ceremony e2e",
    .enabled(
        if: RealSSHFixture.gate(PairingE2EEnvironment.isAvailable),
        "requires localhost sshd, an authorized Ed25519 test key, node, and the plugin checkout"),
    .serialized)
struct PairingCeremonyE2ETests {
    @Test func fullCeremonyEnrollsTheDeviceKeyAndVerifies() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        try await AuthorizedKeysTestLock.shared.withLock {
            let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
            let staged = try StagedPairing(environment: environment, ttlSeconds: 120)
            defer { staged.cleanUp() }
            let snapshot = AuthorizedKeysSnapshot(path: environment.authorizedKeysPath)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try await snapshot.append(
                line: staged.authorizedKeysLine,
                environment: environment)

            let deviceKey = DeviceKey(privateKey: .init())
            // A dead address and, in mandatory CI, a live sshd with another
            // Host Key precede the pinned Host. Success proves ordered
            // reachability and Host Key failover before authentication.
            let candidates = ["192.0.2.1"]
                + (environment.mismatchedHostAddress.map { [$0] } ?? [])
                + [environment.base.host]
            let code = PairingCode(
                addresses: candidates,
                port: environment.base.port,
                username: environment.base.username,
                hostKeyFingerprint: pinned,
                bootstrap: .init(seed: staged.seed, expiresAt: staged.expiresAt))
            let steps = Mutex<[PairingStep]>([])

            let result = try await Self.connector.pair(code: code, deviceKey: deviceKey) {
                step in steps.withLock { $0.append(step) }
            }

            #expect(
                result
                    == PairingResult(
                        address: environment.base.host,
                        port: environment.base.port,
                        username: environment.base.username,
                        hostKeyFingerprint: pinned))
            #expect(result.hostKeyFingerprint.algorithm != HostKeyFingerprint.unknownAlgorithm)
            #expect(steps.withLock { $0 } == [.reach, .enroll, .verify])

            // The server side really happened: the Device Key is enrolled,
            // the bootstrap line self-revoked, the pending state consumed,
            // and the popup's Enrollment record written.
            let contents = snapshot.currentContents
            #expect(contents.contains(deviceKey.openSSHPublicKey))
            #expect(!contents.contains(staged.publicLine))
            #expect(!FileManager.default.fileExists(atPath: staged.pendingPath))
            let record = try #require(staged.enrollmentRecord)
            #expect(
                record.fingerprint
                    == HostKeyFingerprint(publicKeyBlob: deviceKey.publicKeyBlob).displayString)
        }
    }

    @Test func expiredPairingIsRefusedAtEnrollAndSelfHeals() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        try await AuthorizedKeysTestLock.shared.withLock {
            let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
            let staged = try StagedPairing(environment: environment, ttlSeconds: -30)
            defer { staged.cleanUp() }
            let snapshot = AuthorizedKeysSnapshot(path: environment.authorizedKeysPath)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try await snapshot.append(
                line: staged.authorizedKeysLine,
                environment: environment)

            let code = PairingCode(
                addresses: [environment.base.host],
                port: environment.base.port,
                username: environment.base.username,
                hostKeyFingerprint: pinned,
                bootstrap: .init(seed: staged.seed, expiresAt: staged.expiresAt))
            let steps = Mutex<[PairingStep]>([])

            await #expect(throws: PairingCeremonyError.enrollmentRefused(.expired)) {
                _ = try await Self.connector.pair(
                    code: code, deviceKey: DeviceKey(privateKey: .init())
                ) { step in steps.withLock { $0.append(step) } }
            }
            #expect(steps.withLock { $0 } == [.reach, .enroll])
            // The accept entrypoint's self-heal removed the expired line.
            #expect(!snapshot.currentContents.contains(staged.publicLine))
        }
    }

    @Test func missingPendingStateIsRefusedAsUnknownPairing() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        try await AuthorizedKeysTestLock.shared.withLock {
            let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
            let staged = try StagedPairing(
                environment: environment, ttlSeconds: 120, writePendingState: false)
            defer { staged.cleanUp() }
            let snapshot = AuthorizedKeysSnapshot(path: environment.authorizedKeysPath)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try await snapshot.append(
                line: staged.authorizedKeysLine,
                environment: environment)

            let code = PairingCode(
                addresses: [environment.base.host],
                port: environment.base.port,
                username: environment.base.username,
                hostKeyFingerprint: pinned,
                bootstrap: .init(seed: staged.seed, expiresAt: staged.expiresAt))

            await #expect(throws: PairingCeremonyError.enrollmentRefused(.unknownPairing)) {
                _ = try await Self.connector.pair(
                    code: code, deviceKey: DeviceKey(privateKey: .init())
                ) { _ in }
            }
        }
    }

    /// A Bootstrap Key sshd has never seen (the line was never installed):
    /// the pinned host key matches, so this is our Host saying no — the
    /// authenticate step, telling the user to regenerate, not to fix the
    /// network. Mutates nothing, so no snapshot is needed.
    @Test func unauthorizedBootstrapKeyFailsTheAuthenticateStep() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        let pinned = try await Self.discoverHostKeyFingerprint(environment.base)

        let strayKey = Curve25519.Signing.PrivateKey()
        let code = PairingCode(
            addresses: [environment.base.host],
            port: environment.base.port,
            username: environment.base.username,
            hostKeyFingerprint: pinned,
            bootstrap: .init(
                seed: strayKey.rawRepresentation,
                expiresAt: Date(timeIntervalSinceNow: 120)))
        let steps = Mutex<[PairingStep]>([])

        await #expect(throws: PairingCeremonyError.bootstrapRejected) {
            _ = try await Self.connector.pair(code: code, deviceKey: DeviceKey(privateKey: .init())) {
                step in steps.withLock { $0.append(step) }
            }
        }
        #expect(steps.withLock { $0 } == [.reach])
    }

    /// A pin that matches nothing: the ceremony must never authenticate
    /// against a host whose key differs from the Pairing Code's fingerprint
    /// (that host is not ours), and the failure reads as unreachable.
    @Test func mismatchedPinnedFingerprintNeverAuthenticates() async throws {
        let environment = try #require(PairingE2EEnvironment.current)

        let code = PairingCode(
            addresses: [environment.base.host],
            port: environment.base.port,
            username: environment.base.username,
            hostKeyFingerprint: HostKeyFingerprint(digest: Data(repeating: 7, count: 32)),
            bootstrap: .init(
                seed: Curve25519.Signing.PrivateKey().rawRepresentation,
                expiresAt: Date(timeIntervalSinceNow: 120)))

        do {
            _ = try await Self.connector.pair(
                code: code, deviceKey: DeviceKey(privateKey: .init())
            ) { _ in }
            Issue.record("ceremony succeeded against a host with the wrong key")
        } catch let error as PairingCeremonyError {
            guard case .hostUnreachable(let detail) = error else {
                Issue.record("expected hostUnreachable, got \(error)")
                return
            }
            #expect(detail.contains("not the pinned host key"))
        }
    }

    @Test func configOnlyPairingVerifiesTheExistingDeviceKeyDirectly() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
        let code = PairingCode(
            addresses: [environment.base.host],
            port: environment.base.port,
            username: environment.base.username,
            hostKeyFingerprint: pinned,
            bootstrap: nil)
        let steps = Mutex<[PairingStep]>([])

        let result = try await Self.connector.pair(
            code: code,
            deviceKey: DeviceKey(privateKey: environment.base.privateKey)
        ) { step in
            steps.withLock { $0.append(step) }
        }

        #expect(result.address == environment.base.host)
        #expect(result.hostKeyFingerprint == pinned)
        #expect(steps.withLock { $0 } == [.reach, .verify])
    }

    @Test func verificationRejectsAnEnrollmentClaimThatDidNotPersistTheKey() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        try await AuthorizedKeysTestLock.shared.withLock {
            let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
            let deviceKey = DeviceKey(privateKey: .init())
            let fingerprint = HostKeyFingerprint(publicKeyBlob: deviceKey.publicKeyBlob)
            let staged = try StagedPairing(
                environment: environment,
                ttlSeconds: 120,
                forcedCommand: .acceptWithoutEnrollment(
                    fingerprint: fingerprint.displayString))
            defer { staged.cleanUp() }
            let snapshot = AuthorizedKeysSnapshot(path: environment.authorizedKeysPath)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try await snapshot.append(
                line: staged.authorizedKeysLine,
                environment: environment)
            let code = PairingCode(
                addresses: [environment.base.host],
                port: environment.base.port,
                username: environment.base.username,
                hostKeyFingerprint: pinned,
                bootstrap: .init(seed: staged.seed, expiresAt: staged.expiresAt))
            let steps = Mutex<[PairingStep]>([])

            let error = await #expect(throws: PairingCeremonyError.self) {
                _ = try await Self.connector.pair(code: code, deviceKey: deviceKey) {
                    step in steps.withLock { $0.append(step) }
                }
            }
            guard case .verificationFailed = error else {
                Issue.record("expected verificationFailed, got \(String(describing: error))")
                return
            }
            #expect(steps.withLock { $0 } == [.reach, .enroll, .verify])
        }
    }

    @Test func enrollmentTimeoutKeepsTheEnrollFailureTaxonomy() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        try await AuthorizedKeysTestLock.shared.withLock {
            let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
            let staged = try StagedPairing(
                environment: environment,
                ttlSeconds: 120,
                forcedCommand: .hang)
            defer { staged.cleanUp() }
            let snapshot = AuthorizedKeysSnapshot(path: environment.authorizedKeysPath)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try await snapshot.append(
                line: staged.authorizedKeysLine,
                environment: environment)
            let code = PairingCode(
                addresses: [environment.base.host],
                port: environment.base.port,
                username: environment.base.username,
                hostKeyFingerprint: pinned,
                bootstrap: .init(seed: staged.seed, expiresAt: staged.expiresAt))
            let connector = SSHPairingConnector(
                perAddressTimeout: .seconds(2),
                enrollTimeout: .milliseconds(150),
                deviceKeyComment: "heeler-e2e")

            await #expect(
                throws: PairingCeremonyError.enrollmentFailed(
                    detail: "the Enrollment exchange timed out")
            ) {
                _ = try await connector.pair(
                    code: code,
                    deviceKey: DeviceKey(privateKey: .init())) { _ in }
            }
        }
    }

    @Test func enrollmentCancellationRemainsTaskCancellation() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        try await AuthorizedKeysTestLock.shared.withLock {
            let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
            let staged = try StagedPairing(
                environment: environment,
                ttlSeconds: 120,
                forcedCommand: .hang)
            defer { staged.cleanUp() }
            let snapshot = AuthorizedKeysSnapshot(path: environment.authorizedKeysPath)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try await snapshot.append(
                line: staged.authorizedKeysLine,
                environment: environment)
            let code = PairingCode(
                addresses: [environment.base.host],
                port: environment.base.port,
                username: environment.base.username,
                hostKeyFingerprint: pinned,
                bootstrap: .init(seed: staged.seed, expiresAt: staged.expiresAt))
            let pairing = Task {
                try await Self.connector.pair(
                    code: code,
                    deviceKey: DeviceKey(privateKey: .init())) { _ in }
            }
            try await Task.sleep(for: .milliseconds(150))
            pairing.cancel()

            await #expect(throws: CancellationError.self) {
                _ = try await pairing.value
            }
        }
    }

    @Test func enrollmentRejectsAnOversizedResponseLine() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        try await AuthorizedKeysTestLock.shared.withLock {
            let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
            let staged = try StagedPairing(
                environment: environment,
                ttlSeconds: 120,
                forcedCommand: .oversizedResponse)
            defer { staged.cleanUp() }
            let snapshot = AuthorizedKeysSnapshot(path: environment.authorizedKeysPath)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try await snapshot.append(
                line: staged.authorizedKeysLine,
                environment: environment)
            let code = PairingCode(
                addresses: [environment.base.host],
                port: environment.base.port,
                username: environment.base.username,
                hostKeyFingerprint: pinned,
                bootstrap: .init(seed: staged.seed, expiresAt: staged.expiresAt))

            let error = await #expect(throws: PairingCeremonyError.self) {
                _ = try await Self.connector.pair(
                    code: code,
                    deviceKey: DeviceKey(privateKey: .init())) { _ in }
            }
            guard case .enrollmentFailed = error else {
                Issue.record("expected enrollmentFailed, got \(String(describing: error))")
                return
            }
        }
    }

    @Test func enrollmentVerifiesTheReturnedDeviceFingerprint() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        try await AuthorizedKeysTestLock.shared.withLock {
            let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
            let staged = try StagedPairing(
                environment: environment,
                ttlSeconds: 120,
                forcedCommand: .acceptWithoutEnrollment(
                    fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
            defer { staged.cleanUp() }
            let snapshot = AuthorizedKeysSnapshot(path: environment.authorizedKeysPath)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try await snapshot.append(
                line: staged.authorizedKeysLine,
                environment: environment)
            let code = PairingCode(
                addresses: [environment.base.host],
                port: environment.base.port,
                username: environment.base.username,
                hostKeyFingerprint: pinned,
                bootstrap: .init(seed: staged.seed, expiresAt: staged.expiresAt))

            let error = await #expect(throws: PairingCeremonyError.self) {
                _ = try await Self.connector.pair(
                    code: code,
                    deviceKey: DeviceKey(privateKey: .init())) { _ in }
            }
            guard case .enrollmentFailed(let detail) = error else {
                Issue.record("expected enrollmentFailed, got \(String(describing: error))")
                return
            }
            #expect(detail.contains("different key"))
        }
    }

    private static let connector = SSHPairingConnector(
        perAddressTimeout: .seconds(2), deviceKeyComment: "heeler-e2e")

    /// The fingerprint the localhost sshd actually presents, discovered the
    /// same way the plugin discovers it at code-generation time. Pinning it
    /// keeps these tests independent of which host key sshd negotiates.
    private static func discoverHostKeyFingerprint(
        _ base: PairingE2EEnvironment.Base
    ) async throws -> HostKeyFingerprint {
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: base.host, port: UInt16(base.port)),
            timeout: .seconds(5))
        let fingerprint = HostKeyFingerprint(publicKeyBlob: connection.hostKey.key)
        try await connection.close(timeout: .seconds(2))
        return fingerprint
    }
}

// Reach failures that need no live sshd, mirroring SSHConnectFailureTests.
@Suite("Pairing reach failure taxonomy")
struct PairingReachFailureTests {
    @Test func deadCandidateAddressesMapToHostUnreachable() async throws {
        // Nothing listens on port 1 (privileged, unused): connection refused.
        let code = PairingCode(
            addresses: ["127.0.0.1"],
            port: 1,
            username: "nobody",
            hostKeyFingerprint: HostKeyFingerprint(digest: Data(repeating: 1, count: 32)),
            bootstrap: .init(
                seed: Curve25519.Signing.PrivateKey().rawRepresentation,
                expiresAt: Date(timeIntervalSinceNow: 120)))
        let steps = Mutex<[PairingStep]>([])

        do {
            _ = try await SSHPairingConnector(perAddressTimeout: .seconds(2)).pair(
                code: code, deviceKey: DeviceKey(privateKey: .init())
            ) { step in steps.withLock { $0.append(step) } }
            Issue.record("ceremony succeeded against a dead port")
        } catch let error as PairingCeremonyError {
            guard case .hostUnreachable = error else {
                Issue.record("expected hostUnreachable, got \(error)")
                return
            }
        }
        #expect(steps.withLock { $0 } == [.reach])
    }
}

/// Probes for the pairing e2e prerequisites on top of the shared local-SSH
/// environment: a Node binary for the forced command and the plugin checkout
/// (the accept script runs from the working tree, exactly as
/// `herdr plugin link` would run it). Overridable via HERDR_TEST_NODE.
private struct PairingE2EEnvironment: Sendable {
    struct Base: Sendable {
        let host: String
        let port: Int
        let username: String
        let privateKey: Curve25519.Signing.PrivateKey
    }

    let base: Base
    let mismatchedHostAddress: String?
    let nodePath: String
    let acceptScriptPath: String
    let homePath: String
    let authorizedKeysPath: String
    let localStateRoot: String
    let remoteStateRoot: String

    static var isAvailable: Bool { current != nil }

    static let current: PairingE2EEnvironment? = probe()

    private static func probe() -> PairingE2EEnvironment? {
        let environment = ProcessInfo.processInfo.environment
        if
            let encoded = environment["HEELER_PAIRING_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded),
            let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
            let privateKey = try? RealSSHFixture.deviceKey(seed: configuration.deviceKeySeed)
        {
            return PairingE2EEnvironment(
                base: Base(
                    host: configuration.host,
                    port: configuration.port,
                    username: configuration.username,
                    privateKey: privateKey),
                mismatchedHostAddress: configuration.mismatchedHostAddress,
                nodePath: configuration.nodePath,
                acceptScriptPath: configuration.acceptScriptPath,
                homePath: configuration.homePath,
                authorizedKeysPath: configuration.authorizedKeysPath,
                localStateRoot: configuration.localStateRoot,
                remoteStateRoot: configuration.remoteStateRoot)
        }

        // Developer convenience only, and deliberately unavailable under the
        // merge gate: this path targets the machine's own sshd on port 22 and
        // rewrites the developer's real `~/.ssh/authorized_keys`. It restores
        // them byte-exactly, but a crash mid-run does not, and the gate's
        // "no machine state to undo" contract cannot depend on not crashing.
        // With the fallback refused the suite skips in the gate's final full
        // lane, exactly as every other fixture-backed suite does.
        guard !RealSSHFixture.isUnderMergeGate else { return nil }
        guard let local = LocalSSHTestEnvironment.current else { return nil }
        let nodePath = environment["HERDR_TEST_NODE"] ?? "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: nodePath) else { return nil }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HeelerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let acceptScript = repoRoot.appendingPathComponent("plugin/src/pair-accept.js").path
        guard FileManager.default.fileExists(atPath: acceptScript) else { return nil }

        return PairingE2EEnvironment(
            base: Base(
                host: local.host,
                port: local.port,
                username: local.username,
                privateKey: local.privateKey),
            mismatchedHostAddress: nil,
            nodePath: nodePath,
            acceptScriptPath: acceptScript,
            homePath: "/Users/\(local.username)",
            authorizedKeysPath: "/Users/\(local.username)/.ssh/authorized_keys",
            localStateRoot: FileManager.default.temporaryDirectory.path,
            remoteStateRoot: FileManager.default.temporaryDirectory.path)
    }

    private struct Configuration: Decodable {
        let host: String
        let port: Int
        let mismatchedHostAddress: String?
        let username: String
        let deviceKeySeed: String
        let nodePath: String
        let acceptScriptPath: String
        let homePath: String
        let authorizedKeysPath: String
        let localStateRoot: String
        let remoteStateRoot: String
    }
}

/// One staged server-side pairing: the restricted Bootstrap Key line whose
/// forced command runs the real accept script, plus the pending state the
/// plugin's `beginPairing` would have written. Field-for-field the format of
/// `pairing-session.js`/`authorized-keys.js`; composed in Swift because the
/// simulator cannot spawn Node itself.
private struct StagedPairing {
    enum ForcedCommand {
        case plugin
        case hang
        case acceptWithoutEnrollment(fingerprint: String)
        case oversizedResponse
    }

    let seed: Data
    let publicLine: String
    let pairingId: String
    let expiresAt: Date
    let stateDir: URL
    let authorizedKeysLine: String

    var pendingPath: String {
        stateDir.appendingPathComponent("pending/\(pairingId).json").path
    }

    private var enrolledPath: String {
        stateDir.appendingPathComponent("enrolled/\(pairingId).json").path
    }

    struct EnrollmentRecord: Decodable {
        let pairingId: String
        let fingerprint: String
        let line: String
    }

    /// The record `pair-accept.js` leaves for the popup, or nil.
    var enrollmentRecord: EnrollmentRecord? {
        guard let data = FileManager.default.contents(atPath: enrolledPath) else { return nil }
        return try? JSONDecoder().decode(EnrollmentRecord.self, from: data)
    }

    init(
        environment: PairingE2EEnvironment,
        ttlSeconds: Int,
        writePendingState: Bool = true,
        forcedCommand: ForcedCommand = .plugin
    ) throws {
        let bootstrapKey = Curve25519.Signing.PrivateKey()
        seed = bootstrapKey.rawRepresentation
        publicLine = DeviceKey(privateKey: bootstrapKey).openSSHPublicKey
        pairingId = Data((0..<6).map { _ in UInt8.random(in: 0...255) })
            .map { String(format: "%02x", $0) }.joined()
        let expiresAtSeconds = Int(Date().timeIntervalSince1970) + ttlSeconds
        expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtSeconds))
        stateDir = URL(fileURLWithPath: environment.localStateRoot, isDirectory: true)
            .appendingPathComponent("herdr-pairing-e2e-\(pairingId)", isDirectory: true)
        let remoteStateDir = URL(
            fileURLWithPath: environment.remoteStateRoot,
            isDirectory: true
        ).appendingPathComponent("herdr-pairing-e2e-\(pairingId)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true)

        for path in [
            environment.nodePath,
            environment.acceptScriptPath,
            environment.homePath,
            remoteStateDir.path,
        ] {
            precondition(!path.contains("'"), "unquotable path in test setup: \(path)")
        }
        let command: String
        switch forcedCommand {
        case .plugin:
            // Mandatory CI uses the runner's account for sshd but an isolated
            // HOME so the real accept entrypoint edits only fixture keys. The
            // Pairing sshd cannot force POSIX sh without overriding this very
            // forced command, so use `env` rather than a variable prefix: the
            // account's login shell parses this line and not every shell
            // accepts `VAR=value command`.
            command = "env HOME='\(environment.homePath)'"
                + " '\(environment.nodePath)' '\(environment.acceptScriptPath)'"
                + " --state-dir '\(remoteStateDir.path)' --pairing-id \(pairingId)"
        case .hang:
            command = try Self.writeForcedCommandScript(
                localDirectory: stateDir,
                remoteDirectory: remoteStateDir,
                contents: "#!/bin/sh\nsleep 30\n")
        case .acceptWithoutEnrollment(let fingerprint):
            command = try Self.writeForcedCommandScript(
                localDirectory: stateDir,
                remoteDirectory: remoteStateDir,
                contents: "#!/bin/sh\nIFS= read -r ignored\nprintf '%s\\n' "
                    + "'HERDR-ENROLL:OK:\(fingerprint)'\n")
        case .oversizedResponse:
            command = try Self.writeForcedCommandScript(
                localDirectory: stateDir,
                remoteDirectory: remoteStateDir,
                contents: "#!/bin/sh\ni=0\nwhile [ \"$i\" -lt 5000 ]; do "
                    + "printf x; i=$((i + 1)); done\nprintf '\\n'\n")
        }
        precondition(
            !command.contains("\"") && !command.contains("\n"),
            "forced command is not authorized_keys-safe")
        authorizedKeysLine =
            "restrict,command=\"\(command)\" \(publicLine)"
            + " herdr-pairing:\(pairingId):exp:\(expiresAtSeconds)"

        if writePendingState {
            let pendingDir = stateDir.appendingPathComponent("pending", isDirectory: true)
            try FileManager.default.createDirectory(
                at: pendingDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let pending = try JSONSerialization.data(withJSONObject: [
                "pairingId": pairingId,
                "expiresAt": expiresAtSeconds,
                "publicLine": publicLine,
            ])
            try pending.write(to: URL(fileURLWithPath: pendingPath))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: pendingPath)
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private static func writeForcedCommandScript(
        localDirectory: URL,
        remoteDirectory: URL,
        contents: String
    ) throws -> String {
        let name = "forced-command"
        let localPath = localDirectory.appendingPathComponent(name)
        try contents.write(to: localPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: localPath.path)
        let remotePath = remoteDirectory.appendingPathComponent(name).path
        precondition(!remotePath.contains("'"), "unquotable forced-command path")
        return "'\(remotePath)'"
    }
}

/// Snapshot of the host user's real authorized_keys, restored byte-exactly
/// after each test. The ceremony rewrites the file server-side (enroll
/// appends, self-revoke removes), so restoration writes the original bytes
/// back and `isRestoredByteExact` proves it with a SHA-256 comparison — the
/// suite's acceptance criterion for touching the real file at all.
private struct AuthorizedKeysSnapshot {
    private struct PublicationError: Error {}

    private let path: String
    private let original: Data?
    private let permissions: Int

    init(path: String) {
        self.path = path
        original = FileManager.default.contents(atPath: path)
        permissions =
            (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
            ?? 0o600
    }

    /// Appends one line with an atomic replacement. The disposable Docker
    /// sshd and the Simulator observe this file through the same bind mount;
    /// an in-place truncate after the server-side Node helper has renamed the
    /// file can expose a partial options word to sshd.
    func append(
        line: String,
        environment: PairingE2EEnvironment
    ) async throws {
        var content = original.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        content += line + "\n"
        let expected = Data(content.utf8)

        for attempt in 0..<10 {
            try write(expected)
            if try await remoteContents(environment: environment) == expected {
                return
            }
            if attempt < 9 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw PublicationError()
    }

    var currentContents: String {
        FileManager.default.contents(atPath: path)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func restore() {
        if let original {
            try? write(original)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    var isRestoredByteExact: Bool {
        let current = FileManager.default.contents(atPath: path)
        guard let original else { return current == nil }
        guard let current else { return false }
        return SHA256.hash(data: current) == SHA256.hash(data: original) && current == original
    }

    private func write(_ data: Data) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: path)
    }

    private func remoteContents(
        environment: PairingE2EEnvironment
    ) async throws -> Data {
        guard let port = UInt16(exactly: environment.base.port) else {
            throw PublicationError()
        }
        let endpoint = SSHEndpoint(
            host: environment.base.host,
            port: port)
        let connection = try await SSHConnection.connect(
            to: endpoint,
            timeout: .seconds(2))
        do {
            let identity = DeviceKey(privateKey: environment.base.privateKey)
            try await connection.authenticate(
                username: environment.base.username,
                publicKey: identity.publicKeyBlob,
                signer: { challenge in
                    try identity.privateKey.signature(for: challenge)
                },
                timeout: .seconds(2))
            let remotePath = "\(environment.homePath)/.ssh/authorized_keys"
            precondition(!remotePath.contains("'"), "unquotable authorized_keys path")
            let result = try await connection.execute(
                "cat -- '\(remotePath)'",
                timeout: .seconds(2))
            try await connection.close(timeout: .seconds(2))
            guard result.reachedEOF, result.exitStatus == 0 else {
                throw PublicationError()
            }
            return result.stdout
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }
}
