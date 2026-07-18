import Foundation
import Testing

@testable import HerdrMobile

// End-to-end over the real stack: Citadel -> localhost sshd -> login shell ->
// real socat -> in-test fake herdr server. Only herdr itself is faked.
// Skipped as a suite when the machine lacks the prerequisites.
@Suite(
    "SSHTransport e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, socat, and an authorized Ed25519 test key"))
struct SSHTransportE2ETests {
    @Test func pingRoundTripsAndChecksProtocolVersion() async throws {
        try await withTransport { request in
            [
                #"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":16,"capabilities":{"live_handoff":true,"future_capability":true}}}"#
            ]
        } body: { transport, server in
            let info = try await transport.ping()

            #expect(info == ServerInfo(version: "9.9.9-fake", protocolVersion: 16))
            #expect(server.receivedRequests.map(\.method) == ["ping"])
        }
    }

    @Test func pingRejectsUnsupportedProtocolVersion() async throws {
        try await withTransport { request in
            [#"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":99}}"#]
        } body: { transport, _ in
            await #expect(
                throws: TransportError.protocolVersionMismatch(
                    server: 99, supported: SSHTransport.supportedProtocolVersion)
            ) {
                try await transport.ping()
            }
        }
    }

    @Test func agentListRoundTrips() async throws {
        try await withTransport { request in
            [
                #"{"id":"\#(request.id)","result":{"type":"agent_list","agents":[{"terminal_id":"term_a","agent":"claude","terminal_title":"⠐ Fix the bug","terminal_title_stripped":"Fix the bug","agent_status":"blocked","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"cwd":"/work/a","foreground_cwd":"/work/a","revision":3},{"terminal_id":"term_b","agent":"codex","terminal_title":"idle","terminal_title_stripped":"idle","agent_status":"idle","workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p4","focused":false,"cwd":"/work/b","foreground_cwd":"/work/b","revision":7}]}}"#
            ]
        } body: { transport, server in
            let agents = try await transport.listAgents()

            #expect(
                agents == [
                    Agent(
                        terminalID: "term_a", kind: "claude", title: "Fix the bug",
                        status: .blocked, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                        cwd: "/work/a", revision: 3),
                    Agent(
                        terminalID: "term_b", kind: "codex", title: "idle",
                        status: .idle, workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p4",
                        cwd: "/work/b", revision: 7),
                ])
            #expect(server.receivedRequests.map(\.method) == ["agent.list"])
        }
    }

    @Test func serverErrorSurfacesAsHerdrAPIError() async throws {
        try await withTransport { request in
            [#"{"id":"\#(request.id)","error":{"code":500,"message":"scripted failure"}}"#]
        } body: { transport, _ in
            await #expect(throws: HerdrAPIError(code: "500", message: "scripted failure")) {
                try await transport.listAgents()
            }
        }
    }

    @Test func eachRequestUsesAFreshConnection() async throws {
        // herdr serves one request per connection; two sequential calls must
        // arrive on two separate socket connections (= two exec channels).
        try await withTransport { request in
            switch request.method {
            case "ping":
                [#"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":16}}"#]
            default:
                [#"{"id":"\#(request.id)","result":{"type":"agent_list","agents":[]}}"#]
            }
        } body: { transport, server in
            _ = try await transport.ping()
            let agents = try await transport.listAgents()

            #expect(agents.isEmpty)
            #expect(server.connectionCount == 2)
            #expect(server.receivedRequests.map(\.method) == ["ping", "agent.list"])
        }
    }

    @Test func isConnectedTracksTheSSHConnectionLifecycle() async throws {
        // The reconnect machinery (#18) decides "re-subscribe or re-dial"
        // from this flag; it must be honest about the SSH layer's liveness.
        let environment = try #require(LocalSSHTestEnvironment.current)
        let server = try FakeHerdrServer { _ in nil }
        defer { server.stop() }

        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(socket: .absolutePath(server.socketPath)))
        #expect(await transport.isConnected)

        try await transport.close()
        #expect(await !transport.isConnected)
    }

    @Test func namedSessionSocketPathResolvesOverRemoteHome() async throws {
        // The transport is given only a session name; it must resolve the
        // remote home directory over exec and find the socket at
        // ~/.config/herdr/sessions/<name>/herdr.sock. The fake server is
        // bound at exactly that spot in the real home directory (the
        // simulator shares the host filesystem, where home is /Users/<user>).
        let environment = try #require(LocalSSHTestEnvironment.current)
        let sessionName = "hm-e2e-\(UUID().uuidString.prefix(8))"
        let sessionDir = "/Users/\(environment.username)/.config/herdr/sessions/\(sessionName)"
        try FileManager.default.createDirectory(
            atPath: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sessionDir) }

        let server = try FakeHerdrServer(socketPath: sessionDir + "/herdr.sock") { request in
            switch request.method {
            case "ping":
                [#"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":16}}"#]
            default:
                [#"{"id":"\#(request.id)","result":{"type":"agent_list","agents":[]}}"#]
            }
        }
        defer { server.stop() }

        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(socket: .namedSession(sessionName)))
        do {
            // Two requests: the second reuses the cached home directory.
            _ = try await transport.ping()
            let agents = try await transport.listAgents()

            #expect(agents.isEmpty)
            #expect(server.receivedRequests.map(\.method) == ["ping", "agent.list"])
            #expect(server.connectionCount == 2)
        } catch {
            try? await transport.close()
            throw error
        }
        try await transport.close()
    }

    /// Boots a fake herdr server plus a real SSH connection to localhost and
    /// tears both down afterwards. The transport is handed to `body` as the
    /// concrete actor; assertions go through its public Transport surface.
    private func withTransport(
        script: @escaping FakeHerdrServer.Script,
        body: (SSHTransport, FakeHerdrServer) async throws -> Void
    ) async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let server = try FakeHerdrServer(script: script)
        let transport: SSHTransport
        do {
            transport = try await SSHTransport.connect(
                settings: environment.makeSettings(socket: .absolutePath(server.socketPath)))
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
