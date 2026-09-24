import Foundation
import Testing

@testable import Heeler

@Suite("Terminal list projection")
struct TerminalListProjectionTests {
    private func terminal(
        host: Host, paneID: String, workspaceID: String = "w1",
        workspaceOrder: Int = 0, tabPosition: Int = 1, order: Int = 0,
        cwd: String? = "/project", agent: String? = nil, title: String = "zsh"
    ) -> ConsoleTerminal {
        ConsoleTerminal(
            hostID: host.id, hostName: host.displayName, hostUsername: host.username,
            pane: PaneInfo(
                agentStatus: .idle, focused: false, paneID: paneID, revision: 1,
                tabID: "\(workspaceID):t\(tabPosition)", terminalID: "terminal-\(paneID)",
                workspaceID: workspaceID, agent: agent, cwd: cwd,
                terminalTitleStripped: title),
            workspaceLabel: "Workspace \(workspaceID)", tabLabel: "Tab \(tabPosition)",
            workspaceOrder: workspaceOrder, tabPosition: tabPosition, snapshotOrder: order,
            snapshotAgentKind: agent)
    }

    private func agent(host: Host, paneID: String, workspaceID: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, workspaceID: workspaceID)),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    private func projection(
        hosts: [Host], terminals: [ConsoleTerminal] = [],
        workspaces: [Host.ID: [ConsoleWorkspace]] = [:], agents: [ConsoleAgent] = [],
        statuses: [Host.ID: EventsSessionStatus] = [:],
        awaiting: Set<Host.ID> = [],
        collapsedWorkspaces: Set<TerminalWorkspaceGroup.ID> = [],
        collapsedHosts: Set<Host.ID> = []
    ) -> TerminalListProjection {
        TerminalListProjection(
            hosts: hosts, terminals: terminals, workspacesByHost: workspaces, agents: agents,
            hostStatuses: statuses, hostStandingFailures: [:], hostsAwaitingSnapshot: awaiting,
            hostSyncErrors: [:], collapsedWorkspaces: collapsedWorkspaces,
            collapsedHosts: collapsedHosts)
    }

    @Test func cardsFollowHostThenWorkspaceOrderAndListShellsInTabOrder() throws {
        let first = Host.fixture(name: "zeta")
        let second = Host.fixture(name: "alpha")
        let cards = projection(
            hosts: [first, second],
            terminals: [
                terminal(host: second, paneID: "other-host"),
                terminal(host: first, paneID: "second-tab", tabPosition: 2),
                terminal(host: first, paneID: "late-pane", order: 2),
                terminal(host: first, paneID: "early-pane", order: 1),
            ],
            workspaces: [
                first.id: [
                    ConsoleWorkspace(id: "w2", label: "docs", order: 1),
                    ConsoleWorkspace(id: "w1", label: "api", order: 0),
                ]
            ]
        ).workspaces()
        #expect(cards.map(\.title) == ["api", "docs", "Workspace w1"])
        #expect(cards.map(\.hostID) == [first.id, first.id, second.id])
        #expect(cards.first?.terminals.map(\.paneID) == ["early-pane", "late-pane", "second-tab"])
    }

    @Test func agentPanesStayOffTheTerminalsListAndEmptyWorkspacesRemain() {
        let host = Host.fixture()
        let cards = projection(
            hosts: [host],
            terminals: [terminal(host: host, paneID: "agent", agent: "claude")],
            workspaces: [host.id: [ConsoleWorkspace(id: "w1", label: "api", order: 0)]]
        ).workspaces()
        #expect(cards.count == 1)
        #expect(cards.first?.terminals.isEmpty == true)
    }

    @Test func shellWhoseWorkspaceIsNotYetKnownIsStillListed() {
        let host = Host.fixture()
        let cards = projection(
            hosts: [host],
            terminals: [terminal(host: host, paneID: "p1", workspaceID: "w9")],
            workspaces: [host.id: [ConsoleWorkspace(id: "w1", label: "api", order: 0)]]
        ).workspaces()
        #expect(cards.map(\.workspaceID) == ["w1", "w9"])
        #expect(cards.last?.title == "Workspace w9")
    }

    @Test func searchKeepsMatchingShellsAndDropsCardsLeftEmpty() {
        let host = Host.fixture()
        let cards = projection(
            hosts: [host],
            terminals: [
                terminal(host: host, paneID: "match", cwd: "/srv/API"),
                terminal(host: host, paneID: "miss", cwd: "/srv/docs"),
            ],
            workspaces: [
                host.id: [
                    ConsoleWorkspace(id: "w1", label: "main", order: 0),
                    ConsoleWorkspace(id: "w2", label: "empty", order: 1),
                ]
            ],
            collapsedWorkspaces: [.init(hostID: host.id, workspaceID: "w1")]
        ).workspaces(searchQuery: " api ")
        #expect(cards.map(\.workspaceID) == ["w1"])
        #expect(cards.first?.terminals.map(\.paneID) == ["match"])
        #expect(cards.first?.isCollapsed == false)
    }

    @Test func hostFilterLimitsCardsAndIssues() {
        let first = Host.fixture(name: "one")
        let second = Host.fixture(name: "two")
        let list = projection(
            hosts: [first, second],
            terminals: [
                terminal(host: first, paneID: "a"), terminal(host: second, paneID: "b"),
            ],
            statuses: [first.id: .suspended, second.id: .suspended])
        #expect(list.workspaces(filteredHostID: second.id).map(\.hostID) == [second.id])
        #expect(list.issues(filteredHostID: second.id).map(\.hostID) == [second.id])
        #expect(list.issues().map(\.hostID) == [first.id, second.id])
    }

    @Test func directoryPrefersCheckoutThenShellThenAgentAbsolutePaths() {
        let host = Host.fixture()
        let list = projection(
            hosts: [host],
            terminals: [
                terminal(host: host, paneID: "relative", workspaceID: "w2", cwd: "relative"),
                terminal(host: host, paneID: "shell", workspaceID: "w2", order: 1, cwd: "/shell"),
            ],
            workspaces: [
                host.id: [
                    ConsoleWorkspace(id: "w1", label: "repo", order: 0, checkoutPath: "/repo"),
                    ConsoleWorkspace(id: "w2", label: "shells", order: 1, checkoutPath: nil),
                    ConsoleWorkspace(id: "w3", label: "agents", order: 2),
                    ConsoleWorkspace(id: "w4", label: "bare", order: 3),
                ]
            ],
            agents: [agent(host: host, paneID: "w3:p1", workspaceID: "w3")])
        let directories = list.workspaces().map(\.directory)
        #expect(directories == ["/repo", "/shell", "/work/w3", nil])
    }

    @Test func hostGroupsCarryReadinessIssueAndCollapsedState() throws {
        let connected = Host.fixture(name: "connected")
        let paused = Host.fixture(name: "paused")
        let groups = projection(
            hosts: [connected, paused],
            terminals: [terminal(host: connected, paneID: "p1")],
            workspaces: [connected.id: [ConsoleWorkspace(id: "w1", label: "api", order: 0)]],
            statuses: [connected.id: .connected, paused.id: .suspended],
            collapsedHosts: [paused.id]
        ).hostGroups()
        #expect(groups.map(\.hostName) == ["connected", "paused"])
        let first = try #require(groups.first)
        #expect(first.readinessText == "Connected")
        #expect(first.issue == nil)
        #expect(first.terminalCount == 1)
        #expect(!first.isCollapsed)
        let last = try #require(groups.last)
        #expect(last.readinessText == "Paused")
        #expect(last.issue != nil)
        #expect(last.isCollapsed)
    }

    @Test func connectedHostWithoutShellsReadsNoTerminals() {
        let host = Host.fixture()
        let group = projection(hosts: [host], statuses: [host.id: .connected]).hostGroups().first
        #expect(group?.readinessText == "No Terminals")
    }
}

@MainActor
@Suite("Terminal list presentation store")
struct TerminalListPresentationStoreTests {
    private func defaults() throws -> UserDefaults {
        let suite = "TerminalListPresentationStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsToByWorkspaceWithNothingCollapsed() throws {
        let store = TerminalListPresentationStore(defaults: try defaults())
        #expect(store.mode == .byWorkspace)
        #expect(store.collapsedWorkspaces.isEmpty)
        #expect(store.collapsedHosts.isEmpty)
    }

    @Test func modeAndCollapsedStatePersistAcrossStores() throws {
        let defaults = try defaults()
        let host = Host.fixture()
        // Workspace ids are opaque: one containing the key separator must
        // survive the round trip intact.
        let workspace = TerminalWorkspaceGroup.ID(hostID: host.id, workspaceID: "w1/odd:id")
        let store = TerminalListPresentationStore(defaults: defaults)
        store.select(.byHost)
        store.toggleCollapsed(workspace)
        store.toggleCollapsed(host.id)

        let restored = TerminalListPresentationStore(defaults: defaults)
        #expect(restored.mode == .byHost)
        #expect(restored.collapsedWorkspaces == [workspace])
        #expect(restored.collapsedHosts == [host.id])

        restored.toggleCollapsed(workspace)
        restored.toggleCollapsed(host.id)
        let expanded = TerminalListPresentationStore(defaults: defaults)
        #expect(expanded.collapsedWorkspaces.isEmpty)
        #expect(expanded.collapsedHosts.isEmpty)
    }
}

@Suite("Terminal row presentation")
struct TerminalRowPresentationTests {
    private let host = Host.fixture(name: "studio", username: "dev")

    private func shell(
        tabLabel: String? = "2", tabPosition: Int? = 2, paneLabel: String? = nil,
        cwd: String = "/home/dev/app", title: String = "~/app"
    ) -> ConsoleTerminal {
        ConsoleTerminal(
            hostID: host.id, hostName: host.displayName, hostUsername: host.username,
            pane: PaneInfo(
                agentStatus: .idle, focused: false, paneID: "w1:p2", revision: 1,
                tabID: "w1:t2", terminalID: "t2", workspaceID: "w1", cwd: cwd,
                label: paneLabel, terminalTitleStripped: title),
            workspaceLabel: "api", tabLabel: tabLabel, workspaceOrder: 0,
            tabPosition: tabPosition, snapshotOrder: 0, snapshotAgentKind: nil)
    }

    @Test func herdrsNumberedLabelIsNotANameButACustomOneIs() {
        #expect(shell().customTabLabel == nil)
        #expect(shell().displayTabTitle == "Tab 2")
        #expect(shell(tabLabel: " logs ").customTabLabel == "logs")
        #expect(shell(tabLabel: "logs").displayTabTitle == "Tab \u{201C}logs\u{201D}")
        // herdr renumbers default labels, so a number off its position was typed.
        #expect(shell(tabLabel: "3").customTabLabel == "3")
        #expect(shell(tabLabel: nil, tabPosition: nil).displayTabTitle == "Tab w1:t2")
    }

    @Test func namedTabLeadsTheRowAndIsNotRepeated() {
        let row = TerminalRowPresentation(terminal: shell(tabLabel: "logs"), showsTab: true)
        #expect(row.title == "logs")
        #expect(row.subtitle == "~/app")
    }

    @Test func unnamedShellsInOneCardAreToldApartByTab() {
        let row = TerminalRowPresentation(terminal: shell(), showsTab: true)
        #expect(row.title == "~/app")
        #expect(row.subtitle == "Tab 2 · ~/app")
        #expect(TerminalRowPresentation(terminal: shell()).subtitle == "~/app")
    }

    @Test func paneLabelOutranksTheTabNameWhichMovesToTheSubtitle() {
        let row = TerminalRowPresentation(
            terminal: shell(tabLabel: "logs", paneLabel: "tail"), showsWorkspace: true,
            showsTab: true)
        #expect(row.title == "tail")
        #expect(row.subtitle == "api · Tab \u{201C}logs\u{201D} · ~/app")
    }

    @Test func closeMessagesNameTheTabAndWorkspace() {
        #expect(TerminalCloseScope.tab.message(for: shell()) == "Closes Tab 2 in api.")
        #expect(
            TerminalCloseScope.pane.message(for: shell(tabLabel: "logs"))
                == "Closes this pane of Tab \u{201C}logs\u{201D} in api. The tab's other panes stay open.")
        #expect(TerminalCloseScope.workspace.message(for: shell()).contains("workspace api"))
    }

    @Test func terminalsIssueRowWaitsForTerminals() throws {
        let row = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .connected, isAwaitingSnapshot: true, syncError: nil,
                inventoryNoun: "Terminals"))
        #expect(row.message == "Loading Terminals from studio…")
    }
}
