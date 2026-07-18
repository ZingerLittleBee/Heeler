import Foundation
import Testing

@testable import HerdrMobile

// Request queue, per-request timeout, and cancellation (#5), observed only
// through the public Transport surface against the real stack: localhost
// sshd (default MaxSessions 10), real socat, in-test fake herdr server.
@Suite(
    "Transport concurrency e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"))
struct TransportConcurrencyE2ETests {
    @Test func burstOf30ConcurrentRequestsCompletesWithoutChannelFailures() async throws {
        // 30 concurrent RPCs on one SSH connection would need 30 exec
        // channels at once; sshd's default MaxSessions is 10. The bounding
        // queue must keep concurrent channels under that cap so every
        // request completes without a channel-open failure.
        try await withTransport { request in
            [#"{"id":"\#(request.id)","result":{"type":"agent_list","agents":[]}}"#]
        } body: { transport, server in
            try await withThrowingTaskGroup(of: [Agent].self) { group in
                for _ in 0..<30 {
                    group.addTask { try await transport.listAgents() }
                }
                var completed = 0
                for try await agents in group {
                    #expect(agents.isEmpty)
                    completed += 1
                }
                #expect(completed == 30)
            }
            #expect(server.connectionCount == 30)
        }
    }

    /// Boots a fake herdr server plus a real SSH connection to localhost and
    /// tears both down afterwards. The wake command is stubbed to a no-op so
    /// no test path can ever poke the machine's real herdr server.
    private func withTransport(
        script: @escaping FakeHerdrServer.Script,
        body: (SSHTransport, FakeHerdrServer) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let server = try FakeHerdrServer(script: script)
        let transport: SSHTransport
        do {
            transport = try await SSHTransport.connect(
                settings: SSHTransportSettings(
                    host: environment.host,
                    port: environment.port,
                    username: environment.username,
                    privateKey: environment.privateKey,
                    socket: .absolutePath(server.socketPath),
                    socatPath: environment.socatPath,
                    wakeCommand: "false"))
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
