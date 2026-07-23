import Foundation
import Synchronization
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
                #"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":17,"capabilities":{"live_handoff":true,"future_capability":true}}}"#
            ]
        } body: { transport, server in
            let info = try await transport.ping()

            #expect(info == ServerInfo(version: "9.9.9-fake", protocolVersion: 17))
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

    @Test func sessionSnapshotRoundTrips() async throws {
        // The Console's snapshot source (#8): one call carries agents plus
        // the workspace context (labels, worktrees) that agent.list lacks.
        try await withTransport { request in
            [
                #"{"id":"\#(request.id)","result":{"type":"session_snapshot","snapshot":{"version":"9.9.9-fake","protocol":17,"workspaces":[{"workspace_id":"w1","number":1,"label":"Proj","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"unknown","worktree":{"repo_key":"/work/a/.git","repo_name":"Proj","repo_root":"/work/a","checkout_path":"/work/a","is_linked_worktree":false}}],"tabs":[],"panes":[],"layouts":[],"agents":[{"terminal_id":"term_a","agent":"claude","terminal_title":"⠐ Fix","terminal_title_stripped":"Fix","agent_status":"blocked","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"cwd":"/work/a","foreground_cwd":"/work/a","revision":3}]}}}"#
            ]
        } body: { transport, server in
            let snapshot = try await transport.sessionSnapshot()

            #expect(snapshot.agents.map(\.paneID) == ["w1:p1"])
            #expect(snapshot.agents.first?.agentStatus == .blocked)
            #expect(snapshot.workspaces.first?.label == "Proj")
            #expect(snapshot.workspaces.first?.worktree?.repoName == "Proj")
            #expect(server.receivedRequests.map(\.method) == ["session.snapshot"])
        }
    }

    @Test func paneReadSendsItsParamsAndRoundTrips() async throws {
        // The Console's last-output snippet source (#8). Wire shape verified
        // against live herdr 0.7.4: pane_id/source/lines/strip_ansi params,
        // pane_read result envelope.
        try await withTransport { request in
            [
                #"{"id":"\#(request.id)","result":{"type":"pane_read","read":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","source":"recent","format":"text","text":"› waiting for input\n","revision":4,"truncated":false}}}"#
            ]
        } body: { transport, server in
            let read = try await transport.readPane(
                PaneReadParams(paneID: "w1:p1", source: .recent, lines: 5, stripANSI: true))

            #expect(read.text == "› waiting for input\n")
            #expect(read.paneID == "w1:p1")
            let request = try #require(server.receivedRequests.first)
            #expect(request.method == "pane.read")
            #expect(
                request.params
                    == #"{"lines":5,"pane_id":"w1:p1","source":"recent","strip_ansi":true}"#)
        }
    }

    @Test func closePaneRoundTripsItsParams() async throws {
        // The destructive close action (#13, User Story 9): pane.close
        // carries the pane id and is answered with the bare `ok` envelope
        // (verified against herdr 0.7.4's schema).
        try await withTransport { request in
            [#"{"id":"\#(request.id)","result":{"type":"ok"}}"#]
        } body: { transport, server in
            try await transport.closePane(PaneTarget(paneID: "w1:p1"))

            let request = try #require(server.receivedRequests.first)
            #expect(request.method == "pane.close")
            #expect(request.params == #"{"pane_id":"w1:p1"}"#)
        }
    }

    @Test func agentStartSendsItsParamsAndMapsTheStartedAgent() async throws {
        // Protocol 17 splits the new-agent flow into topology creation and a
        // pane-targeted start. Both requests stay behind the Transport seam.
        try await withTransport { request in
            switch request.method {
            case "tab.create":
                return [
                    #"{"id":"\#(request.id)","result":{"type":"tab_created","tab":{"tab_id":"w1:t9","workspace_id":"w1","number":9,"label":"9","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"w1:p9","terminal_id":"term_new","workspace_id":"w1","tab_id":"w1:t9","focused":false,"agent_status":"unknown","revision":0}}}"#
                ]
            case "agent.start":
                return [
                    #"{"id":"\#(request.id)","result":{"type":"agent_started","argv":["claude","--continue"],"agent":{"terminal_id":"term_new","agent":"claude","terminal_title":"⠐ claude","terminal_title_stripped":"claude","agent_status":"working","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p9","focused":true,"cwd":"/work/a","foreground_cwd":"/work/a","revision":1}}}"#
                ]
            default:
                Issue.record("Unexpected request: \(request.method)")
                return []
            }
        } body: { transport, server in
            let agent = try await transport.startAgent(
                AgentLaunchRequest(
                    kind: "claude", name: "reviewer", arguments: ["--continue"],
                    workspaceID: "w1"))

            #expect(agent.paneID == "w1:p9")
            #expect(agent.kind == "claude")
            #expect(agent.status == .working)
            #expect(server.receivedRequests.map(\.method) == ["tab.create", "agent.start"])
            let create = try #require(server.receivedRequests.first)
            #expect(create.params == #"{"focus":false,"workspace_id":"w1"}"#)
            let start = try #require(server.receivedRequests.last)
            #expect(
                start.params
                    == #"{"args":["--continue"],"kind":"claude","name":"reviewer","pane_id":"w1:p9"}"#
            )
        }
    }

    @Test func agentStartFailureClosesTheFreshPaneAndPreservesTheError() async throws {
        try await withTransport { request in
            switch request.method {
            case "tab.create":
                return [
                    #"{"id":"\#(request.id)","result":{"type":"tab_created","tab":{"tab_id":"w1:t9","workspace_id":"w1","number":9,"label":"9","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"w1:p9","terminal_id":"term_new","workspace_id":"w1","tab_id":"w1:t9","focused":false,"agent_status":"unknown","revision":0}}}"#
                ]
            case "agent.start":
                return [
                    #"{"id":"\#(request.id)","error":{"code":"unsupported_agent","message":"unsupported agent kind"}}"#
                ]
            case "pane.close":
                return [#"{"id":"\#(request.id)","result":{"type":"ok"}}"#]
            default:
                Issue.record("Unexpected request: \(request.method)")
                return []
            }
        } body: { transport, server in
            await #expect(
                throws: HerdrAPIError(
                    code: "unsupported_agent", message: "unsupported agent kind")
            ) {
                try await transport.startAgent(
                    AgentLaunchRequest(kind: "unsupported", name: "unsupported"))
            }

            #expect(
                server.receivedRequests.map(\.method)
                    == ["tab.create", "agent.start", "pane.close"])
            #expect(server.receivedRequests.last?.params == #"{"pane_id":"w1:p9"}"#)
        }
    }

    @Test func agentStartRetriesWhileTheFreshPanesShellBoots() async throws {
        // herdr 0.7.5 rejects agent.start with agent_pane_busy until the new
        // pane's shell reaches its interactive prompt (a few seconds on some
        // hosts). The transport retries the start briefly instead of
        // surfacing the boot race to the user.
        let busyReplies = Mutex(2)
        try await withTransport { request in
            switch request.method {
            case "tab.create":
                return [
                    #"{"id":"\#(request.id)","result":{"type":"tab_created","tab":{"tab_id":"w1:t9","workspace_id":"w1","number":9,"label":"9","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"w1:p9","terminal_id":"term_new","workspace_id":"w1","tab_id":"w1:t9","focused":false,"agent_status":"unknown","revision":0}}}"#
                ]
            case "agent.start":
                let stillBooting = busyReplies.withLock { remaining in
                    guard remaining > 0 else { return false }
                    remaining -= 1
                    return true
                }
                if stillBooting {
                    return [
                        #"{"id":"\#(request.id)","error":{"code":"agent_pane_busy","message":"agent target pane w1:p9 is not an available shell"}}"#
                    ]
                }
                return [
                    #"{"id":"\#(request.id)","result":{"type":"agent_started","argv":["claude"],"agent":{"terminal_id":"term_new","agent":"claude","terminal_title":"⠐ claude","terminal_title_stripped":"claude","agent_status":"working","workspace_id":"w1","tab_id":"w1:t9","pane_id":"w1:p9","focused":false,"cwd":"/work/a","foreground_cwd":"/work/a","revision":1}}}"#
                ]
            default:
                Issue.record("Unexpected request: \(request.method)")
                return []
            }
        } body: { transport, server in
            let agent = try await transport.startAgent(
                AgentLaunchRequest(kind: "claude", name: "reviewer", workspaceID: "w1"))

            #expect(agent.paneID == "w1:p9")
            #expect(agent.status == .working)
            // Two boot rejections, then success — and the fresh pane must
            // never have been torn down along the way.
            #expect(
                server.receivedRequests.map(\.method)
                    == ["tab.create", "agent.start", "agent.start", "agent.start"])
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
                [#"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":17}}"#]
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

    @Test func sessionDiscoveryDecodesTheOfficialCLIJSON() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-session-list-\(UUID().uuidString).sh")
        let script = """
            #!/bin/sh
            [ "$LC_ALL" = C ] || exit 2
            printf '%s' '{"sessions":[{"name":"default","default":true,"running":false},{"name":"work","default":false,"running":true}]}'
            """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        var settings = environment.makeSettings(
            socket: .absolutePath("/tmp/herdr-irrelevant.sock"))
        settings.sessionListCommand = scriptURL.path
        let transport = try await SSHTransport.connect(settings: settings)
        do {
            let sessions = try await transport.listSessions()

            #expect(
                sessions == [
                    HerdrSession(name: "default", isDefault: true, isRunning: false),
                    HerdrSession(name: "work", isDefault: false, isRunning: true),
                ])
        } catch {
            try? await transport.close()
            throw error
        }
        try await transport.close()
    }

    @Test func sessionDiscoveryRejectsNamesOutsideHerdrsGrammar() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-session-list-\(UUID().uuidString).sh")
        let script = """
            #!/bin/sh
            printf '%s' '{"sessions":[{"name":"work; false","default":false,"running":true}]}'
            """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        var settings = environment.makeSettings(
            socket: .absolutePath("/tmp/herdr-irrelevant.sock"))
        settings.sessionListCommand = scriptURL.path
        let transport = try await SSHTransport.connect(settings: settings)
        await #expect(throws: TransportError.self) {
            _ = try await transport.listSessions()
        }
        try await transport.close()
    }

    @Test func socketAndSocatPathsWithSpacesRoundTripSafely() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let directory = URL(
            fileURLWithPath: "/tmp/hm paths \(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("herdr socket.sock").path
        let socatPath = directory.appendingPathComponent("socat binary").path
        try FileManager.default.createSymbolicLink(
            atPath: socatPath, withDestinationPath: environment.socatPath)
        let server = try FakeHerdrServer(socketPath: socketPath) { request in
            [#"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":17}}"#]
        }
        defer { server.stop() }
        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .absolutePath(socketPath), socatPath: socatPath))
        do {
            let info = try await transport.ping()

            #expect(info.protocolVersion == SSHTransport.supportedProtocolVersion)
            #expect(server.receivedRequests.map(\.method) == ["ping"])
        } catch {
            try? await transport.close()
            throw error
        }
        try await transport.close()
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
                [#"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":17}}"#]
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

    @Test func homeResolutionIgnoresLoginShellStdoutNoise() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let home = "/tmp/hm home \(UUID().uuidString.prefix(8))"
        let sessionName = "work"
        let sessionDirectory = "\(home)/.config/herdr/sessions/\(sessionName)"
        try FileManager.default.createDirectory(
            atPath: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = try FakeHerdrServer(socketPath: "\(sessionDirectory)/herdr.sock") { request in
            [#"{"id":"\#(request.id)","result":{"type":"pong","version":"9.9.9-fake","protocol":17}}"#]
        }
        defer { server.stop() }
        let homeCommand =
            "printf 'login banner\\n__HERDR_MOBILE_HOME__=%s\\nlast login\\n' '\(home)'"
        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .namedSession(sessionName), homeCommand: homeCommand))

        let info = try await transport.ping()

        #expect(info.protocolVersion == SSHTransport.supportedProtocolVersion)
        try await transport.close()
    }

    @Test func firstHomeRelativeRequestUsesOneTotalDeadline() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let home = "/tmp/hm-deadline-\(UUID().uuidString.prefix(8))"
        let sessionName = "work"
        let sessionDirectory = "\(home)/.config/herdr/sessions/\(sessionName)"
        try FileManager.default.createDirectory(
            atPath: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = try FakeHerdrServer(socketPath: "\(sessionDirectory)/herdr.sock") { _ in nil }
        defer { server.stop() }
        let homeCommand =
            "sleep 0.6; printf '__HERDR_MOBILE_HOME__=%s\\n' '\(home)'"
        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .namedSession(sessionName), requestTimeout: .seconds(1),
                homeCommand: homeCommand))
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: TransportError.timedOut) {
            try await transport.ping()
        }

        let elapsed = started.duration(to: clock.now)
        #expect(elapsed < .milliseconds(1_400))
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
