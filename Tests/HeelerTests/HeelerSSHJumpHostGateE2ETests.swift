import CryptoKit
import Foundation
import Testing

@testable import Heeler
@testable import HeelerSSH

@Suite(
    "HeelerSSH Jump Host gate e2e",
    .enabled(
        if: RealSSHFixture.gate(HeelerSSHJumpHostTestEnvironment.current != nil),
        "requires the disposable two-sshd Jump Host fixture"),
    .serialized)
struct HeelerSSHJumpHostGateE2ETests {
    @Test("protocol 17 ping traverses independent SSH hops")
    func protocolPingTraversesBothHops() async throws {
        let environment = try #require(HeelerSSHJumpHostTestEnvironment.current)
        let teardown = SSHConnectionTeardownRecorder()
        let jump = try await environment.connectJump()
        let target = try await jump.connectThrough(
            to: environment.targetEndpoint,
            timeout: .seconds(5),
            teardownObserver: { teardown.record($0) })

        #expect(jump.hostKey != target.hostKey)
        try await environment.authenticate(target, privateKey: environment.deviceKey)
        try await expectPing(target, environment: environment, id: "jump-ping")
        try await target.close(timeout: .seconds(3))
        #expect(teardown.steps == [.targetSession, .forwardingChannel, .jumpSession])

        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await jump.execute("printf poisoned", timeout: .seconds(1))
        }
    }

    @Test("TOFU records both endpoints once and identifies either mismatch")
    func trustIsIndependentAtBothHops() async throws {
        let environment = try #require(HeelerSSHJumpHostTestEnvironment.current)
        let knownHosts = InMemoryKnownHostsStore()
        let confirmations = HostKeyConfirmationRecorder()
        let policy = HostKeyPolicy(knownHosts: knownHosts) { candidate in
            await confirmations.confirm(candidate)
        }

        let first = try await HeelerSSHTransport.connect(
            settings: environment.settings(policy: policy))
        _ = try await first.ping()
        try await first.close()
        let second = try await HeelerSSHTransport.connect(
            settings: environment.settings(policy: policy))
        try await second.close()

        #expect(await confirmations.endpoints == [
            "\(environment.host):\(environment.jumpPort)",
            "\(environment.targetHost):\(environment.targetPort)",
        ])

        let jumpFingerprint = try #require(
            await knownHosts.fingerprint(
                host: environment.host,
                port: Int(environment.jumpPort)))
        await knownHosts.setFingerprint(
            HostKeyFingerprint(
                digest: Data(repeating: 0xA5, count: 32),
                algorithm: jumpFingerprint.algorithm),
            host: environment.host,
            port: Int(environment.jumpPort))
        let jumpError = await #expect(throws: TransportError.self) {
            _ = try await HeelerSSHTransport.connect(
                settings: environment.settings(policy: policy))
        }
        guard case .jumpHostFailed(.hostKeyMismatch) = jumpError else {
            Issue.record("expected the mismatch to identify the Jump Host, got \(String(describing: jumpError))")
            return
        }

        await knownHosts.setFingerprint(
            jumpFingerprint,
            host: environment.host,
            port: Int(environment.jumpPort))
        let targetFingerprint = try #require(
            await knownHosts.fingerprint(
                host: environment.targetHost,
                port: Int(environment.targetPort)))
        await knownHosts.setFingerprint(
            HostKeyFingerprint(
                digest: Data(repeating: 0x5A, count: 32),
                algorithm: targetFingerprint.algorithm),
            host: environment.targetHost,
            port: Int(environment.targetPort))
        let targetError = await #expect(throws: TransportError.self) {
            _ = try await HeelerSSHTransport.connect(
                settings: environment.settings(policy: policy))
        }
        guard case .hostKeyMismatch = targetError else {
            Issue.record("expected the unwrapped mismatch to identify the Host, got \(String(describing: targetError))")
            return
        }
    }

    @Test("outer and target authentication failures retain wrapping and retryability")
    func authenticationFailuresRemainDistinct() async throws {
        let environment = try #require(HeelerSSHJumpHostTestEnvironment.current)
        let policy = environment.acceptingPolicy()
        let unauthorized = Curve25519.Signing.PrivateKey()

        let outerError = await #expect(throws: TransportError.self) {
            _ = try await HeelerSSHTransport.connect(
                settings: environment.settings(
                    policy: policy,
                    jumpCredentials: .ed25519(unauthorized)))
        }
        #expect(outerError == .jumpHostFailed(.authenticationFailed))
        #expect(outerError?.isRetryable == false)

        let targetError = await #expect(throws: TransportError.self) {
            _ = try await HeelerSSHTransport.connect(
                settings: environment.settings(
                    policy: policy,
                    targetCredentials: .ed25519(unauthorized)))
        }
        #expect(targetError == .authenticationFailed)
        #expect(targetError?.isRetryable == false)
    }

    @Test("outer, target, and forwarding failures remain distinct")
    func reachabilityAndForwardingFailuresRemainDistinct() async throws {
        let environment = try #require(HeelerSSHJumpHostTestEnvironment.current)

        let outerError = await #expect(throws: TransportError.self) {
            _ = try await HeelerSSHTransport.connect(
                settings: environment.settings(jumpPort: 1))
        }
        guard case .jumpHostFailed(.sshUnreachable) = outerError else {
            Issue.record("expected wrapped Jump Host reachability, got \(String(describing: outerError))")
            return
        }
        #expect(outerError?.isRetryable == true)

        let targetError = await #expect(throws: TransportError.self) {
            _ = try await HeelerSSHTransport.connect(
                settings: environment.settings(targetPort: 1))
        }
        guard case .sshUnreachable = targetError else {
            Issue.record("expected unwrapped target reachability, got \(String(describing: targetError))")
            return
        }
        #expect(targetError?.isRetryable == true)

        let forwardingError = await #expect(throws: TransportError.self) {
            _ = try await HeelerSSHTransport.connect(
                settings: environment.settings(
                    jumpPort: environment.forwardingDeniedPort))
        }
        #expect(forwardingError == .jumpHostFailed(.tcpForwardingUnavailable))
        #expect(forwardingError?.isRetryable == false)
    }

    @Test("outer and inner handshake deadlines terminate promptly")
    func handshakeDeadlinesTerminatePromptly() async throws {
        let environment = try #require(HeelerSSHJumpHostTestEnvironment.current)
        let startedOuter = ContinuousClock.now
        let outerError = await #expect(throws: TransportError.self) {
            _ = try await HeelerSSHTransport.connect(
                settings: environment.settings(
                    jumpPort: environment.outerStallPort,
                    timeout: .milliseconds(150)))
        }
        #expect(outerError == .jumpHostFailed(.timedOut))
        #expect(ContinuousClock.now - startedOuter < .seconds(1))

        let jump = try await environment.connectJump()
        let startedInner = ContinuousClock.now
        await #expect(throws: SSHError.timedOut) {
            _ = try await jump.connectThrough(
                to: environment.innerStallEndpoint,
                timeout: .milliseconds(150))
        }
        #expect(ContinuousClock.now - startedInner < .seconds(1))
        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await jump.execute("printf poisoned", timeout: .seconds(1))
        }
    }

    @Test("outer connect and forwarding open obey cancellation and deadlines")
    func outerAndForwardingCancellationTerminatePromptly() async throws {
        let environment = try #require(HeelerSSHJumpHostTestEnvironment.current)
        let outerConnect = Task {
            try await SSHConnection.connect(
                to: SSHEndpoint(host: environment.host, port: environment.outerStallPort),
                timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        let outerStarted = ContinuousClock.now
        outerConnect.cancel()
        await #expect(throws: SSHError.cancelled) { _ = try await outerConnect.value }
        #expect(ContinuousClock.now - outerStarted < .seconds(1))

        let deadlineJump = try await environment.connectJump()
        await #expect(throws: SSHError.timedOut) {
            _ = try await deadlineJump.connectThrough(
                to: environment.targetEndpoint,
                timeout: .zero)
        }
        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await deadlineJump.execute("printf poisoned", timeout: .seconds(1))
        }

        let cancelledJump = try await environment.connectJump()
        let forwardingOpen = Task {
            await Task.yield()
            return try await cancelledJump.connectThrough(
                to: environment.targetEndpoint,
                timeout: .seconds(30))
        }
        forwardingOpen.cancel()
        await #expect(throws: SSHError.cancelled) { _ = try await forwardingOpen.value }
        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await cancelledJump.execute("printf poisoned", timeout: .seconds(1))
        }
    }

    @Test("inner handshake and authentication cancellation terminate promptly")
    func nestedCancellationTerminatesPromptly() async throws {
        let environment = try #require(HeelerSSHJumpHostTestEnvironment.current)
        let jump = try await environment.connectJump()
        let startedHandshake = ContinuousClock.now
        let handshake = Task {
            try await jump.connectThrough(
                to: environment.innerStallEndpoint,
                timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        handshake.cancel()
        await #expect(throws: SSHError.cancelled) { _ = try await handshake.value }
        #expect(ContinuousClock.now - startedHandshake < .seconds(1))

        let (secondJump, target) = try await environment.connectBothHops()
        let authentication = Task {
            await Task.yield()
            try await environment.authenticate(target, privateKey: environment.deviceKey)
        }
        authentication.cancel()
        await #expect(throws: SSHError.cancelled) { try await authentication.value }
        await #expect(throws: SSHError.connectionInvalidated) {
            try await environment.authenticate(target, privateKey: environment.deviceKey)
        }
        try await target.close(timeout: .seconds(3))
        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await secondJump.execute("printf poisoned", timeout: .seconds(1))
        }

        let (_, deadlineTarget) = try await environment.connectBothHops()
        await #expect(throws: SSHError.timedOut) {
            try await environment.authenticate(
                deadlineTarget,
                privateKey: environment.deviceKey,
                timeout: .zero)
        }
        await #expect(throws: SSHError.connectionInvalidated) {
            try await environment.authenticate(
                deadlineTarget,
                privateKey: environment.deviceKey)
        }
        try await deadlineTarget.close(timeout: .seconds(3))
    }

    @Test("sequential and concurrent nested exchanges make bounded progress")
    func nestedStressMakesProgress() async throws {
        let environment = try #require(HeelerSSHJumpHostTestEnvironment.current)
        let (_, target) = try await environment.connectAuthenticatedTarget()
        let started = ContinuousClock.now

        for index in 0..<20 {
            try await expectPing(target, environment: environment, id: "sequential-\(index)")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try await expectPing(
                        target,
                        environment: environment,
                        id: "concurrent-\(index)")
                }
            }
            try await group.waitForAll()
        }

        #expect(ContinuousClock.now - started < .seconds(15))
        try await target.close(timeout: .seconds(3))
    }
}

private final class SSHConnectionTeardownRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSteps: [SSHConnectionTeardownStep] = []

    var steps: [SSHConnectionTeardownStep] {
        lock.withLock { recordedSteps }
    }

    func record(_ step: SSHConnectionTeardownStep) {
        lock.withLock { recordedSteps.append(step) }
    }
}

private actor HostKeyConfirmationRecorder {
    private(set) var endpoints: [String] = []

    func confirm(_ candidate: HostKeyCandidate) -> Bool {
        endpoints.append("\(candidate.host):\(candidate.port)")
        return true
    }
}

private struct HeelerSSHJumpHostTestEnvironment: Decodable, Sendable {
    let host: String
    let jumpPort: UInt16
    let forwardingDeniedPort: UInt16
    let targetHost: String
    let targetPort: UInt16
    let outerStallPort: UInt16
    let innerStallHost: String
    let innerStallPort: UInt16
    let username: String
    let deviceKeySeed: String
    let socketPath: String

    var jumpEndpoint: SSHEndpoint { SSHEndpoint(host: host, port: jumpPort) }
    var targetEndpoint: SSHEndpoint { SSHEndpoint(host: targetHost, port: targetPort) }
    var innerStallEndpoint: SSHEndpoint {
        SSHEndpoint(host: innerStallHost, port: innerStallPort)
    }
    var deviceKey: Curve25519.Signing.PrivateKey {
        get throws { try RealSSHFixture.deviceKey(seed: deviceKeySeed) }
    }

    static let current: HeelerSSHJumpHostTestEnvironment? = {
        guard
            let encoded = ProcessInfo.processInfo.environment["HEELER_SSH_JUMP_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded)
        else {
            return nil
        }
        return try? JSONDecoder().decode(HeelerSSHJumpHostTestEnvironment.self, from: data)
    }()

    func acceptingPolicy() -> HostKeyPolicy {
        HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true }
    }

    func settings(
        policy: HostKeyPolicy? = nil,
        jumpPort: UInt16? = nil,
        targetPort: UInt16? = nil,
        jumpCredentials: SSHCredentials? = nil,
        targetCredentials: SSHCredentials? = nil,
        timeout: Duration = .seconds(5)
    ) -> SSHTransportSettings {
        let key = try? deviceKey
        let credentials = targetCredentials ?? key.map(SSHCredentials.ed25519)
            ?? .password("unavailable")
        let jumpCredentials = jumpCredentials ?? key.map(SSHCredentials.ed25519)
            ?? .password("unavailable")
        var settings = SSHTransportSettings(
            host: targetHost,
            port: Int(targetPort ?? self.targetPort),
            username: username,
            credentials: credentials,
            hostKeyPolicy: policy ?? acceptingPolicy(),
            socket: .absolutePath(socketPath),
            jump: SSHJumpSettings(
                host: host,
                port: Int(jumpPort ?? self.jumpPort),
                username: username,
                credentials: jumpCredentials))
        settings.requestTimeout = timeout
        return settings
    }

    func connectJump() async throws -> SSHConnection {
        let connection = try await SSHConnection.connect(to: jumpEndpoint, timeout: .seconds(5))
        do {
            try await authenticate(connection, privateKey: deviceKey)
            return connection
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    func connectBothHops() async throws -> (SSHConnection, SSHConnection) {
        let jump = try await connectJump()
        do {
            let target = try await jump.connectThrough(to: targetEndpoint, timeout: .seconds(5))
            return (jump, target)
        } catch {
            try? await jump.close(timeout: .seconds(2))
            throw error
        }
    }

    func connectAuthenticatedTarget() async throws -> (SSHConnection, SSHConnection) {
        let (jump, target) = try await connectBothHops()
        do {
            try await authenticate(target, privateKey: deviceKey)
            return (jump, target)
        } catch {
            try? await target.close(timeout: .seconds(2))
            throw error
        }
    }

    func authenticate(
        _ connection: SSHConnection,
        privateKey: Curve25519.Signing.PrivateKey,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deviceKey = DeviceKey(privateKey: privateKey)
        try await connection.authenticate(
            username: username,
            publicKey: deviceKey.publicKeyBlob,
            signer: { data in try deviceKey.privateKey.signature(for: data) },
            timeout: timeout)
    }
}

private func requestLine(id: String, method: String = "ping") -> Data {
    Data("{\"id\":\"\(id)\",\"method\":\"\(method)\",\"params\":{}}\n".utf8)
}

private func expectPing(
    _ connection: SSHConnection,
    environment: HeelerSSHJumpHostTestEnvironment,
    id: String
) async throws {
    let response = try await connection.exchangeStreamLocal(
        socketPath: environment.socketPath,
        request: requestLine(id: id),
        timeout: .seconds(5))
    #expect(
        response
            == Data(
                "{\"id\":\"\(id)\",\"result\":{\"protocol\":17,\"version\":\"fake\"}}\n"
                    .utf8))
}
