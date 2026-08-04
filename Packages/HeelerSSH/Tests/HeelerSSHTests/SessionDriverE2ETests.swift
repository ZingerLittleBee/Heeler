import CryptoKit
import Foundation
import Testing

@testable import HeelerSSH

@Suite(
    "Session driver resource e2e",
    .enabled(
        if: SessionDriverTestEnvironment.current != nil
            || SessionDriverTestEnvironment.isRequired,
        "requires the disposable sshd fixture"),
    .serialized)
struct SessionDriverE2ETests {
    @Test("public connection resolves localhost before authenticating")
    func publicConnectionResolvesLocalhost() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: "localhost", port: environment.endpoint.port),
            timeout: .seconds(5))

        try await environment.authenticate(connection)
        let result = try await connection.execute(
            "printf resolved",
            timeout: .seconds(5))

        #expect(result.stdout == Data("resolved".utf8))
        #expect(result.exitStatus == 0)
        try await connection.close(timeout: .seconds(1))
    }

    @Test("bounded response-line exec closes channels on success and failure")
    func boundedResponseLineExec() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()

        let response = try await connection.executeResponseLine(
            "IFS= read -r line; printf 'accepted:%s\\n' \"$line\"",
            input: Data("device-key-line\n".utf8),
            maximumResponseBytes: 64,
            timeout: .seconds(5))
        #expect(response == Data("accepted:device-key-line\n".utf8))

        await #expect(throws: SSHError.responseTooLarge(limit: 64)) {
            _ = try await connection.executeResponseLine(
                "i=0; while [ \"$i\" -lt 65 ]; do printf x; i=$((i + 1)); done; printf '\\n'",
                input: Data("device-key-line\n".utf8),
                maximumResponseBytes: 64,
                timeout: .seconds(5))
        }
        let reuse = try await connection.execute(
            "printf reusable",
            timeout: .seconds(5))
        #expect(reuse.stdout == Data("reusable".utf8))
        #expect(reuse.exitStatus == 0)

        await #expect(throws: SSHError.timedOut) {
            _ = try await connection.executeResponseLine(
                "sleep 30",
                input: Data("device-key-line\n".utf8),
                maximumResponseBytes: 64,
                timeout: .milliseconds(100))
        }
        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await connection.execute(
                "printf unreachable",
                timeout: .seconds(5))
        }
    }

    @Test("remote transport loss reclaims every owned native resource")
    func remoteTransportLossReclaimsResources() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)

        for _ in 0..<3 {
            let driver = SessionDriver()
            _ = try await driver.handshake(
                endpoint: environment.endpoint,
                timeout: .seconds(5))
            let privateKey = environment.privateKey
            try await driver.authenticate(
                username: environment.username,
                publicKey: environment.publicKeyBlob,
                signer: { try privateKey.signature(for: $0) },
                timeout: .seconds(5))

            await #expect(throws: SSHError.self) {
                _ = try await driver.execute(
                    command: "kill -9 $PPID; sleep 30",
                    input: Data(),
                    timeout: .seconds(5))
            }

            let state = await driver.resourceStateForTesting()
            #expect(state == SessionDriverResourceState(
                hasSession: false,
                descriptorIsOpen: false,
                isValid: false))
        }
    }

    @Test("minimal SFTP surface creates, writes, attributes, renames, and removes")
    func minimalSFTPSurface() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let rootResult = try await connection.execute(
            "mktemp -d /tmp/heeler-sftp.XXXXXXXX",
            timeout: .seconds(5))
        let root = String(decoding: rootResult.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = "\(root)/private"
        let partial = "\(directory)/image.part"
        let final = "\(directory)/image.png"
        let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })

        let sftp = try await connection.openSFTP(timeout: .seconds(5))
        try await sftp.createDirectory(
            at: directory,
            permissions: 0o700,
            timeout: .seconds(5))
        try await sftp.setPermissions(0o700, at: directory, timeout: .seconds(5))
        #expect(try await sftp.attributes(at: directory, timeout: .seconds(5)).permissions == 0o700)

        let file = try await sftp.openFileForWriting(
            at: partial,
            permissions: 0o600,
            timeout: .seconds(5))
        try await file.write(bytes, timeout: .seconds(5))
        try await file.close(timeout: .seconds(5))
        try await sftp.setPermissions(0o600, at: partial, timeout: .seconds(5))
        let partialAttributes = try await sftp.attributes(at: partial, timeout: .seconds(5))
        #expect(partialAttributes.size == UInt64(bytes.count))
        #expect(partialAttributes.permissions == 0o600)

        try await sftp.renameFileAtomically(
            from: partial,
            to: final,
            timeout: .seconds(5))
        #expect(try await sftp.attributes(at: final, timeout: .seconds(5)).size == UInt64(bytes.count))
        #expect(
            try await sftp.readFileIfPresent(at: final, timeout: .seconds(5))
                == bytes)
        #expect(
            try await sftp.readFileIfPresent(
                at: "\(directory)/absent.json",
                timeout: .seconds(5)) == nil)
        try await sftp.removeFile(at: final, timeout: .seconds(5))
        await #expect(throws: SSHError.sftpFailure(status: 2)) {
            _ = try await sftp.attributes(at: final, timeout: .seconds(5))
        }
        try await sftp.removeFileForCompensation(
            at: final,
            timeout: .seconds(5))
        #expect(
            try await sftp.readFileIfPresent(
                at: final,
                timeout: .seconds(5)) == nil)

        try await sftp.close(timeout: .seconds(5))
        _ = try await connection.execute("rm -rf -- '\(root)'", timeout: .seconds(5))
        try await connection.close(timeout: .seconds(2))
    }

    @Test("SFTP status errors never include remote paths")
    func sftpStatusErrorsArePathFree() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let sftp = try await connection.openSFTP(timeout: .seconds(5))
        let privatePath = "/tmp/heeler-private-\(UUID().uuidString)"

        do {
            _ = try await sftp.attributes(at: privatePath, timeout: .seconds(5))
            Issue.record("A missing remote path unexpectedly existed.")
        } catch {
            #expect(error as? SSHError == .sftpFailure(status: 2))
            #expect(!String(describing: error).contains(privatePath))
        }

        try await sftp.close(timeout: .seconds(5))
        try await connection.close(timeout: .seconds(2))
    }
}

private struct SessionDriverTestEnvironment: Sendable {
    let endpoint: SSHEndpoint
    let username: String
    let privateKey: Curve25519.Signing.PrivateKey

    /// Merge CI demands real SSH coverage. When the flag is set the suite stays
    /// enabled even without a decodable fixture, so a missing fixture fails at
    /// the per-test `#require` instead of skipping green.
    static var isRequired: Bool {
        ProcessInfo.processInfo.environment["HEELER_SSH_E2E_REQUIRED"] == "1"
    }

    static let current: SessionDriverTestEnvironment? = {
        let environment = ProcessInfo.processInfo.environment
        guard
            let host = environment["HEELER_SSH_E2E_HOST"],
            let portText = environment["HEELER_SSH_E2E_PORT"],
            let port = UInt16(portText),
            let username = environment["HEELER_SSH_E2E_USERNAME"],
            let seed = environment["HEELER_SSH_E2E_DEVICE_KEY_SEED"],
            let seedData = Data(base64Encoded: seed),
            let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seedData)
        else {
            return nil
        }
        return SessionDriverTestEnvironment(
            endpoint: SSHEndpoint(host: host, port: port),
            username: username,
            privateKey: privateKey)
    }()

    /// SSH wire-format public key blob (RFC 4253 §6.6).
    var publicKeyBlob: Data {
        var blob = Data()
        for field in [Data("ssh-ed25519".utf8), privateKey.publicKey.rawRepresentation] {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
            blob.append(field)
        }
        return blob
    }

    func connect() async throws -> SSHConnection {
        let connection = try await SSHConnection.connect(
            to: endpoint,
            timeout: .seconds(5))
        try await authenticate(connection)
        return connection
    }

    func authenticate(_ connection: SSHConnection) async throws {
        let privateKey = self.privateKey
        try await connection.authenticate(
            username: username,
            publicKey: publicKeyBlob,
            signer: { try privateKey.signature(for: $0) },
            timeout: .seconds(5))
    }
}
