import Foundation
import Testing

@testable import Heeler

/// Session binding for Rex terminals (ADR 0034): processes match by the
/// `REX_SESSION` and `REX_BLOCK` Rex gives every program in a terminal, from
/// the foreground Rex names, which counts only under a name Rex gave it. A
/// process in a multiplexer run inside the terminal is in another terminal.
/// Rex gives no argv past the first argument and no process of the
/// terminal's own, so a Codex's launch is read from its own process, and
/// what needs the rest cannot tell or leaves it to a pick.
@Suite("Rex session binder", .timeLimit(.minutes(1)))
struct RexSessionBinderTests {
    private static let first = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let second = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
    private static let sessionID = "session:0000-0000-0000-00000000c0c0"
    private static let blockID = "block:0000-0000-0000-00000000d0d0"
    private static let home = "/Users/dev"
    private static let start = "Thu Nov 12 06:00:00 2026"
    private static let linuxStart = "987654321"

    private static func scope(
        session: String = sessionID, block: String = blockID, names: Set<String> = ["claude"]
    ) -> HerdrCoreSessionBinder.ProcessScope {
        .rex(sessionID: session, blockID: block, foregroundNames: names)
    }

    private static func rexEnvironment(
        session: String = sessionID, block: String = blockID, home: String = home
    ) -> [String: String] {
        [
            "REX_SESSION": session,
            "REX_BLOCK": block,
            "REX_SERVER": "unix://%2Frun%2Fuser%2F1000%2Frex%2Fserver.sock",
            "HOME": home,
        ]
    }

    private static func record(
        pid: Int? = 4000, program: String = "claude", directory: String = "/work/app", pick: String? = nil
    ) -> HerdrCoreTerminalRecord {
        HerdrCoreTerminalRecord(
            rexTerminal: RexTerminalDetails(program: program, directory: directory, processID: pid, argv0: program),
            paneID: RexPaneAddress(sessionID: sessionID, blockID: blockID).paneID, chatPick: pick)
    }

    private static func registryEntry(pid: Int = 4000, session: String = first, procStart: String = start) -> Data {
        Data(
            """
            {"pid":\(pid),"sessionId":"\(session)","cwd":"/work/app","startedAt":1780000000000,\
            "procStart":"\(procStart)","version":"2.1.314","kind":"interactive","entrypoint":"cli",\
            "status":"idle","updatedAt":1780000000000}
            """.utf8)
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
            home: { try await files.home() })
    }

    private static func binder(
        _ program: ChatProgram = .claude, table: ScriptedProcessTable, files: VirtualHostFiles,
        cleared: ClearedLabels = ClearedLabels(), hostSystem: HerdrCoreHostSystem = .macOS,
        scope: HerdrCoreSessionBinder.ProcessScope = scope()
    ) -> HerdrCoreSessionBinder {
        HerdrCoreSessionBinder(
            program: program,
            processes: { try await table.read($0) },
            files: chatFiles(files),
            clearLabels: { await cleared.record($0) },
            hostSystem: hostSystem,
            processScope: scope)
    }

    // MARK: The record

    /// A Rex terminal's record holds what Rex names of its foreground and
    /// this device's pick, and nothing Rex does not give.
    @Test func aRexTerminalsRecordHoldsOnlyWhatRexGives() {
        let pick = "{\"pid\":4000,\"session\":\"\(Self.first)\",\"start\":\"\(Self.start)\"}"
        let record = Self.record(program: "2.1.316", pick: pick)

        #expect(record.pid == nil)
        #expect(record.argv.isEmpty)
        #expect(record.cwd == "/work/app")
        #expect(record.foreground == HerdrCoreForeground(pid: 4000, name: "2.1.316", argv: [], cwd: "/work/app"))
        #expect(record.labels == [HerdrCoreSessionHint.pickLabel: pick])
        #expect(Self.record(pid: nil).foreground == nil)
        #expect(Self.record().labels.isEmpty)
    }

    // MARK: Scope matching

    /// Claude Code in the terminal binds by its registry entry, from one exec
    /// that reads Rex's variables and those of a nested multiplexer, and
    /// nothing of herdr's.
    @Test func bindsClaudeCodeInItsBlock() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        await table.add(.init(pid: 4000, name: "claude", start: Self.start, environment: Self.rexEnvironment()))
        await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/4000.json")

        let evidence = try await Self.binder(table: table, files: files).check(Self.record())

        #expect(evidence == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
        let request = try #require(await table.requests.first)
        #expect(await table.requests.count == 1)
        #expect(request.pids == ["4000"])
        #expect(request.descendantsOf == "4000")
        #expect(request.readsStart)
        #expect(
            Array(request.valuesOf.prefix(5)) == ["REX_SESSION", "REX_BLOCK", "TMUX", "TMUX_PANE", "HC_SCOPE"])
        #expect(!(request.valuesOf + request.namesOf).contains { $0.hasPrefix("HERDR_") || $0 == "REX_SERVER" })
    }

    @Test(arguments: [
        ("another block", ["REX_SESSION": Self.sessionID, "REX_BLOCK": "block:other", "HOME": Self.home]),
        ("another session", ["REX_SESSION": "session:other", "REX_BLOCK": Self.blockID, "HOME": Self.home]),
        ("no block", ["REX_SESSION": Self.sessionID, "HOME": Self.home]),
        ("no session", ["REX_BLOCK": Self.blockID, "HOME": Self.home]),
        ("no Rex at all", ["HOME": Self.home]),
    ])
    func rejectsAProcessOutsideTheTerminal(_ label: String, _ environment: [String: String]) async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        await table.add(.init(pid: 4000, name: "claude", start: Self.start, environment: environment))
        await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/4000.json")

        let evidence = try await Self.binder(table: table, files: files).check(Self.record())

        #expect(evidence == .unavailable(.cannotTellSession(.claude)), "\(label)")
    }

    /// A Codex under npm's launcher binds by the rollout its native process
    /// holds, unless that process runs in a tmux or herdr-core inside the
    /// terminal: then it is another terminal's, and the launcher alone holds
    /// nothing. A terminal whose server itself runs in tmux carries the same
    /// `TMUX` all the way down, and still binds.
    @Test(arguments: [
        ("same terminal", [:], [:], true),
        ("nested tmux", [:], ["TMUX": "/tmp/tmux-1000/nested,7777,0", "TMUX_PANE": "%3"], false),
        ("nested herdr-core", [:], ["HC_SCOPE": "scope-1"], false),
        (
            "server in tmux", ["TMUX": "/tmp/tmux-1000/default,4242,0", "TMUX_PANE": "%0"],
            ["TMUX": "/tmp/tmux-1000/default,4242,0", "TMUX_PANE": "%0"], true
        ),
        (
            "nested tmux in a server in tmux", ["TMUX": "/tmp/tmux-1000/default,4242,0", "TMUX_PANE": "%0"],
            ["TMUX": "/tmp/tmux-1000/nested,7777,0", "TMUX_PANE": "%3"], false
        ),
    ] as [(String, [String: String], [String: String], Bool)])
    func aProcessInANestedMultiplexerIsAnotherTerminals(
        _ label: String, outer: [String: String], inner: [String: String], binds: Bool
    ) async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/dev")
        let rollout = "/home/dev/.codex/sessions/2026/11/12/rollout-2026-11-12T06-00-00-\(Self.first).jsonl"
        let head = #"{"type":"session_meta","payload":{"id":"\#(Self.first)","cwd":"/work/app","source":"cli"}}"#
        await files.write(Data((head + "\n").utf8), at: rollout)
        let environment = Self.rexEnvironment(home: "/home/dev")
        await table.add(
            .init(
                pid: 4100, name: "node", start: Self.linuxStart,
                environment: environment.merging(outer) { $1 }))
        await table.add(
            .init(
                pid: 4110, parent: 4100, name: "codex", start: Self.linuxStart,
                environment: environment.merging(outer) { $1 }.merging(inner) { $1 }, openFiles: [rollout]))

        let evidence = try await Self.binder(
            .codex, table: table, files: files, hostSystem: .other, scope: Self.scope(names: ["node"])
        ).check(Self.record(pid: 4100, program: "node"))

        let bound = ChatSessionEvidence.bound(sessionID: Self.first, transcriptRoot: "/home/dev/.codex", directory: "/work/app")
        #expect((evidence == bound) == binds, "\(label)")
        if !binds { #expect(evidence == .unavailable(.cannotTellSession(.codex)), "\(label)") }
    }

    // MARK: A reused pid

    /// The pid Rex named, read under no name Rex gave it, is another process
    /// by now: it binds nothing, and a pick stands unconfirmed for the next
    /// check rather than going.
    @Test func aPidReadUnderAnotherNameSaysNothing() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let cleared = ClearedLabels()
        await table.add(.init(pid: 4000, name: "vim", start: Self.start, environment: Self.rexEnvironment()))
        await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/4000.json")
        let binder = Self.binder(table: table, files: files, cleared: cleared)

        #expect(try await binder.check(Self.record()) == .unavailable(.cannotTellSession(.claude)))
        #expect(try await binder.candidates(of: Self.record()) == .noProcess)

        let pick = try #require(
            HerdrCoreSessionHint.pickLabelValue(session: Self.first, file: nil, pid: 4000, start: Self.start))
        #expect(try await binder.check(Self.record(pick: pick)) == .pickUnconfirmed(.cannotTellSession(.claude)))
        #expect(await cleared.batches.isEmpty)
    }

    /// Past the walk's cap the read names no process, the foreground included.
    /// One carrying the terminal's own variables still binds by its registry
    /// entry, as on the other kinds. A walk that answered without it says it is
    /// gone, and one in another terminal is not this one's.
    @Test(arguments: [
        ("past the cap", false, Self.sessionID, true),
        ("gone", true, Self.sessionID, false),
        ("another terminal", false, "session:other", false),
    ] as [(String, Bool, String, Bool)])
    func aForegroundTheWalkNamesNoneOf(_ label: String, walked: Bool, session: String, binds: Bool) async throws {
        let files = VirtualHostFiles(home: Self.home)
        await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/4000.json")
        let environment = Self.rexEnvironment(session: session)
        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { request in
                var fact = HostProcessReader.Facts()
                fact.start = .value(Self.start)
                for name in request.valuesOf {
                    fact.variables[name] = environment[name].map(HostProcessReader.Variable.value) ?? .unset
                }
                fact.nonEmptyNames = .value([])
                if walked { fact.descendants = .value([]) }
                return ["4000": fact]
            },
            files: Self.chatFiles(files), clearLabels: { _ in }, hostSystem: .macOS, processScope: Self.scope())

        let evidence = try await binder.check(Self.record())

        #expect(
            evidence
                == (binds
                    ? .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app")
                    : .unavailable(.cannotTellSession(.claude))),
            "\(label)")
    }

    /// Rex's name for a native install is the versioned binary's, the read's
    /// is argv[0]'s on a Mac and the kernel's on Linux, cut to 15 bytes.
    @Test func aForegroundIsReadUnderAnyNameRexGaveIt() {
        #expect(HerdrCoreTerminalProcesses.isNamed("claude", oneOf: ["2.1.316", "claude"]))
        #expect(HerdrCoreTerminalProcesses.isNamed("2.1.316", oneOf: ["2.1.316", "claude"]))
        #expect(HerdrCoreTerminalProcesses.isNamed("a-very-long-pro", oneOf: ["a-very-long-program"]))
        #expect(!HerdrCoreTerminalProcesses.isNamed("a-very-long-pr", oneOf: ["a-very-long-program"]))
        #expect(!HerdrCoreTerminalProcesses.isNamed("vim", oneOf: ["claude"]))
        #expect(!HerdrCoreTerminalProcesses.isNamed("-", oneOf: ["claude"]))
        #expect(!HerdrCoreTerminalProcesses.isNamed("claude", oneOf: []))
    }

    /// A start that moved is another run of the same name: its registry entry
    /// and a pick of the old one bind nothing, and the pick goes.
    @Test func anotherRunUnderTheSamePidBindsNothing() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let cleared = ClearedLabels()
        let later = "Thu Nov 12 07:00:00 2026"
        await table.add(.init(pid: 4000, name: "claude", start: later, environment: Self.rexEnvironment()))
        await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/4000.json")
        let binder = Self.binder(table: table, files: files, cleared: cleared)

        let pick = try #require(
            HerdrCoreSessionHint.pickLabelValue(session: Self.first, file: nil, pid: 4000, start: Self.start))
        #expect(try await binder.check(Self.record(pick: pick)) == .unavailable(.cannotTellSession(.claude)))
        #expect(await cleared.batches == [[HerdrCoreSessionHint.pickLabel: pick]])
    }

    // MARK: macOS and Codex

    /// A foreground whose environment a Mac withholds, as a script run by
    /// `/bin/sh` is, still leads to the Agent under it, and only to one in no
    /// multiplexer of its own.
    @Test func aWithheldForegroundOnAMacStillFindsTheAgentUnderIt() async throws {
        let cases: [(inner: [String: String], binds: Bool)] = [
            ([:], true), (["TMUX": "/private/tmp/tmux-501/nested,7777,0"], false),
        ]
        for (inner, binds) in cases {
            let table = MacOSProcessTable()
            let files = VirtualHostFiles(home: Self.home)
            await table.add(.init(pid: 3999, name: "sh", start: Self.start, environment: Self.rexEnvironment()))
            await table.withholdEnvironment(of: 3999)
            await table.add(
                .init(
                    pid: 4000, parent: 3999, name: "claude", start: Self.start,
                    environment: Self.rexEnvironment().merging(inner) { $1 }))
            await files.write(Self.registryEntry(), at: "\(Self.home)/.claude/sessions/4000.json")
            let binder = HerdrCoreSessionBinder(
                program: .claude, processes: { try await table.read($0) }, files: Self.chatFiles(files),
                clearLabels: { _ in }, hostSystem: .macOS, processScope: Self.scope(names: ["sh"]))

            let evidence = try await binder.check(Self.record(pid: 3999, program: "sh"))

            #expect(
                evidence
                    == (binds
                        ? .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app")
                        : .unavailable(.cannotTellSession(.claude))))
        }
    }

    /// Rex names no command line, so a Codex's launch is read from its own
    /// process, keeping only the words that decide it. One on the shared
    /// server, holding no rollout beside that server's socket, gets the
    /// server's notice and no candidate list, as on the other kinds: every
    /// window there looks alike. A launch that keeps its own server, or a
    /// subcommand without the terminal UI, cannot tell and lists. A `--remote`
    /// address never leaves the Host, so any `--remote` counts as the shared
    /// server.
    @Test(arguments: [
        ("default", ["codex"], true),
        ("resume", ["/opt/homebrew/bin/codex", "resume", "--last"], true),
        ("a model", ["codex", "-m", "o3"], true),
        ("remote", ["codex", "--remote", "unix://"], true),
        ("remote elsewhere", ["codex", "--remote=ws://example.invalid:4500"], true),
        ("no daemon after --", ["codex", "--", "--no-daemon"], true),
        ("no daemon", ["codex", "--no-daemon"], false),
        ("a config", ["codex", "-c", "model=o3"], false),
        ("a profile", ["codex", "--profile=work"], false),
        ("exec", ["codex", "exec", "--no-daemon"], false),
    ] as [(String, [String], Bool)])
    func aCodexOnTheSharedServerGetsItsNoticeAndNoList(
        _ label: String, argv: [String], onSharedServer: Bool
    ) async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/dev")
        await files.write(Data(), at: "/home/dev/.codex/app-server-control/app-server-control.sock")
        await table.add(
            .init(
                pid: 4100, name: "codex", start: Self.linuxStart, environment: Self.rexEnvironment(home: "/home/dev"),
                argv: argv))
        let binder = Self.binder(
            .codex, table: table, files: files, hostSystem: .other, scope: Self.scope(names: ["codex"]))
        let record = Self.record(pid: 4100, program: "codex")

        let evidence = try await binder.check(record)
        let candidates = try await binder.candidates(of: record)

        if onSharedServer {
            #expect(evidence == .unavailable(.codexSharedDaemon), "\(label)")
            #expect(candidates == .sharedDaemon, "\(label)")
        } else {
            #expect(evidence == .unavailable(.cannotTellSession(.codex)), "\(label)")
            guard case .listed(let listed) = candidates else {
                Issue.record("Expected listed candidates: \(label)")
                return
            }
            #expect(listed.pid == 4100, "\(label)")
        }
        let request = try #require(await table.requests.first)
        #expect(request.preservesArgumentOrder)
        #expect(Set(CodexLaunch.launchWords).isSubset(of: Set(request.argumentsAmong)))
    }

    /// Without its socket no shared server runs, so a Codex holding nothing
    /// cannot tell, and a pick stays possible.
    @Test func aCodexWithNoSharedServerRunningCannotTell() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/dev")
        await table.add(
            .init(
                pid: 4100, name: "codex", start: Self.linuxStart, environment: Self.rexEnvironment(home: "/home/dev"),
                argv: ["codex"]))
        let binder = Self.binder(
            .codex, table: table, files: files, hostSystem: .other, scope: Self.scope(names: ["codex"]))

        #expect(try await binder.check(Self.record(pid: 4100, program: "codex")) == .unavailable(.cannotTellSession(.codex)))
    }

    // MARK: Candidates and picks

    /// Candidates list for the process in the terminal, and a pick holds to
    /// that process; outside the terminal nothing is listed, and a pick
    /// stands unconfirmed without going.
    @Test func listsCandidatesAndHoldsAPickToItsProcess() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let cleared = ClearedLabels()
        await table.add(.init(pid: 4000, name: "claude", start: Self.start, environment: Self.rexEnvironment()))
        await files.write(
            Data("{\"type\":\"user\"}\n".utf8), at: "\(Self.home)/.claude/projects/-work-app/\(Self.first).jsonl")
        let binder = Self.binder(table: table, files: files, cleared: cleared)

        guard case .listed(let listed) = try await binder.candidates(of: Self.record()) else {
            Issue.record("Expected listed candidates")
            return
        }
        #expect(listed.pid == 4000)
        #expect(listed.start == Self.start)
        #expect(listed.directories == ["/work/app"])
        #expect(listed.candidates.map(\.sessionID) == [Self.first])

        let pick = try #require(
            HerdrCoreSessionHint.pickLabelValue(session: Self.first, file: nil, pid: 4000, start: Self.start))
        #expect(
            try await binder.check(Self.record(pick: pick))
                == .picked(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude"))

        let elsewhere = Self.binder(
            table: table, files: files, cleared: cleared, scope: Self.scope(block: "block:other"))
        #expect(try await elsewhere.candidates(of: Self.record()) == .noProcess)
        #expect(try await elsewhere.check(Self.record(pick: pick)) == .pickUnconfirmed(.cannotTellSession(.claude)))
        #expect(await cleared.batches.isEmpty)
    }

    /// A terminal whose foreground Rex has yet to name runs no exec: it
    /// cannot tell, lists nothing, and its pick stands unconfirmed.
    @Test func aTerminalWithNoForegroundRunsNothing() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let binder = Self.binder(table: table, files: files)
        let pick = try #require(
            HerdrCoreSessionHint.pickLabelValue(session: Self.first, file: nil, pid: 4000, start: Self.start))

        #expect(try await binder.check(Self.record(pid: nil)) == .unavailable(.cannotTellSession(.claude)))
        #expect(try await binder.check(Self.record(pid: nil, pick: pick)) == .pickUnconfirmed(.cannotTellSession(.claude)))
        #expect(try await binder.candidates(of: Self.record(pid: nil)) == .noProcess)
        #expect(await table.requests.isEmpty)
    }
}
