import Testing

@testable import Heeler

@Suite("tmux organization")
struct TmuxOrganizationTests {
    private let instance = TmuxServerInstance(pid: 4100, startTime: 1_794_000_000)

    private func build(_ panes: [TmuxInventory.Pane]) -> SessionSnapshot {
        TmuxOrganization.build(TmuxInventory(instance: instance, panes: panes)).snapshot
    }

    @Test func sessionsWindowsAndPanesKeepTmuxsNamesAndOrder() {
        // As `list-panes -a` gives them: sessions by name, windows and panes by index.
        let snapshot = build([
            .make(session: 3, sessionName: "api", window: 7, windowIndex: 1, windowName: "server", pane: 9),
            .make(session: 3, sessionName: "api", window: 7, windowIndex: 1, windowName: "server", pane: 12, paneIndex: 1),
            .make(session: 3, sessionName: "api", window: 2, windowIndex: 4, windowName: "logs", pane: 4),
            .make(session: 0, sessionName: "web", window: 0, windowIndex: 0, windowName: "", pane: 0, path: "/srv/web"),
        ])

        #expect(snapshot.workspaces.map(\.workspaceID) == ["$3", "$0"])
        #expect(snapshot.workspaces.map(\.label) == ["api", "web"])
        #expect(snapshot.workspaces.map(\.number) == [1, 2])
        #expect(snapshot.workspaces.map(\.tabCount) == [2, 1])
        #expect(snapshot.workspaces.map(\.paneCount) == [3, 1])
        #expect(snapshot.workspaces.map(\.activeTabID) == ["@7", "@0"])

        #expect(snapshot.tabs.map(\.tabID) == ["@7", "@2", "@0"])
        #expect(snapshot.tabs.map(\.label) == ["server", "logs", ""])
        #expect(snapshot.tabs.map(\.number) == [1, 4, 0])
        #expect(snapshot.tabs.map(\.workspaceID) == ["$3", "$3", "$0"])
        #expect(snapshot.tabs.map(\.paneCount) == [2, 1, 1])

        #expect(snapshot.panes.map(\.paneID) == ["%9", "%12", "%4", "%0"])
        #expect(snapshot.panes.map(\.terminalID) == ["%9", "%12", "%4", "%0"])
        #expect(snapshot.panes.map(\.tabID) == ["@7", "@7", "@2", "@0"])
        #expect(snapshot.panes.map(\.workspaceID) == ["$3", "$3", "$3", "$0"])
        #expect(snapshot.panes.last?.foregroundCwd == "/srv/web")
        #expect(snapshot.panes.last?.title == "zsh")
        #expect(snapshot.agents.isEmpty)
    }

    @Test func aWindowSharedBySeveralSessionsShowsOnceUnderTheLowestID() {
        // `$10` sorts before `$2` as text and after it as a number.
        let shared = { (session: Int, name: String, index: Int) in
            TmuxInventory.Pane.make(
                session: session, sessionName: name, window: 5, windowIndex: index, windowName: "shared", pane: 8,
                command: "claude", arguments: ["claude"])
        }
        let snapshot = build([
            shared(10, "alpha", 0),
            .make(session: 10, sessionName: "alpha", window: 6, windowIndex: 1, windowName: "own", pane: 9),
            shared(2, "beta", 3),
            shared(4, "gamma", 0),
        ])

        #expect(snapshot.workspaces.map(\.workspaceID) == ["$10", "$2"])
        #expect(snapshot.workspaces.map(\.tabCount) == [1, 1])
        #expect(snapshot.tabs.map(\.tabID) == ["@6", "@5"])
        #expect(snapshot.tabs.map(\.workspaceID) == ["$10", "$2"])
        #expect(snapshot.tabs.map(\.number) == [1, 3])
        #expect(snapshot.panes.map(\.paneID) == ["%9", "%8"])
        #expect(snapshot.agents.map(\.paneID) == ["%8"])
        #expect(snapshot.agents.map(\.workspaceID) == ["$2"])
    }

    @Test func aGroupedSessionWithNoWindowOfItsOwnIsNotListed() {
        let snapshot = build([
            .make(session: 1, sessionName: "main", window: 0, pane: 0),
            .make(session: 1, sessionName: "main", window: 1, windowIndex: 1, pane: 1),
            .make(session: 2, sessionName: "main-2", window: 0, pane: 0),
            .make(session: 2, sessionName: "main-2", window: 1, windowIndex: 1, pane: 1),
        ])
        #expect(snapshot.workspaces.map(\.label) == ["main"])
        #expect(snapshot.panes.map(\.paneID) == ["%0", "%1"])
    }

    @Test func aWindowOneSessionLinksTwiceShowsAtItsFirstIndex() {
        let snapshot = build([
            .make(window: 0, windowIndex: 0, pane: 0),
            .make(window: 0, windowIndex: 0, pane: 1, paneIndex: 1),
            .make(window: 0, windowIndex: 5, pane: 0),
            .make(window: 0, windowIndex: 5, pane: 1, paneIndex: 1),
        ])
        #expect(snapshot.tabs.map(\.number) == [0])
        #expect(snapshot.tabs.map(\.paneCount) == [2])
        #expect(snapshot.panes.map(\.paneID) == ["%0", "%1"])
        #expect(snapshot.workspaces.map(\.paneCount) == [2])
    }

    @Test func heelersOwnSessionsNeverShow() {
        let snapshot = build([
            // Heeler's session has the lowest id and links the user's window.
            .make(session: 0, sessionName: "heeler-1", window: 3, windowIndex: 0, windowName: "work", pane: 3, attachMark: "1"),
            .make(session: 0, sessionName: "heeler-1", window: 9, windowIndex: 1, windowName: "hold", pane: 20, attachMark: "1"),
            .make(session: 1, sessionName: "main", window: 3, windowIndex: 0, windowName: "work", pane: 3),
        ])
        #expect(snapshot.workspaces.map(\.label) == ["main"])
        #expect(snapshot.tabs.map(\.tabID) == ["@3"])
        #expect(snapshot.tabs.map(\.workspaceID) == ["$1"])
        #expect(snapshot.panes.map(\.paneID) == ["%3"])

        // With the user's session gone, the window Heeler still links is not listed either.
        let alone = build([
            .make(session: 0, sessionName: "heeler-1", window: 3, pane: 3, attachMark: "1")
        ])
        #expect(alone.workspaces.isEmpty)
        #expect(alone.tabs.isEmpty)
        #expect(alone.panes.isEmpty)
    }

    @Test func aPaneIsAnAgentWhileAKnownProgramHoldsItsForeground() {
        let snapshot = build([
            .make(pane: 0, command: "node", path: "/srv/app", arguments: ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js"]),
            .make(pane: 1, paneIndex: 1, command: "zsh", arguments: ["-zsh"]),
            .make(pane: 2, paneIndex: 2, command: "vim", arguments: ["vim", "notes.md"]),
            .make(pane: 3, paneIndex: 3, command: "claude", isDead: true, arguments: ["claude"]),
            .make(pane: 4, paneIndex: 4, command: "sh", status: "state=working:app=claude-code", arguments: ["sh", "-c", "exec claude"]),
        ])

        #expect(snapshot.panes.map(\.paneID) == ["%0", "%1", "%2", "%3", "%4"])
        #expect(snapshot.panes.map(\.agent) == ["codex", nil, nil, nil, "claude"])
        #expect(snapshot.agents.map(\.paneID) == ["%0", "%4"])
        #expect(snapshot.agents.map(\.agent) == ["codex", "claude"])
        // A status is read by a later change; until then every Agent reads Unknown.
        #expect(snapshot.agents.map(\.agentStatus) == [.unknown, .unknown])
        #expect(snapshot.agents.first?.foregroundCwd == "/srv/app")
        #expect(snapshot.agents.first?.terminalTitleStripped == AgentNotificationIdentity.kindLabel("codex"))
        #expect(snapshot.agents.first?.tabID == "@0")
        #expect(snapshot.agents.first?.workspaceID == "$0")
    }

    @Test func theShownPanesAreThoseOfTheSnapshot() {
        let result = TmuxOrganization.build(
            TmuxInventory(
                instance: instance,
                panes: [
                    .make(session: 0, window: 0, pane: 0, width: 120, height: 40),
                    .make(session: 5, sessionName: "other", window: 0, pane: 0, width: 120, height: 40),
                    .make(session: 9, sessionName: "heeler", window: 2, pane: 2, attachMark: "1"),
                ]))
        #expect(result.panes.map(\.paneID) == result.snapshot.panes.map(\.paneID))
        #expect(result.panes.map(\.sessionID) == ["$0"])
        #expect(result.panes.map(\.width) == [120])
    }

    @Test func aServerWithNoPaneListsNothing() {
        let snapshot = build([])
        #expect(snapshot.workspaces.isEmpty && snapshot.tabs.isEmpty && snapshot.panes.isEmpty && snapshot.agents.isEmpty)
    }
}
