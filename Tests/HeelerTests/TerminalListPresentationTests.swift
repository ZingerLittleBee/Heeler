import Foundation
import Testing

@testable import Heeler

@Suite("Terminal list grouping")
struct TerminalListPresentationTests {
    private func terminal(
        host: Host, paneID: String, workspaceID: String = "w1",
        workspaceOrder: Int = 0, tabPosition: Int = 1, order: Int = 0,
        cwd: String = "/project", agent: String? = nil
    ) -> ConsoleTerminal {
        ConsoleTerminal(
            hostID: host.id, hostName: host.displayName, hostUsername: host.username,
            pane: PaneInfo(
                agentStatus: .idle, focused: false, paneID: paneID, revision: 1,
                tabID: "\(workspaceID):t\(tabPosition)", terminalID: "terminal-\(paneID)",
                workspaceID: workspaceID, agent: agent, cwd: cwd),
            workspaceLabel: "Workspace \(workspaceID)", tabLabel: "Tab \(tabPosition)",
            workspaceOrder: workspaceOrder, tabPosition: tabPosition, snapshotOrder: order,
            snapshotAgentKind: agent)
    }

    @Test func groupsHostBeforeWorkspaceAndPreservesSnapshotOrder() throws {
        let first = Host.fixture(name: "zeta")
        let second = Host.fixture(name: "alpha")
        let terminals = [
            terminal(host: second, paneID: "second-host", workspaceID: "w1"),
            terminal(host: first, paneID: "late-workspace", workspaceID: "w2", workspaceOrder: 1),
            terminal(host: first, paneID: "second-tab", tabPosition: 2),
            terminal(host: first, paneID: "second-pane", order: 2, agent: "claude"),
            terminal(host: first, paneID: "first-pane", order: 1),
        ]
        let sections = ConsoleTerminalHostSection.sections(
            hosts: [first, second], terminals: terminals, filteredHostID: nil, searchQuery: "")
        #expect(sections.map(\.id) == [first.id, second.id])
        let firstSection = try #require(sections.first)
        #expect(firstSection.workspaces.map(\.id) == ["w1", "w2"])
        #expect(firstSection.workspaces.first?.terminals.map(\.paneID)
            == ["first-pane", "second-pane", "second-tab"])
        #expect(sections.last?.workspaces.first?.terminals.map(\.paneID) == ["second-host"])
    }

    @Test func hostFilterAndPathSearchRetainAgentAndShellPanes() throws {
        let first = Host.fixture(name: "one")
        let second = Host.fixture(name: "two")
        let terminals = [
            terminal(host: first, paneID: "agent", cwd: "/project/API", agent: "claude"),
            terminal(host: first, paneID: "shell", cwd: "/project/api"),
            terminal(host: first, paneID: "other", cwd: "/project/docs"),
            terminal(host: second, paneID: "hidden", cwd: "/project/api"),
        ]
        let sections = ConsoleTerminalHostSection.sections(
            hosts: [first, second], terminals: terminals,
            filteredHostID: first.id, searchQuery: " API ")
        #expect(sections.count == 1)
        let rows = try #require(sections.first?.workspaces.first?.terminals)
        #expect(Set(rows.map(\.paneID)) == ["agent", "shell"])
        #expect(rows.contains { $0.isAgent })
    }

    @Test func emptyHostsRemainVisibleForConnectionStatus() {
        let host = Host.fixture()
        let sections = ConsoleTerminalHostSection.sections(
            hosts: [host], terminals: [], filteredHostID: nil, searchQuery: "unmatched")
        #expect(sections.count == 1)
        #expect(sections.first?.workspaces.isEmpty == true)
    }
}
