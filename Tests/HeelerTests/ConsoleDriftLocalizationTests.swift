import Foundation
import Testing

@testable import Heeler

/// Console copy that is shown keeps its logic on tokens and enums, and
/// words each variant as one whole phrase, so a translation never has to
/// stitch English words into a sentence. Tests run in English.
@Suite("Console localization tokens")
struct ConsoleDriftLocalizationTests {
    // MARK: Host conditions

    @Test func aHostConditionIsATokenWordedPerCondition() throws {
        let host = Host.fixture(name: "studio")
        let paused = try #require(
            ConsoleHostStatusPresentation(host: host, status: .suspended, syncError: nil))
        #expect(paused.condition == .paused)
        #expect(paused.status == "Paused")
        #expect(paused.message == "Connection to studio is paused.")

        let failed = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(.authenticationFailed), syncError: nil))
        #expect(failed.condition == .cannotConnect)
        #expect(failed.status == "Can't connect")
    }

    /// The noun is a token: each inventory has its own whole sentences.
    @Test func loadingRowsWordEachInventoryWhole() throws {
        let host = Host.fixture(name: "studio")
        let agents = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .connected, isAwaitingSnapshot: true, syncError: nil))
        #expect(agents.condition == .loadingAgents)
        #expect(agents.status == "Loading Agents…")
        #expect(agents.message == "Loading Agents from studio…")

        let terminals = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .connected, isAwaitingSnapshot: true, syncError: nil,
                inventoryNoun: "Terminals"))
        #expect(terminals.condition == .loadingTerminals)
        #expect(terminals.status == "Loading Terminals…")
        #expect(terminals.message == "Loading Terminals from studio…")
    }

    /// Hosts group by their condition, not by lowercasing its words, and
    /// each count is one phrase.
    @Test func theIssueSummaryCountsHostsPerCondition() throws {
        let reconnecting: EventsSessionStatus = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .timedOut)
        let issues = [
            ConsoleHostStatusPresentation(
                host: Host.fixture(name: "a"), status: .suspended, syncError: nil),
            ConsoleHostStatusPresentation(
                host: Host.fixture(name: "b"), status: reconnecting, syncError: nil),
            ConsoleHostStatusPresentation(
                host: Host.fixture(name: "c"), status: .connecting, syncError: nil),
            ConsoleHostStatusPresentation(
                host: Host.fixture(name: "d"), status: reconnecting, syncError: nil),
        ].compactMap { $0 }
        try #require(issues.count == 4)

        let summary = try #require(ConsoleHostIssueSummary(issues: issues))
        #expect(summary.title == "4 Hosts not connected")
        #expect(summary.counts == [
            ConsoleHostIssueSummary.Count(tone: .reconnecting, text: "2 reconnecting"),
            ConsoleHostIssueSummary.Count(tone: .pending, text: "1 connecting"),
            ConsoleHostIssueSummary.Count(tone: .paused, text: "1 paused"),
        ])
        #expect(summary.tone == .reconnecting)
        #expect(ConsoleHostStatusPresentation.Condition.loadingTerminals.countText(2) == "2 loading terminals")
        #expect(ConsoleHostStatusPresentation.Condition.cannotConnect.countText(3) == "3 can't connect")
    }

    // MARK: Closing

    @Test func closeScopesWordTheirActionAndQuestionWhole() {
        #expect(TerminalCloseScope.workspace.actionTitle == "Close Workspace")
        #expect(TerminalCloseScope.tab.actionTitle == "Close Tab")
        #expect(TerminalCloseScope.pane.actionTitle == "Close Pane")
        #expect(TerminalCloseScope.workspace.confirmationTitle == "Close Workspace?")
        #expect(TerminalCloseScope.tab.confirmationTitle == "Close Tab?")
        #expect(TerminalCloseScope.pane.confirmationTitle == "Close Pane?")
    }

    /// An unnamed Workspace has sentences of its own rather than "this
    /// Workspace" dropped into the named one.
    @Test func anUnnamedWorkspaceGetsItsOwnSentences() {
        let host = Host.fixture()
        let shell = ConsoleTerminal(
            hostID: host.id, hostName: host.displayName, hostUsername: host.username,
            pane: PaneInfo(
                agentStatus: .idle, focused: false, paneID: "p1", revision: 1,
                tabID: "w1:t1", terminalID: "terminal-p1", workspaceID: "w1"),
            workspaceLabel: nil, tabLabel: nil, workspaceOrder: 0, tabPosition: 1,
            snapshotOrder: 0, snapshotAgentKind: nil)
        #expect(TerminalCloseScope.tab.message(for: shell) == "Closes Tab 1 in this Workspace.")
        #expect(
            TerminalCloseScope.pane.message(for: shell)
                == "Closes this pane of Tab 1 in this Workspace. The tab's other panes stay open.")
        #expect(
            TerminalCloseScope.workspace.message(for: shell)
                == "Are you sure you want to also close this workspace? It is the workspace's last tab.")
    }

    // MARK: Agent statuses

    /// The filter saves its raw values; what it shows is worded per choice.
    @Test func statusFilterChoicesKeepTheirTokensAndWordTheirTitles() {
        #expect(ConsoleAgentStatusFilter.allCases.map(\.rawValue) == ["blocked", "working", "done", "idle"])
        #expect(ConsoleAgentStatusFilter.blocked.title(count: 2) == "Blocked (2)")
        #expect(ConsoleAgentStatusFilter.working.title(count: 0) == "Working (0)")
        #expect(ConsoleAgentStatusFilter.done.title(count: 1) == "Done (1)")
        #expect(ConsoleAgentStatusFilter.idle.title(count: 3) == "Idle (3)")
    }

    @Test func statusCountPillsAreWholePhrases() {
        #expect(ConsoleHostAgentStatusCount(status: .blocked, count: 1).text == "1 blocked")
        #expect(ConsoleHostAgentStatusCount(status: .error, count: 1).text == "1 error")
        #expect(ConsoleHostAgentStatusCount(status: .error, count: 2).text == "2 errors")
        #expect(ConsoleHostAgentStatusCount(status: .working, count: 3).text == "3 working")
        #expect(ConsoleHostAgentStatusCount(status: .done, count: 4).text == "4 done")
    }
}
