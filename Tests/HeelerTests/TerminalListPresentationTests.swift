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
        syncErrors: [Host.ID: String] = [:],
        collapsedWorkspaces: Set<TerminalWorkspaceGroup.ID> = [],
        collapsedHosts: Set<Host.ID> = []
    ) -> TerminalListProjection {
        TerminalListProjection(
            hosts: hosts, terminals: terminals, workspacesByHost: workspaces, agents: agents,
            hostStatuses: statuses, hostStandingFailures: [:], hostsAwaitingSnapshot: awaiting,
            hostSyncErrors: syncErrors, collapsedWorkspaces: collapsedWorkspaces,
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

    private var rex: Host {
        Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: "/run/user/1000/rex/server.sock"))
    }

    /// A card with no shell holds New Terminal alone. A Rex Host starts no
    /// terminals, so its session running only Agents, or listing no terminal,
    /// has nothing to show or offer and is left out of both presentations.
    /// Another kind's stays, there to hold New Terminal, even while a
    /// herdr-core Host is still connecting and cannot start one yet.
    @Test(arguments: [ServerKind.herdrTUI, .herdrCore, .tmux])
    func aWorkspaceWithNothingToShowOrOfferIsLeftOut(beside kind: ServerKind) throws {
        let rex = rex
        let other = Host(name: "other", address: "other.example", username: "dev", serverKind: kind)
        let list = projection(
            hosts: [rex, other],
            terminals: [
                terminal(host: rex, paneID: "codex", workspaceID: "agents", agent: "codex"),
                terminal(host: rex, paneID: "shell", workspaceID: "mixed", order: 1),
                terminal(host: rex, paneID: "claude", workspaceID: "mixed", order: 2, agent: "claude"),
                terminal(host: other, paneID: "agent", workspaceID: "agents", agent: "claude"),
            ],
            workspaces: [
                rex.id: [
                    ConsoleWorkspace(id: "agents", label: "agents", order: 0),
                    ConsoleWorkspace(id: "mixed", label: "mixed", order: 1),
                    ConsoleWorkspace(id: "bare", label: "bare", order: 2),
                ],
                other.id: [ConsoleWorkspace(id: "agents", label: "agents", order: 0)],
            ],
            statuses: [rex.id: .connected, other.id: kind == .herdrCore ? .connecting : .connected])

        let cards = list.workspaces()
        #expect(
            cards.map(\.id) == [
                .init(hostID: rex.id, workspaceID: "mixed"), .init(hostID: other.id, workspaceID: "agents"),
            ])
        #expect(cards.map(\.terminals.count) == [1, 0])
        #expect(!HostCapabilities(serverKind: .rex).startsTerminals)
        #expect(HostCapabilities(serverKind: kind).startsTerminals)
        let groups = list.hostGroups()
        #expect(groups.map { $0.workspaces.map(\.workspaceID) } == [["mixed"], ["agents"]])
        #expect(groups.map(\.terminalCount) == [1, 0])
    }

    /// A Rex Host whose sessions all run Agents lists no card, so both
    /// presentations show their empty state, and its Host header reads No
    /// Terminals with no count; a search or a filter finds nothing either.
    /// The session's card comes back, collapsed as it was left, once it has a
    /// shell: its Agent exits to the shell, or a new terminal appears.
    @Test func aRexSessionRunningOnlyAgentsComesBackWithAShell() throws {
        let rex = rex
        let session = TerminalWorkspaceGroup.ID(hostID: rex.id, workspaceID: "agents")
        func list(_ terminals: [ConsoleTerminal]) -> TerminalListProjection {
            projection(
                hosts: [rex], terminals: terminals,
                workspaces: [rex.id: [ConsoleWorkspace(id: "agents", label: "agents", order: 0)]],
                statuses: [rex.id: .connected], collapsedWorkspaces: [session])
        }
        let codex = terminal(host: rex, paneID: "codex", workspaceID: "agents", agent: "codex")
        let agentsOnly = list([codex])
        // What each presentation reads for its empty state.
        #expect(agentsOnly.workspaces().isEmpty)
        #expect(agentsOnly.issues().isEmpty)
        let group = try #require(agentsOnly.hostGroups().first)
        #expect(group.workspaces.isEmpty)
        #expect(group.issue == nil)
        #expect(group.readiness.text == "No Terminals")
        #expect(group.terminalCount == 0)
        #expect(agentsOnly.workspaces(filteredHostIDs: [rex.id]).isEmpty)
        #expect(agentsOnly.workspaces(searchQuery: "agents").isEmpty)
        #expect(agentsOnly.hostGroups(searchQuery: "agents").isEmpty)

        let exited = terminal(host: rex, paneID: "codex", workspaceID: "agents")
        let opened = terminal(host: rex, paneID: "zsh", workspaceID: "agents", tabPosition: 2)
        for terminals in [[exited], [codex, opened]] {
            let back = list(terminals)
            let card = try #require(back.workspaces().first)
            #expect(card.id == session)
            #expect(card.headerAccessibilityValue == "1 terminal, Collapsed")
            let group = try #require(back.hostGroups().first)
            #expect(group.readiness.text == "Connected")
            #expect(group.terminalCount == 1)
            #expect(back.workspaces(searchQuery: "agents").first?.isCollapsed == false)
        }
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
        let third = Host.fixture(name: "three")
        let list = projection(
            hosts: [first, second, third],
            terminals: [
                terminal(host: first, paneID: "a"), terminal(host: second, paneID: "b"),
                terminal(host: third, paneID: "c"),
            ],
            statuses: [first.id: .suspended, second.id: .suspended, third.id: .suspended])
        #expect(list.workspaces(filteredHostIDs: [second.id]).map(\.hostID) == [second.id])
        #expect(list.issues(filteredHostIDs: [second.id]).map(\.hostID) == [second.id])
        #expect(list.issues().map(\.hostID) == [first.id, second.id, third.id])
        let selected: Set<Host.ID> = [third.id, first.id]
        #expect(list.workspaces(filteredHostIDs: selected).map(\.hostID) == [first.id, third.id])
        #expect(list.hostGroups(filteredHostIDs: selected).map(\.hostID) == [first.id, third.id])
        #expect(list.issues(filteredHostIDs: selected).map(\.hostID) == [first.id, third.id])
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
        #expect(first.readiness.text == "Connected")
        #expect(first.issue == nil)
        #expect(first.terminalCount == 1)
        #expect(!first.isCollapsed)
        let last = try #require(groups.last)
        #expect(last.readiness.text == "Paused")
        #expect(last.issue != nil)
        #expect(last.isCollapsed)
    }

    @Test func hostSearchKeepsOnlyHostsWithMatchesOpen() throws {
        let match = Host.fixture(name: "match")
        let quiet = Host.fixture(name: "quiet")
        let paused = Host.fixture(name: "paused")
        let failed = Host.fixture(name: "failed")
        let groups = projection(
            hosts: [match, quiet, paused, failed],
            terminals: [
                terminal(host: match, paneID: "hit", cwd: "/srv/API"),
                terminal(host: quiet, paneID: "miss", cwd: "/srv/docs"),
            ],
            statuses: [
                match.id: .connected, quiet.id: .connected, paused.id: .suspended,
                failed.id: .failed(.authenticationFailed),
            ],
            collapsedHosts: [match.id]
        ).hostGroups(searchQuery: "api")
        // Paused or failed, a Host without a match leaves too.
        #expect(groups.map(\.hostName) == ["match"])
        let first = try #require(groups.first)
        #expect(!first.isCollapsed)
        #expect(first.workspaces.flatMap(\.terminals).map(\.paneID) == ["hit"])
    }

    @Test func onlyFailingHostsOpenTheConnectionSheet() {
        let live = Host.fixture(name: "live")
        let stopped = Host.fixture(name: "stopped")
        let groups = projection(
            hosts: [live, stopped],
            statuses: [live.id: .connected, stopped.id: .failed(.authenticationFailed)]
        ).hostGroups()
        #expect(groups.map(\.opensConnectionDetail) == [false, true])
    }

    @Test func connectedHostWithoutShellsReadsNoTerminals() {
        let host = Host.fixture()
        let group = projection(hosts: [host], statuses: [host.id: .connected]).hostGroups().first
        #expect(group?.readiness.text == "No Terminals")
    }

    @Test func aHostWhoseSyncFailedReadsAsASyncIssueUnderItsOwnHeader() throws {
        let host = Host.fixture(name: "mini")
        let group = try #require(
            projection(
                hosts: [host], statuses: [host.id: .connected], awaiting: [host.id],
                syncErrors: [host.id: "Could not sync this Host. Retrying…"]
            ).hostGroups().first)
        #expect(group.readiness == HostReadiness(text: "Sync issue", tone: .warning))
        let issue = try #require(group.issue)
        #expect(issue.tone == group.readiness.tone)
        #expect(issue.message == "mini: Could not sync this Host. Retrying…")
        #expect(issue.sectionMessage == "Could not sync this Host. Retrying…")
    }

    @Test func workspaceHeadersCountOneShellInTheSingular() throws {
        let host = Host.fixture()
        let cards = projection(
            hosts: [host],
            terminals: [
                terminal(host: host, paneID: "only", workspaceID: "w1"),
                terminal(host: host, paneID: "first", workspaceID: "w2"),
                terminal(host: host, paneID: "second", workspaceID: "w2", tabPosition: 2),
            ],
            collapsedWorkspaces: [TerminalWorkspaceGroup.ID(hostID: host.id, workspaceID: "w2")]
        ).workspaces()
        #expect(
            cards.map(\.headerAccessibilityValue) == [
                "1 terminal, Expanded", "2 terminals, Collapsed",
            ])
        #expect(TerminalCount.text(0) == "0 terminals")
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

    @Test func theTabBesideTheTitleIsLeftOutWhenTheTitleIsTheTab() {
        #expect(TerminalRowPresentation(terminal: shell(tabLabel: "logs")).tab == nil)
        #expect(TerminalRowPresentation(terminal: shell()).tab == "Tab 2")
        #expect(
            TerminalRowPresentation(terminal: shell(tabLabel: "logs", paneLabel: "tail")).tab
                == "Tab \u{201C}logs\u{201D}")
    }

    /// One shell reads alike in the Terminals list and, one tap on, in the
    /// Workspace drawer.
    @MainActor @Test func theWorkspaceDrawerNamesShellsAsTheListDoes() {
        let named = WorkspaceTerminalDrawer.rowName(for: shell(tabLabel: "logs", title: "zsh"))
        #expect(named.title == "logs")
        #expect(named.tab == nil)

        let unnamed = WorkspaceTerminalDrawer.rowName(for: shell())
        #expect(unnamed.title == "~/app")
        #expect(unnamed.tab == "Tab 2")

        let labelled = WorkspaceTerminalDrawer.rowName(
            for: shell(tabLabel: "logs", paneLabel: "tail"))
        #expect(labelled.title == "tail")
        #expect(labelled.tab == "Tab \u{201C}logs\u{201D}")
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

@Suite("Console row lift")
struct ConsoleRowLiftTests {
    @Test func liftedCardIsTheRowPaddedAsACardPadsItsRows() {
        // A 320-point sidebar's card row: 256 points of content, a 288-point card.
        #expect(ConsoleRowLift.cardWidth(rowWidth: 256) == 288)
        #expect(ConsoleRowLift.cardWidth(rowWidth: 376) == 408)
    }

    @Test func anUnmeasuredRowLiftsTheIdealSidebarsCard() {
        #expect(ConsoleRowLift.cardWidth(rowWidth: nil) == ConsoleRowLift.fallbackWidth)
        #expect(ConsoleRowLift.cardWidth(rowWidth: 0) == ConsoleRowLift.fallbackWidth)
    }
}

@Suite("Terminal card edges")
struct TerminalCardEdgesTests {
    @Test func theLastShellClosesACardWithoutNewTerminal() {
        let rows = (0..<3).map { TerminalCardEdges.shell(at: $0, of: 3, endsInNewTerminal: false) }
        #expect(rows.map(\.isFirst) == [true, false, false])
        #expect(rows.map(\.isLast) == [false, false, true])
        #expect(
            TerminalCardEdges.shell(at: 0, of: 1, endsInNewTerminal: false)
                == TerminalCardEdges(isFirst: true, isLast: true))
    }

    @Test func newTerminalClosesACardThatOffersIt() {
        let rows = (0..<2).map { TerminalCardEdges.shell(at: $0, of: 2, endsInNewTerminal: true) }
        #expect(rows.map(\.isFirst) == [true, false])
        #expect(rows.map(\.isLast) == [false, false])
        #expect(
            TerminalCardEdges.newTerminal(afterShells: 2)
                == TerminalCardEdges(isFirst: false, isLast: true))
        #expect(
            TerminalCardEdges.newTerminal(afterShells: 0)
                == TerminalCardEdges(isFirst: true, isLast: true))
    }
}
