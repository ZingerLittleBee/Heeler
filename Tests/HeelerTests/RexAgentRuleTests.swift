import Testing

@testable import Heeler

/// Which Rex terminal is an Agent and the status it reads (ADR 0054): the
/// foreground read by the rule every kind uses, from what Rex gives of it, and
/// the root Program Status only while its owner is that foreground. Forms are
/// those seen on Rex 0.1.0-preview.14 with invented paths and ids.
@Suite("Rex agent rule")
struct RexAgentRuleTests {
    private func details(
        _ program: String?, argv0: String? = nil, script: String? = nil, processID: Int? = 77,
        status: RexProgramStatus? = nil
    ) -> RexTerminalDetails {
        RexTerminalDetails(
            title: nil, program: program, directory: "/home/dev/app", processID: processID, argv0: argv0,
            script: script, status: status)
    }

    @Test(arguments: [
        ("codex", "codex", nil, "codex"),
        ("codex", "/opt/homebrew/bin/codex", nil, "codex"),
        // Claude Code's native install runs a binary named for its version.
        ("2.1.316", "claude", nil, "claude"),
        // An interpreter is read through its script, or the title it set.
        ("node", "node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "claude"),
        ("node", "node", "/usr/local/bin/gemini", "gemini"),
        ("node", "claude", nil, "claude"),
        ("Python", "/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python", "/home/dev/bin/claude", "claude"),
        // No first argument, as for another user's process: the name speaks.
        ("codex", nil, nil, "codex"),
    ] as [(String, String?, String?, String)])
    func aKnownAgentProgramInTheForegroundIsAnAgent(name: String, argv0: String?, script: String?, kind: String) {
        #expect(RexAgentRule.agentKind(in: details(name, argv0: argv0, script: script)) == kind)
    }

    @Test(arguments: [
        ("bash", "-bash", nil), ("zsh", "-zsh", nil), ("fish", "-fish", nil), ("bash", "sh", nil),
        // A program Rex started under `login` hides behind it.
        ("login", nil, nil),
        ("vim", "vim", nil), ("node", "node", "/srv/app/server.js"),
        ("Python", "python3", "/home/dev/tools/report.py"),
    ] as [(String, String?, String?)])
    func aShellOrAnyOtherProgramIsATerminalOnly(name: String, argv0: String?, script: String?) {
        // Whatever it reported: a known app does not make an Agent.
        let reported = RexProgramStatus(state: "working", app: "codex", ownerProcessID: 77, ownerName: name)
        #expect(RexAgentRule.agentKind(in: details(name, argv0: argv0, script: script, status: reported)) == nil)
    }

    @Test func noForegroundIsNoAgent() {
        #expect(RexAgentRule.agentKind(in: details(nil, argv0: "codex")) == nil)
    }

    // MARK: Status

    private func status(
        _ state: String, app: String? = "codex", owner: (pid: Int, name: String)? = (77, "codex"),
        foreground: (pid: Int?, name: String) = (77, "codex")
    ) -> AgentStatus {
        let report = RexProgramStatus(state: state, app: app, ownerProcessID: owner?.pid, ownerName: owner?.name)
        let terminal = details(foreground.name, argv0: foreground.name, processID: foreground.pid, status: report)
        return RexAgentRule.status(of: terminal, heldBy: "codex")
    }

    /// The words map as on every other kind, and a word Heeler does not know
    /// is Unknown. Done and idle read Idle here: Done is per device, this
    /// device's turns' to say (`RexTurnState`).
    @Test(arguments: [
        ("idle", AgentStatus.idle), ("done", .idle), ("working", .working), ("blocked", .blocked),
        ("error", .error), ("thinking", .unknown), ("WORKING", .unknown),
    ])
    func eachStateReadsAsOnTheOtherKinds(state: String, expected: AgentStatus) {
        #expect(status(state) == expected)
    }

    @Test func noReportIsUnknown() {
        #expect(RexAgentRule.status(of: details("codex", argv0: "codex"), heldBy: "codex") == .unknown)
    }

    /// A report counts only while its owner is the foreground by process id
    /// and name: Rex keeps an exited program's idle, done and error records,
    /// and process ids come back.
    @Test func aReportFromAnotherProcessIsUnknown() {
        #expect(status("idle", owner: (76, "codex")) == .unknown)
        #expect(status("idle", owner: (77, "bash")) == .unknown)
        #expect(status("idle", owner: nil) == .unknown)
        #expect(status("idle", foreground: (nil, "codex")) == .unknown)
    }

    /// A report whose app names another known program is that program's;
    /// an app Heeler does not know, or none, does not say so.
    @Test func aReportFromAnotherKnownProgramIsUnknown() {
        #expect(status("working", app: "claude-code") == .unknown)
        #expect(status("working", app: "Codex") == .working)
        #expect(status("working", app: "make") == .working)
        #expect(status("working", app: nil) == .working)
    }

    /// The record stays while the foreground moves, and is read again each
    /// time: a report made before its program's process change applies once
    /// that change arrives, and a program that left takes its status with it.
    @Test func theRecordIsCheckedAgainAsTheForegroundMoves() {
        let report = RexProgramStatus(state: "working", app: "codex", ownerProcessID: 77, ownerName: "codex")
        var terminal = details("bash", argv0: "-bash", processID: 70, status: report)
        #expect(RexAgentRule.agentKind(in: terminal) == nil)

        terminal.noteForeground(.init(program: "codex", directory: "/home/dev/app", processID: 77, argv0: "codex"))
        #expect(RexAgentRule.agentKind(in: terminal) == "codex")
        #expect(RexAgentRule.status(of: terminal, heldBy: "codex") == .working)

        terminal.noteForeground(.init(program: "codex", directory: "/home/dev/app", processID: 99, argv0: "codex"))
        #expect(RexAgentRule.status(of: terminal, heldBy: "codex") == .unknown)
    }

    // MARK: The Console's rows

    /// A terminal running an agent is listed as an Agent and as an Agent Pane,
    /// reading as its title, or its kind before it sets one, named as its block
    /// is; the others stay Terminals.
    @Test func theOrganizationListsAgentsBesideTerminals() throws {
        let report = RexProgramStatus(state: "blocked", app: "claude-code", ownerProcessID: 77, ownerName: "2.1.316")
        var claude = details("2.1.316", argv0: "claude", status: report)
        claude.title = "✳ Fix the build"
        let codex = details("codex", argv0: "codex")
        let shell = details("zsh", argv0: "-zsh")
        let inventory = RexInventory(sessions: [
            RexInventory.Session(
                id: "session:studio", label: "studio", activeWindowID: "window:a",
                windows: [
                    RexInventory.Window(
                        id: "window:a", label: "editor",
                        terminals: [
                            .init(blockID: "block:claude", label: "review", owner: nil, details: claude),
                            .init(blockID: "block:codex", label: nil, owner: nil, details: codex),
                            .init(blockID: "block:shell", label: nil, owner: nil, details: shell),
                        ])
                ],
                detached: [])
        ])

        let snapshot = RexOrganization.build(inventory)

        #expect(snapshot.agents.map(\.agent) == ["claude", "codex"])
        #expect(snapshot.agents.map(\.agentStatus) == [.blocked, .unknown])
        #expect(snapshot.agents.map(\.terminalTitleStripped) == ["Fix the build", "Codex"])
        #expect(snapshot.agents.map(\.name) == ["review", nil])
        #expect(snapshot.agents.map(\.workspaceID) == ["session:studio", "session:studio"])
        #expect(snapshot.agents.map(\.tabID) == ["window:a", "window:a"])
        #expect(snapshot.agents.map(\.cwd) == ["/home/dev/app", "/home/dev/app"])
        #expect(snapshot.panes.map(\.agent) == ["claude", "codex", nil])
        #expect(snapshot.panes.map(\.agentStatus) == [.blocked, .unknown, .unknown])
    }

    /// An Agent whose finished turn this device has not seen reads Done while
    /// its record reads Idle, and only then: not while it works, nor while its
    /// record is not its own.
    @Test func anUnseenFinishedTurnReadsDone() {
        func terminal(_ blockID: String, _ state: String, owner: Int = 77) -> RexInventory.Terminal {
            let report = RexProgramStatus(state: state, app: "codex", ownerProcessID: owner, ownerName: "codex")
            return .init(blockID: blockID, label: nil, owner: nil, details: details("codex", argv0: "codex", status: report))
        }
        let terminals = [
            terminal("block:done", "done"), terminal("block:idle", "idle"), terminal("block:working", "working"),
            terminal("block:stale", "done", owner: 76), terminal("block:seen", "done"),
        ]
        let inventory = RexInventory(sessions: [
            RexInventory.Session(
                id: "session:studio", label: "studio", activeWindowID: "window:a",
                windows: [RexInventory.Window(id: "window:a", label: nil, terminals: terminals)], detached: [])
        ])
        let unseen = ["block:done", "block:idle", "block:working", "block:stale"].map {
            RexPaneAddress(sessionID: "session:studio", blockID: $0).paneID
        }

        let snapshot = RexOrganization.build(inventory, doneTerminals: Set(unseen))

        #expect(snapshot.agents.map(\.agentStatus) == [.done, .done, .working, .unknown, .idle])
        #expect(snapshot.panes.map(\.agentStatus) == [.done, .done, .working, .unknown, .idle])
    }
}
