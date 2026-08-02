import Foundation
import Testing

@testable import Heeler

// Request queue, per-request timeout, and cancellation (#5), observed only
// through the public Transport surface against the real stack: localhost
// sshd (default MaxSessions 10), real socat, in-test fake herdr server.
@Suite(
    "Transport concurrency e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"),
    .timeLimit(.minutes(1)))
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

    @Test func unresponsiveServerMapsToTimedOutAndClosesTheChannel() async throws {
        // The fake herdr accepts the connection and reads the request but
        // never answers — a hung host. The request must fail with .timedOut
        // at the configured deadline, and the transport must end the read by
        // closing the exec channel: the server observes that close as its
        // socat peer dying.
        try await withTransport(requestTimeout: .seconds(2)) { _ in
            nil
        } body: { transport, server in
            await #expect(throws: TransportError.timedOut) {
                try await transport.ping()
            }
            #expect(await server.wait(for: { $0.closedConnectionCount == 1 }))
        }
    }

    @Test func requestsAfterATimeoutStillSucceed() async throws {
        // Citadel upgrade guard: its inbound stream must resume when the
        // request task is cancelled. A timed-out request must therefore
        // close its channel and release its slot; afterwards, a full
        // queue-width burst still completes.
        try await withTransport(requestTimeout: .seconds(2)) { request in
            switch request.method {
            case "ping": nil
            default: [#"{"id":"\#(request.id)","result":{"type":"agent_list","agents":[]}}"#]
            }
        } body: { transport, server in
            await #expect(throws: TransportError.timedOut) {
                try await transport.ping()
            }
            try await withThrowingTaskGroup(of: [Agent].self) { group in
                for _ in 0..<8 {
                    group.addTask { try await transport.listAgents() }
                }
                for try await agents in group {
                    #expect(agents.isEmpty)
                }
            }
            #expect(server.receivedRequests.filter { $0.method == "agent.list" }.count == 8)
        }
    }

    @Test func cancelledRequestMapsToCancelledAndClosesTheChannel() async throws {
        // A live exec channel ignores Swift task cancellation, so the
        // transport must end the read by closing the channel explicitly and
        // surface `.cancelled` — never hang, never misread the truncated
        // output as a protocol error.
        try await withTransport { _ in
            nil
        } body: { transport, server in
            let request = Task { try await transport.ping() }
            // Cancel only once the request is in flight on the wire.
            #expect(await server.wait(for: { $0.receivedRequests.count == 1 }))
            request.cancel()
            await #expect(throws: TransportError.cancelled) {
                try await request.value
            }
            #expect(await server.wait(for: { $0.closedConnectionCount == 1 }))
        }
    }

    /// Boots a fake herdr server plus a real SSH connection to localhost and
    /// tears both down afterwards. The wake command is stubbed to a no-op so
    /// no test path can ever poke the machine's real herdr server.
    private func withTransport(
        requestTimeout: Duration = .seconds(15),
        script: @escaping FakeHerdrServer.Script,
        body: (SSHTransport, FakeHerdrServer) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let server = try FakeHerdrServer(script: script)
        let transport: SSHTransport
        do {
            transport = try await SSHTransport.connect(
                settings: environment.makeSettings(
                    socket: .absolutePath(server.socketPath),
                    wakeCommand: "false",
                    requestTimeout: requestTimeout))
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
