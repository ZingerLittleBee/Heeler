import Foundation
import Testing

@testable import Heeler

/// Session binding for tmux Panes (ADRs 0034 and 0045): processes match by
/// `TMUX_PANE` together with the socket path and server pid in `TMUX`, while
/// `@heeler-session` and `@heeler-chat` follow the same verification rules as
/// `heeler.session` and `heeler.chat`.
@Suite("tmux session binder", .timeLimit(.minutes(1)))
struct TmuxSessionBinderTests {
    private static let first = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let second = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
    private static let socketPath = "/private/tmp/tmux-501/default"
    private static let serverPID = 4242
    private static let paneID = "%0"
    private static let home = "/Users/dev"
    private static let start = "Thu Nov 12 06:00:00 2026"
    private static let linuxStart = "987654321"

    private static var tmuxScope: HerdrCoreSessionBinder.ProcessScope {
        .tmux(paneID: paneID, socketPath: socketPath, serverPID: serverPID)
    }

    private static func tmuxEnvironment(
        socket: String = socketPath, pid: Int = serverPID, session: String = "0", pane: String = paneID
    ) -> [String: String] {
        [
            "TMUX": "\(socket),\(pid),\(session)",
            "TMUX_PANE": pane,
            "HOME": home,
        ]
    }

    private static func record(
        pid: Int = 4000, name: String = "claude", argv: [String]? = ["claude"],
        cwd: String = "/work/app", labels: [String: String] = [:]
    ) -> HerdrCoreTerminalRecord {
        let pane = TmuxInventory.Pane(
            sessionID: "$0",
            sessionName: "main",
            windowID: "@0",
            windowIndex: 0,
            windowName: "work",
            paneID: paneID,
            paneIndex: 0,
            processID: pid,
            command: name,
            path: cwd,
            width: 80,
            height: 24,
            isDead: false,
            hasPipe: false,
            agentSession: labels[HerdrCoreSessionHint.sessionLabel] ?? "",
            chatPick: labels[HerdrCoreSessionHint.pickLabel] ?? "",
            foregroundArguments: argv)
        return HerdrCoreTerminalRecord(tmuxPane: pane)
    }

    private static func registryEntry(
        pid: Int = 4000, session: String = first, procStart: String = start, cwd: String = "/work/app"
    ) -> Data {
        Data(
            """
            {"pid":\(pid),"sessionId":"\(session)","cwd":"\(cwd)","startedAt":1780000000000,\
            "procStart":"\(procStart)","version":"2.1.314","kind":"interactive","entrypoint":"cli",\
            "status":"idle","updatedAt":1780000000000}
            """.utf8)
    }

    private static func sessionHint(
        session: String = first, file: String? = nil, pid: Int = 4000, start: String = start
    ) -> String {
        var fields: [String] = [
            "\"session\":\"\(session)\"",
            "\"pid\":\(pid)",
            "\"start\":\"\(start)\"",
        ]
        if let file {
            fields.append("\"file\":\"\(file)\"")
        }
        return "{\(fields.joined(separator: ","))}"
    }

    private actor ClearedLabels {
        private(set) var batches: [[String: String]] = []
        func record(_ batch: [String: String]) { batches.append(batch) }
    }

    private static func chatFiles(_ files: VirtualHostFiles) -> ChatHostFiles {
        ChatHostFiles(
            status: { try await files.fileStatus(atPath: $0) },
            list: { try await files.listFiles($0) },
            read: { try await files.readRange($0) },
            home: { try await files.home() },
            queryOpenCode: nil,
            accountDirectories: { _ in [] })
    }

    // MARK: TMUX parsing

    @Test func parsesTmuxEnvironmentIncludingCommasInSocketPath() {
        #expect(
            HerdrCoreTerminalProcesses.parseTmuxEnvironment("/private/tmp/tmux-501/default,4242,0")
                == .init(socketPath: "/private/tmp/tmux-501/default", serverPID: 4242))
        #expect(
            HerdrCoreTerminalProcesses.parseTmuxEnvironment("/tmp/dir,with,commas/sock,910,12")
                == .init(socketPath: "/tmp/dir,with,commas/sock", serverPID: 910))
        #expect(HerdrCoreTerminalProcesses.parseTmuxEnvironment("") == nil)
        #expect(HerdrCoreTerminalProcesses.parseTmuxEnvironment("/tmp/sock,4242") == nil)
        #expect(HerdrCoreTerminalProcesses.parseTmuxEnvironment("relative/sock,4242,0") == nil)
        #expect(HerdrCoreTerminalProcesses.parseTmuxEnvironment("/tmp/sock,notapid,0") == nil)
        #expect(HerdrCoreTerminalProcesses.parseTmuxEnvironment("/tmp/sock,0,0") == nil)
        #expect(HerdrCoreTerminalProcesses.parseTmuxEnvironment("/tmp/sock,4242,notanumber") == nil)
        #expect(HerdrCoreTerminalProcesses.parseTmuxEnvironment("/tmp/sock,4242,") == nil)
    }

    // MARK: Scope matching

    @Test func bindsProcessMatchingTmuxPaneSocketAndServerPIDIncludingCommaSocket() async throws {
        let commaSocket = "/private/tmp/work,dir/default"
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        await table.add(
            .init(
                pid: 4000, name: "zsh", start: Self.start,
                environment: Self.tmuxEnvironment(socket: commaSocket, session: "3")))
        await table.add(
            .init(
                pid: 4010, parent: 4000, name: "claude", start: Self.start,
                environment: Self.tmuxEnvironment(socket: commaSocket, session: "3")))
        await files.write(Self.registryEntry(pid: 4010), at: "\(Self.home)/.claude/sessions/4010.json")

        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { _ in },
            hostSystem: .macOS,
            processScope: .tmux(paneID: Self.paneID, socketPath: commaSocket, serverPID: Self.serverPID))

        let tmuxRecord = Self.record(pid: 4000, name: "claude", argv: ["claude", "--resume"])
        #expect(tmuxRecord.pid == 4000)
        #expect(tmuxRecord.foreground?.pid == nil)
        #expect(tmuxRecord.foreground?.name == "claude")
        #expect(tmuxRecord.foreground?.argv == ["claude", "--resume"])
        let evidence = try await binder.check(tmuxRecord)
        #expect(
            evidence
                == .bound(
                    sessionID: Self.first,
                    transcriptRoot: "\(Self.home)/.claude",
                    directory: "/work/app"))
    }

    @Test(arguments: [
        ("wrong pane", ["TMUX": "/private/tmp/tmux-501/default,4242,0", "TMUX_PANE": "%1", "HOME": "/Users/dev"]),
        ("wrong socket", ["TMUX": "/private/tmp/tmux-501/other,4242,0", "TMUX_PANE": "%0", "HOME": "/Users/dev"]),
        ("wrong server pid", ["TMUX": "/private/tmp/tmux-501/default,9999,0", "TMUX_PANE": "%0", "HOME": "/Users/dev"]),
        ("missing TMUX", ["TMUX_PANE": "%0", "HOME": "/Users/dev"]),
        ("missing TMUX_PANE", ["TMUX": "/private/tmp/tmux-501/default,4242,0", "HOME": "/Users/dev"]),
    ])
    func rejectsProcessesOutsideTheHostServerAndPane(_ label: String, _ badEnvironment: [String: String]) async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        await table.add(.init(pid: 4000, name: "claude", start: Self.start, environment: badEnvironment))
        await files.write(Self.registryEntry(pid: 4000), at: "\(Self.home)/.claude/sessions/4000.json")

        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { _ in },
            hostSystem: .macOS,
            processScope: Self.tmuxScope)

        let evidence = try await binder.check(Self.record())
        #expect(evidence == .unavailable(.cannotTellSession(.claude)), "\(label)")
    }

    @Test func ignoresDescendantsInNestedTmuxOrAnotherPane() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        await table.add(.init(pid: 4000, name: "zsh", start: Self.start, environment: Self.tmuxEnvironment()))
        // Nested tmux client spawned a child in another server/pane.
        await table.add(
            .init(
                pid: 4010, parent: 4000, name: "claude", start: Self.start,
                environment: Self.tmuxEnvironment(socket: "/private/tmp/tmux-501/nested", pid: 7777, pane: "%0")))
        await files.write(Self.registryEntry(pid: 4010), at: "\(Self.home)/.claude/sessions/4010.json")

        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { _ in },
            hostSystem: .macOS,
            processScope: Self.tmuxScope)

        let evidence = try await binder.check(Self.record(pid: 4000, name: "zsh"))
        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
    }

    // MARK: @heeler-session hint verification

    @Test func verifiesClaudeSessionHintByPidAndStartAndClearsStaleHint() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let cleared = ClearedLabels()
        await table.add(.init(pid: 4000, name: "claude", start: Self.start, environment: Self.tmuxEnvironment()))

        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { await cleared.record($0) },
            hostSystem: .macOS,
            processScope: Self.tmuxScope)

        let valid = Self.sessionHint(session: Self.first, pid: 4000, start: Self.start)
        let bound = try await binder.check(
            Self.record(labels: [HerdrCoreSessionHint.sessionLabel: valid]))
        #expect(bound == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: nil))
        #expect(await cleared.batches.isEmpty)

        // Stale hint from an earlier process with another start is cleared and does not bind.
        let stale = Self.sessionHint(session: Self.second, pid: 4000, start: "Wed Nov 11 06:00:00 2026")
        let afterStale = try await binder.check(
            Self.record(labels: [HerdrCoreSessionHint.sessionLabel: stale]))
        #expect(afterStale == .unavailable(.cannotTellSession(.claude)))
        #expect(await cleared.batches == [[HerdrCoreSessionHint.sessionLabel: stale]])
    }

    @Test func keepsHintFromRunningSameNameDescendantWithoutBinding() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let cleared = ClearedLabels()
        // Wrapper named `claude` (4000) with a child `claude` tool (4010) marked as child session.
        await table.add(.init(pid: 4000, name: "claude", start: Self.start, environment: Self.tmuxEnvironment()))
        var childEnv = Self.tmuxEnvironment()
        childEnv["CLAUDE_CODE_CHILD_SESSION"] = "1"
        await table.add(
            .init(
                pid: 4010, parent: 4000, name: "claude", start: "Thu Nov 12 06:01:00 2026",
                environment: childEnv))

        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { await cleared.record($0) },
            hostSystem: .macOS,
            processScope: Self.tmuxScope)

        let descendantHint = Self.sessionHint(session: Self.second, pid: 4010, start: "Thu Nov 12 06:01:00 2026")
        let evidence = try await binder.check(
            Self.record(labels: [HerdrCoreSessionHint.sessionLabel: descendantHint]))
        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
        #expect(await cleared.batches.isEmpty)
    }

    // MARK: Other programs & macOS SIP

    @Test func bindsPiExtensionHintAndOmpBreadcrumbInTmuxScope() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let sessionFile = "\(Self.home)/.pi/agent/sessions/--work-app--/2026-11-12_\(Self.first).jsonl"
        await table.add(.init(pid: 4000, name: "pi", start: Self.start, environment: Self.tmuxEnvironment()))

        let piBinder = HerdrCoreSessionBinder(
            program: .pi,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { _ in },
            hostSystem: .macOS,
            processScope: Self.tmuxScope)

        let hint = Self.sessionHint(session: Self.first, file: sessionFile, pid: 4000, start: Self.start)
        let piBound = try await piBinder.check(
            Self.record(name: "pi", argv: ["pi"], labels: [HerdrCoreSessionHint.sessionLabel: hint]))
        #expect(
            piBound
                == .bound(
                    sessionID: sessionFile,
                    transcriptRoot: "\(Self.home)/.pi/agent/sessions",
                    directory: nil))

        let ompFile = "\(Self.home)/.omp/agent/sessions/--work-app--/2026-11-12_\(Self.second).jsonl"
        await table.add(
            .init(
                pid: 5000, name: "omp", start: Self.start, environment: Self.tmuxEnvironment(),
                openFiles: ["/dev/ttys004", ompFile]))
        await files.write(Data("5000\n\(ompFile)\n".utf8), at: "\(Self.home)/.omp/agent/terminal-sessions/ttys004")

        let ompBinder = HerdrCoreSessionBinder(
            program: .omp,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { _ in },
            hostSystem: .macOS,
            processScope: Self.tmuxScope)

        let ompBound = try await ompBinder.check(
            Self.record(pid: 5000, name: "omp", argv: ["omp"]))
        #expect(
            ompBound
                == .bound(
                    sessionID: ompFile,
                    transcriptRoot: "\(Self.home)/.omp/agent/sessions",
                    directory: nil))
    }

    @Test func bindsCodexAndGrokInTmuxScope() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/dev")
        let linuxEnv = [
            "TMUX": "\(Self.socketPath),\(Self.serverPID),0",
            "TMUX_PANE": Self.paneID,
            "HOME": "/home/dev",
        ]
        let rolloutPath = "/home/dev/.codex/sessions/2026/11/12/rollout-2026-11-12T06-00-00-\(Self.first).jsonl"
        let head = """
            {"type":"session_meta","payload":{"id":"\(Self.first)","cwd":"/work/app","source":"cli"}}
            """
        await files.write(Data((head + "\n").utf8), at: rolloutPath)
        await table.add(
            .init(
                pid: 4100, name: "codex", start: Self.linuxStart, environment: linuxEnv,
                argv: ["codex", "--no-daemon"], openFiles: [rolloutPath]))

        let codexBinder = HerdrCoreSessionBinder(
            program: .codex,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { _ in },
            hostSystem: .other,
            processScope: Self.tmuxScope)
        let codexBound = try await codexBinder.check(
            Self.record(pid: 4100, name: "codex", argv: ["codex", "--no-daemon"]))
        #expect(codexBound == .bound(sessionID: Self.first, transcriptRoot: "/home/dev/.codex", directory: "/work/app"))

        let grokSessions = """
            [{"session_id":"\(Self.second)","pid":4200,"pid_start":987654321,"cwd":"/work/app"}]
            """
        await files.write(Data(grokSessions.utf8), at: "/home/dev/.grok/active_sessions.json")
        await table.add(.init(pid: 4200, name: "grok", start: Self.linuxStart, environment: linuxEnv))

        let grokBinder = HerdrCoreSessionBinder(
            program: .grok,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { _ in },
            hostSystem: .other,
            processScope: Self.tmuxScope)
        let grokBound = try await grokBinder.check(
            Self.record(pid: 4200, name: "grok", argv: ["grok"]))
        #expect(grokBound == .bound(sessionID: Self.second, transcriptRoot: "/home/dev/.grok", directory: "/work/app"))
    }

    @Test func macOSSIPWithheldPaneShellStillBindsForegroundAgentInTmuxScope() async throws {
        let table = MacOSProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        await table.add(.init(pid: 3999, name: "zsh", start: Self.start, environment: Self.tmuxEnvironment()))
        await table.withholdEnvironment(of: 3999)
        await table.add(
            .init(pid: 4000, parent: 3999, name: "claude", start: Self.start, environment: Self.tmuxEnvironment()))
        await files.write(Self.registryEntry(pid: 4000), at: "\(Self.home)/.claude/sessions/4000.json")

        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { _ in },
            hostSystem: .macOS,
            processScope: Self.tmuxScope)

        let evidence = try await binder.check(Self.record(pid: 3999, name: "claude"))
        #expect(
            evidence
                == .bound(
                    sessionID: Self.first,
                    transcriptRoot: "\(Self.home)/.claude",
                    directory: "/work/app"))
    }

    @Test func paneShellWithoutAnAgentUnderItNeverBindsAsTheAgentWhileALeafRuntimeDoes() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        await table.add(.init(pid: 3999, name: "zsh", start: Self.start, environment: Self.tmuxEnvironment()))
        await files.write(Self.registryEntry(pid: 3999), at: "\(Self.home)/.claude/sessions/3999.json")

        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { _ in },
            hostSystem: .macOS,
            processScope: Self.tmuxScope)

        // When Claude has exited leaving only `zsh` at `pane_pid`, `zsh` is neither
        // bound nor offered for candidate confirmation.
        #expect(try await binder.check(Self.record(pid: 3999, name: "claude")) == .unavailable(.cannotTellSession(.claude)))
        #expect(try await binder.candidates(of: Self.record(pid: 3999, name: "claude")) == .noProcess)

        // A leaf `node` child running `cli.js` under `zsh` binds by its registry entry.
        await table.add(
            .init(pid: 4000, parent: 3999, name: "node", start: Self.start, environment: Self.tmuxEnvironment()))
        await files.write(Self.registryEntry(pid: 4000), at: "\(Self.home)/.claude/sessions/4000.json")
        #expect(
            try await binder.check(Self.record(pid: 3999, name: "node"))
                == .bound(
                    sessionID: Self.first,
                    transcriptRoot: "\(Self.home)/.claude",
                    directory: "/work/app"))
    }

    // MARK: Candidates & picks

    @Test func listsCandidatesAndAppliesPickOnlyForTmuxScopedProcess() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let cleared = ClearedLabels()
        await table.add(.init(pid: 4000, name: "claude", start: Self.start, environment: Self.tmuxEnvironment()))
        await files.write(
            Data("{\"type\":\"user\"}\n".utf8),
            at: "\(Self.home)/.claude/projects/-work-app/\(Self.first).jsonl")

        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { await cleared.record($0) },
            hostSystem: .macOS,
            processScope: Self.tmuxScope)

        let answer = try await binder.candidates(of: Self.record())
        guard case .listed(let listed) = answer else {
            Issue.record("Expected listed candidates, got \(answer)")
            return
        }
        #expect(listed.pid == 4000)
        #expect(listed.start == Self.start)
        #expect(listed.candidates.map(\.sessionID) == [Self.first])

        let pick = try #require(
            HerdrCoreSessionHint.pickLabelValue(session: Self.first, file: nil, pid: 4000, start: Self.start))
        let picked = try await binder.check(Self.record(labels: [HerdrCoreSessionHint.pickLabel: pick]))
        #expect(picked == .picked(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude"))

        // When no process in the pane's scope can be resolved, candidates return `.noProcess`
        // and the pick stands unconfirmed without clearing its label.
        let wrongScopeBinder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: Self.chatFiles(files),
            clearLabels: { await cleared.record($0) },
            hostSystem: .macOS,
            processScope: .tmux(paneID: "%1", socketPath: Self.socketPath, serverPID: Self.serverPID))
        #expect(try await wrongScopeBinder.candidates(of: Self.record()) == .noProcess)
        let unconfirmed = try await wrongScopeBinder.check(Self.record(labels: [HerdrCoreSessionHint.pickLabel: pick]))
        #expect(unconfirmed == .pickUnconfirmed(.cannotTellSession(.claude)))
        #expect(await cleared.batches.isEmpty)

        // Once a new process replaces it in the pane's scope, the stale pick drops and clears.
        await table.add(.init(pid: 4001, name: "claude", start: Self.start, environment: Self.tmuxEnvironment()))
        let dropped = try await binder.check(
            Self.record(pid: 4001, labels: [HerdrCoreSessionHint.pickLabel: pick]))
        #expect(dropped == .unavailable(.cannotTellSession(.claude)))
        #expect(await cleared.batches == [[HerdrCoreSessionHint.pickLabel: pick]])
    }
}
