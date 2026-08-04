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

    /// The same reclamation property as above, but the loss arrives as a TCP
    /// reset on a degraded link rather than as a remote process exit, and it is
    /// repeated. The native session state is the per-driver instrument; the
    /// descriptor census is the process-wide one, and it is what would catch a
    /// leak the driver's own accounting cannot see.
    @Test("an abruptly severed weak link reclaims every owned native resource")
    func abruptWeakLinkLossReclaimsResources() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        try await proxy.degrade()
        let endpoint = SSHEndpoint(host: environment.endpoint.host, port: proxy.port)
        let rounds = 3

        // One warm-up round: the first connection allocates caches that never
        // come back, and that is not what the census measures.
        try await severOneSession(environment: environment, endpoint: endpoint, proxy: proxy)
        let baseline = openFileDescriptorCount()
        for _ in 0..<rounds {
            try await severOneSession(environment: environment, endpoint: endpoint, proxy: proxy)
        }
        let final = openFileDescriptorCount()
        print(
            "[weak-network] driver descriptors: baseline \(baseline), "
                + "after \(rounds) severed sessions \(final)")
        #expect(
            final <= baseline + 2,
            "descriptors grew from \(baseline) to \(final) across \(rounds) severed sessions")
        try await proxy.reset()
    }

    private func severOneSession(
        environment: SessionDriverTestEnvironment,
        endpoint: SSHEndpoint,
        proxy: WeakNetworkProxyFixture
    ) async throws {
        let driver = SessionDriver()
        _ = try await driver.handshake(endpoint: endpoint, timeout: .seconds(15))
        let privateKey = environment.privateKey
        try await driver.authenticate(
            username: environment.username,
            publicKey: environment.publicKeyBlob,
            signer: { try privateKey.signature(for: $0) },
            timeout: .seconds(15))

        let execution = Task {
            try await driver.execute(
                command: "sleep 30",
                input: Data(),
                timeout: .seconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await proxy.cut() > 0)
        await #expect(throws: SSHError.self) { _ = try await execution.value }

        let state = await driver.resourceStateForTesting()
        #expect(state == SessionDriverResourceState(
            hasSession: false,
            descriptorIsOpen: false,
            isValid: false))
    }

    /// How many descriptors this process holds open right now.
    private func openFileDescriptorCount() -> Int {
        var limit = rlimit()
        let ceiling = getrlimit(RLIMIT_NOFILE, &limit) == 0
            ? Int(min(limit.rlim_cur, 8_192))
            : 1_024
        var open = 0
        for descriptor in 0..<Int32(ceiling) where fcntl(descriptor, F_GETFD) != -1 {
            open += 1
        }
        return open
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

    /// The lost wakeup this guards against: one operation releases the session
    /// after EAGAIN, and before its socket watch is armed another operation
    /// takes the bytes it was waiting for off the shared socket. Nothing is
    /// left to signal, so a purely edge-triggered wait sleeps out its whole
    /// deadline on data that already arrived. The hold widens that window from
    /// a few instructions to something a test can drive.
    @Test("a wait armed after another operation drained the socket retries at once")
    func blockedReadSurvivesAConcurrentDrain() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let blocked = try await connection.openPTY(
            command: "cat",
            columns: 80,
            rows: 24,
            timeout: .seconds(5))
        let draining = try await connection.openPTY(
            command: "cat",
            columns: 80,
            rows: 24,
            timeout: .seconds(5))
        let hold = SessionWaitHold()

        await connection.holdNextSessionWaitForTesting { await hold.waitUntilReleased() }
        let read = Task { try await blocked.read(timeout: .seconds(6)) }
        try await waitUntilTrue("the read should reach the wait") { await hold.hasEntered }

        // The held channel's echo reaches the socket while that channel cannot
        // watch it, and the other channel's round trip is what consumes it.
        try await blocked.write(Data("held\n".utf8), timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(500))
        try await draining.write(Data("drain\n".utf8), timeout: .seconds(5))
        _ = try await draining.read(timeout: .seconds(5))

        await hold.release()
        let released = ContinuousClock.now
        let output = try #require(try await read.value)
        #expect(String(decoding: output, as: UTF8.self).contains("held"))
        #expect(released.duration(to: .now) < .seconds(2))

        try await blocked.close(timeout: .seconds(5))
        try await draining.close(timeout: .seconds(5))
        try await connection.close(timeout: .seconds(2))
    }

    private func waitUntilTrue(
        _ comment: Comment,
        timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}

/// A one-shot gate the driver parks in, so the test controls exactly what runs
/// while an operation sits between releasing the session and watching it.
private actor SessionWaitHold {
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

/// Minimal control client for `scripts/fixtures/weak-network-proxy.py`: the
/// unprivileged TCP proxy the merge fixture puts in front of the disposable
/// sshd. Only the two commands this suite needs are wired up — the app test
/// target drives the full surface.
private struct WeakNetworkProxyFixture: Sendable {
    let port: UInt16
    let controlPort: UInt16

    static let current: WeakNetworkProxyFixture? = {
        let environment = ProcessInfo.processInfo.environment
        guard
            let portText = environment["HEELER_SSH_E2E_WEAK_PORT"],
            let port = UInt16(portText),
            let controlText = environment["HEELER_SSH_E2E_WEAK_CONTROL_PORT"],
            let controlPort = UInt16(controlText)
        else { return nil }
        return WeakNetworkProxyFixture(port: port, controlPort: controlPort)
    }()

    /// Latency plus heavy fragmentation, so the severance below lands on a
    /// session that is genuinely mid-stream rather than idle. Both knobs are
    /// fixed values, so the treatment repeats exactly.
    func degrade() async throws {
        _ = try await send(
            #"{"command":"profile","profile":{"latencyMillis":30,"segmentBytes":256}}"#)
    }

    func reset() async throws {
        _ = try await send(#"{"command":"reset"}"#)
    }

    /// Severs every live proxied connection abruptly; the peer sees RST.
    func cut() async throws -> Int {
        let response = try await send(#"{"command":"cut"}"#)
        guard
            let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
            let count = object["cutConnections"] as? Int
        else { return 0 }
        return count
    }

    private func send(_ request: String) async throws -> Data {
        let controlPort = self.controlPort
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result {
                    try Self.exchange(Data((request + "\n").utf8), port: controlPort)
                })
            }
        }
    }

    private static let queue = DispatchQueue(label: "heelerssh.weak-network-control")

    private static func exchange(_ payload: Data, port: UInt16) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WeakNetworkProxyFixtureError.unreachable }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw WeakNetworkProxyFixtureError.unreachable
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw WeakNetworkProxyFixtureError.unreachable }

        var sent = 0
        try payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < buffer.count {
                let written = write(descriptor, base + sent, buffer.count - sent)
                guard written > 0 else { throw WeakNetworkProxyFixtureError.unreachable }
                sent += written
            }
        }

        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while !line.contains(UInt8(ascii: "\n")) {
            let received = read(descriptor, &buffer, buffer.count)
            guard received > 0 else { throw WeakNetworkProxyFixtureError.unreachable }
            line.append(contentsOf: buffer[0..<received])
        }
        return line
    }
}

private enum WeakNetworkProxyFixtureError: Error {
    case unreachable
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
