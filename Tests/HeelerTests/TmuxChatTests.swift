import Foundation
import Testing

@testable import Heeler

/// Chat on a tmux Host through `ConsoleStore` and `ScriptedTmuxHost` (ADRs 0034,
/// 0044, 0045 and 0046): capabilities, process-scoped binding via `TMUX` and
/// `TMUX_PANE`, `@heeler-session` hints, `@heeler-chat` candidate picks, and
/// resetting per-instance Chat and retained-Attach state when another tmux server
/// instance takes the socket.
@MainActor
@Suite("tmux Chat", .timeLimit(.minutes(1)))
struct TmuxChatTests {
    private static let first = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let second = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
    private static let grokHeld = "6f1d2c3b-8a7e-4f10-9b2d-0c1e2f3a4b5c"
    private static let grokRecent = "8b3f4e5d-ac90-4b32-9d4f-2e3a4b5c6d7e"
    private static let pid = 4000
    private static let start = "Thu Nov 12 06:00:00 2026"
    private static let cwd = "/work/app"
    private static let home = ScriptedTmuxHost.home
    private static let nextInstance = TmuxServerInstance(pid: 9191, startTime: 1_794_399_999)

    private let host = Host(
        address: "mac.example",
        username: "dev",
        serverKind: .tmux,
        tmuxPaths: ScriptedTmuxHost.paths())

    private static func tmuxEnvironment(
        socket: String = ScriptedTmuxHost.socketPath(),
        serverPID: Int = ScriptedTmuxHost.instance.pid,
        pane: String = "%0",
        extra: [String: String?] = [:]
    ) -> [String: String?] {
        var environment: [String: String?] = [
            "TMUX": "\(socket),\(serverPID),0",
            "TMUX_PANE": pane,
            "HOME": home,
        ]
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }

    private static func registryEntry(
        pid: Int = pid, session: String = first, procStart: String = start, cwd: String = cwd
    ) -> Data {
        Data(
            """
            {"pid":\(pid),"sessionId":"\(session)","cwd":"\(cwd)","startedAt":1780000000000,\
            "procStart":"\(procStart)","version":"2.1.314","kind":"interactive","entrypoint":"cli",\
            "status":"idle","updatedAt":1780000000000}
            """.utf8)
    }

    private static func claudeTranscript(session: String = first) throws -> Data {
        Data(try ChatFixture.text("claude/probe2-transcript.jsonl").replacingOccurrences(of: first, with: session).utf8)
    }

    private static func claudeTranscriptPath(root: String = "\(home)/.claude", session: String = first) -> String {
        "\(root)/projects/-work-app/\(session).jsonl"
    }

    private static func grokFile(_ session: String) -> String {
        "\(home)/.grok/sessions/%2Fwork%2Fapp/\(session)/updates.jsonl"
    }

    private static func grokTranscript(session: String, lines: Int = 4) throws -> Data {
        let text = try ChatFixture.text("grok/core-turns.jsonl")
        let original = try #require(GrokTranscriptLocator.sessionID(inHead: Data(text.utf8)))
        let kept = text.replacingOccurrences(of: original, with: session)
            .split(separator: "\n").prefix(lines).joined(separator: "\n")
        return Data((kept + "\n").utf8)
    }

    private static func sessionHint(
        session: String = first, file: String? = nil, pid: Int = pid, start: String = start
    ) -> String {
        HerdrCoreSessionHint.pickLabelValue(session: session, file: file, pid: pid, start: start) ?? ""
    }

    private final class PickClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_792_440_000)

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    @MainActor
    private final class Rig {
        let files = VirtualHostFiles(home: TmuxChatTests.home)
        let tmux: ScriptedTmuxHost
        let cache = VolatileChatTranscriptCache()
        let pins: PinnedAgentsStore
        let store: ConsoleStore
        let host: Host
        let clock = PickClock()

        init(
            host: Host,
            kernel: String = "Darwin",
            tmux existingTmux: ScriptedTmuxHost? = nil,
            files existingFiles: VirtualHostFiles? = nil,
            steppedByTheTest: Bool = false
        ) {
            self.host = host
            if let existingFiles {
                self.tmux = existingTmux ?? ScriptedTmuxHost(kernel: kernel, virtualFiles: existingFiles)
            } else {
                self.tmux = existingTmux ?? ScriptedTmuxHost(kernel: kernel, virtualFiles: files)
            }
            let suiteName = "TmuxChatTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            pins = PinnedAgentsStore(defaults: defaults)
            var timing = AgentChatStore.Timing()
            if steppedByTheTest {
                timing.activeInterval = .seconds(3_600)
                timing.idleInterval = .seconds(3_600)
                timing.queryActiveInterval = .seconds(3_600)
            } else {
                timing.activeInterval = .milliseconds(20)
                timing.idleInterval = .milliseconds(20)
                timing.queryActiveInterval = .milliseconds(20)
            }
            let tmux = self.tmux
            let clock = self.clock
            store = ConsoleStore(
                pins: pins,
                chatCache: cache,
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeTmuxSession: { candidate in
                    TmuxHostSession(
                        storedPaths: candidate.storedTmuxPaths,
                        connect: { paths in
                            await tmux.transport(socketName: candidate.tmuxSocketName, storedPaths: paths)
                        },
                        reconnectPolicy: ReconnectPolicy(
                            initialDelay: .milliseconds(20), multiplier: 1, maxDelay: .milliseconds(40)),
                        keepalive: KeepalivePolicy(interval: .seconds(60)),
                        settledLoopLife: .zero)
                },
                chatTiming: timing,
                chatNow: { steppedByTheTest ? clock.now : Date() })
        }

        func start() async throws {
            store.setHosts([host])
            await store.resume()
            try await waitUntil("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(self.host.id) }
        }

        var agent: ConsoleAgent? { store.agents.first }

        func chat(for program: ChatProgram = .claude) throws -> AgentChatStore {
            let agent = try #require(agent)
            return try #require(store.chatStore(for: agent, program: program))
        }

        var checks: Int {
            get async { await tmux.processReadRequests.count }
        }

        func waitUntil(
            _ what: String, _ condition: @MainActor () async -> Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            var budget = PollBudget(.seconds(5))
            while budget.hasTimeLeft {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(10))
                budget.charge()
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }
    }

    private static func isFollowing(_ chat: AgentChatStore, suffix: String) -> Bool {
        guard case .following(let path) = chat.conversation.phase else { return false }
        return path.hasSuffix(suffix)
    }

    // MARK: Capabilities & offer

    @Test func hostCapabilitiesOfferTmuxChatOnlyOnLinuxAndMacOSForConfirmedPrograms() {
        #expect(!HostCapabilities(serverKind: .tmux).chat)
        #expect(!HostCapabilities(serverKind: .tmux, coreKernel: "FreeBSD").chat)
        let expected: Set<ChatProgram> = [.claude, .codex, .grok, .pi, .omp, .agy]
        for kernel in ["Linux", "Darwin"] {
            let capabilities = HostCapabilities(serverKind: .tmux, coreKernel: kernel)
            #expect(capabilities.chat)
            #expect(capabilities.chatPrograms == expected)
            for program in ChatProgram.allCases {
                #expect(capabilities.offersChat(for: program) == expected.contains(program))
            }
        }
        // Offline saved Chat directory stays off because pane ids repeat across instances.
        #expect(!host.capabilities.chat)
    }

    @Test(arguments: [
        ("Darwin", "claude", ["claude"], ChatProgram.claude as ChatProgram?),
        ("Linux", "codex", ["codex", "--no-daemon"], .codex),
        ("Darwin", "grok", ["grok"], .grok),
        ("Linux", "pi", ["pi"], .pi),
        ("Darwin", "omp", ["omp"], .omp),
        ("Darwin", "opencode", ["opencode"], nil),
        ("FreeBSD", "claude", ["claude"], nil),
    ])
    func chatOfferFollowsKernelAndProgram(
        _ kernel: String, _ command: String, _ arguments: [String], _ expected: ChatProgram?
    ) async throws {
        let rig = Rig(host: host, kernel: kernel)
        await rig.tmux.setPanes([
            .make(processID: Self.pid, command: command, path: Self.cwd, arguments: arguments),
        ])
        try await rig.start()
        defer { rig.store.setHosts([]) }

        let agent = try #require(rig.agent)
        #expect(rig.store.chatProgram(for: agent) == expected)
        if let expected {
            #expect(rig.store.chatStore(for: agent, program: expected) != nil)
        } else {
            let unoffered = ChatProgram(rawValue: command) ?? .claude
            #expect(rig.store.chatStore(for: agent, program: unoffered) == nil)
        }
        // Connecting and listing an Agent does not run background process or platform checks.
        #expect(await rig.checks == 0)
        #expect(rig.store.hostPlatforms[host.id] == nil)
    }

    // MARK: Binding across programs and macOS SIP shell

    @Test func claudeBindsFromSessionRegistryAndClearsStaleSessionOption() async throws {
        let rig = Rig(host: host, kernel: "Darwin")
        let staleHint = Self.sessionHint(session: Self.second, pid: 999, start: "old-start")
        await rig.tmux.setPanes([
            .make(
                processID: Self.pid, command: "claude", path: Self.cwd,
                status: "state=idle:app=claude-code:turn=0:blocked=0",
                agentSession: staleHint, arguments: ["claude"]),
        ])
        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(), forProcess: Self.pid, name: "claude", start: Self.start)
        await rig.files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await rig.files.write(try Self.claudeTranscript(), at: Self.claudeTranscriptPath())

        try await rig.start()
        defer { rig.store.setHosts([]) }
        let chat = try rig.chat()
        chat.show()
        defer { chat.end() }

        try await rig.waitUntil("Claude Transcript") { Self.isFollowing(chat, suffix: "\(Self.first).jsonl") }
        try await rig.waitUntil("stale @heeler-session cleared") {
            await rig.tmux.listedPanes().first?.agentSession == ""
        }
        // One check on open, and at most one after the cleared option shows in inventory.
        let checksAfterClear = await rig.checks
        #expect((1...2).contains(checksAfterClear))
    }

    @Test func claudeBindsUnderMacOSSIPShellInOneProcessCheck() async throws {
        let shellPID = 3999
        let rig = Rig(host: host, kernel: "Darwin")
        await rig.tmux.setPanes([
            .make(
                processID: shellPID, command: "claude", path: Self.cwd,
                status: "state=idle:app=claude-code:turn=0:blocked=0",
                agentSession: Self.sessionHint(
                    session: Self.first,
                    file: Self.claudeTranscriptPath(),
                    pid: Self.pid,
                    start: Self.start),
                arguments: ["claude"]),
        ])
        await rig.tmux.setProcessEnvironment([:], forProcess: shellPID, name: "zsh", start: "shell-start")
        await rig.tmux.makeProcessEnvironmentUnavailable(forProcess: shellPID)
        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(), forProcess: Self.pid, name: "claude", parent: shellPID, start: Self.start)
        await rig.files.write(try Self.claudeTranscript(), at: Self.claudeTranscriptPath())

        try await rig.start()
        defer { rig.store.setHosts([]) }
        let chat = try rig.chat()
        chat.show()
        defer { chat.end() }

        try await rig.waitUntil("Claude Transcript via @heeler-session") {
            Self.isFollowing(chat, suffix: "\(Self.first).jsonl")
        }
        #expect(await rig.checks == 1)
    }

    @Test func rejectsProcessWhoseTmuxEnvironmentNamesAnotherServerOrPane() async throws {
        let rig = Rig(host: host, kernel: "Darwin")
        await rig.tmux.setPanes([
            .make(processID: Self.pid, command: "claude", path: Self.cwd, arguments: ["claude"]),
        ])
        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(serverPID: ScriptedTmuxHost.instance.pid + 1),
            forProcess: Self.pid, name: "claude", start: Self.start)
        await rig.files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/\(Self.pid).json")
        await rig.files.write(try Self.claudeTranscript(), at: Self.claudeTranscriptPath())

        try await rig.start()
        defer { rig.store.setHosts([]) }
        let chat = try rig.chat()
        chat.show()
        defer { chat.end() }

        try await rig.waitUntil("cannot tell when server pid mismatches") {
            chat.conversation.phase == .unavailable(.cannotTellSession(.claude))
        }
    }

    @Test func claudePermissionLaunchFollowsLiveProcessArgumentsInPaneScope() async throws {
        let rig = Rig(host: host, kernel: "Darwin")
        await rig.tmux.setPanes([
            .make(
                processID: Self.pid, command: "claude", path: Self.cwd,
                arguments: ["claude", "--allow-dangerously-skip-permissions"]),
        ])
        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(), forProcess: Self.pid, name: "claude", start: Self.start, argv: ["claude"])
        try await rig.start()
        defer { rig.store.setHosts([]) }

        let agent = try #require(rig.agent)
        let pin = rig.store.composerSession(for: agent).corePin
        let normal = try await rig.store.claudePermissionLaunch(for: agent, corePin: pin)
        #expect(normal?.optsIntoBypass == false)

        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(), forProcess: Self.pid, name: "claude", start: "new-start",
            argv: ["claude", "--permission-mode", "manual", "--allow-dangerously-skip-permissions"])
        let allowed = try await rig.store.claudePermissionLaunch(for: agent, corePin: pin)
        #expect(allowed?.optsIntoBypass == true)
        #expect(allowed?.process != normal?.process)
    }

    @Test func unrelatedPaneChangesDoNotTriggerExtraProcessChecks() async throws {
        let rig = Rig(host: host, kernel: "Darwin")
        await rig.tmux.setPanes([
            .make(
                pane: 0, processID: Self.pid, command: "claude", path: Self.cwd,
                status: "state=idle:app=claude-code:turn=0:blocked=0",
                agentSession: Self.sessionHint(session: Self.first, file: Self.claudeTranscriptPath()),
                arguments: ["claude"]),
            .make(window: 1, windowIndex: 1, pane: 1, processID: 4100, command: "zsh", path: Self.cwd, arguments: ["zsh"]),
        ])
        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(), forProcess: Self.pid, name: "claude", start: Self.start)
        await rig.files.write(try Self.claudeTranscript(), at: Self.claudeTranscriptPath())

        try await rig.start()
        defer { rig.store.setHosts([]) }
        let chat = try rig.chat()
        chat.show()
        defer { chat.end() }

        try await rig.waitUntil("initial bind") { Self.isFollowing(chat, suffix: "\(Self.first).jsonl") }
        #expect(await rig.checks == 1)

        // Resize %0 and %1 and rename a window: none of these change %0's session evidence.
        await rig.tmux.setPanes([
            .make(
                windowName: "renamed", pane: 0, processID: Self.pid, command: "claude", path: Self.cwd,
                width: 132, height: 42,
                status: "state=idle:app=claude-code:turn=0:blocked=0",
                agentSession: Self.sessionHint(session: Self.first, file: Self.claudeTranscriptPath()),
                arguments: ["claude"]),
            .make(
                window: 1, windowIndex: 1, pane: 1, processID: 4100, command: "zsh", path: Self.cwd,
                width: 100, height: 30, arguments: ["zsh"]),
        ])
        try await rig.waitUntil("resized grid") { rig.store.terminals.first?.gridColumns == 132 }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await rig.checks == 1)

        // Changing @heeler-status on %0 asks again.
        await rig.tmux.setPanes([
            .make(
                windowName: "renamed", pane: 0, processID: Self.pid, command: "claude", path: Self.cwd,
                width: 132, height: 42,
                status: "state=working:app=claude-code:turn=0:blocked=0",
                agentSession: Self.sessionHint(session: Self.first, file: Self.claudeTranscriptPath()),
                arguments: ["claude"]),
            .make(
                window: 1, windowIndex: 1, pane: 1, processID: 4100, command: "zsh", path: Self.cwd,
                width: 100, height: 30, arguments: ["zsh"]),
        ])
        try await rig.waitUntil("re-checked after @heeler-status moved") { await rig.checks == 2 }
    }

    // MARK: Candidates & @heeler-chat picks

    @Test func confirmingCandidateWritesHeelerChatOptionAndSecondDeviceAdoptsIt() async throws {
        let rig = Rig(host: host, kernel: "Linux")
        await rig.tmux.setPanes([
            .make(
                processID: Self.pid, command: "grok", path: Self.cwd,
                status: "state=idle:app=grok-build:turn=0:blocked=0", arguments: ["grok"]),
        ])
        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(extra: ["GROK_HOME": nil]),
            forProcess: Self.pid, name: "grok", start: Self.start,
            openFiles: ["\(Self.home)/.grok/sessions/%2Fwork%2Fapp/\(Self.grokHeld)/events.jsonl"])
        await rig.files.write(
            #"[{"session_id":"\#(Self.grokRecent)","pid":9,"pid_start":1,"cwd":"/work/app"}]"#,
            at: "\(Self.home)/.grok/active_sessions.json")
        await rig.files.write(try Self.grokTranscript(session: Self.grokRecent), at: Self.grokFile(Self.grokRecent))
        await rig.files.write(try Self.grokTranscript(session: Self.grokHeld), at: Self.grokFile(Self.grokHeld))

        try await rig.start()
        defer { rig.store.setHosts([]) }
        let chat = try rig.chat(for: .grok)
        chat.show()
        defer { chat.end() }

        try await rig.waitUntil("cannot tell") {
            chat.conversation.phase == .unavailable(.cannotTellSession(.grok))
        }
        await chat.listCandidates()
        guard case .listed(let list) = chat.candidates,
            let candidate = list.candidates.first(where: { $0.sessionID == Self.grokHeld })
        else {
            Issue.record("expected \(Self.grokHeld) in candidates, got \(chat.candidates)")
            return
        }
        _ = await chat.previewCandidate(candidate)
        await chat.confirmCandidate(candidate)

        #expect(chat.pickConfirmation == .confirmed)
        let expectedOption = try #require(
            HerdrCoreSessionHint.pickLabelValue(session: Self.grokHeld, file: nil, pid: Self.pid, start: Self.start))
        try await rig.waitUntil("@heeler-chat written on pane") {
            await rig.tmux.listedPanes().first?.chatPick == expectedOption
        }
        try await rig.waitUntil("following picked transcript") {
            chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }

        // A second ConsoleStore connected to the same tmux server adopts @heeler-chat directly.
        let secondDevice = Rig(host: host, kernel: "Linux", tmux: rig.tmux, files: rig.files)
        try await secondDevice.start()
        defer { secondDevice.store.setHosts([]) }
        let secondChat = try secondDevice.chat(for: .grok)
        secondChat.show()
        defer { secondChat.end() }

        try await secondDevice.waitUntil("second device follows @heeler-chat") {
            secondChat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld))
        }
    }

    @Test func sendGuardDropClearsHeelerChatOptionOnPane() async throws {
        let rig = Rig(host: host, kernel: "Linux", steppedByTheTest: true)
        let pickValue = try #require(
            HerdrCoreSessionHint.pickLabelValue(session: Self.grokHeld, file: nil, pid: Self.pid, start: Self.start))
        await rig.tmux.setPanes([
            .make(
                processID: Self.pid, command: "grok", path: Self.cwd,
                status: "state=idle:app=grok-build:turn=0:blocked=0",
                chatPick: pickValue, arguments: ["grok"]),
        ])
        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(extra: ["GROK_HOME": nil]),
            forProcess: Self.pid, name: "grok", start: Self.start)
        await rig.files.write(try Self.grokTranscript(session: Self.grokHeld), at: Self.grokFile(Self.grokHeld))

        try await rig.start()
        defer { rig.store.setHosts([]) }
        let chat = try rig.chat(for: .grok)
        chat.show()
        defer { chat.end() }

        for _ in 0..<200 {
            await chat.step()
            if chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld)) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.conversation.phase == .following(path: Self.grokFile(Self.grokHeld)))

        // Simulate a delivered send whose prompt never lands in the picked transcript across a turn.
        let id = UUID()
        chat.updateSends([AgentChatStore.SentMessage(id: id, text: "missing prompt", isDelivered: false, mayNotHaveGone: false)])
        chat.updateSends([AgentChatStore.SentMessage(id: id, text: "missing prompt", isDelivered: true, mayNotHaveGone: false)])
        await rig.tmux.setPanes([
            .make(
                processID: Self.pid, command: "grok", path: Self.cwd,
                status: "state=working:app=grok-build:turn=0:blocked=0",
                chatPick: pickValue, arguments: ["grok"]),
        ])
        try await rig.waitUntil("working") { rig.agent?.agent.status == .working }
        await rig.tmux.setPanes([
            .make(
                processID: Self.pid, command: "grok", path: Self.cwd,
                status: "state=done:app=grok-build:turn=1:blocked=0",
                chatPick: pickValue, arguments: ["grok"]),
        ])
        try await rig.waitUntil("idle after turn") { rig.agent?.agent.status != .working }

        rig.clock.advance(AgentChatStore.Timing().pickGuardSettle)
        await chat.step()

        try await rig.waitUntil("pick dropped and @heeler-chat cleared") {
            await rig.tmux.listedPanes().first?.chatPick == ""
                && chat.conversation.phase == .unavailable(.cannotTellSession(.grok))
        }
    }

    // MARK: Server instance replacement (ADR 0044)

    @Test func newServerInstanceDropsChatStatePinsAndIdleRetainedAttaches() async throws {
        let rig = Rig(host: host, kernel: "Darwin")
        let pickValue = Self.sessionHint(session: Self.first)
        await rig.tmux.setPanes([
            .make(
                processID: Self.pid, command: "claude", path: Self.cwd, height: 4,
                status: "state=idle:app=claude-code:turn=0:blocked=0",
                chatPick: pickValue, arguments: ["claude"]),
        ])
        await rig.tmux.setScreen(["$ claude", "> ", "", ""], of: "%0")
        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(), forProcess: Self.pid, name: "claude", start: Self.start)
        await rig.files.write(try Self.claudeTranscript(session: Self.first), at: Self.claudeTranscriptPath(session: Self.first))
        await rig.files.write(try Self.claudeTranscript(session: Self.second), at: Self.claudeTranscriptPath(session: Self.second))

        try await rig.start()
        defer { rig.store.setHosts([]) }

        let oldAgent = try #require(rig.agent)
        rig.pins.togglePin(hostID: host.id, paneID: oldAgent.agent.paneID)
        #expect(rig.pins.isPinned(hostID: host.id, paneID: oldAgent.agent.paneID))

        // Open and release a terminal Attach on %0 so it sits idle in AgentTerminalCache.
        let owner = UUID()
        let retained = rig.store.agentTerminals.acquire(
            agent: oldAgent, console: rig.store, ownerID: owner, corePin: rig.store.corePin(on: host.id))
        retained.attach.viewDidResize(cols: 80, rows: 4)
        try await rig.waitUntil("the retained attach's first paint") { retained.attach.terminalStatus == .live }
        rig.store.agentTerminals.release(retained, ownerID: owner)
        #expect(rig.store.agentTerminals.entries[oldAgent.id] === retained)

        // Open Chat on %0 under the first server instance.
        let firstChat = try rig.chat()
        let viewer = UUID()
        firstChat.show(viewer)
        try await rig.waitUntil("first server's Transcript") {
            Self.isFollowing(firstChat, suffix: "\(Self.first).jsonl")
        }
        let firstScope = firstChat.coreScope

        // Drop the pick on the first server instance, then start a new server instance
        // with %0 reusing the same pane id, process id, and pick value!
        if let tmuxProjection = rig.store.tmuxProjection(on: host.id) {
            tmuxProjection.dropChatPick(paneID: "%0", scope: firstScope, program: .claude)
        }

        await rig.tmux.setProcessEnvironment(
            Self.tmuxEnvironment(serverPID: Self.nextInstance.pid),
            forProcess: Self.pid, name: "claude", start: Self.start)
        await rig.tmux.startServer(
            instance: Self.nextInstance,
            panes: [
                .make(
                    processID: Self.pid, command: "claude", path: Self.cwd, height: 4,
                    status: "state=idle:app=claude-code:turn=0:blocked=0",
                    chatPick: pickValue, arguments: ["claude"]),
            ])

        try await rig.waitUntil("new server instance and evicted idle retained attach") {
            rig.store.tmuxServer(on: self.host.id)?.instance == Self.nextInstance
                && rig.store.agentTerminals.entries[oldAgent.id] == nil
        }
        #expect(!rig.pins.isPinned(hostID: host.id, paneID: oldAgent.agent.paneID))

        // The open Chat store was replaced by one scoped to the new server instance, and
        // `droppedPicks` from the old server instance no longer blocks `pickValue`.
        let newAgent = try #require(rig.agent)
        let secondChat = try #require(rig.store.chatStore(for: newAgent, program: .claude))
        #expect(secondChat !== firstChat)
        #expect(secondChat.coreScope != firstScope)
        secondChat.show()
        try await rig.waitUntil("second server's Transcript") {
            Self.isFollowing(secondChat, suffix: "\(Self.first).jsonl")
        }
        secondChat.end()
    }
}
