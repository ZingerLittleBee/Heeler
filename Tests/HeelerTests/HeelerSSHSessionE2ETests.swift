import CryptoKit
import Foundation
import HeelerSSH
import Testing

@testable import Heeler

@Suite(
    "HeelerSSH session e2e",
    .enabled(
        if: HeelerSSHTestEnvironment.isAvailable,
        "requires the disposable password-authenticated sshd fixture"),
    .serialized)
struct HeelerSSHSessionE2ETests {
    @Test("handshake exposes the negotiated Host Key before authentication")
    func handshakeReturnsHostKeyBeforeAuthentication() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await SSHConnection.connect(
            to: environment.endpoint,
            timeout: .seconds(5))

        try await withClosingConnection(connection) { connection in
            #expect(!connection.hostKey.algorithm.isEmpty)
            #expect(!connection.hostKey.key.isEmpty)
        }
    }

    @Test("password authentication and exec round trip through real sshd")
    func passwordAuthenticationExecutesCommand() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let input = Data(repeating: 0x78, count: 256 * 1024)
            let result = try await connection.execute(
                "wc -c; yes y | head -c 524288; printf 'stderr-chunk' >&2; exit 23",
                input: input,
                timeout: .seconds(10))

            #expect(String(decoding: result.stdout, as: UTF8.self).contains("262144"))
            #expect(result.stdout.count > 524_288)
            #expect(result.stderr == Data("stderr-chunk".utf8))
            #expect(result.exitStatus == 23)
            #expect(result.reachedEOF)
        }
    }

    @Test("incorrect password has a distinct authentication error")
    func incorrectPasswordFailsAuthentication() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await SSHConnection.connect(
            to: environment.endpoint,
            timeout: .seconds(5))

        try await withClosingConnection(connection) { connection in
            await #expect(throws: SSHError.authenticationFailed) {
                try await connection.authenticate(
                    username: environment.username,
                    password: "wrong-\(UUID().uuidString)",
                    timeout: .seconds(5))
            }

            try await connection.authenticate(
                username: environment.username,
                password: environment.password,
                timeout: .seconds(5))
            let result = try await connection.execute("printf reused", timeout: .seconds(5))
            #expect(result.stdout == Data("reused".utf8))
        }
    }

    @Test("authorized Device Key authenticates and executes through real sshd")
    func authorizedDeviceKeyAuthenticates() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((0..<32).map(UInt8.init)))
        let deviceKey = DeviceKey(privateKey: privateKey)
        let connection = try await SSHConnection.connect(
            to: environment.endpoint,
            timeout: .seconds(5))

        try await withClosingConnection(connection) { connection in
            try await connection.authenticate(
                username: environment.username,
                publicKey: deviceKey.publicKeyBlob,
                signer: { data in
                    try deviceKey.privateKey.signature(for: data)
                },
                timeout: .seconds(5))
            let result = try await connection.execute(
                "printf device-key",
                timeout: .seconds(5))

            #expect(result.stdout == Data("device-key".utf8))
            #expect(result.exitStatus == 0)
        }
    }

    @Test("unauthorized Device Key has a distinct authentication error")
    func unauthorizedDeviceKeyFailsAuthentication() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let deviceKey = DeviceKey(privateKey: Curve25519.Signing.PrivateKey())
        let connection = try await SSHConnection.connect(
            to: environment.endpoint,
            timeout: .seconds(5))

        try await withClosingConnection(connection) { connection in
            await #expect(throws: SSHError.authenticationFailed) {
                try await connection.authenticate(
                    username: environment.username,
                    publicKey: deviceKey.publicKeyBlob,
                    signer: { data in
                        try deviceKey.privateKey.signature(for: data)
                    },
                    timeout: .seconds(5))
            }
        }
    }

    @Test("authentication cancellation invalidates the connection")
    func authenticationCancellationInvalidatesConnection() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await SSHConnection.connect(
            to: environment.endpoint,
            timeout: .seconds(5))

        try await withClosingConnection(connection) { connection in
            let authentication = Task {
                await Task.yield()
                try await connection.authenticate(
                    username: environment.username,
                    password: environment.password,
                    timeout: .seconds(5))
            }
            authentication.cancel()

            await #expect(throws: SSHError.cancelled) {
                try await authentication.value
            }
            await #expect(throws: SSHError.connectionInvalidated) {
                try await connection.authenticate(
                    username: environment.username,
                    password: environment.password,
                    timeout: .seconds(1))
            }
        }
    }

    @Test(
        "unsupported server algorithms have a distinct negotiation error",
        .enabled(
            if: HeelerSSHTestEnvironment.hasLegacyEndpoint,
            "requires the legacy-algorithm sshd fixture"))
    func unsupportedAlgorithmsFailNegotiation() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let legacyEndpoint = try #require(environment.legacyEndpoint)

        await #expect(throws: SSHError.algorithmNegotiationFailed) {
            _ = try await SSHConnection.connect(
                to: legacyEndpoint,
                timeout: .seconds(5))
        }
    }

    @Test(
        "uncertain channel open invalidates the connection",
        .enabled(
            if: HeelerSSHTestEnvironment.hasRestrictedEndpoint,
            "requires the no-session-channel sshd fixture"))
    func failedChannelOpenInvalidatesConnection() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let restrictedEndpoint = try #require(environment.restrictedEndpoint)
        let connection = try await environment.connect(to: restrictedEndpoint)

        await #expect(throws: SSHError.channelFailed) {
            _ = try await connection.execute("printf unreachable", timeout: .seconds(5))
        }
        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await connection.execute("printf poisoned", timeout: .seconds(1))
        }
        try await connection.close(timeout: .seconds(1))
    }

    @Test("clean channel close leaves the connection reusable")
    func cleanChannelCloseLeavesConnectionReusable() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let first = try await connection.execute("printf first", timeout: .seconds(5))
            let second = try await connection.execute("printf second", timeout: .seconds(5))

            #expect(first.stdout == Data("first".utf8))
            #expect(second.stdout == Data("second".utf8))
        }
    }

    @Test("direct-streamlocal exchanges one NDJSON line through real sshd")
    func directStreamLocalExchangesNDJSONLine() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let socketPath = try #require(environment.streamLocalSocketPath)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let response = try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: Data("{\"id\":\"red\",\"method\":\"ping\",\"params\":{}}\n".utf8),
                timeout: .seconds(5))

            #expect(response == Data("{\"id\":\"red\",\"result\":{\"protocol\":17,\"version\":\"fake\"}}\n".utf8))
        }
    }

    @Test("caller cancellation completes promptly and invalidates uncertain cleanup")
    func cancellationInvalidatesUncertainCleanup() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let started = ContinuousClock.now
            let command = Task {
                try await connection.execute("sleep 30", timeout: .seconds(40))
            }
            try await Task.sleep(for: .milliseconds(100))
            command.cancel()

            await #expect(throws: SSHError.cancelled) {
                _ = try await command.value
            }
            #expect(ContinuousClock.now - started < .seconds(3))

            await #expect(throws: SSHError.connectionInvalidated) {
                _ = try await connection.execute("printf poisoned", timeout: .seconds(1))
            }
        }
    }

    @Test("deadline completes promptly and invalidates uncertain cleanup")
    func deadlineInvalidatesUncertainCleanup() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let started = ContinuousClock.now
            await #expect(throws: SSHError.timedOut) {
                _ = try await connection.execute("sleep 30", timeout: .milliseconds(150))
            }
            #expect(ContinuousClock.now - started < .seconds(3))

            await #expect(throws: SSHError.connectionInvalidated) {
                _ = try await connection.execute("printf poisoned", timeout: .seconds(1))
            }
        }
    }

    @Test(
        "handshake deadline completes promptly",
        .enabled(
            if: HeelerSSHTestEnvironment.hasStallEndpoint,
            "requires the non-speaking TCP fixture"))
    func handshakeDeadlineCompletesPromptly() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let stallEndpoint = try #require(environment.stallEndpoint)
        let started = ContinuousClock.now

        await #expect(throws: SSHError.timedOut) {
            _ = try await SSHConnection.connect(
                to: stallEndpoint,
                timeout: .milliseconds(150))
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test(
        "handshake cancellation completes promptly",
        .enabled(
            if: HeelerSSHTestEnvironment.hasStallEndpoint,
            "requires the non-speaking TCP fixture"))
    func handshakeCancellationCompletesPromptly() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let stallEndpoint = try #require(environment.stallEndpoint)
        let started = ContinuousClock.now
        let connection = Task {
            try await SSHConnection.connect(to: stallEndpoint, timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        connection.cancel()

        await #expect(throws: SSHError.cancelled) {
            _ = try await connection.value
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}

private struct HeelerSSHTestEnvironment: Sendable {
    let endpoint: SSHEndpoint
    let legacyEndpoint: SSHEndpoint?
    let restrictedEndpoint: SSHEndpoint?
    let stallEndpoint: SSHEndpoint?
    let streamLocalSocketPath: String?
    let username: String
    let password: String

    static var isAvailable: Bool { current != nil }
    static var hasLegacyEndpoint: Bool { current?.legacyEndpoint != nil }
    static var hasRestrictedEndpoint: Bool { current?.restrictedEndpoint != nil }
    static var hasStallEndpoint: Bool { current?.stallEndpoint != nil }

    static let current: HeelerSSHTestEnvironment? = {
        let environment = ProcessInfo.processInfo.environment
        if
            let encoded = environment["HEELER_SSH_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded),
            let configuration = try? JSONDecoder().decode(
                HeelerSSHTestConfiguration.self,
                from: data)
        {
            return HeelerSSHTestEnvironment(
                endpoint: SSHEndpoint(host: configuration.host, port: configuration.port),
                legacyEndpoint: configuration.legacyPort.map {
                    SSHEndpoint(host: configuration.host, port: $0)
                },
                restrictedEndpoint: configuration.restrictedPort.map {
                    SSHEndpoint(host: configuration.host, port: $0)
                },
                stallEndpoint: configuration.stallPort.map {
                    SSHEndpoint(host: configuration.host, port: $0)
                },
                streamLocalSocketPath: configuration.streamLocalSocketPath,
                username: configuration.username,
                password: configuration.password)
        }
        guard
            environment["HEELER_SSH_E2E_REQUIRED"] == "1",
            let host = environment["HEELER_SSH_E2E_HOST"],
            let portText = environment["HEELER_SSH_E2E_PORT"],
            let port = UInt16(portText),
            let username = environment["HEELER_SSH_E2E_USERNAME"],
            let password = environment["HEELER_SSH_E2E_PASSWORD"]
        else {
            return nil
        }
        return HeelerSSHTestEnvironment(
            endpoint: SSHEndpoint(host: host, port: port),
            legacyEndpoint: endpoint(
                host: host,
                port: environment["HEELER_SSH_E2E_LEGACY_PORT"]),
            restrictedEndpoint: endpoint(
                host: host,
                port: environment["HEELER_SSH_E2E_RESTRICTED_PORT"]),
            stallEndpoint: endpoint(
                host: host,
                port: environment["HEELER_SSH_E2E_STALL_PORT"]),
            streamLocalSocketPath: environment["HEELER_SSH_E2E_STREAMLOCAL_SOCKET"],
            username: username,
            password: password)
    }()

    func connect() async throws -> SSHConnection {
        try await connect(to: endpoint)
    }

    func connect(to endpoint: SSHEndpoint) async throws -> SSHConnection {
        let connection = try await SSHConnection.connect(to: endpoint, timeout: .seconds(5))
        do {
            try await connection.authenticate(
                username: username,
                password: password,
                timeout: .seconds(5))
            return connection
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    private static func endpoint(host: String, port: String?) -> SSHEndpoint? {
        guard let port, let parsedPort = UInt16(port) else { return nil }
        return SSHEndpoint(host: host, port: parsedPort)
    }
}

private struct HeelerSSHTestConfiguration: Decodable {
    let host: String
    let port: UInt16
    let legacyPort: UInt16?
    let restrictedPort: UInt16?
    let stallPort: UInt16?
    let streamLocalSocketPath: String?
    let username: String
    let password: String
}

private func withClosingConnection<Result>(
    _ connection: SSHConnection,
    operation: (SSHConnection) async throws -> Result
) async throws -> Result {
    do {
        let result = try await operation(connection)
        try await connection.close(timeout: .seconds(2))
        return result
    } catch {
        try? await connection.close(timeout: .seconds(2))
        throw error
    }
}
