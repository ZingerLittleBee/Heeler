import CryptoKit
import Foundation
import Testing

@testable import Heeler

@Suite(
    "HeelerSSH Transport behavior e2e",
    .enabled(
        if: RealSSHFixture.gate(HeelerSSHTransportBehaviorEnvironment.current != nil),
        "requires the disposable direct and Jump Host fixtures"),
    .serialized)
struct HeelerSSHTransportBehaviorE2ETests {
    /// Both directions of the floor, because a fix tested in one direction is
    /// untested in the direction that broke. This test replaces one that
    /// asserted protocol 18 was *refused*: that encoded the equality rule
    /// #140 removed, and a server above the generated version is now usable.
    @Test("the protocol floor admits newer servers and refuses older ones")
    func protocolFloorAdmitsNewerAndRefusesOlder() throws {
        // Below the floor: refused, because methods this app calls may be absent.
        #expect(
            throws: TransportError.protocolVersionMismatch(server: 16, supported: 17)
        ) {
            _ = try HeelerSSHTransport.serverInfo(
                from: PongResponse(protocolVersion: 16, version: "ancient"))
        }

        // At the floor and at the generated version: usable, no notice.
        for version in [
            HeelerSSHTransport.minimumProtocolVersion,
            HeelerSSHTransport.generatedProtocolVersion,
        ] {
            let info = try HeelerSSHTransport.serverInfo(
                from: PongResponse(protocolVersion: version, version: "known"))
            #expect(info.protocolVersion == version)
            #expect(!info.exceedsGeneratedProtocol)
        }

        // Above the generated version: still usable — this is the case that
        // made the user's 0.8.0 Host unusable — and it carries the notice.
        let newer = try HeelerSSHTransport.serverInfo(
            from: PongResponse(
                protocolVersion: HeelerSSHTransport.generatedProtocolVersion + 1,
                version: "future"))
        #expect(newer.exceedsGeneratedProtocol)
        #expect(newer.version == "future")
    }

    /// The exact reply the user's live herdr 0.8.0 returns, captured from
    /// `~/.config/herdr/herdr.sock`. Pins the regression itself rather than a
    /// synthetic version number.
    @Test("the live herdr 0.8.0 pong connects rather than being refused")
    func liveZeroEightZeroPongIsAccepted() throws {
        let pong = try JSONDecoder().decode(
            PongResponse.self,
            from: Data(
                #"""
                {"type":"pong","version":"0.8.0","protocol":19,
                 "capabilities":{"live_handoff":true,"detached_server_daemon":true}}
                """#.utf8))
        let info = try HeelerSSHTransport.serverInfo(from: pong)

        #expect(info.version == "0.8.0")
        #expect(info.protocolVersion == 19)
        #expect(!info.exceedsGeneratedProtocol)
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

    /// The ADR 0011 Host contract in one test: SSH access plus a running herdr.
    /// Nothing here is injected — the catalog Host maps straight onto production
    /// settings, so the connection resolves the default-session socket over the
    /// real home probe and reaches herdr with no Host-side helper in the path.
    @Test("the production connector reaches a direct Host")
    func productionConnectorReachesADirectHost() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseProductionConnector(host: environment.directHost())
    }

    @Test("the production connector reaches a Jump Host target")
    func productionConnectorReachesAJumpHostTarget() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseProductionConnector(host: environment.jumpHost())
    }

    @Test("direct Host notification files preserve atomic SFTP behavior")
    func directNotificationFiles() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseNotificationFiles(
            settings: environment.directSettings(),
            homePath: environment.homePath)
    }

    @Test("direct Host files list, read, and atomically replace over SFTP")
    func directRemoteFiles() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let directory = "\(environment.homePath)/.heeler-ci"
        let filename = "files-\(UUID().uuidString.lowercased()).txt"
        let path = "\(directory)/\(filename)"
        let first = Data("first revision".utf8)
        let replacement = Data("replacement revision".utf8)
        let transport = try await HeelerSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        _ = try await transport.writeFile(at: path, data: first)
        let written = try await transport.writeFile(at: path, data: replacement)
        #expect(written.name == filename)
        #expect(written.path == path)
        #expect(written.kind == .file)
        #expect(written.sizeBytes == UInt64(replacement.count))
        #expect(written.modified != nil)

        let listing = try await transport.listDirectory(at: directory)
        let listed = try #require(listing.first { $0.path == path })
        #expect(listed.kind == .file)
        #expect(listed.sizeBytes == UInt64(replacement.count))
        #expect(listed.modified != nil)
        #expect(!listing.contains {
            $0.name.hasPrefix(".\(filename).heeler-") && $0.name.hasSuffix(".part")
        })

        let snapshot = try await transport.readFile(at: path, byteLimit: 2 * 1_024 * 1_024)
        #expect(snapshot.path == path)
        #expect(snapshot.data == replacement)
        #expect(snapshot.sizeBytes == UInt64(replacement.count))
        #expect(snapshot.modified != nil)
        #expect(try await transport.statFile(at: path) == listed)
    }

    @Test("Jump Host notification files preserve atomic SFTP behavior")
    func jumpNotificationFiles() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseNotificationFiles(
            settings: environment.jumpSettings(),
            homePath: environment.homePath)
    }

    /// "Not installed" is a recoverable instruction to the user; anything else
    /// is a Host problem. Collapsing the two would tell someone to install a
    /// plugin that is already there, so every way the probe can fail stays
    /// distinct from absence.
    @Test("a disabled or unprobeable notification plugin stays distinguishable")
    func notificationPluginProbeFailuresStayTyped() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)

        // Installed but switched off: herdr will not run it, so it counts as
        // not installed rather than as a broken Host.
        var disabled = environment.directSettings()
        disabled.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
            + "{\"plugin_id\":\"heeler\",\"enabled\":false}]}}'"
        #expect(
            try await notificationRegistrationFailure(settings: disabled)
                == .pluginNotInstalled)

        // herdr missing from the Host's PATH: the probe exits nonzero.
        var missingBinary = environment.directSettings()
        missingBinary.pluginListCommand = "/nonexistent/herdr plugin list --json"
        try await expectPluginProbeFailure(
            settings: missingBinary, "a Host without herdr on PATH")

        // The probe runs and succeeds but answers with something that is not
        // a plugin list.
        var unparseable = environment.directSettings()
        unparseable.pluginListCommand = "printf '%s' 'herdr: not json'"
        try await expectPluginProbeFailure(
            settings: unparseable, "an unparseable plugin list")

        // The plugin resolves, but the config-directory probe answers without
        // its marker, so there is no directory to trust.
        var unmarkedDirectory = environment.directSettings()
        unmarkedDirectory.pluginListCommand = Self.installedPluginListCommand
        unmarkedDirectory.notificationConfigDirCommand = "printf 'no marker here\\n'"
        try await expectPluginProbeFailure(
            settings: unmarkedDirectory, "a config directory probe without its marker")
    }

    /// A Host still running the plugin under an earlier id keeps accepting
    /// Notification Registration: the matched id is substituted into the
    /// config-dir probe, so the file lands in the directory that plugin
    /// actually reads — and the current id wins when both are installed.
    @Test("a legacy plugin id routes registration into that plugin's config dir")
    func legacyNotificationPluginIDKeepsRegistrationWorking() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let baseDirectory =
            "\(environment.homePath)/.heeler-ci/notify-legacy-\(UUID().uuidString.lowercased())"
        let tokenConfigDirCommand =
            "/bin/sh -c 'umask 077; mkdir -p \"$1\" || exit 1; "
            + "printf \"__HEELER_PLUGIN_CONFIG_DIR__=%s\\n\" \"$1\"' notify "
            + (try #require(RemoteShellPath.quotedAbsolute(
                "\(baseDirectory)/\(SSHTransportSettings.notificationPluginIDToken)")))
        let registration = Data(#"{"v":1,"devices":[]}"#.utf8)

        var legacyOnly = environment.directSettings()
        legacyOnly.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
            + "{\"plugin_id\":\"herdr-mobile.pairing\",\"enabled\":true}]}}'"
        legacyOnly.notificationConfigDirCommand = tokenConfigDirCommand
        let legacyTransport = try await HeelerSSHTransport.connect(settings: legacyOnly)
        try await legacyTransport.replaceNotificationRegistration(registration)
        #expect(
            try await legacyTransport.readRemoteFileForTesting(
                at: "\(baseDirectory)/herdr-mobile.pairing/notifications.json")
                == registration)
        try await legacyTransport.close()

        // Legacy listed first must not outrank the current id.
        var bothInstalled = environment.directSettings()
        bothInstalled.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
            + "{\"plugin_id\":\"herdr-mobile.pairing\",\"enabled\":true},"
            + "{\"plugin_id\":\"heeler\",\"enabled\":true}]}}'"
        bothInstalled.notificationConfigDirCommand = tokenConfigDirCommand
        let preferredTransport = try await HeelerSSHTransport.connect(settings: bothInstalled)
        try await preferredTransport.replaceNotificationRegistration(registration)
        #expect(
            try await preferredTransport.readRemoteFileForTesting(
                at: "\(baseDirectory)/heeler/notifications.json")
                == registration)
        try await preferredTransport.close()
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
        // Fixture never ACKs, so the first assertion stays deterministic at any
        // finite budget. 100ms was a scheduling assertion under load (#145): the
        // same timeout also bounds the replacement subscribe and ping that prove
        // the channel was freed.
        settings.requestTimeout = .seconds(1)
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

    /// Three wake outcomes, one bound: a wake that works recovers the request,
    /// and a wake that fails or changes nothing both surface the combined
    /// cause. The two failing cases are kept apart deliberately — they exercise
    /// different arms even though neither may narrow the classification the
    /// socket handed us.
    @Test("stale socket wake retries once and never narrows the failure")
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
            throws: TransportError.streamLocalOpenFailed(
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

    /// The wake starts but never exits, as a wedged Host leaves it. The
    /// request must surface `.timedOut` at its own deadline rather than hang
    /// on the wake — and must not launder the timeout into the socket
    /// classification, which would hide the deadline the Host never met.
    @Test("a hung wake command surfaces the timeout rather than a stopped server")
    func hungWakeSurfacesTimedOut() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let socketPath = environment.wakeFailureStaleSocketPath
        var resetting = environment.directSettings(socket: .absolutePath(socketPath))
        resetting.sessionListCommand = environment.resetStaleSocketCommand(socketPath)
        let reset = try await HeelerSSHTransport.connect(settings: resetting)
        _ = try await reset.listSessions()
        try await reset.close()

        var settings = environment.directSettings(socket: .absolutePath(socketPath))
        settings.wakeCommand = "sleep 600"
        settings.requestTimeout = .seconds(2)
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let started = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) { _ = try await transport.ping() }
        #expect(started.duration(to: .now) < .seconds(30))
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
        var observerSettings = environment.directSettings()
        observerSettings.requestTimeout = .seconds(25)
        let observer = try await HeelerSSHTransport.connect(settings: observerSettings)
        defer { Task { try? await observer.close() } }

        let hangToken = UUID().uuidString
        let request = Task {
            try await transport.readPane(
                PaneReadParams(paneID: "fixture:hang:\(hangToken)", source: .recent))
        }
        defer { request.cancel() }
        let observation = try await observer.readPane(
            PaneReadParams(paneID: "fixture:await-hang:\(hangToken)", source: .recent))
        try #require(observation.text == "observed")
        request.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await request.value }
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(await transport.isConnected)
    }

    @Test("a timed out RPC closes its channel and preserves later reuse")
    func timedOutRequestPreservesReuse() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        // Hang fixture never answers, so the first assertion stays deterministic
        // at any finite budget. 100ms was a scheduling assertion under load
        // (#145): the same timeout also bounds the post-timeout ping that proves
        // the channel was freed for reuse.
        settings.requestTimeout = .seconds(1)
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

    /// CLAUDE.md's load-bearing herdr 0.7.5 fact: `agent.start` on a pane whose
    /// shell has not reached its prompt is refused with `agent_pane_busy`, and
    /// the Transport waits the shell out rather than surfacing it. herdr 0.8.0
    /// answers asynchronously instead, so nothing live exercises this any more
    /// — only the fixture can hold the older server's behavior still.
    @Test("agent start waits out a fresh pane's booting shell")
    func agentStartRetriesWhileTheFreshPaneShellBoots() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("busy2")
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "codex",
                name: "fixture",
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))

        #expect(agent.paneID == "pane:\(token)")
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded.filter { $0.hasPrefix("agent.start ") }.count == 3)
        #expect(!recorded.contains { $0.hasPrefix("pane.close ") })
    }

    /// The other end of the same retry: a pane that never becomes an available
    /// shell must surface herdr's refusal rather than retry forever, and the
    /// wait before it does so must be long enough to cover a real shell's boot.
    @Test("a shell that never boots exhausts the retry budget and surfaces herdr's refusal")
    func agentStartStopsRetryingWhenTheShellNeverBoots() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("busyforever")
        let started = ContinuousClock.now
        await #expect(
            throws: HerdrAPIError(
                code: "agent_pane_busy",
                message: "pane is not an available shell")
        ) {
            _ = try await transport.startAgent(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture",
                    workspaceID: "workspace-1",
                    cwd: "/fixture/\(token)"))
        }
        // A band, not a point: the budget is private to the Transport. The
        // lower bound is load-safe because the wait is a deadline rather than
        // work — a slow machine cannot finish it early. The upper bound stays
        // generous because load pushes only that way.
        let elapsed = started.duration(to: .now)
        #expect(elapsed > .seconds(8))
        #expect(elapsed < .seconds(30))

        let attempts = try await Self.recordedRequests(from: transport, token: token)
            .filter { $0.hasPrefix("agent.start ") }
            .count
        #expect(attempts >= 10)
    }

    /// The tab is created before the agent, so a refused launch would otherwise
    /// strand an empty pane on the Host. Only the failing launch may clean it
    /// up — nothing later knows the pane was ever meant to hold an agent.
    @Test("a refused agent start closes the pane it created")
    func refusedAgentStartClosesTheFreshPane() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("startfails")
        await #expect(throws: Self.refusedStart) {
            _ = try await transport.startAgent(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture",
                    workspaceID: "workspace-1",
                    cwd: "/fixture/\(token)"))
        }

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        try #require(recorded.count == 3)
        #expect(recorded[0].hasPrefix("tab.create "))
        #expect(recorded[1].hasPrefix("agent.start "))
        #expect(recorded[2] == #"pane.close {"pane_id":"pane:\#(token)"}"#)
    }

    /// The worktree half of the same compensation, and the only caller of
    /// `removeWorktree`. A refused launch here would otherwise leave a checkout
    /// and a workspace behind, which is worse than a stranded pane.
    @Test("a refused worktree agent start removes the worktree it created")
    func refusedWorktreeAgentStartRemovesTheWorktree() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("startfails")
        await #expect(throws: Self.refusedStart) {
            _ = try await transport.startAgentInNewWorktree(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture",
                    workspaceID: "workspace-1"),
                worktree: WorktreeSpec(branch: "task/\(token)", base: "main"))
        }

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        try #require(recorded.count == 3)
        #expect(recorded[0].hasPrefix("worktree.create "))
        #expect(recorded[1].hasPrefix("agent.start "))
        #expect(recorded[2] == #"worktree.remove {"workspace_id":"workspace:\#(token)"}"#)
    }

    /// A launch started from another agent's screen carries that agent's
    /// directory. Dropping the cwd is invisible in the reply — herdr answers
    /// with a healthy tab either way — so only the request proves it went.
    @Test("agent start places the fresh tab in the requested directory")
    func agentStartPlacesTheFreshTabInTheRequestedDirectory() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("ok")
        _ = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "codex",
                name: "fixture",
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded.first
                == #"tab.create {"cwd":"/fixture/\#(token)","focus":false,"workspace_id":"workspace-1"}"#
        )
    }

    /// A named session becomes a directory component of the remote socket path,
    /// so discovery output is not trusted to stay inside herdr's grammar. One
    /// bad name fails the whole list rather than being dropped from it: a
    /// partial list would silently hide a session the Host really has.
    @Test("session discovery refuses a name outside herdr's grammar")
    func sessionDiscoveryRefusesNamesOutsideTheGrammar() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.sessionListCommand =
            "printf '%s\\n' '{\"sessions\":["
            + "{\"name\":\"fixture\",\"default\":true,\"running\":true},"
            + "{\"name\":\"../escape\",\"default\":false,\"running\":false}]}'"
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(
            throws: TransportError.malformedResponse(
                "herdr session list returned an invalid session name")
        ) {
            _ = try await transport.listSessions()
        }
    }

    /// The probe runs through the Host's login shell, so its stdout carries
    /// whatever that shell prints. Only marker-prefixed lines count, only kinds
    /// this build knows survive, and the answer is a stable ordered set — a
    /// banner that merely says "gemini" must not install an agent.
    @Test("agent discovery ignores login noise, unknown kinds, and duplicates")
    func agentDiscoveryIgnoresLoginNoiseUnknownKindsAndDuplicates() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.agentDiscoveryCommand =
            "printf '%s\\n' 'Welcome to the Host' 'gemini' "
            + "'__HEELER_AGENT_KIND__=codex' "
            + "'__HEELER_AGENT_KIND__=notarealagent' "
            + "'__HEELER_AGENT_KIND__=codex' "
            + "'__HEELER_AGENT_KIND__=claude' "
            + "'last login: never'"
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.availableAgentKinds() == [.claude, .codex])
    }

    /// The home probe also runs through the login shell, and its answer becomes
    /// a directory component of the socket path every later request opens. A
    /// banner, a trailing login line, and a stale marker printed by a sourced
    /// profile must all leave the resolved home exact — the last marker wins.
    @Test("home resolution ignores login-shell stdout around its marker")
    func homeResolutionIgnoresLoginShellNoise() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let quotedHome = try #require(RemoteShellPath.quotedAbsolute(environment.homePath))
        var settings = environment.directSettings(socket: .defaultSession)
        settings.homeCommand =
            "/bin/sh -c 'printf \"Welcome to the Host\\n"
            + "__HEELER_HOME__=/wrong/home\\n"
            + "__HEELER_HOME__=%s\\n"
            + "last login: never\\n\" \"$1\"' home \(quotedHome)"
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        // The home-relative socket only resolves onto the fixture if both the
        // banner and the stale earlier marker were discarded.
        #expect(try await transport.ping().protocolVersion == 17)
        let skills = try await transport.listSkills(SkillListQuery(kind: .codex))
        let skill = try #require(skills.first { $0.name == "fixture" })
        #expect(skill.path == "\(environment.homePath)/.codex/skills/fixture/SKILL.md")
    }

    /// The first request against a home-relative socket pays for the home probe
    /// as well as the exchange. Both must come out of one budget: giving each
    /// its own would let a Host that is slow in both halves overrun the deadline
    /// the caller was promised, silently, and only on the first request.
    @Test("the first home-relative request spends one deadline, not two")
    func firstHomeRelativeRequestSpendsOneTotalDeadline() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let quotedHome = try #require(RemoteShellPath.quotedAbsolute(environment.homePath))
        var settings = environment.directSettings(socket: .defaultSession)
        settings.requestTimeout = .seconds(4)
        // Three quarters of the budget spent resolving the home, then a pane
        // read the fixture never answers. One deadline expires at four seconds;
        // two stacked budgets would run to seven.
        settings.homeCommand =
            "/bin/sh -c 'sleep 3; printf \"__HEELER_HOME__=%s\\n\" \"$1\"' home \(quotedHome)"
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let started = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) {
            _ = try await transport.readPane(
                PaneReadParams(paneID: "hang", source: .recent))
        }
        // Bounded on both sides: overrunning is the stacked-budget bug, and
        // expiring early would mean the probe never came out of this budget.
        let elapsed = started.duration(to: .now)
        #expect(elapsed > .seconds(3))
        #expect(elapsed < .seconds(5.5))
    }

    /// A custom Agent name is a write against real Host state, so the response
    /// alone is not evidence that the requested value reached herdr. Record the
    /// request at the Unix-socket fixture boundary and pin the exact JSON params.
    @Test("agent rename sends its custom name and target exactly")
    func agentRenameSendsItsCustomNameAndTargetExactly() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        try await transport.renameAgent(AgentRenameParams(target: token, name: "reviewer"))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded == [#"agent.rename {"name":"reviewer","target":"\#(token)"}"#])
    }

    /// Omission clears a custom name in herdr 0.7.5. JSON null is not the wire
    /// contract: this assertion distinguishes an absent key from a present null.
    @Test("agent rename omits name when clearing a custom name")
    func agentRenameOmitsNameWhenClearingACustomName() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        try await transport.renameAgent(AgentRenameParams(target: token))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded == [#"agent.rename {"target":"\#(token)"}"#])
    }

    /// Workspace labels accept a wider grammar than Agent names. Pin both the
    /// label and snake-cased workspace id at the real Transport boundary.
    @Test("workspace rename sends its label and workspace id exactly")
    func workspaceRenameSendsItsLabelAndWorkspaceIDExactly() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        try await transport.renameWorkspace(
            WorkspaceRenameParams(label: "Review workspace", workspaceID: token))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded
                == [
                    #"workspace.rename {"label":"Review workspace","workspace_id":"\#(token)"}"#
                ])
    }

    /// `pane.read` has no cursor and the options choose what herdr samples.
    /// Assert both directions: exact params into herdr, typed result back out.
    @Test("pane read sends exact params and round trips the result")
    func paneReadSendsExactParamsAndRoundTripsTheResult() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        let read = try await transport.readPane(
            PaneReadParams(
                paneID: token,
                source: .recentUnwrapped,
                format: .ansi,
                lines: 5,
                stripANSI: false))

        #expect(read.paneID == token)
        #expect(read.source == .recentUnwrapped)
        #expect(read.format == .ansi)
        #expect(read.text == "fixture output")
        #expect(read.revision == 1)
        #expect(!read.truncated)
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded
                == [
                    #"pane.read {"format":"ansi","lines":5,"pane_id":"\#(token)","source":"recent_unwrapped","strip_ansi":false}"#
                ])
    }

    /// A syntactically valid herdr error envelope is not a channel failure.
    /// Numeric codes normalize to strings in the Transport's domain error.
    @Test("a herdr error envelope surfaces as a typed API rejection")
    func herdrErrorEnvelopeSurfacesAsATypedAPIRejection() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        await #expect(throws: HerdrAPIError(code: "500", message: "scripted failure")) {
            try await transport.renameAgent(
                AgentRenameParams(target: "api-error", name: "reviewer"))
        }
    }

    /// The session boundary converts the Transport's typed herdr rejection to
    /// the public failure taxonomy that drives reconnect and user guidance.
    @Test("the session maps a herdr rejection to apiRejected")
    func eventsSessionMapsAHerdrRejectionToAPIRejected() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let settings = environment.directSettings()
        let session = EventsSession(
            subscriptions: [.pane(.agentStatusChanged, paneID: "fixture:reject")],
            connect: { try await HeelerSSHTransport.connect(settings: settings) },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(30), multiplier: 1, maxDelay: .seconds(30)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        let update = try #require(await updates.next())
        guard case .status(
            .reconnecting(
                attempt: 1,
                delay: .seconds(30),
                failure: .apiRejected(
                    code: "fixture_rejected",
                    message: "scripted rejection"))) = update
        else {
            Issue.record("Expected apiRejected reconnect status, got \(update)")
            await session.end()
            return
        }
        await session.end()
    }

    /// What the `startfails` script answers `agent.start` with. Any code but
    /// `agent_pane_busy` takes the compensating path, so the fixture uses one
    /// of its own rather than guessing at herdr's — 0.7.5's refusal of an
    /// unsupported kind is recorded by its message alone.
    private static let refusedStart = HerdrAPIError(
        code: "fixture_agent_start_refused",
        message: "scripted non-retryable agent.start failure")

    /// One scripted run of the fixture, keyed so its recorded requests cannot
    /// be confused with another test's. The behavior word steers the fixture;
    /// see `scripts/fixtures/fake-herdr-streamlocal.py`.
    private static func scriptToken(_ behavior: String) -> String {
        "fixture:\(behavior):\(UUID().uuidString.lowercased())"
    }

    /// Every request the fixture served under `token`, in order, as
    /// `<method> <compact-json-params>`.
    private static func recordedRequests(
        from transport: HeelerSSHTransport,
        token: String
    ) async throws -> [String] {
        let read = try await transport.readPane(
            PaneReadParams(paneID: "record:\(token)", source: .recent))
        return read.text.split(separator: "\n").map(String.init)
    }

    private func exerciseProductionConnector(host: Host) async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let settings = SSHTransportSettings(
            host: host,
            credentials: environment.credentials,
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true })

        let transport = try await SSHTransportConnector().connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(transport is HeelerSSHTransport)
        #expect(try await transport.ping() == ServerInfo(version: "fake", protocolVersion: 17))
        #expect(try await transport.listAgents().isEmpty)
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
        let agentRead = try await transport.readAgent(
            AgentReadParams(
                source: .visible, target: "pane-1", format: .ansi,
                stripANSI: false))
        #expect(agentRead.text == "\u{1B}[31mfixture agent output\u{1B}[0m")
        #expect(agentRead.source == .visible)
        #expect(agentRead.format == .ansi)
        let prompted = try await transport.promptAgent(
            AgentPromptParams(target: "pane-1", text: "fixture prompt"))
        #expect(prompted.paneID == "pane-1")
        #expect(prompted.status == .working)
        try await transport.sendAgentKeys(
            AgentSendKeysParams(keys: ["ctrl+c", "enter"], target: "pane-1"))
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
                code: "500",
                message: "scripted failure")
        ) {
            try await transport.renameAgent(
                AgentRenameParams(target: "api-error", name: "fixture"))
        }
    }

    private func exerciseNotificationFiles(
        settings baseSettings: SSHTransportSettings,
        homePath: String
    ) async throws {
        let configDirectory =
            "\(homePath)/.heeler-ci/notify-\(UUID().uuidString.lowercased())"
        let quotedDirectory = try #require(RemoteShellPath.quotedAbsolute(configDirectory))

        var missingSettings = baseSettings
        missingSettings.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":[]}}'"
        missingSettings.notificationConfigDirCommand = "/bin/sh -c 'exit 99'"
        let missingTransport = try await HeelerSSHTransport.connect(settings: missingSettings)
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            _ = try await missingTransport.readNotificationRegistration()
        }
        try await missingTransport.close()

        var settings = baseSettings
        settings.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
            + "{\"plugin_id\":\"heeler\",\"enabled\":true}]}}'"
        settings.notificationConfigDirCommand =
            "/bin/sh -c 'umask 077; mkdir -p \"$1\" || exit 1; "
            + "printf \"__HEELER_PLUGIN_CONFIG_DIR__=%s\\n\" \"$1\"' notify "
            + quotedDirectory
        settings.sessionListCommand = notificationInspectionCommand(
            quotedDirectory: quotedDirectory)

        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.readNotificationRegistration() == nil)
        #expect(try await transport.readNotificationConfig() == nil)

        let firstRegistration = Data(
            #"{"v":1,"devices":[{"token":"private-device-token","key":"private-notification-key"}]}"#.utf8)
        try await transport.replaceNotificationRegistration(firstRegistration)
        #expect(try await transport.readNotificationRegistration() == firstRegistration)

        let configuration = Data(
            #"{"relay_url":"https://relay.example.test/","future_knob":"kept"}"#.utf8)
        try await transport.replaceNotificationConfig(configuration)
        let decodedConfiguration = try NotificationConfigFile.decode(
            try await transport.readNotificationConfig())
        #expect(decodedConfiguration.relayURL == "https://relay.example.test")

        let previousLive = Data(#"{"v":1,"devices":[]}"#.utf8)
        try await transport.replaceNotificationRegistration(previousLive)
        #expect(try await transport.readNotificationRegistration() == previousLive)

        await transport.delayNextNotificationSFTPWriteForTesting(.seconds(10))
        let cancellation = Task {
            try await transport.replaceNotificationRegistration(
                Data(repeating: 0x61, count: 1_024 * 1_024))
        }
        let writeEntryDeadline = ContinuousClock.now + .seconds(3)
        var activeState = await transport.notificationFileStateForTesting()
        while !activeState.writeIsDelayed, ContinuousClock.now < writeEntryDeadline {
            try await Task.sleep(for: .milliseconds(10))
            activeState = await transport.notificationFileStateForTesting()
        }
        try #require(activeState.writeIsDelayed)
        #expect(activeState.activeClientCount == 1)
        #expect(activeState.ordinarySessionCount == 1)
        #expect(activeState.connectionChannelCount == 1)
        #expect(activeState.temporaryPaths.count == 1)
        let temporaryPath = try #require(activeState.temporaryPaths.first)

        let cancellationStarted = ContinuousClock.now
        cancellation.cancel()
        await #expect(throws: TransportError.cancelled) {
            try await cancellation.value
        }
        #expect(cancellationStarted.duration(to: .now) < .seconds(5))

        let settledState = await transport.notificationFileStateForTesting()
        #expect(!settledState.writeIsDelayed)
        #expect(settledState.activeClientCount == 0)
        #expect(settledState.temporaryPaths.isEmpty)
        #expect(settledState.ordinarySessionCount == 0)
        #expect(settledState.connectionChannelCount == 0)
        #expect(try await transport.readRemoteFileForTesting(at: temporaryPath) == nil)
        #expect(
            try await transport.readNotificationRegistration() == previousLive)

        _ = try await transport.listSessions()
        do {
            try await transport.replaceNotificationRegistration(
                Data("replacement".utf8))
            Issue.record("A failed atomic rename unexpectedly succeeded.")
        } catch let error as NotificationRegistrationError {
            guard case .writeFailed = error else {
                Issue.record("Expected writeFailed, got \(error).")
                return
            }
        }
        _ = try await transport.listSessions()

        try await transport.close()
        do {
            _ = try await transport.readNotificationRegistration()
            Issue.record("A disconnected notification read unexpectedly succeeded.")
        } catch let error as NotificationRegistrationError {
            guard case .readFailed = error else {
                Issue.record("Expected readFailed, got \(error).")
                return
            }
        }
        do {
            try await transport.replaceNotificationConfig(Data("{}".utf8))
            Issue.record("A disconnected notification write unexpectedly succeeded.")
        } catch let error as NotificationRegistrationError {
            guard case .writeFailed = error else {
                Issue.record("Expected writeFailed, got \(error).")
                return
            }
        }
    }

    private func notificationInspectionCommand(quotedDirectory: String) -> String {
        "/bin/sh -c 'directory=$1; "
            + "mode() { stat -c \"%a\" \"$1\" 2>/dev/null || stat -f \"%Lp\" \"$1\"; }; "
            + "if [ ! -e \"$directory/.failure-mode\" ]; then "
            + "[ \"$(mode \"$directory\")\" = 700 ] || exit 31; "
            + "[ \"$(mode \"$directory/notifications.json\")\" = 600 ] || exit 32; "
            + "[ \"$(mode \"$directory/notify.json\")\" = 600 ] || exit 33; "
            + "[ -z \"$(find \"$directory\" -maxdepth 1 -name \"*.tmp-*\" -print -quit)\" ] "
            + "|| exit 34; "
            + "rm -f \"$directory/notifications.json\" || exit 35; "
            + "mkdir \"$directory/notifications.json\" || exit 36; "
            + "touch \"$directory/.failure-mode\" || exit 37; "
            + "else "
            + "[ -d \"$directory/notifications.json\" ] || exit 38; "
            + "[ -z \"$(find \"$directory\" -maxdepth 1 -name \"*.tmp-*\" -print -quit)\" ] "
            + "|| exit 39; "
            + "chmod 700 \"$directory\"; rm -rf -- \"$directory\" || exit 40; "
            + "fi; printf \"{\\\"sessions\\\":[]}\\n\"' inspect "
            + quotedDirectory
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

    private static let installedPluginListCommand =
        "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
        + "{\"plugin_id\":\"heeler\",\"enabled\":true}]}}'"

    /// The `NotificationRegistrationError` a registration read raises on a
    /// Host connected with `settings`, or nil if the read succeeded.
    private func notificationRegistrationFailure(
        settings: SSHTransportSettings
    ) async throws -> NotificationRegistrationError? {
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        do {
            _ = try await transport.readNotificationRegistration()
            return nil
        } catch let error as NotificationRegistrationError {
            return error
        }
    }

    private func expectPluginProbeFailure(
        settings: SSHTransportSettings,
        _ subject: String
    ) async throws {
        let failure = try await notificationRegistrationFailure(settings: settings)
        let error = try #require(
            failure,
            Comment(rawValue: "\(subject) must not read as success"))
        guard case .pluginProbeFailed = error else {
            Issue.record(
                Comment(rawValue: "\(subject) expected pluginProbeFailed, got \(error)"))
            return
        }
    }

    private func connectionCount(from transport: HeelerSSHTransport) async throws -> Int {
        let session = try #require(try await transport.listSessions().first)
        return try #require(Int(session.name.dropFirst("count-".count)))
    }
}

struct HeelerSSHTransportBehaviorEnvironment: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let deviceKey: Curve25519.Signing.PrivateKey
    let socketPath: String
    let staleSocketPath: String
    let wakeFailureStaleSocketPath: String
    let countFilePath: String
    let homePath: String
    let jumpPort: UInt16
    let targetHost: String
    let targetPort: UInt16
    /// The unprivileged impairment proxy in front of the direct fixture sshd,
    /// and the control port that steers it. Optional in the wire format so an
    /// older fixture still decodes; the weak-network suite `#require`s them, so
    /// under the merge gate a fixture without a proxy fails rather than skips.
    let weakNetworkPort: UInt16?
    let weakNetworkControlPort: UInt16?

    static let current: HeelerSSHTransportBehaviorEnvironment? = {
        guard
            let directEncoded = ProcessInfo.processInfo.environment["HEELER_SSH_E2E_CONFIG"],
            let directData = Data(base64Encoded: directEncoded),
            let jumpEncoded = ProcessInfo.processInfo.environment["HEELER_SSH_JUMP_E2E_CONFIG"],
            let jumpData = Data(base64Encoded: jumpEncoded),
            let direct = try? JSONDecoder().decode(DirectFixture.self, from: directData),
            let jump = try? JSONDecoder().decode(JumpFixture.self, from: jumpData),
            let deviceKey = try? RealSSHFixture.deviceKey(seed: direct.deviceKeySeed)
        else { return nil }
        return HeelerSSHTransportBehaviorEnvironment(
            host: direct.host,
            port: direct.port,
            username: direct.username,
            deviceKey: deviceKey,
            socketPath: direct.socketPath,
            staleSocketPath: direct.staleSocketPath,
            wakeFailureStaleSocketPath: direct.wakeFailureStaleSocketPath,
            countFilePath: direct.countFilePath,
            homePath: direct.homePath,
            jumpPort: jump.jumpPort,
            targetHost: jump.targetHost,
            targetPort: jump.targetPort,
            weakNetworkPort: direct.weakNetworkPort,
            weakNetworkControlPort: direct.weakNetworkControlPort)
    }()

    /// The fixture authorizes one throwaway Device Key. Everything but the two
    /// dedicated password tests authenticates with it, which is also what a real
    /// Host does.
    var credentials: SSHCredentials { .ed25519(deviceKey) }

    func directSettings(
        socket: HerdrSocketLocation? = nil
    ) -> SSHTransportSettings {
        settings(
            host: host,
            port: port,
            credentials: credentials,
            jump: nil,
            socket: socket)
    }

    func jumpSettings(
        socket: HerdrSocketLocation? = nil
    ) -> SSHTransportSettings {
        let credentials = self.credentials
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

    /// The same direct fixture reached through the impairment proxy, so the
    /// whole SSH byte stream — RPC, SFTP, PTY and the forwarded herdr socket
    /// alike — crosses a link the test controls.
    func weakNetworkSettings(
        port: UInt16,
        socket: HerdrSocketLocation? = nil
    ) -> SSHTransportSettings {
        settings(
            host: host,
            port: port,
            credentials: credentials,
            jump: nil,
            socket: socket)
    }

    /// A catalog Host for the direct fixture, exactly as onboarding would save
    /// it: a blank session name resolves the default socket over the Host's own
    /// home directory.
    func directHost() -> Host {
        Host(
            name: "Fixture",
            address: host,
            port: Int(port),
            username: username,
            authMethod: .deviceKey)
    }

    /// The same fixture reached through the Jump Host hop. Both hops share the
    /// account and credential, which is what the Host model already assumes.
    func jumpHost() -> Host {
        Host(
            name: "Fixture behind a Jump Host",
            address: targetHost,
            port: Int(targetPort),
            username: username,
            authMethod: .deviceKey,
            jumpAddress: host,
            jumpPort: Int(jumpPort))
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
        settings.stageDirectoryCommand =
            "/bin/sh -c 'umask 077; "
            + "directory=$(mktemp -d \"$1/heeler.XXXXXXXX\") || exit 1; "
            + "printf \"__HEELER_STAGE_DIR__=%s\\n\" \"$directory\"' stage \(quotedHome)/.heeler-ci"
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
        let deviceKeySeed: String
        let socketPath: String
        let staleSocketPath: String
        let wakeFailureStaleSocketPath: String
        let countFilePath: String
        let homePath: String
        let weakNetworkPort: UInt16?
        let weakNetworkControlPort: UInt16?
    }

    private struct JumpFixture: Decodable {
        let jumpPort: UInt16
        let targetHost: String
        let targetPort: UInt16
    }
}
