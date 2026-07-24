import Foundation
import Testing

@testable import HerdrMobile

// Authentication (#2) against the real localhost sshd. The device-key test
// generates a key in-test, installs its authorized_keys line for the test's
// duration, and restores the file afterwards — proving the whole chain:
// CryptoKit keypair -> our authorized_keys formatting -> sshd accepting it.
@Suite(
    "SSH auth e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"),
    .serialized)
struct SSHAuthE2ETests {
    @Test func generatedDeviceKeyAuthenticatesOnceItsLineIsAuthorized() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let deviceKey = try DeviceKeyStore(secrets: InMemorySecretStore()).loadOrCreate()
        // Cross-suite exclusion: the pairing e2e rewrites the same file.
        try await AuthorizedKeysTestLock.shared.withLock {
            let installed = try AuthorizedKeysEntry(
                username: environment.username,
                line: deviceKey.authorizedKeysLine(comment: "herdr-mobile-e2e"))
            defer { installed.restore() }

            let transport = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath("/tmp/herdr-irrelevant.sock"),
                    credentials: .ed25519(deviceKey.privateKey)))
            try await transport.close()
        }
    }

    @Test func unauthorizedDeviceKeyMapsToAuthenticationFailed() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let deviceKey = try DeviceKeyStore(secrets: InMemorySecretStore()).loadOrCreate()

        await #expect(throws: TransportError.authenticationFailed) {
            _ = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath("/tmp/herdr-irrelevant.sock"),
                    credentials: .ed25519(deviceKey.privateKey)))
        }
    }

    @Test func wrongPasswordMapsToAuthenticationFailed() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)

        await #expect(throws: TransportError.authenticationFailed) {
            _ = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath("/tmp/herdr-irrelevant.sock"),
                    credentials: .password("definitely-wrong-\(UUID().uuidString)")))
        }
    }
}

/// Appends one line to the host user's authorized_keys and restores the
/// file's exact prior contents afterwards. The simulator shares the host
/// filesystem, so the file sshd reads is directly writable.
private struct AuthorizedKeysEntry {
    private let path: String
    private let original: Data?

    init(username: String, line: String) throws {
        path = "/Users/\(username)/.ssh/authorized_keys"
        original = FileManager.default.contents(atPath: path)
        var content = original.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        content += line + "\n"
        // Non-atomic on purpose: rewriting in place keeps the permissions
        // sshd's StrictModes checks.
        try content.write(toFile: path, atomically: false, encoding: .utf8)
    }

    func restore() {
        if let original {
            try? original.write(to: URL(fileURLWithPath: path))
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
