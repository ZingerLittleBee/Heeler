import CryptoKit
import Foundation
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
        if: PairingE2EEnvironment.isAvailable,
        "requires localhost sshd, an authorized Ed25519 test key, node, and the plugin checkout"),
    .serialized)
struct PairingCeremonyE2ETests {
    @Test func fullCeremonyEnrollsTheDeviceKeyAndVerifies() async throws {
        let environment = try #require(PairingE2EEnvironment.current)
        try await AuthorizedKeysTestLock.shared.withLock {
            let pinned = try await Self.discoverHostKeyFingerprint(environment.base)
            let staged = try StagedPairing(environment: environment, ttlSeconds: 120)
            defer { staged.cleanUp() }
            let snapshot = AuthorizedKeysSnapshot(username: environment.base.username)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try snapshot.append(line: staged.authorizedKeysLine)

            let deviceKey = DeviceKey(privateKey: .init())
            // A TEST-NET-1 address first: unroutable, so success proves the
            // client fails over to the next candidate within its timeout.
            let code = PairingCode(
                addresses: ["192.0.2.1", environment.base.host],
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
            let snapshot = AuthorizedKeysSnapshot(username: environment.base.username)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try snapshot.append(line: staged.authorizedKeysLine)

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
            let snapshot = AuthorizedKeysSnapshot(username: environment.base.username)
            defer {
                snapshot.restore()
                #expect(snapshot.isRestoredByteExact)
            }
            try snapshot.append(line: staged.authorizedKeysLine)

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

    private static let connector = SSHPairingConnector(
        perAddressTimeout: .seconds(2), deviceKeyComment: "heeler-e2e")

    /// The fingerprint the localhost sshd actually presents, discovered the
    /// same way the plugin discovers it at code-generation time. Pinning it
    /// keeps these tests independent of which host key sshd negotiates.
    private static func discoverHostKeyFingerprint(
        _ base: LocalSSHTestEnvironment
    ) async throws -> HostKeyFingerprint {
        let seen = Mutex<HostKeyFingerprint?>(nil)
        let policy = HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { candidate in
            seen.withLock { $0 = candidate.fingerprint }
            return true
        }
        let transport = try await SSHTransport.connect(
            settings: base.makeSettings(
                socket: .absolutePath("/tmp/herdr-irrelevant.sock"), hostKeyPolicy: policy))
        try await transport.close()
        return try #require(seen.withLock { $0 })
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
    let base: LocalSSHTestEnvironment
    let nodePath: String
    let acceptScriptPath: String

    static var isAvailable: Bool { current != nil }

    static let current: PairingE2EEnvironment? = probe()

    private static func probe() -> PairingE2EEnvironment? {
        guard let base = LocalSSHTestEnvironment.current else { return nil }

        let environment = ProcessInfo.processInfo.environment
        let nodePath = environment["HERDR_TEST_NODE"] ?? "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: nodePath) else { return nil }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HeelerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let acceptScript = repoRoot.appendingPathComponent("plugin/src/pair-accept.js").path
        guard FileManager.default.fileExists(atPath: acceptScript) else { return nil }

        return PairingE2EEnvironment(
            base: base, nodePath: nodePath, acceptScriptPath: acceptScript)
    }
}

/// One staged server-side pairing: the restricted Bootstrap Key line whose
/// forced command runs the real accept script, plus the pending state the
/// plugin's `beginPairing` would have written. Field-for-field the format of
/// `pairing-session.js`/`authorized-keys.js`; composed in Swift because the
/// simulator cannot spawn Node itself.
private struct StagedPairing {
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
        environment: PairingE2EEnvironment, ttlSeconds: Int, writePendingState: Bool = true
    ) throws {
        let bootstrapKey = Curve25519.Signing.PrivateKey()
        seed = bootstrapKey.rawRepresentation
        publicLine = DeviceKey(privateKey: bootstrapKey).openSSHPublicKey
        pairingId = Data((0..<6).map { _ in UInt8.random(in: 0...255) })
            .map { String(format: "%02x", $0) }.joined()
        let expiresAtSeconds = Int(Date().timeIntervalSince1970) + ttlSeconds
        expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtSeconds))
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-pairing-e2e-\(pairingId)", isDirectory: true)

        // The forced command embeds absolute paths, single-quoted exactly
        // like the plugin's acceptCommand; the paths involved carry no
        // quotes on any supported setup.
        for path in [environment.nodePath, environment.acceptScriptPath, stateDir.path] {
            precondition(!path.contains("'"), "unquotable path in test setup: \(path)")
        }
        let command = "'\(environment.nodePath)' '\(environment.acceptScriptPath)'"
            + " --state-dir '\(stateDir.path)' --pairing-id \(pairingId)"
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
}

/// Snapshot of the host user's real authorized_keys, restored byte-exactly
/// after each test. The ceremony rewrites the file server-side (enroll
/// appends, self-revoke removes), so restoration writes the original bytes
/// back and `isRestoredByteExact` proves it with a SHA-256 comparison — the
/// suite's acceptance criterion for touching the real file at all.
private struct AuthorizedKeysSnapshot {
    private let path: String
    private let original: Data?

    init(username: String) {
        path = "/Users/\(username)/.ssh/authorized_keys"
        original = FileManager.default.contents(atPath: path)
    }

    /// Appends one line, preserving prior content. Non-atomic on purpose:
    /// rewriting in place keeps the permissions sshd's StrictModes checks.
    func append(line: String) throws {
        var content = original.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        content += line + "\n"
        try content.write(toFile: path, atomically: false, encoding: .utf8)
    }

    var currentContents: String {
        FileManager.default.contents(atPath: path)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func restore() {
        if let original {
            try? original.write(to: URL(fileURLWithPath: path))
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
}
