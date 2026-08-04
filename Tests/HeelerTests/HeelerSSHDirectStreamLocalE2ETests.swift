import CryptoKit
import Foundation
import HeelerSSH
import Testing

@testable import Heeler

@Suite(
    "HeelerSSH direct-streamlocal e2e",
    .enabled(
        if: DirectStreamLocalTestEnvironment.current != nil,
        "requires the disposable stream-local fixture"),
    .serialized)
struct HeelerSSHDirectStreamLocalE2ETests {
    @Test("Transport ping validates protocol 17 and opens a fresh channel")
    func transportPingUsesFreshChannels() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(to: environment.endpoint)
        let before = try await environment.connectionCount(using: connection)
        let transport: any Transport = HeelerSSHTransport(
            connection: connection,
            socketPath: environment.socketPath)

        let first = try await transport.ping()
        let second = try await transport.ping()
        let after = try await environment.connectionCount(using: connection)

        #expect(first == ServerInfo(version: "fake", protocolVersion: 17))
        #expect(second == first)
        #expect(after == before + 2)
        try await transport.close()
    }

    @Test("partial request writes and response reads complete one line")
    func partialReadsAndWritesComplete() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            let padding = String(repeating: "x", count: 4 * 1024 * 1024)
            let request = requestLine(method: "partial", extra: padding)
            let response = try await connection.exchangeStreamLocal(
                socketPath: environment.socketPath,
                request: request,
                timeout: .seconds(10))
            #expect(response.last == 0x0A)
            #expect(String(decoding: response, as: UTF8.self).contains("\"protocol\":17"))
        }
    }

    @Test("orderly EOF before a response line preserves connection reuse")
    func eofPreservesConnectionReuse() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            await #expect(throws: SSHError.unexpectedEOF) {
                _ = try await connection.exchangeStreamLocal(
                    socketPath: environment.socketPath,
                    request: requestLine(method: "eof"),
                    timeout: .seconds(5))
            }
            try await expectPing(connection, socketPath: environment.socketPath)
        }
    }

    @Test("one MiB response bound preserves connection reuse")
    func responseBoundPreservesConnectionReuse() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            await #expect(throws: SSHError.responseTooLarge(limit: 1_048_576)) {
                _ = try await connection.exchangeStreamLocal(
                    socketPath: environment.socketPath,
                    request: requestLine(method: "oversized"),
                    timeout: .seconds(5))
            }
            try await expectPing(connection, socketPath: environment.socketPath)
        }
    }

    @Test("timeout closes only its channel and preserves connection reuse")
    func timeoutPreservesConnectionReuse() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            await #expect(throws: SSHError.timedOut) {
                _ = try await connection.exchangeStreamLocal(
                    socketPath: environment.socketPath,
                    request: requestLine(method: "hang"),
                    timeout: .milliseconds(150))
            }
            try await expectPing(connection, socketPath: environment.socketPath)
        }
    }

    @Test("cancellation closes only its channel and preserves connection reuse")
    func cancellationPreservesConnectionReuse() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            let exchange = Task {
                try await connection.exchangeStreamLocal(
                    socketPath: environment.socketPath,
                    request: requestLine(method: "hang"),
                    timeout: .seconds(30))
            }
            try await Task.sleep(for: .milliseconds(100))
            exchange.cancel()
            await #expect(throws: SSHError.cancelled) { _ = try await exchange.value }
            try await expectPing(connection, socketPath: environment.socketPath)
        }
    }

    @Test("missing socket maps from one read-only diagnostic")
    func missingSocketMapsToSocketNotFound() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(to: environment.endpoint)
        let transport = HeelerSSHTransport(
            connection: connection,
            socketPath: environment.missingSocketPath)

        await #expect(
            throws: TransportError.socketNotFound(path: environment.missingSocketPath)
        ) {
            _ = try await transport.ping()
        }
        try await transport.close()
    }

    @Test("stale socket reports the honest combined cause")
    func staleSocketMapsToCombinedFailure() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(to: environment.endpoint)
        let transport = HeelerSSHTransport(
            connection: connection,
            socketPath: environment.staleSocketPath)

        await #expect(
            throws: TransportError.streamLocalOpenFailed(path: environment.staleSocketPath)
        ) {
            _ = try await transport.ping()
        }
        try await transport.close()
    }

    @Test("global forwarding denial reports the honest combined cause")
    func globalPolicyDenialMapsToCombinedFailure() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(
            to: environment.globalPolicyEndpoint)
        let transport = HeelerSSHTransport(
            connection: connection,
            socketPath: environment.socketPath)

        await #expect(
            throws: TransportError.streamLocalOpenFailed(path: environment.socketPath)
        ) {
            _ = try await transport.ping()
        }
        try await transport.close()
    }

    @Test("authorized_keys forwarding denial reports the honest combined cause")
    func keyPolicyDenialMapsToCombinedFailure() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(
            to: environment.keyPolicyEndpoint)
        let transport = HeelerSSHTransport(
            connection: connection,
            socketPath: environment.socketPath)

        await #expect(
            throws: TransportError.streamLocalOpenFailed(path: environment.socketPath)
        ) {
            _ = try await transport.ping()
        }
        try await transport.close()
    }

    @Test("repeatable loopback benchmark records open exchange and close")
    func benchmarkRecordsLatency() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.passwordConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            let iterations = 25
            let started = ContinuousClock.now
            for _ in 0..<iterations {
                try await expectPing(connection, socketPath: environment.socketPath)
            }
            let elapsed = ContinuousClock.now - started
            print(
                "direct-streamlocal loopback benchmark: \(iterations) fresh channel exchanges "
                    + "completed in \(elapsed); this is not a WAN latency promise")
            #expect(elapsed > .zero)
        }
    }
}

private struct DirectStreamLocalTestEnvironment: Decodable, Sendable {
    let host: String
    let port: UInt16
    let globalPolicyPort: UInt16
    let keyPolicyPort: UInt16
    let username: String
    let password: String
    let socketPath: String
    let staleSocketPath: String
    let missingSocketPath: String
    let countFilePath: String

    var endpoint: SSHEndpoint { SSHEndpoint(host: host, port: port) }
    var globalPolicyEndpoint: SSHEndpoint {
        SSHEndpoint(host: host, port: globalPolicyPort)
    }
    var keyPolicyEndpoint: SSHEndpoint { SSHEndpoint(host: host, port: keyPolicyPort) }

    static let current: DirectStreamLocalTestEnvironment? = {
        guard
            let encoded = ProcessInfo.processInfo.environment["HEELER_SSH_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded)
        else {
            return nil
        }
        return try? JSONDecoder().decode(DirectStreamLocalTestEnvironment.self, from: data)
    }()

    func passwordConnection(to endpoint: SSHEndpoint) async throws -> SSHConnection {
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

    func deviceKeyConnection(to endpoint: SSHEndpoint) async throws -> SSHConnection {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((0..<32).map(UInt8.init)))
        let deviceKey = DeviceKey(privateKey: privateKey)
        let connection = try await SSHConnection.connect(to: endpoint, timeout: .seconds(5))
        do {
            try await connection.authenticate(
                username: username,
                publicKey: deviceKey.publicKeyBlob,
                signer: { data in try deviceKey.privateKey.signature(for: data) },
                timeout: .seconds(5))
            return connection
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    func connectionCount(using connection: SSHConnection) async throws -> Int {
        let quotedPath = try #require(RemoteShellPath.quotedAbsolute(countFilePath))
        let result = try await connection.execute("cat \(quotedPath)", timeout: .seconds(5))
        return try #require(Int(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

private func requestLine(method: String, extra: String? = nil) -> Data {
    var object: [String: String] = ["id": UUID().uuidString, "method": method]
    if let extra { object["extra"] = extra }
    let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    var line = encoded ?? Data()
    line.append(0x0A)
    return line
}

private func expectPing(_ connection: SSHConnection, socketPath: String) async throws {
    let response = try await connection.exchangeStreamLocal(
        socketPath: socketPath,
        request: requestLine(method: "ping"),
        timeout: .seconds(5))
    #expect(response.last == 0x0A)
    #expect(String(decoding: response, as: UTF8.self).contains("\"protocol\":17"))
}

private func withClosingDirectConnection<Result>(
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
