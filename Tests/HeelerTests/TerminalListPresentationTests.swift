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
        let first = Host.fixture(name: "zeta", address: "zeta.example")
        let second = Host.fixture(name: "alpha", address: "alpha.example")
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

    /// A card with no shell holds New Terminal alone, on every kind of Host:
    /// a Rex session running only Agents, or listing no terminal, keeps its
    /// card for New Terminal (ADR 0049's update of 2026-11-25), as another
    /// kind's does, even while a herdr-core Host is still connecting and
    /// cannot start one yet.
    @Test(arguments: [ServerKind.herdrTUI, .herdrCore, .tmux])
    func aWorkspaceWithNoShellHoldsNewTerminal(beside kind: ServerKind) throws {
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
                .init(hostID: rex.id, workspaceID: "agents"), .init(hostID: rex.id, workspaceID: "mixed"),
                .init(hostID: rex.id, workspaceID: "bare"), .init(hostID: other.id, workspaceID: "agents"),
            ])
        #expect(cards.map(\.terminals.count) == [0, 1, 0, 0])
        #expect(HostCapabilities(serverKind: .rex).startsTerminals)
        #expect(HostCapabilities(serverKind: kind).startsTerminals)
        let groups = list.hostGroups()
        #expect(groups.map { $0.workspaces.map(\.workspaceID) } == [["agents", "mixed", "bare"], ["agents"]])
        #expect(groups.map(\.terminalCount) == [1, 0])
    }

    /// A Rex session whose terminals all run Agents keeps its card, collapsed
    /// as it was left, for New Terminal; a shell that appears, or an Agent
    /// that exits to its shell, lists in it.
    @Test func aRexSessionRunningOnlyAgentsKeepsItsCard() throws {
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
        let empty = try #require(agentsOnly.workspaces().first)
        #expect(empty.id == session)
        #expect(empty.terminals.isEmpty)
        #expect(empty.isCollapsed)
        #expect(agentsOnly.hostGroups().first?.terminalCount == 0)

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

    /// A Host with two Servers on, beside a Host with one, as the catalog
    /// words them.
    @MainActor private func twoServerHosts() -> (tui: Host, tmux: Host, build: Host) {
        let tui = Host(name: "m3", address: "m3.example", username: "dev")
        let tmux = Host(name: "m3", address: "m3.example", username: "dev", serverKind: .tmux, sessionName: "default")
        let build = Host(name: "Build", address: "build.example", username: "dev", serverKind: .herdrCore)
        let records = HostStore(volatileHosts: [tui, build, tmux]).consoleHosts
        let labelled = { (host: Host) in records.first { $0.id == host.id } ?? host }
        return (labelled(tui), labelled(tmux), labelled(build))
    }

    /// By Host lists a Host once, by its name, holding every Server's
    /// Workspaces, a Server after another in catalog order, and counting
    /// all their shells; each card names the Host alone, and two Workspaces
    /// named alike on two Servers stay two cards.
    @MainActor @Test func aHostWithTwoServersIsOneGroupByItsName() throws {
        let (tui, tmux, build) = twoServerHosts()
        #expect(tmux.displayName == "m3 · tmux")
        let list = projection(
            hosts: [tui, build, tmux],
            terminals: [
                terminal(host: tmux, paneID: "t1", workspaceID: "api"),
                terminal(host: tmux, paneID: "t2", workspaceID: "api", tabPosition: 2),
                terminal(host: build, paneID: "b1"),
                terminal(host: tui, paneID: "h1", workspaceID: "api"),
            ],
            workspaces: [
                tui.id: [ConsoleWorkspace(id: "api", label: "api", order: 0)],
                tmux.id: [ConsoleWorkspace(id: "api", label: "api", order: 0)],
            ],
            statuses: [tui.id: .connected, tmux.id: .connected, build.id: .connected],
            collapsedHosts: [tui.id])
        let groups = list.hostGroups()
        #expect(groups.map(\.hostName) == ["m3", "Build"])
        #expect(groups.map(\.hostIDs) == [[tui.id, tmux.id], [build.id]])
        let m3 = try #require(groups.first)
        #expect(m3.hostID == tui.id)
        #expect(m3.workspaces.map(\.id) == [
            .init(hostID: tui.id, workspaceID: "api"), .init(hostID: tmux.id, workspaceID: "api"),
        ])
        #expect(m3.workspaces.map(\.hostName) == ["m3", "m3"])
        #expect(m3.terminalCount == 3)
        #expect(m3.readiness == HostReadiness(text: "Connected", tone: .connected))
        // Folded as its Herdr TUI Server was when each Server had a section.
        #expect(m3.isCollapsed)
        #expect(groups.last?.isCollapsed == false)
        // By Workspace keeps a Host's Servers together, in catalog order.
        #expect(list.workspaces().map(\.hostID) == [tui.id, tmux.id, build.id])
        #expect(list.workspaces().map(\.hostName) == ["m3", "m3", "Build"])
    }

    /// While another Server on the Host is connected, the Host's header stays
    /// Connected and the failing Server's row under it names that Server; when
    /// none is connected, the header reads Unavailable, and a Host with several
    /// Servers still expands rather than open one Server's connection sheet.
    @MainActor @Test func aFailingServerShowsOnItsHostsGroup() throws {
        let (tui, tmux, _) = twoServerHosts()
        let alone = Host.fixture(name: "alone", address: "alone.example")
        let failure = TransportError.sshUnreachable(detail: "connection refused")
        let groups = projection(
            hosts: [tui, tmux, alone],
            terminals: [terminal(host: tui, paneID: "h1")],
            statuses: [tui.id: .connected, tmux.id: .failed(failure), alone.id: .failed(failure)]
        ).hostGroups()
        let m3 = try #require(groups.first)
        #expect(m3.readiness.tone == .connected)
        #expect(m3.readiness.text == "Connected")
        #expect(m3.readiness.nameEmphasis == .full)
        #expect(m3.issues.map(\.hostID) == [tmux.id])
        #expect(m3.issues.first?.message.hasPrefix("m3 · tmux: ") == true)
        #expect(m3.terminalCount == 1)
        #expect(groups.map(\.opensConnectionDetail) == [false, true])

        let allFailing = projection(
            hosts: [tui, tmux],
            statuses: [tui.id: .failed(failure), tmux.id: .failed(failure)]
        ).hostGroups()
        let unreachable = try #require(allFailing.first)
        #expect(unreachable.readiness.tone == .unavailable)
        #expect(unreachable.readiness.text == "Unavailable")
        #expect(unreachable.readiness.nameEmphasis == .dimmed)
        #expect(!unreachable.opensConnectionDetail)
    }

    /// A Rex Host starts terminals, so with nothing to list it keeps its
    /// section, to start one from, connected, connecting or failing, as any
    /// Host that starts terminals does.
    @Test func aRexHostWithNothingToListKeepsItsGroup() {
        let rex = rex
        let herdr = Host.fixture(name: "herdr", address: "herdr.example")
        func groups(_ statuses: [Host.ID: EventsSessionStatus]) -> [String] {
            projection(hosts: [rex, herdr], statuses: statuses).hostGroups().map(\.hostName)
        }
        #expect(groups([rex.id: .connected, herdr.id: .connected]) == ["Rex", "herdr"])
        #expect(groups([rex.id: .connecting, herdr.id: .connected]) == ["Rex", "herdr"])
        #expect(groups([rex.id: .failed(.authenticationFailed), herdr.id: .connected]) == ["Rex", "herdr"])
        #expect(groups([:]) == ["Rex", "herdr"])
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
        let first = Host.fixture(name: "one", address: "one.example")
        let second = Host.fixture(name: "two", address: "two.example")
        let third = Host.fixture(name: "three", address: "three.example")
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
        let connected = Host.fixture(name: "connected", address: "connected.example")
        let paused = Host.fixture(name: "paused", address: "paused.example")
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
        #expect(first.issues.isEmpty)
        #expect(first.terminalCount == 1)
        #expect(!first.isCollapsed)
        let last = try #require(groups.last)
        #expect(last.readiness.text == "Paused")
        #expect(last.issues.count == 1)
        #expect(last.isCollapsed)
    }

    @Test func hostSearchKeepsOnlyHostsWithMatchesOpen() throws {
        let match = Host.fixture(name: "match", address: "match.example")
        let quiet = Host.fixture(name: "quiet", address: "quiet.example")
        let paused = Host.fixture(name: "paused", address: "paused.example")
        let failed = Host.fixture(name: "failed", address: "failed.example")
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
        let live = Host.fixture(name: "live", address: "live.example")
        let stopped = Host.fixture(name: "stopped", address: "stopped.example")
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
        let issue = try #require(group.issues.first)
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
        store.toggleCollapsed([host.id])

        let restored = TerminalListPresentationStore(defaults: defaults)
        #expect(restored.mode == .byHost)
        #expect(restored.collapsedWorkspaces == [workspace])
        #expect(restored.collapsedHosts == [host.id])

        restored.toggleCollapsed(workspace)
        restored.toggleCollapsed([host.id])
        let expanded = TerminalListPresentationStore(defaults: defaults)
        #expect(expanded.collapsedWorkspaces.isEmpty)
        #expect(expanded.collapsedHosts.isEmpty)
    }

    /// A Host is folded while any of its Servers' records is: unfolding drops
    /// them all, and folding holds them all.
    @Test func aHostFoldsAndUnfoldsWithEveryServer() throws {
        let defaults = try defaults()
        let tui = UUID()
        let tmux = UUID()
        let store = TerminalListPresentationStore(defaults: defaults)
        store.toggleCollapsed([tmux])
        store.toggleCollapsed([tui, tmux])
        #expect(TerminalListPresentationStore(defaults: defaults).collapsedHosts.isEmpty)
        store.toggleCollapsed([tui, tmux])
        #expect(TerminalListPresentationStore(defaults: defaults).collapsedHosts == [tui, tmux])
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
