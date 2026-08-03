import Foundation
import Testing

@testable import Heeler

@Suite(
    "HeelerSSH Transport behavior e2e",
    .enabled(
        if: HeelerSSHTransportBehaviorEnvironment.current != nil,
        "requires the disposable direct and Jump Host fixtures"),
    .serialized)
struct HeelerSSHTransportBehaviorE2ETests {
    @Test("ordinary forwarding admission reserves the Events slot")
    func forwardingAdmissionStartsAtEight() {
        #expect(HeelerSSHTransport.maxConcurrentForwardingChannels == 8)
    }

    @Test("ordinary session admission reserves the Attach slot")
    func sessionAdmissionStartsAtEight() {
        #expect(HeelerSSHTransport.maxConcurrentExecChannels == 8)
    }

    @Test("protocol mismatches remain typed at the Transport seam")
    func protocolMismatchStaysTyped() {
        #expect(
            throws: TransportError.protocolVersionMismatch(server: 18, supported: 17)
        ) {
            _ = try HeelerSSHTransport.serverInfo(
                from: PongResponse(protocolVersion: 18, version: "future"))
        }
    }

    @Test("direct Host ordinary RPCs preserve the Transport seam")
    func directOrdinaryRPCs() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseOrdinaryRPCs(settings: environment.directSettings())
    }

    @Test("Jump Host ordinary RPCs preserve the same Transport seam")
    func jumpOrdinaryRPCs() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseOrdinaryRPCs(settings: environment.jumpSettings())
    }

    @Test("direct Host Events preserve framing, concurrency, and slot reuse")
    func directEventsStream() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseEventsStream(settings: environment.directSettings())
    }

    @Test("Jump Host Events preserve framing, concurrency, and slot reuse")
    func jumpEventsStream() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseEventsStream(settings: environment.jumpSettings())
    }

    @Test("direct Host Attach preserves PTY IO, resize, end, and reuse")
    func directAttach() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseAttach(
            settings: environment.directSettings(),
            socketPath: environment.socketPath)
    }

    @Test("Jump Host Attach preserves PTY IO, resize, end, and reuse")
    func jumpAttach() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseAttach(
            settings: environment.jumpSettings(),
            socketPath: environment.socketPath)
    }

    @Test("direct Host clean Attach exit frees the reserved channel")
    func directCleanAttachExit() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseCleanAttachExit(settings: environment.directSettings())
    }

    @Test("Jump Host clean Attach exit frees the reserved channel")
    func jumpCleanAttachExit() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseCleanAttachExit(settings: environment.jumpSettings())
    }

    @Test("one Host admits exactly one live Attach")
    func attachIsExclusive() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let first = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:pane", cols: 80, rows: 24))
        var iterator = first.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "TTY-OK")
        await #expect(throws: TransportError.terminalChannelAlreadyOpen) {
            _ = try await transport.attachTerminal(
                TerminalAttachRequest(target: "fixture:second", cols: 80, rows: 24))
        }

        await first.end()
        let replacement = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:replacement", cols: 80, rows: 24))
        await replacement.end()
    }

    @Test("nonzero Attach exit reports the primary channel failure and wakes input")
    func failedAttachExitFreesChannel() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let failed = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:failure", cols: 80, rows: 24))
        var iterator = failed.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "TTY-OK")
        failed.send(Data("__fail__\n".utf8))
        await #expect(
            throws: TransportError.channelFailed(
                detail: "attach channel: remote exit status 23")
        ) {
            while try await iterator.next() != nil {}
        }

        let replacement = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:replacement", cols: 80, rows: 24))
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    @Test("remote Events close is typed and frees only the reserved channel")
    func remoteEventsClosePreservesConnection() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let stream = try await transport.subscribeToEvents([
            .pane(.agentStatusChanged, paneID: "fixture:remote-close")
        ])
        var iterator = stream.events.makeAsyncIterator()
        #expect(try await iterator.next()?.data["pane_id"] == .string("fixture:remote-close"))
        await #expect(
            throws: TransportError.channelFailed(detail: "events channel closed by remote")
        ) {
            _ = try await iterator.next()
        }

        #expect(try await transport.ping().protocolVersion == 17)
        let replacement = try await transport.subscribeToEvents([.global(.paneCreated)])
        await replacement.end()
        #expect(await transport.isConnected)
    }

    @Test("rejected Events ack frees the reserved channel")
    func rejectedEventsAckPreservesConnection() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        await #expect(
            throws: HerdrAPIError(code: "fixture_rejected", message: "scripted rejection")
        ) {
            _ = try await transport.subscribeToEvents([
                .pane(.agentStatusChanged, paneID: "fixture:reject")
            ])
        }

        let replacement = try await transport.subscribeToEvents([.global(.paneCreated)])
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    @Test("missing Events ack times out and frees the reserved channel")
    func missingEventsAckPreservesConnection() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.requestTimeout = .milliseconds(100)
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(throws: TransportError.timedOut) {
            _ = try await transport.subscribeToEvents([
                .pane(.agentStatusChanged, paneID: "fixture:no-ack")
            ])
        }

        let replacement = try await transport.subscribeToEvents([.global(.paneCreated)])
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    @Test("Host exec discovery and home-relative sockets match on direct and Jump paths")
    func hostExecDiscoveryMatchesBothPaths() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseHostExecOperations(
            settings: environment.directSettings(socket: .defaultSession),
            homePath: environment.homePath)
        try await exerciseHostExecOperations(
            settings: environment.jumpSettings(socket: .namedSession("fixture")),
            homePath: environment.homePath)
    }

    @Test("concurrent first-use home probes share work and cache only success")
    func firstUseHomeProbeIsSingleFlight() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let probePath = environment.countFilePath + ".home-probe"
        var settings = environment.directSettings(socket: .defaultSession)
        settings.sessionListCommand = environment.removeFileThenSessionListCommand(probePath)
        settings.homeCommand = environment.countingHomeCommand(probePath)
        settings.agentDiscoveryCommand = environment.countAssertionCommand(
            probePath,
            expected: 1)
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        _ = try await transport.listSessions()

        try await withThrowingTaskGroup(of: ServerInfo.self) { group in
            for _ in 0..<12 {
                group.addTask { try await transport.ping() }
            }
            for try await info in group {
                #expect(info.protocolVersion == 17)
            }
        }
        #expect(try await transport.availableAgentKinds() == [.codex])
        _ = try await transport.ping()
        #expect(try await transport.availableAgentKinds() == [.codex])
    }

    @Test("failed first-use home probes retry instead of caching failure")
    func failedHomeProbeRetries() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let probePath = environment.countFilePath + ".home-retry"
        var settings = environment.directSettings(socket: .defaultSession)
        settings.sessionListCommand = environment.removeFileThenSessionListCommand(probePath)
        settings.homeCommand = environment.failOnceHomeCommand(probePath)
        settings.agentDiscoveryCommand = environment.countAssertionCommand(
            probePath,
            expected: 2)
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        _ = try await transport.listSessions()

        await #expect(throws: TransportError.self) { _ = try await transport.ping() }
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(try await transport.availableAgentKinds() == [.codex])
    }

    @Test("stale socket wake retries once and preserves both failure types")
    func staleSocketWakeIsBounded() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        var recovering = environment.directSettings(
            socket: .absolutePath(environment.staleSocketPath))
        recovering.sessionListCommand = environment.resetStaleSocketCommand(
            environment.staleSocketPath)
        recovering.wakeCommand = environment.linkWakeCommand
        let recovered = try await HeelerSSHTransport.connect(settings: recovering)
        _ = try await recovered.listSessions()
        #expect(try await recovered.ping().protocolVersion == 17)
        try await recovered.close()

        var failing = environment.directSettings(
            socket: .absolutePath(environment.wakeFailureStaleSocketPath))
        failing.sessionListCommand = environment.resetStaleSocketCommand(
            environment.wakeFailureStaleSocketPath)
        failing.wakeCommand = "false"
        let failed = try await HeelerSSHTransport.connect(settings: failing)
        _ = try await failed.listSessions()
        await #expect(
            throws: TransportError.serverNotRunning(
                path: environment.wakeFailureStaleSocketPath)
        ) {
            _ = try await failed.ping()
        }
        try await failed.close()

        var ineffective = environment.directSettings(
            socket: .absolutePath(environment.wakeFailureStaleSocketPath))
        ineffective.sessionListCommand = environment.resetStaleSocketCommand(
            environment.wakeFailureStaleSocketPath)
        ineffective.wakeCommand = "true"
        let unrecovered = try await HeelerSSHTransport.connect(settings: ineffective)
        _ = try await unrecovered.listSessions()
        await #expect(
            throws: TransportError.streamLocalOpenFailed(
                path: environment.wakeFailureStaleSocketPath)
        ) {
            _ = try await unrecovered.ping()
        }
        try await unrecovered.close()
    }

    @Test("a missing socket is distinguished without attempting wake")
    func missingSocketStaysTyped() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let missingPath = environment.socketPath + ".missing"
        var settings = environment.directSettings(socket: .absolutePath(missingPath))
        settings.wakeCommand = "touch /must-not-run-wake"
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(throws: TransportError.socketNotFound(path: missingPath)) {
            _ = try await transport.ping()
        }
        #expect(await transport.isConnected)
    }

    @Test("cancellation closes one RPC channel and preserves later reuse")
    func cancelledRequestPreservesReuse() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }
        let request = Task {
            try await transport.readPane(PaneReadParams(paneID: "hang", source: .recent))
        }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await request.value }
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(await transport.isConnected)
    }

    @Test("a timed out RPC closes its channel and preserves later reuse")
    func timedOutRequestPreservesReuse() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.requestTimeout = .milliseconds(100)
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(throws: TransportError.timedOut) {
            _ = try await transport.readPane(
                PaneReadParams(paneID: "hang", source: .recent))
        }
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(await transport.isConnected)
    }

    @Test("concurrent ordinary RPCs use one fresh channel each")
    func concurrentRPCsUseFreshChannels() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.sessionListCommand = environment.connectionCountCommand
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let before = try await connectionCount(from: transport)
        try await withThrowingTaskGroup(of: ServerInfo.self) { group in
            for _ in 0..<12 { group.addTask { try await transport.ping() } }
            for try await info in group { #expect(info.protocolVersion == 17) }
        }
        let after = try await connectionCount(from: transport)
        #expect(after - before == 12)
    }

    private func exerciseOrdinaryRPCs(settings: SSHTransportSettings) async throws {
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.ping() == ServerInfo(version: "fake", protocolVersion: 17))
        #expect(try await transport.listAgents().isEmpty)
        #expect(try await transport.sessionSnapshot().agents.isEmpty)
        #expect(
            try await transport.readPane(PaneReadParams(paneID: "pane-1", source: .recent)).text
                == "fixture output")
        try await transport.closePane(PaneTarget(paneID: "pane-1"))
        try await transport.renameAgent(AgentRenameParams(target: "pane-1", name: "fixture"))
        try await transport.renameWorkspace(
            WorkspaceRenameParams(label: "Fixture", workspaceID: "workspace-1"))
        #expect(
            try await transport.startAgent(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture",
                    workspaceID: "workspace-1"))
                .paneID == "pane-new")
        #expect(
            try await transport.startAgentInNewWorktree(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture-worktree",
                    workspaceID: "workspace-1"),
                worktree: WorktreeSpec(branch: "task/fixture", base: "main"))
                .workspaceID == "workspace-worktree")
        await #expect(
            throws: HerdrAPIError(
                code: "fixture_error",
                message: "scripted failure")
        ) {
            try await transport.renameAgent(
                AgentRenameParams(target: "api-error", name: "fixture"))
        }
    }

    private func exerciseEventsStream(settings: SSHTransportSettings) async throws {
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.ping().protocolVersion == 17)
        let stream = try await transport.subscribeToEvents([.global(.paneCreated)])
        await #expect(throws: TransportError.eventsChannelAlreadyOpen) {
            _ = try await transport.subscribeToEvents([.global(.paneCreated)])
        }

        try await withThrowingTaskGroup(of: ServerInfo.self) { group in
            for _ in 0..<HeelerSSHTransport.maxConcurrentForwardingChannels {
                group.addTask { try await transport.ping() }
            }
            for try await info in group {
                #expect(info.protocolVersion == 17)
            }
        }

        var iterator = stream.events.makeAsyncIterator()
        let unknown = try await iterator.next()
        #expect(unknown?.kind == HerdrEventKind(name: "future_herdr_event"))
        #expect(unknown?.data["value"] == .string("preserved"))

        let canonical = try await iterator.next()
        #expect(canonical?.kind == GlobalEventKind.paneCreated.kind)
        #expect(canonical?.data["pane_id"] == .string("fixture:event"))
        #expect(try await iterator.next() == canonical)

        await stream.end()
        let replacement = try await transport.subscribeToEvents([.global(.paneCreated)])
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    private func exerciseAttach(
        settings: SSHTransportSettings,
        socketPath: String
    ) async throws {
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let session = try await transport.attachTerminal(
            TerminalAttachRequest(
                target: "fixture:pane",
                takeover: true,
                cols: 80,
                rows: 24))
        var iterator = session.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "24 80")
        #expect(output.hasPrefix("TTY-OK"))
        #expect(output.contains("ARGS:fixture:pane --takeover"))
        #expect(output.contains("SOCKET:\(socketPath)"))
        #expect(!output.contains("HERDR_SOCKET_PATH"))
        #expect(!output.contains("heeler-attach"))

        session.send(Data("raw-\u{1B}[A\n".utf8))
        try await expectAttachOutput(
            &iterator,
            accumulated: &output,
            contains: "GOT:raw-\u{1B}[A")
        session.resize(cols: 109, rows: 47)
        session.send(Data("probe\n".utf8))
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "47 109")

        session.send(Data("__end_race__\n".utf8))
        try await expectAttachOutput(
            &iterator,
            accumulated: &output,
            contains: "END-RACE-READY")
        // The fixture writes another chunk after one second, then waits ten
        // seconds before a final chunk. Sleeping two seconds deliberately
        // leaves the first tail unread and the second scheduled after end.
        try await Task.sleep(for: .seconds(2))
        let started = ContinuousClock.now
        await session.end()
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(try await iterator.next() == nil)
        #expect(try await transport.ping().protocolVersion == 17)

        let replacement = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:replacement", cols: 80, rows: 24))
        await replacement.end()
    }

    private func exerciseCleanAttachExit(settings: SSHTransportSettings) async throws {
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let session = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:clean", cols: 80, rows: 24))
        var iterator = session.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "TTY-OK")
        session.send(Data("__exit__\n".utf8))
        while let chunk = try await iterator.next() {
            output += String(decoding: chunk, as: UTF8.self)
        }

        let replacement = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:replacement", cols: 80, rows: 24))
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    private func expectAttachOutput(
        _ iterator: inout AsyncThrowingStream<Data, any Error>.AsyncIterator,
        accumulated: inout String,
        contains marker: String
    ) async throws {
        while !accumulated.contains(marker) {
            let chunk = try #require(try await iterator.next())
            accumulated += String(decoding: chunk, as: UTF8.self)
        }
    }

    private func exerciseHostExecOperations(
        settings: SSHTransportSettings,
        homePath: String
    ) async throws {
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(try await transport.listSessions().map(\.name) == ["fixture"])
        #expect(try await transport.availableAgentKinds() == [.codex, .gemini])
        let skills = try await transport.listSkills(SkillListQuery(kind: .codex))
        let skill = try #require(skills.first { $0.name == "fixture" })
        #expect(skill.path == "\(homePath)/.codex/skills/fixture/SKILL.md")
        #expect(try await transport.readSkillFile(atPath: skill.path).contains("Fixture body."))
    }

    private func connectionCount(from transport: HeelerSSHTransport) async throws -> Int {
        let session = try #require(try await transport.listSessions().first)
        return try #require(Int(session.name.dropFirst("count-".count)))
    }
}

private struct HeelerSSHTransportBehaviorEnvironment: Decodable, Sendable {
    let host: String
    let port: UInt16
    let username: String
    let password: String
    let socketPath: String
    let staleSocketPath: String
    let wakeFailureStaleSocketPath: String
    let countFilePath: String
    let homePath: String
    let jumpPort: UInt16
    let targetHost: String
    let targetPort: UInt16

    static let current: HeelerSSHTransportBehaviorEnvironment? = {
        guard
            let directEncoded = ProcessInfo.processInfo.environment["HEELER_SSH_E2E_CONFIG"],
            let directData = Data(base64Encoded: directEncoded),
            let jumpEncoded = ProcessInfo.processInfo.environment["HEELER_SSH_JUMP_E2E_CONFIG"],
            let jumpData = Data(base64Encoded: jumpEncoded),
            let direct = try? JSONDecoder().decode(DirectFixture.self, from: directData),
            let jump = try? JSONDecoder().decode(JumpFixture.self, from: jumpData)
        else { return nil }
        return HeelerSSHTransportBehaviorEnvironment(
            host: direct.host,
            port: direct.port,
            username: direct.username,
            password: direct.password,
            socketPath: direct.socketPath,
            staleSocketPath: direct.staleSocketPath,
            wakeFailureStaleSocketPath: direct.wakeFailureStaleSocketPath,
            countFilePath: direct.countFilePath,
            homePath: direct.homePath,
            jumpPort: jump.jumpPort,
            targetHost: jump.targetHost,
            targetPort: jump.targetPort)
    }()

    func directSettings(
        socket: HerdrSocketLocation? = nil
    ) -> SSHTransportSettings {
        settings(
            host: host,
            port: port,
            credentials: .password(password),
            jump: nil,
            socket: socket)
    }

    func jumpSettings(
        socket: HerdrSocketLocation? = nil
    ) -> SSHTransportSettings {
        let credentials = SSHCredentials.password(password)
        return settings(
            host: targetHost,
            port: targetPort,
            credentials: credentials,
            jump: SSHJumpSettings(
                host: host,
                port: Int(jumpPort),
                username: username,
                credentials: credentials),
            socket: socket)
    }

    private func settings(
        host: String,
        port: UInt16,
        credentials: SSHCredentials,
        jump: SSHJumpSettings?,
        socket: HerdrSocketLocation?
    ) -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: host,
            port: Int(port),
            username: username,
            credentials: credentials,
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: socket ?? .absolutePath(socketPath),
            socatPath: "/must-not-run/socat",
            jump: jump)
        settings.sessionListCommand =
            "printf '%s\\n' '{\"sessions\":[{\"name\":\"fixture\","
            + "\"default\":true,\"running\":true}]}'"
        settings.agentDiscoveryCommand =
            "printf '__HEELER_AGENT_KIND__=codex\\n__HEELER_AGENT_KIND__=gemini\\n'"
        guard let quotedHome = RemoteShellPath.quotedAbsolute(homePath) else {
            return settings
        }
        settings.homeCommand =
            "/bin/sh -c 'printf \"__HEELER_HOME__=%s\\n\" \"$1\"' home \(quotedHome)"
        settings.attachCommand = "\(homePath)/.heeler-ci/fake-attach"
        return settings
    }

    var connectionCountCommand: String {
        let path = RemoteShellPath.quotedAbsolute(countFilePath) ?? "''"
        return "/bin/sh -c 'count=$(cat \"$1\"); "
            + "printf \"{\\\"sessions\\\":[{\\\"name\\\":\\\"count-%s\\\","
            + "\\\"default\\\":true,\\\"running\\\":true}]}\\n\" \"$count\"' count \(path)"
    }

    func removeFileThenSessionListCommand(_ path: String) -> String {
        let quoted = RemoteShellPath.quotedAbsolute(path) ?? "''"
        return "/bin/sh -c 'rm -f \"$1\"; printf \"{\\\"sessions\\\":[]}\\n\"' reset \(quoted)"
    }

    func countingHomeCommand(_ path: String) -> String {
        let quotedPath = RemoteShellPath.quotedAbsolute(path) ?? "''"
        let quotedHome = RemoteShellPath.quotedAbsolute(homePath) ?? "''"
        return "/bin/sh -c 'printf x >> \"$1\"; "
            + "printf \"__HEELER_HOME__=%s\\n\" \"$2\"' home \(quotedPath) \(quotedHome)"
    }

    func failOnceHomeCommand(_ path: String) -> String {
        let quotedPath = RemoteShellPath.quotedAbsolute(path) ?? "''"
        let quotedHome = RemoteShellPath.quotedAbsolute(homePath) ?? "''"
        return "/bin/sh -c 'count=$(wc -c < \"$1\" 2>/dev/null || printf 0); "
            + "printf x >> \"$1\"; if [ \"$count\" -eq 0 ]; then "
            + "printf \"__HEELER_HOME__=relative\\n\"; else "
            + "printf \"__HEELER_HOME__=%s\\n\" \"$2\"; fi' home \(quotedPath) \(quotedHome)"
    }

    func countAssertionCommand(_ path: String, expected: Int) -> String {
        let quoted = RemoteShellPath.quotedAbsolute(path) ?? "''"
        return "/bin/sh -c '[ \"$(wc -c < \"$1\")\" -eq \"$2\" ] && "
            + "printf \"__HEELER_AGENT_KIND__=codex\\n\"' count \(quoted) \(expected)"
    }

    func resetStaleSocketCommand(_ path: String) -> String {
        let quoted = RemoteShellPath.quotedAbsolute(path) ?? "''"
        return "/usr/bin/python3 -c 'import os,socket,sys; p=sys.argv[1]; "
            + "os.path.lexists(p) and os.unlink(p); s=socket.socket(socket.AF_UNIX); "
            + "s.bind(p); s.close()' \(quoted); "
            + "printf '%s\\n' '{\"sessions\":[]}'"
    }

    var linkWakeCommand: String {
        let active = RemoteShellPath.quotedAbsolute(socketPath) ?? "''"
        return "rm -f \"$HERDR_SOCKET_PATH\"; "
            + "ln -s \(active) \"$HERDR_SOCKET_PATH\""
    }

    private struct DirectFixture: Decodable {
        let host: String
        let port: UInt16
        let username: String
        let password: String
        let socketPath: String
        let staleSocketPath: String
        let wakeFailureStaleSocketPath: String
        let countFilePath: String
        let homePath: String
    }

    private struct JumpFixture: Decodable {
        let jumpPort: UInt16
        let targetHost: String
        let targetPort: UInt16
    }
}
