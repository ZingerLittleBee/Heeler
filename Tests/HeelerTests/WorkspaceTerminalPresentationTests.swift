import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Workspace terminal presentation", .serialized, .timeLimit(.minutes(1)))
struct WorkspaceTerminalPresentationTests {
    @Test func drawerListsTerminalsInTabOrder() {
        #expect(WorkspaceTerminalDrawer.ordered(Self.terminals()).map(\.paneID) == ["agent", "server", "tests"],
                "Tab order, then Pane order, whatever the snapshot order")
    }

    @Test func drawerNamesAgentsByTheirTitleBesideTheirTab() throws {
        let terminals = Self.terminals()
        let agent = try #require(terminals.first { $0.isAgent })
        let name = WorkspaceTerminalDrawer.rowName(for: agent)
        #expect(name.title == agent.displayTitle)
        #expect(name.tab == agent.displayTabTitle)

        let shell = try #require(terminals.first { $0.paneID == "server" })
        let row = TerminalRowPresentation(terminal: shell)
        let shellName = WorkspaceTerminalDrawer.rowName(for: shell)
        #expect(shellName.title == row.title)
        #expect(shellName.tab == row.tab)
    }

    private static func terminals() -> [ConsoleTerminal] {
        let host = Host.fixture()
        func terminal(
            _ id: String, tab: String, label: String, order: Int, agent: String? = nil
        ) -> ConsoleTerminal {
            ConsoleTerminal(
                hostID: host.id, hostName: host.displayName, hostUsername: host.username,
                pane: PaneInfo(
                    agentStatus: .idle, focused: false, paneID: id, revision: 1,
                    tabID: tab, terminalID: "term-\(id)", workspaceID: "workspace",
                    agent: agent, cwd: "/project", label: label),
                workspaceLabel: "Project", tabLabel: tab == "tab-one" ? "Development" : "Checks",
                workspaceOrder: 0, tabPosition: tab == "tab-one" ? 1 : 2,
                snapshotOrder: order, snapshotAgentKind: agent)
        }
        // Snapshot order deliberately disagrees with Tab order.
        return [
            terminal("tests", tab: "tab-two", label: "Tests", order: 0),
            terminal("agent", tab: "tab-one", label: "Code review", order: 1, agent: "claude"),
            terminal("server", tab: "tab-one", label: "Dev server", order: 2),
        ]
    }
}

/// The tab an Agent detail created for Open Terminal: kept while the
/// inventory catches up, forgotten once it is closed.
@MainActor
@Suite("Created workspace terminal")
struct CreatedWorkspaceTerminalTests {
    @Test func openCloseAndOpenAgainForgetsTheClosedTab() {
        let host = Host.fixture()
        let created = ShellTerminalIdentity(paneID: "w1:p2", tabID: "w1:t2", terminalID: "term-p2")
        let listed = ConsoleTerminal(
            hostID: host.id, hostName: host.displayName, hostUsername: host.username,
            pane: PaneInfo(
                agentStatus: .idle, focused: false, paneID: "w1:p2", revision: 1, tabID: "w1:t2",
                terminalID: "term-p2", workspaceID: "workspace", agent: nil, cwd: "/project", label: "zsh"),
            workspaceLabel: "Project", tabLabel: "Terminal", workspaceOrder: 0, tabPosition: 2,
            snapshotOrder: 1, snapshotAgentKind: nil)
        var terminal = CreatedWorkspaceTerminal()
        terminal.created(created)

        // Not listed yet: the inventory has not caught up, so it stays.
        #expect(terminal.resolve(in: [], hostID: host.id) == nil)
        #expect(terminal.identity == created)

        #expect(terminal.resolve(in: [listed], hostID: host.id) == listed)

        // Closed: Open Terminal no longer routes to it.
        #expect(terminal.resolve(in: [], hostID: host.id) == nil)
        #expect(terminal.identity == nil)
    }
}
