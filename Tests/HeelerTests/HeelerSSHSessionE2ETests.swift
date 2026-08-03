import Foundation
import HeelerSSH
import Testing

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
                "wc -c; printf 'stderr-chunk' >&2; exit 23",
                input: input,
                timeout: .seconds(10))

            #expect(String(decoding: result.stdout, as: UTF8.self).contains("262144"))
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
        }
    }

    @Test("unsupported server algorithms have a distinct negotiation error")
    func unsupportedAlgorithmsFailNegotiation() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)

        await #expect(throws: SSHError.algorithmNegotiationFailed) {
            _ = try await SSHConnection.connect(
                to: environment.legacyEndpoint,
                timeout: .seconds(5))
        }
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

    @Test("caller cancellation completes promptly and preserves a clean connection")
    func cancellationClosesOnlyTheAllocatedChannel() async throws {
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

            let followUp = try await connection.execute("printf reusable", timeout: .seconds(5))
            #expect(followUp.stdout == Data("reusable".utf8))
        }
    }

    @Test("deadline completes promptly and preserves a clean connection")
    func deadlineClosesOnlyTheAllocatedChannel() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let started = ContinuousClock.now
            await #expect(throws: SSHError.timedOut) {
                _ = try await connection.execute("sleep 30", timeout: .milliseconds(150))
            }
            #expect(ContinuousClock.now - started < .seconds(3))

            let followUp = try await connection.execute("printf reusable", timeout: .seconds(5))
            #expect(followUp.stdout == Data("reusable".utf8))
        }
    }
}

private struct HeelerSSHTestEnvironment: Sendable {
    let endpoint: SSHEndpoint
    let legacyEndpoint: SSHEndpoint
    let username: String
    let password: String

    static var isAvailable: Bool { current != nil }

    static let current: HeelerSSHTestEnvironment? = {
        let environment = ProcessInfo.processInfo.environment
        guard
            environment["HEELER_SSH_E2E_REQUIRED"] == "1",
            let host = environment["HEELER_SSH_E2E_HOST"],
            let portText = environment["HEELER_SSH_E2E_PORT"],
            let port = UInt16(portText),
            let legacyPortText = environment["HEELER_SSH_E2E_LEGACY_PORT"],
            let legacyPort = UInt16(legacyPortText),
            let username = environment["HEELER_SSH_E2E_USERNAME"],
            let password = environment["HEELER_SSH_E2E_PASSWORD"]
        else {
            return nil
        }
        return HeelerSSHTestEnvironment(
            endpoint: SSHEndpoint(host: host, port: port),
            legacyEndpoint: SSHEndpoint(host: host, port: legacyPort),
            username: username,
            password: password)
    }()

    func connect() async throws -> SSHConnection {
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
