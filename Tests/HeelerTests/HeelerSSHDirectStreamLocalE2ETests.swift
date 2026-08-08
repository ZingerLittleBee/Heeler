import CryptoKit
import Foundation
import HeelerSSH
import Testing

@testable import Heeler

@Suite(
    "HeelerSSH direct-streamlocal e2e",
    .enabled(
        if: RealSSHFixture.gate(DirectStreamLocalTestEnvironment.current != nil),
        "requires the disposable stream-local fixture"),
    .serialized)
struct HeelerSSHDirectStreamLocalE2ETests {
    @Test("Transport ping validates protocol 17 and opens a fresh channel")
    func transportPingUsesFreshChannels() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
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
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
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
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
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
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
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
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
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
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            // The connection under test serializes libssh2 calls, so the fixture
            // acknowledgement must travel over a separate SSH session.
            let observer = try await environment.deviceKeyConnection(to: environment.endpoint)
            try await withClosingDirectConnection(observer) { observer in
                let requestID = UUID().uuidString
                let exchange = Task {
                    try await connection.exchangeStreamLocal(
                        socketPath: environment.socketPath,
                        request: requestLine(id: requestID, method: "hang"),
                        timeout: .seconds(30))
                }
                defer { exchange.cancel() }
                try await environment.waitUntilHangRequestObserved(
                    requestID,
                    using: observer)
                exchange.cancel()
                await #expect(throws: SSHError.cancelled) { _ = try await exchange.value }
                try await expectPing(connection, socketPath: environment.socketPath)
            }
        }
    }

    @Test("missing socket maps from one read-only diagnostic")
    func missingSocketMapsToSocketNotFound() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
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
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
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
        let connection = try await environment.deviceKeyConnection(
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

    /// The two denial tests above let the wake succeed, so they prove only that
    /// a wake which cannot help leaves the classification alone. This pins the
    /// pairing that actually ships: forwarding denied by policy *and* the wake
    /// itself failing, which is what a Host whose herdr is absent from the
    /// non-interactive PATH does every time. The wake is a recovery attempt, so
    /// its exit status is no evidence about the socket and must not narrow the
    /// combined cause. `staleSocketWakeIsBounded` covers the same wake arms
    /// against a stale-socket fixture, where there is no policy denial to lose.
    @Test("a failed wake does not narrow a forwarding denial")
    func failedWakeKeepsTheForwardingDenial() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        // An unresolvable absolute path: the fixture forces a `herdr` stub onto
        // the session PATH, so only bypassing PATH entirely reproduces "herdr
        // is not reachable from a non-interactive shell" deterministically.
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.settings(
                endpoint: environment.globalPolicyEndpoint,
                wakeCommand: "/nonexistent/herdr remote-client-bridge"))

        await #expect(
            throws: TransportError.streamLocalOpenFailed(path: environment.socketPath)
        ) {
            _ = try await transport.ping()
        }
        try await transport.close()
    }

    /// Historical spike measurement (spec #110, ADR 0011, recorded in
    /// `Packages/HeelerSSH/README.md`): 22.368 ms per exchange through
    /// `exec` + `socat` against 0.514 ms through direct-streamlocal on the
    /// same authenticated loopback session. Printed for comparison only —
    /// absolute loopback timing is scheduler-dependent across CI runs and is
    /// not a merge gate. Accidental remote-process fallback is guarded by the
    /// socat-free Host PATH in `scripts/run-ci-ios-tests.sh` and by the rest
    /// of this suite's functional direct-streamlocal coverage.
    static let recordedSocatBaselinePerExchange = Duration.microseconds(22_368)

    @Test("repeatable loopback measurement prints comparison telemetry")
    func loopbackMeasurementPrintsComparisonTelemetry() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            let iterations = 25
            let started = ContinuousClock.now
            for _ in 0..<iterations {
                try await expectPing(connection, socketPath: environment.socketPath)
            }
            let elapsed = ContinuousClock.now - started
            let perExchange = elapsed / iterations
            print(
                "direct-streamlocal loopback telemetry: \(iterations) fresh channel exchanges "
                    + "completed in \(elapsed), \(perExchange) each, against a recorded "
                    + "exec-plus-socat baseline of \(Self.recordedSocatBaselinePerExchange) "
                    + "each; telemetry only, not a merge gate or WAN latency promise")
        }
    }
}

private struct DirectStreamLocalTestEnvironment: Decodable, Sendable {
    let host: String
    let port: UInt16
    let globalPolicyPort: UInt16
    let keyPolicyPort: UInt16
    let username: String
    let deviceKeySeed: String
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

    /// Reaches a fixture through the full `connect(settings:)` path, which
    /// accepts an injectable wake command so a test can choose how the
    /// cold-start wake behaves.
    func settings(
        endpoint: SSHEndpoint,
        wakeCommand: String
    ) throws -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: endpoint.host,
            port: Int(endpoint.port),
            username: username,
            credentials: .ed25519(try RealSSHFixture.deviceKey(seed: deviceKeySeed)),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .absolutePath(socketPath),
            jump: nil)
        settings.wakeCommand = wakeCommand
        return settings
    }

    func deviceKeyConnection(to endpoint: SSHEndpoint) async throws -> SSHConnection {
        let deviceKey = DeviceKey(privateKey: try RealSSHFixture.deviceKey(seed: deviceKeySeed))
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

    func waitUntilHangRequestObserved(
        _ requestID: String,
        using connection: SSHConnection
    ) async throws {
        let response = try await connection.exchangeStreamLocal(
            socketPath: socketPath,
            request: requestLine(method: "fixture.await_hang", extra: requestID),
            timeout: .seconds(25))
        let observation = try JSONDecoder().decode(HangObservation.self, from: response)
        try #require(observation.result.observed)
    }
}

private struct HangObservation: Decodable {
    struct Result: Decodable {
        let observed: Bool
    }

    let result: Result
}

private func requestLine(
    id: String = UUID().uuidString,
    method: String,
    extra: String? = nil
) -> Data {
    var object: [String: String] = ["id": id, "method": method]
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
