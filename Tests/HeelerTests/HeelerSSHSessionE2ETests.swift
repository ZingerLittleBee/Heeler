import CryptoKit
import Foundation
import HeelerSSH
import Testing

@testable import Heeler

@Suite(
    "HeelerSSH session e2e",
    .enabled(
        if: RealSSHFixture.gate(HeelerSSHTestEnvironment.isAvailable),
        "requires the disposable unprivileged sshd fixture"),
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

    @Test(
        "password authentication and exec round trip through real sshd",
        .enabled(
            if: HeelerSSHTestEnvironment.hasPasswordFixture,
            "requires the privileged password-authenticated sshd fixture"))
    func passwordAuthenticationExecutesCommand() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.passwordConnection()

        try await withClosingConnection(connection) { connection in
            let input = Data(repeating: 0x78, count: 256 * 1024)
            let result = try await connection.execute(
                "wc -c; yes y | head -c 524288; printf 'stderr-chunk' >&2; "
                    + "exec 1>&- 2>&-; sleep 0.1; exit 23",
                input: input,
                timeout: .seconds(10))

            #expect(String(decoding: result.stdout, as: UTF8.self).contains("262144"))
            #expect(result.stdout.count > 524_288)
            #expect(result.stderr == Data("stderr-chunk".utf8))
            #expect(result.exitStatus == 23)
            #expect(result.reachedEOF)
        }
    }

    @Test(
        "incorrect password has a distinct authentication error",
        .enabled(
            if: HeelerSSHTestEnvironment.hasPasswordFixture,
            "requires the privileged password-authenticated sshd fixture"))
    func incorrectPasswordFailsAuthentication() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let password = try #require(environment.passwordFixture)
        let connection = try await SSHConnection.connect(
            to: password.endpoint,
            timeout: .seconds(5))

        try await withClosingConnection(connection) { connection in
            await #expect(throws: SSHError.authenticationFailed) {
                try await connection.authenticate(
                    username: password.username,
                    password: "wrong-\(UUID().uuidString)",
                    timeout: passwordAuthenticationObservationBudget)
            }

            try await connection.authenticate(
                username: password.username,
                password: password.password,
                timeout: passwordAuthenticationObservationBudget)
            let result = try await connection.execute("printf reused", timeout: .seconds(5))
            #expect(result.stdout == Data("reused".utf8))
        }
    }

    @Test("authorized Device Key authenticates and executes through real sshd")
    func authorizedDeviceKeyAuthenticates() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let deviceKey = DeviceKey(privateKey: environment.deviceKey)
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
                try await environment.authenticate(connection, timeout: .seconds(5))
            }
            authentication.cancel()

            await #expect(throws: SSHError.cancelled) {
                try await authentication.value
            }
            await #expect(throws: SSHError.connectionInvalidated) {
                try await environment.authenticate(connection, timeout: .seconds(1))
            }
        }
    }

    @Test(
        "unsupported server algorithms have a distinct negotiation error",
        .enabled(
            if: RealSSHFixture.gate(HeelerSSHTestEnvironment.hasLegacyEndpoint),
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
            if: RealSSHFixture.gate(HeelerSSHTestEnvironment.hasRestrictedEndpoint),
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

    /// The allocation gate proves exec owns a channel; the cleanup gate proves
    /// the secondary two-second budget has started. Expiring that budget while
    /// the gates are held removes the 100ms timing guess that flaked under CI
    /// load (run 31164134232): cancel could finish after clean channel setup
    /// and leave the connection reusable instead of invalidated.
    @Test("caller cancellation completes promptly and invalidates uncertain cleanup")
    func cancellationInvalidatesUncertainCleanup() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let allocated = SessionPhaseGate()
            let cleanup = SessionPhaseGate()
            await connection.holdNextExecChannelAllocationForTesting {
                await allocated.waitUntilReleased()
            }
            await connection.holdNextExecCleanupForTesting {
                await cleanup.waitUntilReleased()
            }

            let command = Task {
                try await connection.execute("sleep 30", timeout: .seconds(40))
            }
            try await waitUntilPhase("cancellation should allocate its channel") {
                await allocated.hasEntered
            }
            command.cancel()
            await allocated.release()
            try await waitUntilPhase("cancellation should enter catch cleanup") {
                await cleanup.hasEntered
            }
            try await Task.sleep(for: .milliseconds(2_100))
            // Prompt completion is independent of phase-observation wait and the
            // deliberate 2.1s cleanup hold: start the clock only once cleanup is
            // free to finish and the command should surface promptly.
            let started = ContinuousClock.now
            await cleanup.release()

            await #expect(throws: SSHError.cancelled) {
                _ = try await command.value
            }
            #expect(ContinuousClock.now - started < .seconds(1))

            await #expect(throws: SSHError.connectionInvalidated) {
                _ = try await connection.execute("printf poisoned", timeout: .seconds(1))
            }
        }
    }

    /// Inject timeout only after allocation, then hold cleanup past its
    /// two-second budget. This keeps setup scheduling outside the failure
    /// trigger while exercising the real allocated-channel cleanup path.
    @Test("allocated exec timeout completes promptly and invalidates uncertain cleanup")
    func allocatedExecTimeoutInvalidatesUncertainCleanup() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let allocated = SessionPhaseGate()
            let cleanup = SessionPhaseGate()
            await connection.holdNextExecChannelAllocationForTesting {
                await allocated.waitUntilReleased()
                throw SSHError.timedOut
            }
            await connection.holdNextExecCleanupForTesting {
                await cleanup.waitUntilReleased()
            }

            let command = Task {
                try await connection.execute("sleep 30", timeout: .seconds(40))
            }
            try await waitUntilPhase("timeout should allocate its channel") {
                await allocated.hasEntered
            }
            await allocated.release()
            try await waitUntilPhase("timeout should enter catch cleanup") {
                await cleanup.hasEntered
            }
            try await Task.sleep(for: .milliseconds(2_100))
            // Prompt completion is independent of phase-observation wait and the
            // deliberate 2.1s cleanup hold: start the clock only once cleanup is
            // free to finish and the command should surface promptly.
            let started = ContinuousClock.now
            await cleanup.release()

            await #expect(throws: SSHError.timedOut) {
                _ = try await command.value
            }
            #expect(ContinuousClock.now - started < .seconds(1))

            await #expect(throws: SSHError.connectionInvalidated) {
                _ = try await connection.execute("printf poisoned", timeout: .seconds(1))
            }
        }
    }

    @Test(
        "handshake deadline completes promptly",
        .enabled(
            if: RealSSHFixture.gate(HeelerSSHTestEnvironment.hasStallEndpoint),
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
            if: RealSSHFixture.gate(HeelerSSHTestEnvironment.hasStallEndpoint),
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

@Suite(
    "HeelerSSH PTY e2e",
    .enabled(
        if: RealSSHFixture.gate(HeelerSSHTestEnvironment.isAvailable),
        "requires the disposable unprivileged sshd fixture"),
    .serialized,
    .timeLimit(.minutes(1)))
struct HeelerSSHPTYE2ETests {
    @Test("PTY exec preserves raw IO, merged output, geometry, and exit status")
    func ptyExecPreservesTerminalSemantics() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let channel = try await connection.openPTY(
                command: "stty -echo; printf 'STDOUT\\n'; printf 'STDERR\\n' >&2; "
                    + "stty size; while IFS= read -r line; do "
                    + "printf 'GOT:%s\\n' \"$line\"; stty size; "
                    + "[ \"$line\" = done ] && exit 23; done",
                columns: 80,
                rows: 24,
                timeout: .seconds(5))

            var output = Data()
            try await readPTY(channel, into: &output, until: "24 80")
            let initial = String(decoding: output, as: UTF8.self)
            #expect(initial.contains("STDOUT"))
            #expect(initial.contains("STDERR"))

            try await channel.write(Data("raw-\u{1B}[A\n".utf8), timeout: .seconds(5))
            try await readPTY(channel, into: &output, until: "GOT:raw-\u{1B}[A")
            try await channel.resize(
                columns: 101,
                rows: 43,
                timeout: .seconds(5))
            try await channel.write(Data("done\n".utf8), timeout: .seconds(5))
            try await readPTY(channel, into: &output, until: "43 101")
            while let chunk = try await channel.read(timeout: .seconds(5)) {
                output.append(chunk)
            }
            #expect(try await channel.exitStatus(timeout: .seconds(1)) == 23)
            try await channel.close(timeout: .seconds(2))

            let reused = try await connection.execute("printf reused", timeout: .seconds(5))
            #expect(reused.stdout == Data("reused".utf8))
        }
    }

    @Test("PTY EOF remains observable after a clean remote exit")
    func ptyEOFAndExitStatusAreObservable() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let channel = try await connection.openPTY(
                command: "printf 'DONE\\n'",
                columns: 80,
                rows: 24,
                timeout: .seconds(5))

            var output = Data()
            while let chunk = try await channel.read(timeout: .seconds(5)) {
                output.append(chunk)
            }
            #expect(String(decoding: output, as: UTF8.self).contains("DONE"))
            #expect(try await channel.exitStatus(timeout: .seconds(1)) == 0)
            try await channel.close(timeout: .seconds(2))
        }
    }

    @Test("explicit PTY close is prompt and leaves the connection reusable")
    func explicitPTYClosePreservesConnection() async throws {
        let environment = try #require(HeelerSSHTestEnvironment.current)
        let connection = try await environment.connect()

        try await withClosingConnection(connection) { connection in
            let channel = try await connection.openPTY(
                command: "printf 'READY\\n'; exec sleep 30",
                columns: 80,
                rows: 24,
                timeout: .seconds(5))
            var output = Data()
            try await readPTY(channel, into: &output, until: "READY")

            let started = ContinuousClock.now
            try await channel.close(timeout: .seconds(2))
            #expect(ContinuousClock.now - started < .seconds(3))
            try await channel.close(timeout: .seconds(1))

            let reused = try await connection.execute("printf reused", timeout: .seconds(5))
            #expect(reused.stdout == Data("reused".utf8))
        }
    }
}

private func readPTY(
    _ channel: SSHPTYChannel,
    into output: inout Data,
    until marker: String
) async throws {
    while !String(decoding: output, as: UTF8.self).contains(marker) {
        let chunk = try #require(try await channel.read(timeout: .seconds(5)))
        output.append(chunk)
    }
}

private struct HeelerSSHTestEnvironment: Sendable {
    /// The privileged half of the fixture. macOS cannot verify an account
    /// password without root, so this is the one endpoint the unprivileged
    /// fixture cannot provide; everything else authenticates with the Device
    /// Key the fixture authorizes.
    struct PasswordFixture: Sendable {
        let endpoint: SSHEndpoint
        let username: String
        let password: String
    }

    let endpoint: SSHEndpoint
    let legacyEndpoint: SSHEndpoint?
    let restrictedEndpoint: SSHEndpoint?
    let stallEndpoint: SSHEndpoint?
    let streamLocalSocketPath: String?
    let username: String
    let deviceKey: Curve25519.Signing.PrivateKey
    let passwordFixture: PasswordFixture?

    static var isAvailable: Bool { current != nil }
    static var hasLegacyEndpoint: Bool { current?.legacyEndpoint != nil }
    static var hasRestrictedEndpoint: Bool { current?.restrictedEndpoint != nil }
    static var hasStallEndpoint: Bool { current?.stallEndpoint != nil }
    static var hasPasswordFixture: Bool { current?.passwordFixture != nil }

    /// The whole fixture arrives as one base64 JSON blob from
    /// `scripts/run-ci-ios-tests.sh`; there is deliberately no per-variable
    /// fallback. The scheme forwards its test-environment allow-list as empty
    /// strings when the invoking shell has not exported them, so a fallback
    /// assembled out of individual variables could never see a Device Key seed
    /// and was unreachable.
    static let current: HeelerSSHTestEnvironment? = {
        let environment = ProcessInfo.processInfo.environment
        guard
            let encoded = environment["HEELER_SSH_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded),
            let configuration = try? JSONDecoder().decode(
                HeelerSSHTestConfiguration.self,
                from: data),
            let deviceKey = try? RealSSHFixture.deviceKey(seed: configuration.deviceKeySeed)
        else {
            return nil
        }
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
                deviceKey: deviceKey,
                passwordFixture: configuration.passwordFixture.map {
                    PasswordFixture(
                        endpoint: SSHEndpoint(host: configuration.host, port: $0.port),
                        username: $0.username,
                        password: $0.password)
                })
    }()

    func connect() async throws -> SSHConnection {
        try await connect(to: endpoint)
    }

    func connect(to endpoint: SSHEndpoint) async throws -> SSHConnection {
        let connection = try await SSHConnection.connect(to: endpoint, timeout: .seconds(5))
        do {
            try await authenticate(connection, timeout: .seconds(5))
            return connection
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    func authenticate(_ connection: SSHConnection, timeout: Duration) async throws {
        let key = DeviceKey(privateKey: deviceKey)
        try await connection.authenticate(
            username: username,
            publicKey: key.publicKeyBlob,
            signer: { try key.privateKey.signature(for: $0) },
            timeout: timeout)
    }

    func passwordConnection() async throws -> SSHConnection {
        let fixture = try #require(passwordFixture)
        let connection = try await SSHConnection.connect(
            to: fixture.endpoint,
            timeout: .seconds(5))
        do {
            try await connection.authenticate(
                username: fixture.username,
                password: fixture.password,
                timeout: passwordAuthenticationObservationBudget)
            return connection
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

}

private struct HeelerSSHTestConfiguration: Decodable {
    struct PasswordFixture: Decodable {
        let port: UInt16
        let username: String
        let password: String
    }

    let host: String
    let port: UInt16
    let legacyPort: UInt16?
    let restrictedPort: UInt16?
    let stallPort: UInt16?
    let streamLocalSocketPath: String?
    let username: String
    let deviceKeySeed: String
    let passwordFixture: PasswordFixture?
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

/// One-shot phase gate for DEBUG exec seams: the driver parks here so the test
/// can cancel or expire a budget only after allocation/cleanup has begun.
private actor SessionPhaseGate {
    private(set) var hasEntered = false
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        hasEntered = true
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }
}

/// Observation budget for phase-gate probes under CI load only. Product
/// operation timeouts (150ms / 2s) stay independent and must not widen to match.
private let phaseGateObservationBudget: Duration = .seconds(15)

/// Fixture budget for password authenticate under CI load only. macOS password
/// verification/PAM has reached ~4.9s in CI; this is test-environment headroom,
/// not a product timeout promise. Connect and exec budgets stay independent.
private let passwordAuthenticationObservationBudget: Duration = .seconds(15)

private func waitUntilPhase(
    _ comment: Comment,
    timeout: Duration = phaseGateObservationBudget,
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await condition(), comment)
}
