import Foundation
import Testing

@testable import HerdrMobile

// Two-hop connections over the real stack: Citadel -> localhost sshd (standing
// in for the bastion) -> direct-tcpip -> localhost sshd again -> login shell ->
// real socat -> in-test fake herdr server.
//
// The point of these tests is that everything below `SSHTransport.connect` is
// unchanged: once the second hop is up, the Transport does not know or care
// that it is tunnelled. So the coverage here is the connect path, the failure
// taxonomy, and proof that the ordinary capabilities still work through it.
@Suite(
    "SSH jump host e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"))
struct SSHJumpHostE2ETests {
    @Test func pingRoundTripsThroughTheBastion() async throws {
        try await withJumpedTransport { request in
            [
                #"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":17}}"#
            ]
        } body: { transport, server in
            let info = try await transport.ping()

            #expect(info == ServerInfo(version: "9.9.9-fake", protocolVersion: 17))
            #expect(server.receivedRequests.map(\.method) == ["ping"])
        }
    }

    // Each request opens its own exec channel (ADR 0002). Through a bastion
    // those channels live on the second hop, so the channel budget and the
    // one-request-per-connection dance have to survive the tunnel.
    @Test func sequentialRequestsReuseTheTunnelledConnection() async throws {
        try await withJumpedTransport { request in
            [
                #"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":17}}"#
            ]
        } body: { transport, server in
            for _ in 0..<3 {
                _ = try await transport.ping()
            }

            #expect(server.receivedRequests.count == 3)
        }
    }

    @Test func unreachableBastionIsReportedAsJumpHostFailure() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        // Port 1 is reserved and never listening, so this fails at connect
        // rather than at authentication.
        let deadBastion = SSHJumpSettings(
            host: "127.0.0.1", port: 1, username: environment.username,
            credentials: .ed25519(environment.privateKey))

        let error = await #expect(throws: TransportError.self) {
            _ = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath("/tmp/herdr-irrelevant.sock"), jump: deadBastion))
        }

        guard case .jumpHostFailed(let underlying) = error else {
            Issue.record("expected .jumpHostFailed, got \(String(describing: error))")
            return
        }
        guard case .sshUnreachable = underlying else {
            Issue.record("expected .sshUnreachable behind the bastion, got \(underlying)")
            return
        }
        // A bastion that is merely down must not stop the reconnect machinery.
        #expect(error?.isRetryable == true)
    }

    @Test func bastionRejectingOurKeyIsNotRetryable() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let unauthorized = try DeviceKeyStore(secrets: InMemorySecretStore()).loadOrCreate()
        let bastion = SSHJumpSettings(
            host: environment.host, port: environment.port, username: environment.username,
            credentials: .ed25519(unauthorized.privateKey))

        let error = await #expect(throws: TransportError.self) {
            _ = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath("/tmp/herdr-irrelevant.sock"), jump: bastion))
        }

        #expect(error == .jumpHostFailed(.authenticationFailed))
        #expect(error?.isRetryable == false)
    }

    // Both endpoints are trusted on their own terms: sitting behind a trusted
    // bastion must not, by itself, make a Host trusted.
    //
    // Known-hosts entries are keyed by endpoint, so proving this needs two
    // distinct endpoints. "127.0.0.1" and "localhost" are two endpoint keys
    // reaching the same sshd — enough to exercise the real thing under test
    // (two validators, two endpoints, two independent store writes) without
    // standing up a second daemon. A real deployment separates them by port
    // instead, which the store treats identically.
    @Test func bothHopsAreRecordedInKnownHostsSeparately() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let knownHosts = InMemoryKnownHostsStore()
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in true }
        let server = try FakeHerdrServer { request in
            [#"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9","protocol":17}}"#]
        }
        defer { server.stop() }

        var settings = environment.makeSettings(
            socket: .absolutePath(server.socketPath),
            hostKeyPolicy: policy,
            jump: environment.loopbackJump)
        settings.host = "localhost"
        let transport = try await SSHTransport.connect(settings: settings)
        try await transport.close()

        let bastionFingerprint = await knownHosts.fingerprint(
            host: environment.host, port: environment.port)
        let hostFingerprint = await knownHosts.fingerprint(
            host: "localhost", port: environment.port)
        #expect(bastionFingerprint != nil, "the bastion endpoint should be recorded")
        #expect(hostFingerprint != nil, "the Host endpoint should be recorded on its own")
    }

    @Test func imageStagingWorksThroughTheBastion() async throws {
        try await withJumpedTransport { request in
            [#"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9","protocol":17}}"#]
        } body: { transport, _ in
            let payload = Data("staged through a bastion".utf8)
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("herdr-jump-\(UUID().uuidString).png")
            try payload.write(to: localURL)
            defer { try? FileManager.default.removeItem(at: localURL) }

            let staged = try await transport.stageImage(
                PreparedImage(
                    fileURL: localURL,
                    format: .png,
                    pixelWidth: 1,
                    pixelHeight: 1,
                    byteCount: Int64(payload.count))
            ) { _ in }

            #expect(staged.path.hasSuffix(".png"))
        }
    }

    private func withJumpedTransport(
        script: @escaping FakeHerdrServer.Script,
        body: (SSHTransport, FakeHerdrServer) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let server = try FakeHerdrServer(script: script)
        let transport: SSHTransport
        do {
            transport = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath(server.socketPath), jump: environment.loopbackJump))
        } catch {
            server.stop()
            throw error
        }
        do {
            try await body(transport, server)
        } catch {
            try? await transport.close()
            server.stop()
            throw error
        }
        try await transport.close()
        server.stop()
    }
}
