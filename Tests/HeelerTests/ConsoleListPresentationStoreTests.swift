import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Console list presentation store")
struct ConsoleListPresentationStoreTests {
    @Test func workspacePresentationIsAvailableAndPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let mode = try #require(ConsoleListPresentationMode(rawValue: "byWorkspace"))
        #expect(mode.title == "By Workspace")
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.select(mode)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == mode)
    }

    @Test func statusFilterNarrowsBothGroupingsUnfoldsAndPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let quiet = Host.fixture(name: "Quiet", address: "quiet.example")
        let agents = [
            consoleAgent(host: host, paneID: "p1", status: .working),
            consoleAgent(host: host, paneID: "p2", status: .error, workspaceID: "w2"),
            consoleAgent(host: host, paneID: "p3", status: .idle, workspaceID: "w2"),
            consoleAgent(host: quiet, paneID: "p1", status: .idle),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.setCollapsed(true, for: host.id)
        store.toggleStatusFilter(.blocked)
        store.toggleStatusFilter(.working)
        // Error rides with Blocked; a Host with no match leaves the list.
        let sections = store.sections(hosts: [host, quiet], agents: agents)
        #expect(sections.map(\.hostID) == [host.id])
        #expect(sections.first?.agents.map(\.id) == [agents[0].id, agents[1].id])
        #expect(sections.first?.isCollapsed == false)
        #expect(store.workspaceSections(hosts: [host, quiet], agents: agents)
            .flatMap { $0.agents.map(\.id) } == [agents[0].id, agents[1].id])
        #expect(ConsoleListPresentationStore(defaults: defaults).statusFilter == [.blocked, .working])
        store.toggleStatusFilter(.working)
        #expect(store.statusFilter == [.blocked])
        store.clearStatusFilter()
        #expect(ConsoleListPresentationStore(defaults: defaults).statusFilter.isEmpty)
        #expect(store.sections(hosts: [host, quiet], agents: agents).count == 2)
        #expect(ConsoleAgentsSurface(
            hostCount: 1, filteredHostName: nil, filteredAgentCount: 0, visibleIssueCount: 0,
            isStatusFiltered: true) == .noSearchResults)
    }

    @Test func hostFilterPersistsAndPrunesRemovedHosts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "m3", address: "m3.example")
        let second = Host.fixture(name: "m1 pro", address: "m1.example")
        let removed = Host.fixture(name: "old", address: "old.example")
        let machines = HostMachine.grouped([first, second, removed])

        let store = ConsoleListPresentationStore(defaults: defaults)
        #expect(store.hostFilter.isEmpty)

        store.toggleHostFilter(machines[0])
        store.toggleHostFilter(machines[2])
        #expect(store.hostFilter == [first.id, removed.id])
        #expect(ConsoleListPresentationStore(defaults: defaults).hostFilter == [first.id, removed.id])

        store.pruneHostFilter(keeping: [first, second])
        #expect(store.hostFilter == [first.id])
        #expect(ConsoleListPresentationStore(defaults: defaults).hostFilter == [first.id])

        store.toggleHostFilter(machines[0])
        #expect(store.hostFilter.isEmpty)
        #expect(ConsoleListPresentationStore(defaults: defaults).hostFilter.isEmpty)

        store.setHostFilter([second.id])
        #expect(ConsoleListPresentationStore(defaults: defaults).hostFilter == [second.id])
        store.clearHostFilter()
        #expect(ConsoleListPresentationStore(defaults: defaults).hostFilter.isEmpty)
    }

    private func twoServerCatalog() -> (tui: Host, tmux: Host, build: Host) {
        (Host(name: "m3", address: "m3.example", username: "dev"),
         Host(name: "m3", address: "m3.example", username: "dev", serverKind: .tmux, sessionName: "default"),
         Host(name: "Build", address: "build.example", username: "dev", serverKind: .herdrCore))
    }

    @Test func aSavedServerSelectsItsHostWithEveryServerItHasOn() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (tui, tmux, build) = twoServerCatalog()
        let core = Host(name: "m3", address: "m3.example", username: "dev", serverKind: .herdrCore)
        ConsoleListPresentationStore(defaults: defaults).setHostFilter([tui.id])

        let store = ConsoleListPresentationStore(defaults: defaults)
        store.pruneHostFilter(keeping: [tui, tmux, build])
        #expect(store.hostFilter == [tui.id, tmux.id])
        #expect(ConsoleListPresentationStore(defaults: defaults).hostFilter == [tui.id, tmux.id])

        let agents = [tui, tmux, build].map { consoleAgent(host: $0, paneID: "p1", status: .working) }
        #expect(store.sections(hosts: [tui, tmux, build], agents: agents, filteredHostIDs: store.hostFilter)
            .map(\.hostIDs) == [[tui.id, tmux.id]])
        let terminals = TerminalListProjection(
            hosts: [tui, tmux, build],
            terminals: [tui, tmux, build].map { host in
                ConsoleTerminal(
                    hostID: host.id, hostName: host.hostName, hostUsername: host.username,
                    pane: PaneInfo(
                        agentStatus: .idle, focused: false, paneID: "shell", revision: 1, tabID: "w1:t1",
                        terminalID: "terminal-shell", workspaceID: "w1", cwd: "/project",
                        terminalTitleStripped: "zsh"),
                    workspaceLabel: "api", tabLabel: "Tab 1", workspaceOrder: 0, tabPosition: 1,
                    snapshotOrder: 0, snapshotAgentKind: nil)
            },
            workspacesByHost: [:], agents: [], hostStatuses: [:], hostStandingFailures: [:],
            hostsAwaitingSnapshot: [], hostSyncErrors: [:], collapsedWorkspaces: [], collapsedHosts: [])
        #expect(terminals.workspaces(filteredHostIDs: store.hostFilter).map(\.hostID) == [tui.id, tmux.id])

        store.pruneHostFilter(keeping: [tui, tmux, build, core])
        #expect(store.hostFilter == [tui.id, tmux.id, core.id])
        store.pruneHostFilter(keeping: [core, build])
        #expect(store.hostFilter == [core.id])

        let m3 = try #require(HostMachine.grouped([core, build]).first)
        store.toggleHostFilter(m3)
        #expect(store.hostFilter.isEmpty)
        store.toggleHostFilter(m3)
        store.pruneHostFilter(keeping: [build])
        #expect(store.hostFilter.isEmpty)
        #expect(ConsoleListPresentationStore(defaults: defaults).hostFilter.isEmpty)
    }

    @Test func aFilterWithOneHostLeftToListShowsAllHosts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (tui, tmux, build) = twoServerCatalog()
        ConsoleListPresentationStore(defaults: defaults).setHostFilter([tmux.id])

        let store = ConsoleListPresentationStore(defaults: defaults)
        store.pruneHostFilter(keeping: [tui, tmux])
        #expect(store.hostFilter.isEmpty)
        #expect(ConsoleListPresentationStore(defaults: defaults).hostFilter.isEmpty)
    }

    @Test func theFilterOffersAHostOnceWhenAnyOfItsServersIsOn() throws {
        let (tui, tmux, build) = twoServerCatalog()
        let rex = Host(name: "m3", address: "m3.example", username: "dev", serverKind: .rex)
        let lab = Host(name: "lab", address: "lab.example", username: "dev", serverKind: .rex)
        let held = Host(name: "spare", address: "spare.example", username: "dev", serverKind: .unconfirmed)
        let catalog = HostStore(volatileHosts: [lab, tui, held, build, tmux, rex])
        #expect(catalog.consoleHosts.first { $0.id == tui.id }?.displayName == "m3 · Herdr TUI")

        // A Host with no Server on is not offered; a Rex-only one is, as both
        // lists show its Agents and Terminals (ADR 0054).
        let offered = ConsoleView.hostFilterChoices(in: catalog)
        #expect(offered.map(\.name) == ["lab", "m3", "Build"])
        // Chosen, a Host keeps every Server it has on.
        let m3 = try #require(offered.dropFirst().first)
        #expect(m3.toggled(in: [build.id]) == [build.id, tui.id, tmux.id, rex.id])
        #expect(m3.toggled(in: [rex.id]).isEmpty)
    }

    @Test func newTerminalStartsOnTheFilteredHost() {
        let (tui, tmux, build) = twoServerCatalog()
        let machines = HostMachine.grouped([tui, tmux, build])
        let m3 = machines.filter { $0.contains(tui.id) }

        #expect(ConsoleView.newTerminalHostID(offered: [tui, build], filteredTo: m3) == tui.id)
        #expect(ConsoleView.newTerminalHostID(offered: [tui, tmux, build], filteredTo: m3) == tui.id)
        #expect(ConsoleView.newTerminalHostID(offered: [tui, build], filteredTo: machines) == nil)
        #expect(ConsoleView.newTerminalHostID(offered: [tui, build], filteredTo: []) == nil)
    }

    @Test func rowsAndSectionsOfEachServerNameTheHostAloneAndCarryBackend() throws {
        let (tui, tmux, build) = twoServerCatalog()
        let catalog = HostStore(volatileHosts: [tui, build, tmux])
        let record = try #require(catalog.consoleHosts.first { $0.id == tmux.id })
        #expect(record.displayName == "m3 · tmux")
        let snapshot = SessionSnapshot(
            agents: [.fixture(paneID: "w1:p1")], layouts: [],
            panes: [
                PaneInfo(
                    agentStatus: .idle, focused: false, paneID: "w1:p2", revision: 1, tabID: "w1:t1",
                    terminalID: "terminal-shell", workspaceID: "w1", cwd: "/project",
                    terminalTitleStripped: "zsh")
            ],
            protocolVersion: 17, tabs: [], version: "test",
            workspaces: [.fixture(workspaceID: "w1", label: "api")])
        let builder = ConsolePaneRowBuilder(host: record, inventory: snapshot)
        let agent = try #require(builder.agentRows { _ in nil }["w1:p1"])
        let shell = try #require(builder.terminalRows(agents: [:]) { _ in nil }["w1:p2"])
        #expect(agent.hostName == "m3")
        #expect(agent.backend == .tmux)
        #expect(shell.hostName == "m3")
        #expect(agent.matchesAgentSearch("M3"))
        #expect(!agent.matchesAgentSearch("tmux"))
        #expect(shell.matchesSearch("m3"))
        #expect(!shell.matchesSearch("tmux"))
        let saved = ChatCachedAgent(agent).consoleAgent(for: record)
        #expect(saved.hostName == "m3")
        #expect(saved.backend == .tmux)

        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ConsoleListPresentationStore(defaults: defaults)
        let records = catalog.consoleHosts
        let serverOrder = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
        let agents = [
            consoleAgent(host: record, paneID: "p1", status: .working, label: "api"),
            consoleAgent(host: try #require(records.first { $0.id == build.id }), paneID: "p1", status: .idle, label: "api"),
            consoleAgent(host: try #require(records.first { $0.id == tui.id }), paneID: "p1", status: .done, label: "api"),
        ].consoleSorted(serverOrder: serverOrder)
        let byHost = store.sections(hosts: records, agents: agents)
        #expect(byHost.map(\.hostName) == ["m3", "Build"])
        #expect(byHost.map(\.hostIDs) == [[tui.id, tmux.id], [build.id]])
        #expect(byHost[0].agents.map(\.hostID) == [tui.id, tmux.id])
        #expect(byHost[0].statusCounts == .init(working: 1, done: 1))

        let cards = store.workspaceSections(hosts: records, agents: agents)
        #expect(cards.map(\.hostName) == ["m3", "m3", "Build"])
        #expect(cards.map(\.id.hostID) == [tui.id, tmux.id, build.id])

        // When a later Server of m3 has a higher-priority Agent, both By Host
        // and By Workspace match All Agents filtered to m3 instead of burying
        // the urgent Agent behind the first Server's Idle rows.
        let tuiRecord = try #require(records.first { $0.id == tui.id })
        let mixed = [
            consoleAgent(host: tuiRecord, paneID: "tui-idle", status: .idle, workspaceID: "w-idle", label: "idle-space"),
            consoleAgent(host: tuiRecord, paneID: "tui-working", status: .working, workspaceID: "w-work", label: "tui-work"),
            consoleAgent(host: record, paneID: "tmux-working", status: .working, workspaceID: "$1", label: "tmux-work"),
            consoleAgent(host: record, paneID: "tmux-blocked", status: .blocked, workspaceID: "$2", label: "tmux-blocked"),
        ].consoleSorted(serverOrder: serverOrder)
        let m3Filter: Set<Host.ID> = [tui.id, tmux.id]
        #expect(mixed.filter { m3Filter.contains($0.hostID) }.map(\.agent.paneID)
            == ["tmux-blocked", "tui-working", "tmux-working", "tui-idle"])
        #expect(store.sections(hosts: records, agents: mixed)[0].agents.map(\.agent.paneID)
            == ["tmux-blocked", "tui-working", "tmux-working", "tui-idle"])
        #expect(store.workspaceSections(hosts: records, agents: mixed).map(\.title)
            == ["tmux-blocked", "tui-work", "tmux-work", "idle-space"])
    }

    /// A Host folded while the list showed a section for each Server stays
    /// folded if any of them was; unfolding drops them all, and folding
    /// holds them all, so a build that lists each Server folds both.
    @Test func aHostStaysFoldedIfAnyOfItsServersWas() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (tui, tmux, build) = twoServerCatalog()
        let hosts = [tui, build, tmux]
        let agents = hosts.map { consoleAgent(host: $0, paneID: "p1", status: .idle) }
        // As a build that listed each Server saved "m3 · tmux" folded.
        ConsoleListPresentationStore(defaults: defaults).setCollapsed(true, for: tmux.id)

        let store = ConsoleListPresentationStore(defaults: defaults)
        #expect(store.sections(hosts: hosts, agents: agents).map(\.isCollapsed) == [true, false])
        store.toggleCollapsed([tui.id, tmux.id])
        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        #expect(reloaded.sections(hosts: hosts, agents: agents).map(\.isCollapsed) == [false, false])
        reloaded.toggleCollapsed([tui.id, tmux.id])
        let folded = ConsoleListPresentationStore(defaults: defaults)
        #expect(folded.isCollapsed([tui.id]))
        #expect(folded.isCollapsed([tmux.id]))
        #expect(!folded.isCollapsed([build.id]))
    }

    /// A Host with no Agents keeps its section while it has something to say
    /// or could start an Agent. A connected Rex Host, which starts none,
    /// would be a bare header and has no section; on its own, the list says
    /// No Agents instead (ADR 0054).
    @Test func aHostWithNothingToListOrSayOrOfferHasNoSection() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (tui, tmux, build) = twoServerCatalog()
        let rex = Host(name: "lab", address: "lab.example", username: "dev", serverKind: .rex)
        let m3Rex = Host(name: "m3", address: "m3.example", username: "dev", serverKind: .rex)
        let store = ConsoleListPresentationStore(defaults: defaults)
        let connected = Dictionary(uniqueKeysWithValues: [tui, tmux, build, rex, m3Rex].map { ($0.id, EventsSessionStatus.connected) })

        let sections = store.sections(hosts: [rex, tui, build, tmux, m3Rex], agents: [], hostStatuses: connected)
        // herdr, tmux and herdr-core could start one; a Host with a Server
        // that could keeps its Rex Server in its section.
        #expect(sections.map(\.hostName) == ["m3", "Build"])
        #expect(sections.first?.hostIDs == [tui.id, tmux.id, m3Rex.id])
        #expect(store.sections(hosts: [rex], agents: [], hostStatuses: connected).isEmpty)

        // Something to say keeps a Rex Host: connecting, loading, or a problem.
        #expect(store.sections(hosts: [rex], agents: []).map(\.hostName) == ["lab"])
        #expect(store.sections(
            hosts: [rex], agents: [], hostStatuses: connected, hostsAwaitingSnapshot: [rex.id]
        ).count == 1)
        #expect(store.sections(
            hosts: [rex], agents: [], hostStatuses: [rex.id: .failed(.authenticationFailed)]
        ).count == 1)
        // So does an Agent.
        let agent = consoleAgent(host: rex, paneID: "codex", status: .working)
        #expect(store.sections(hosts: [rex], agents: [agent], hostStatuses: connected).count == 1)

        #expect(
            ConsoleAgentsSurface(
                hostCount: 1, filteredHostName: nil, filteredAgentCount: 0, visibleIssueCount: 0,
                presentationMode: .grouped, projectedSectionCount: 0) == .noAgents)
    }

    @Test func filterChoicesNameAHostOnceAndChooseAllItsServers() async throws {
        let (tui, tmux, build) = twoServerCatalog()
        let catalog = HostStore(volatileHosts: [tui, build, tmux])
        var selectedHosts: Set<Host.ID> = []
        func choices() -> ConsoleListFilterChoices {
            ConsoleListFilterChoices(
                hosts: ConsoleView.hostFilterChoices(in: catalog),
                hostFilter: Binding(get: { selectedHosts }, set: { selectedHosts = $0 }),
                agentStatuses: nil, counts: [:])
        }
        let controller = UIHostingController(rootView: choices())
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 320, height: 568), rootViewController: controller
        ) { window in
            try await Task.sleep(for: .milliseconds(300))
            #expect(accessibleElement(labeled: "m3 · Herdr TUI", in: window) == nil)
            #expect(accessibleElement(labeled: "m3 · tmux", in: window) == nil)
            #expect(accessibleElement(labeled: "Build", in: window) != nil)
            let m3 = try #require(accessibleElement(labeled: "m3", in: window))
            #expect(m3.accessibilityActivate())
            #expect(selectedHosts == [tui.id, tmux.id])
            // The binding reads a local, so the view is drawn again to show it.
            controller.rootView = choices()
            try await Task.sleep(for: .milliseconds(100))
            let chosen = try #require(accessibleElement(labeled: "m3", in: window))
            #expect(chosen.accessibilityTraits.contains(.selected))
            #expect(chosen.accessibilityActivate())
            #expect(selectedHosts.isEmpty)
        }
    }

    @Test(.serialized, arguments: [DynamicTypeSize.large, .accessibility3])
    func filterChoicesKeepHostsBoundedAndSelectionsIndependent(textSize: DynamicTypeSize) async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleStatusFilter(.blocked)
        store.toggleStatusFilter(.working)
        let hosts = (1...20).map { Host.fixture(name: "Host \($0)", address: "host-\($0).example") }
        let machines = HostMachine.grouped(hosts)
        var selectedHosts: Set<Host.ID> = [hosts[0].id]
        let view = ConsoleListFilterChoices(
            hosts: machines, hostFilter: Binding(get: { selectedHosts }, set: { selectedHosts = $0 }),
            agentStatuses: store, counts: [.blocked: 1, .working: 2, .done: 3, .idle: 4])
            .environment(\.dynamicTypeSize, textSize)
        let controller = UIHostingController(rootView: view)
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 320, height: 568), rootViewController: controller
        ) { window in
            try await Task.sleep(for: .milliseconds(300))
            let hostScroll = try #require(accessibleElements(in: window).compactMap { $0 as? UIScrollView }
                .first { $0.contentSize.height > 800 })
            #expect(hostScroll.bounds.height <= 220)
            let all = try #require(accessibleElement(labeled: "All Status", in: window))
            let statusY = all.accessibilityFrame.minY
            #expect(statusY >= hostScroll.convert(hostScroll.bounds, to: window).maxY)
            #expect(!all.accessibilityTraits.contains(.selected))
            let hint = try #require(accessibleElement(labeled: "More Hosts below", in: window))
            #expect(hint.accessibilityFrame.minY >= hostScroll.convert(hostScroll.bounds, to: window).maxY)
            #expect(hint.accessibilityFrame.maxY < statusY)

            // The final Host remains reachable without moving the status section.
            hostScroll.setContentOffset(CGPoint(x: 0, y: hostScroll.contentSize.height - hostScroll.bounds.height), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            #expect(accessibleElement(labeled: "More Hosts below", in: window) == nil)
            let lastHost = try #require(accessibleElement(labeled: "Host 20", in: window))
            #expect(hostScroll.convert(hostScroll.bounds, to: window).contains(lastHost.accessibilityFrame))
            #expect(lastHost.accessibilityActivate())
            #expect(selectedHosts == [hosts[0].id, hosts[19].id])
            #expect(lastHost.accessibilityActivate())
            #expect(selectedHosts == [hosts[0].id])
            #expect(lastHost.accessibilityActivate())
            #expect(abs(all.accessibilityFrame.minY - statusY) < 1)
            #expect(all.accessibilityActivate())
            try await Task.sleep(for: .milliseconds(100))
            #expect(store.statusFilter.isEmpty)
            #expect(ConsoleListPresentationStore(defaults: defaults).statusFilter.isEmpty)
            #expect(selectedHosts == [hosts[0].id, hosts[19].id])
            #expect(accessibleElement(labeled: "All Status", in: window)?.accessibilityTraits.contains(.selected) == true)

            store.toggleStatusFilter(.done)
            hostScroll.setContentOffset(.zero, animated: false)
            try await Task.sleep(for: .milliseconds(100))
            #expect(accessibleElement(labeled: "More Hosts below", in: window) != nil)
            let allHosts = try #require(accessibleElement(labeled: "All Hosts", in: window))
            #expect(allHosts.accessibilityActivate())
            #expect(selectedHosts.isEmpty)
            #expect(store.statusFilter == [.done])
            let firstHost = try #require(accessibleElement(labeled: "Host 1", in: window))
            #expect(firstHost.accessibilityActivate())
            #expect(selectedHosts == [hosts[0].id])
            #expect(firstHost.accessibilityActivate())
            #expect(selectedHosts.isEmpty)

            // A short inventory needs neither a hint nor extra footer space.
            controller.rootView = ConsoleListFilterChoices(
                hosts: Array(machines.prefix(2)),
                hostFilter: Binding(get: { selectedHosts }, set: { selectedHosts = $0 }),
                agentStatuses: store, counts: [:])
                .environment(\.dynamicTypeSize, .large)
            try await Task.sleep(for: .milliseconds(200))
            #expect(accessibleElement(labeled: "More Hosts below", in: window) == nil)
        }
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-list-presentation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func consoleAgent(
        host: Host,
        paneID: String,
        status: AgentStatus,
        workspaceID: String = "w1",
        label: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.hostName,
            agent: Agent(.fixture(paneID: paneID, status: status, workspaceID: workspaceID)),
            workspaceLabel: label,
            repositoryCheckout: nil,
            backend: host.serverKind.agentBackend)
    }

    @Test func workspaceGroupsUseHostAndOpaqueIDAndKeepIncomingOrder() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "Studio", address: "studio.example")
        let second = Host.fixture(name: "Build", address: "build.example")
        let agents = [
            consoleAgent(host: second, paneID: "p1", status: .blocked, label: "Shared"),
            consoleAgent(host: first, paneID: "p2", status: .done, workspaceID: "w2", label: "Shared"),
            consoleAgent(host: first, paneID: "p1", status: .working, label: "Shared"),
            consoleAgent(host: first, paneID: "p3", status: .idle, workspaceID: "w2", label: "Shared"),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        let groups = store.workspaceSections(hosts: [first, second, first], agents: agents)
        #expect(groups.map(\.id) == [
            .init(hostID: first.id, workspaceID: "w2"),
            .init(hostID: first.id, workspaceID: "w1"),
            .init(hostID: second.id, workspaceID: "w1"),
        ])
        #expect(groups.map { $0.agents.map(\.id) } == [
            [agents[1].id, agents[3].id], [agents[2].id], [agents[0].id],
        ])
        #expect(groups.allSatisfy { !$0.isCollapsed && $0.title == "Shared" })
        #expect(ConsoleWorkspaceCard.cards(groups).flatMap(\.visibleAgentIDs).count == agents.count)
        let filtered = store.workspaceSections(
            hosts: [first, second], agents: agents, filteredHostIDs: [second.id])
        #expect(filtered.map(\.id) == [.init(hostID: second.id, workspaceID: "w1")])
    }

    @Test func workspaceCollapsePersistsAcrossRenameAndReconnectButNotOtherHosts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "Studio", address: "studio.example")
        let second = Host.fixture(name: "Build", address: "build.example")
        let opaqueID = "workspace:/with|separators"
        let id = ConsoleWorkspaceSection.ID(hostID: first.id, workspaceID: opaqueID)
        let agents = [first, second].map {
            consoleAgent(host: $0, paneID: "p1", status: .blocked, workspaceID: opaqueID, label: "Renamed")
        }
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleWorkspace(id)
        #expect(store.workspaceSections(hosts: [], agents: []).isEmpty)
        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        let groups = reloaded.workspaceSections(hosts: [first, second], agents: agents)
        let collapsed = try #require(groups.first)
        #expect(collapsed.title == "Renamed")
        #expect(collapsed.isCollapsed)
        #expect(collapsed.statusCounts == .init(blocked: 1))
        #expect(collapsed.accessibilityValue == "1 Agent, Collapsed, 1 blocked")
        #expect(groups.last?.isCollapsed == false)
        reloaded.toggleWorkspace(id)
        #expect(ConsoleListPresentationStore(defaults: defaults)
            .workspaceSections(hosts: [first], agents: agents).first?.isCollapsed == false)
    }

    @Test func workspaceSearchRevealsOnlyMatchesWithoutChangingCollapsePreference() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            consoleAgent(host: host, paneID: "p1", status: .working, label: "Website"),
            consoleAgent(host: host, paneID: "p2", status: .done, workspaceID: "w2", label: "API"),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleWorkspace(.init(hostID: host.id, workspaceID: "w1"))
        let result = store.workspaceSections(hosts: [host], agents: agents, searchQuery: "  WEBSITE  ")
        #expect(result.count == 1)
        #expect(result.first?.isCollapsed == false)
        #expect(ConsoleWorkspaceCard.cards(result).flatMap(\.visibleAgentIDs) == [agents[0].id])
        #expect(store.workspaceSections(hosts: [host], agents: agents, searchQuery: "does-not-exist").isEmpty)
        #expect(store.workspaceSections(hosts: [host], agents: agents, searchQuery: " \n").first?.isCollapsed == true)
    }

    private func checkoutAgent(
        host: Host, paneID: String, status: AgentStatus, workspaceID: String, label: String,
        repo: String?, linked: Bool = false
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status, workspaceID: workspaceID)),
            workspaceLabel: label,
            repositoryCheckout: repo.map {
                RepositoryCheckout(
                    repoKey: "/src/\($0)/.git", repoName: $0, repoRoot: "/src/\($0)",
                    checkoutPath: linked ? "/wt/\(label)" : "/src/\($0)", isLinkedWorktree: linked)
            })
    }

    private func sid(_ host: Host, _ workspaceID: String) -> ConsoleWorkspaceSection.ID {
        .init(hostID: host.id, workspaceID: workspaceID)
    }

    @Test func linkedWorktreesNestUnderTheirMainCheckoutInPriorityOrder() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            checkoutAgent(host: host, paneID: "p1", status: .working, workspaceID: "w1J", label: "PXD-5", repo: "plexus-Diagram", linked: true),
            checkoutAgent(host: host, paneID: "p2", status: .done, workspaceID: "wY", label: "plexus-Diagram", repo: "plexus-Diagram"),
            checkoutAgent(host: host, paneID: "p3", status: .idle, workspaceID: "wT", label: "Heeler Home", repo: nil),
            checkoutAgent(host: host, paneID: "p4", status: .blocked, workspaceID: "w1N", label: "PXD-7", repo: "plexus-Diagram", linked: true),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        let groups = store.workspaceSections(hosts: [host], agents: agents)
        #expect(groups.map(\.id) == [sid(host, "wY"), sid(host, "w1J"), sid(host, "w1N"), sid(host, "wT")])
        #expect(groups.map(\.parentID) == [nil, sid(host, "wY"), sid(host, "wY"), nil])
    }

    @Test func worktreeJoinsTheFirstMainCheckoutWhenSeveralShareARepoKey() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            checkoutAgent(host: host, paneID: "p1", status: .done, workspaceID: "w16", label: "roam-burrow", repo: "roam-burrow"),
            checkoutAgent(host: host, paneID: "p2", status: .working, workspaceID: "w10", label: "BRW-10", repo: "roam-burrow", linked: true),
            checkoutAgent(host: host, paneID: "p3", status: .idle, workspaceID: "w13", label: "roam-burrow", repo: "roam-burrow"),
        ]
        let groups = ConsoleListPresentationStore(defaults: defaults)
            .workspaceSections(hosts: [host], agents: agents)
        #expect(groups.map(\.id) == [sid(host, "w16"), sid(host, "w10"), sid(host, "w13")])
        #expect(groups.map(\.parentID) == [nil, sid(host, "w16"), nil])
    }

    @Test func worktreeWithoutAMainCheckoutWorkspaceStaysTopLevel() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            checkoutAgent(host: host, paneID: "p1", status: .working, workspaceID: "w22", label: "DASH-2", repo: "Food_Safety", linked: true),
            checkoutAgent(host: host, paneID: "p2", status: .idle, workspaceID: "w23", label: "DASH-3", repo: "Food_Safety", linked: true),
        ]
        let groups = ConsoleListPresentationStore(defaults: defaults)
            .workspaceSections(hosts: [host], agents: agents)
        #expect(groups.map(\.id) == [sid(host, "w22"), sid(host, "w23")])
        #expect(groups.allSatisfy { $0.parentID == nil })
    }

    @Test func worktreesNeverNestAcrossHosts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "Studio", address: "studio.example")
        let second = Host.fixture(name: "Build", address: "build.example")
        let agents = [
            checkoutAgent(host: first, paneID: "p1", status: .done, workspaceID: "wY", label: "plexus-Diagram", repo: "plexus-Diagram"),
            checkoutAgent(host: second, paneID: "p2", status: .working, workspaceID: "w1J", label: "PXD-5", repo: "plexus-Diagram", linked: true),
        ]
        let groups = ConsoleListPresentationStore(defaults: defaults)
            .workspaceSections(hosts: [first, second], agents: agents)
        #expect(groups.map(\.id) == [sid(first, "wY"), sid(second, "w1J")])
        #expect(groups.allSatisfy { $0.parentID == nil })
    }

    @Test func collapsedRepositoryCardCountsItsWorktreesAndHidesThem() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            checkoutAgent(host: host, paneID: "p1", status: .done, workspaceID: "wY", label: "plexus-Diagram", repo: "plexus-Diagram"),
            checkoutAgent(host: host, paneID: "p2", status: .blocked, workspaceID: "w1J", label: "PXD-5", repo: "plexus-Diagram", linked: true),
            checkoutAgent(host: host, paneID: "p3", status: .working, workspaceID: "w1N", label: "PXD-7", repo: "plexus-Diagram", linked: true),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleWorkspace(sid(host, "wY"))
        let card = try #require(
            ConsoleWorkspaceCard.cards(store.workspaceSections(hosts: [host], agents: agents)).first)
        #expect(card.isCollapsed)
        #expect(ConsoleHostAgentStatusCounts(agents: card.agents) == .init(blocked: 1, working: 1, done: 1))
        #expect(card.accessibilityValue == "3 Agents, Collapsed, 1 blocked, 1 working, 1 done")
        #expect(rowShape(card) == ["header", "summary"])
        #expect(card.visibleAgentIDs.isEmpty)

        store.toggleWorkspace(sid(host, "wY"))
        let groups = store.workspaceSections(hosts: [host], agents: agents)
        // Each section counts its own Agents; the card adds them up.
        #expect(groups.map(\.statusCounts) == [.init(done: 1), .init(blocked: 1), .init(working: 1)])
        #expect(ConsoleWorkspaceCard.cards(groups).first?.visibleAgentIDs == agents.map(\.id))
    }

    @Test func parentAndChildCollapseStatePersistsIndependently() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            checkoutAgent(host: host, paneID: "p1", status: .done, workspaceID: "wY", label: "plexus-Diagram", repo: "plexus-Diagram"),
            checkoutAgent(host: host, paneID: "p2", status: .blocked, workspaceID: "w1J", label: "PXD-5", repo: "plexus-Diagram", linked: true),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleWorkspace(sid(host, "w1J"))
        var reloaded = ConsoleListPresentationStore(defaults: defaults)
        var groups = reloaded.workspaceSections(hosts: [host], agents: agents)
        #expect(groups.map(\.isCollapsed) == [false, true])
        reloaded.toggleWorkspace(sid(host, "wY"))
        reloaded = ConsoleListPresentationStore(defaults: defaults)
        groups = reloaded.workspaceSections(hosts: [host], agents: agents)
        #expect(groups.map(\.isCollapsed) == [true, true])
        reloaded.toggleWorkspace(sid(host, "wY"))
        groups = ConsoleListPresentationStore(defaults: defaults).workspaceSections(hosts: [host], agents: agents)
        #expect(groups.map(\.isCollapsed) == [false, true])
    }

    @Test func searchOpensParentAndChildWithoutChangingSavedCollapse() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            checkoutAgent(host: host, paneID: "p1", status: .done, workspaceID: "wY", label: "plexus-Diagram", repo: "plexus-Diagram"),
            checkoutAgent(host: host, paneID: "p2", status: .blocked, workspaceID: "w1J", label: "PXD-5", repo: "plexus-Diagram", linked: true),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleWorkspace(sid(host, "wY"))
        store.toggleWorkspace(sid(host, "w1J"))
        // A match inside the child keeps its (unmatched) parent as the header.
        let found = store.workspaceSections(hosts: [host], agents: agents, searchQuery: "PXD-5")
        #expect(found.map(\.id) == [sid(host, "wY"), sid(host, "w1J")])
        #expect(found.map(\.parentID) == [nil, sid(host, "wY")])
        #expect(found.map(\.isCollapsed) == [false, false])
        #expect(found.first?.agents.isEmpty == true)
        #expect(ConsoleWorkspaceCard.cards(found).flatMap(\.visibleAgentIDs) == [agents[1].id])
        let cleared = store.workspaceSections(hosts: [host], agents: agents, searchQuery: "")
        #expect(cleared.map(\.isCollapsed) == [true, true])
    }

    private func rowShape(_ card: ConsoleWorkspaceCard) -> [String] {
        card.rows.map { placed in
            let rule = switch placed.rule {
            case .none: ""
            case .full: "—"
            }
            return switch placed.row {
            case .header: "\(rule)header"
            case .summary: "\(rule)summary"
            case .checkout(let section): "\(rule)checkout \(section.title)"
            case .agent(let agent, _, let alone): "\(rule)\(alone ? "alone" : "agent") \(agent.agent.paneID)"
            }
        }
    }

    @Test func repositoryCardTitlesEachCheckoutOnceAndListsSeveralAgentsUnderIt() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            checkoutAgent(host: host, paneID: "p1", status: .working, workspaceID: "wY", label: "Heeler", repo: "heeler"),
            checkoutAgent(host: host, paneID: "p2", status: .blocked, workspaceID: "w1", label: "fix-inset", repo: "heeler", linked: true),
            checkoutAgent(host: host, paneID: "p3", status: .done, workspaceID: "w2", label: "nest", repo: "heeler", linked: true),
            checkoutAgent(host: host, paneID: "p4", status: .working, workspaceID: "w2", label: "nest", repo: "heeler", linked: true),
            checkoutAgent(host: host, paneID: "p5", status: .idle, workspaceID: "wD", label: "Docs", repo: nil),
            checkoutAgent(host: host, paneID: "p6", status: .idle, workspaceID: "wA", label: "API", repo: nil),
            checkoutAgent(host: host, paneID: "p7", status: .done, workspaceID: "wA", label: "API", repo: nil),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        let cards = ConsoleWorkspaceCard.cards(store.workspaceSections(hosts: [host], agents: agents))
        #expect(cards.map(\.id) == [sid(host, "wY"), sid(host, "wD"), sid(host, "wA")])
        let repository = try #require(cards.first)
        #expect(repository.isRepository)
        #expect(repository.primary.checkout?.repoName == "heeler")
        #expect(repository.agents.count == 4)
        #expect(rowShape(repository) == [
            "header", "alone p1", "—alone p2", "—checkout nest", "agent p3", "agent p4",
        ])
        #expect(repository.rows.map(\.isFirst) == [true, false, false, false, false, false])
        #expect(repository.rows.map(\.isLast) == [false, false, false, false, false, true])
        #expect(repository.rows.map(\.followsHeader) == [false, true, false, false, true, false])
        // A Workspace with one Agent is that Agent's card; with several, a header leads.
        #expect(rowShape(cards[1]) == ["alone p5"])
        #expect(rowShape(cards[2]) == ["header", "agent p6", "agent p7"])
        #expect(cards.flatMap(\.visibleAgentIDs) == agents.map(\.id))
    }

    @Test func cardsFoldAsTheirSectionsDoButALoneAgentHasNothingToFold() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            checkoutAgent(host: host, paneID: "p1", status: .working, workspaceID: "wY", label: "Heeler", repo: "heeler"),
            checkoutAgent(host: host, paneID: "p2", status: .done, workspaceID: "w2", label: "nest", repo: "heeler", linked: true),
            checkoutAgent(host: host, paneID: "p3", status: .working, workspaceID: "w2", label: "nest", repo: "heeler", linked: true),
            checkoutAgent(host: host, paneID: "p4", status: .idle, workspaceID: "wD", label: "Docs", repo: nil),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleWorkspace(sid(host, "w2"))
        store.toggleWorkspace(sid(host, "wD"))
        var cards = ConsoleWorkspaceCard.cards(store.workspaceSections(hosts: [host], agents: agents))
        #expect(rowShape(cards[0]) == ["header", "alone p1", "—checkout nest"])
        #expect(rowShape(cards[1]) == ["alone p4"])
        #expect(cards.flatMap(\.visibleAgentIDs) == [agents[0].id, agents[3].id])

        store.toggleWorkspace(sid(host, "wY"))
        cards = ConsoleWorkspaceCard.cards(store.workspaceSections(hosts: [host], agents: agents))
        // A fold swaps the rows under the header for its summary, so the
        // header keeps its height.
        #expect(rowShape(cards[0]) == ["header", "summary"])
        #expect(cards[0].rows.map(\.isLast) == [false, true])
        #expect(cards[0].accessibilityValue == "3 Agents, Collapsed, 2 working, 1 done")
        #expect(cards.flatMap(\.visibleAgentIDs) == [agents[3].id])
    }

    @Test func collapsedWorkspaceWithNothingToSummarizeEndsAtItsHeader() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        var agents = [
            checkoutAgent(host: host, paneID: "p1", status: .idle, workspaceID: "wA", label: "API", repo: "api"),
            checkoutAgent(host: host, paneID: "p2", status: .idle, workspaceID: "wA", label: "API", repo: "api"),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleWorkspace(sid(host, "wA"))
        var card = try #require(
            ConsoleWorkspaceCard.cards(store.workspaceSections(hosts: [host], agents: agents)).first)
        // An empty summary row would be shorter than the card's corners.
        #expect(card.isCollapsed)
        #expect(rowShape(card) == ["header"])
        #expect(card.rows.map(\.isLast) == [true])

        agents[1] = checkoutAgent(
            host: host, paneID: "p2", status: .working, workspaceID: "wA", label: "API", repo: "api")
        card = try #require(
            ConsoleWorkspaceCard.cards(store.workspaceSections(hosts: [host], agents: agents)).first)
        #expect(rowShape(card) == ["header", "summary"])
    }

    @Test func searchKeepsTheRepositoryHeaderButNotItsUnmatchedMainCheckout() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            checkoutAgent(host: host, paneID: "p1", status: .working, workspaceID: "wY", label: "Heeler", repo: "heeler"),
            checkoutAgent(host: host, paneID: "p2", status: .blocked, workspaceID: "w1", label: "PXD-5", repo: "heeler", linked: true),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        let cards = ConsoleWorkspaceCard.cards(
            store.workspaceSections(hosts: [host], agents: agents, searchQuery: "PXD-5"))
        #expect(cards.count == 1)
        #expect(rowShape(try #require(cards.first)) == ["header", "alone p2"])
    }

    @Test func savedStructureKeepsTheRepositoryCardOfAnEntryWhoseWorktreesAreNotListed() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        // A saved entry reports no checkout; the last snapshot's structure does.
        let saved = consoleAgent(host: host, paneID: "p1", status: .unknown, workspaceID: "wY", label: "Heeler")
        let live = checkoutAgent(host: host, paneID: "p9", status: .working, workspaceID: "w1", label: "nest", repo: "heeler", linked: true)
        let main = checkoutAgent(host: host, paneID: "p1", status: .working, workspaceID: "wY", label: "Heeler", repo: "heeler")
        let structure = try [main, live].map {
            ChatCachedWorkspace(id: $0.agent.workspaceID, label: $0.workspaceLabel, checkout: try #require($0.repositoryCheckout))
        }
        let store = ConsoleListPresentationStore(defaults: defaults)

        let cards = ConsoleWorkspaceCard.cards(
            store.workspaceSections(hosts: [host], agents: [saved], savedStructures: [host.id: structure]))

        #expect(cards.map(\.id) == [sid(host, "wY")])
        let card = try #require(cards.first)
        #expect(card.isRepository)
        #expect(card.primary.checkout == main.repositoryCheckout)
        #expect(rowShape(card) == ["header", "alone p1"])
        let liveCard = try #require(
            ConsoleWorkspaceCard.cards(store.workspaceSections(hosts: [host], agents: [main, live])).first)
        #expect(liveCard.id == card.id)
        #expect(liveCard.nested.map(\.id) == card.nested.map(\.id))
        // A search lists only matches and so no worktree without one.
        let searched = ConsoleWorkspaceCard.cards(store.workspaceSections(
            hosts: [host], agents: [saved], savedStructures: [host.id: structure], searchQuery: "Heeler"))
        #expect(searched.map(rowShape) == [["alone p1"]])
        // Without a structure the entry is a Workspace of its own.
        let unplaced = ConsoleWorkspaceCard.cards(store.workspaceSections(hosts: [host], agents: [saved]))
        #expect(unplaced.map(rowShape) == [["alone p1"]])
        #expect(unplaced.first?.primary.checkout == nil)
    }

    @Test func rowsInACardLeaveTheWorkspaceHostAndCheckoutDirectoryToIt() {
        let host = Host.fixture()
        let atCheckout = checkoutAgent(
            host: host, paneID: "p1", status: .idle, workspaceID: "w1", label: "nest", repo: "heeler", linked: true)
        #expect(ConsoleWorkspaceCard.hiddenTokens(for: atCheckout, checkoutPath: atCheckout.checkoutPath, showsHost: false) == [.workspace, .host])
        #expect(ConsoleWorkspaceCard.hiddenTokens(for: atCheckout, checkoutPath: atCheckout.checkoutPath, showsHost: true) == [.workspace])
        let inCheckout = ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(
                terminalID: "term_p2", kind: "claude", title: "Task", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: "p2", cwd: "/wt/nest", revision: 1),
            workspaceLabel: "nest", repositoryCheckout: atCheckout.repositoryCheckout)
        #expect(ConsoleWorkspaceCard.hiddenTokens(for: inCheckout, checkoutPath: inCheckout.checkoutPath, showsHost: true) == [.workspace, .directory, .path])

        let layout = AgentRowLayout(rows: [
            [.init(.workspace), .init(.host)], [.init(.agent)], [.init(.directory), .init(.path)],
        ])
        let card = AgentCardPresentation(
            agent: inCheckout, layout: layout,
            hiding: ConsoleWorkspaceCard.hiddenTokens(for: inCheckout, checkoutPath: inCheckout.checkoutPath, showsHost: false))
        #expect(card.headline == inCheckout.agent.displayName)
        #expect(card.additionalRows.isEmpty)
    }

    @Test func checkoutTitlesNameTheMainCheckoutByBranchAndAWorktreeByWorkspace() {
        typealias Title = ConsoleCheckoutTitle
        let main = Title.Role.mainCheckout
        let worktree = Title.Role.worktree
        #expect(Title(label: "Heeler", isMainCheckout: true, branch: .named("release/1.4"))
            == Title(title: "release/1.4", role: main))
        #expect(Title(label: "Heeler", isMainCheckout: true, branch: .detached)
            == Title(title: "Heeler", detail: "detached", role: main))
        #expect(Title(label: "Heeler", isMainCheckout: true, branch: nil)
            == Title(title: "Heeler", isPending: true, role: main))
        #expect(Title(label: "nest", isMainCheckout: false, branch: .named("feat/nest"))
            == Title(title: "nest", detail: "feat/nest", role: worktree))
        #expect(Title(label: "fix-inset", isMainCheckout: false, branch: .named("fix-inset"))
            == Title(title: "fix-inset", role: worktree))
        #expect(Title(label: "ipad", isMainCheckout: false, branch: .detached)
            == Title(title: "ipad", detail: "detached", role: worktree))
        #expect(Title(label: "ipad", isMainCheckout: false, branch: nil) == Title(title: "ipad", role: worktree))
    }

    @Test func checkoutTitlesTellVoiceOverWhatTheIconShows() {
        typealias Title = ConsoleCheckoutTitle
        #expect(Title(label: "Heeler", isMainCheckout: true, branch: .named("main")).accessibilityLabel
            == "Branch main")
        #expect(Title(label: "Heeler", isMainCheckout: true, branch: .detached).accessibilityLabel
            == "Heeler, detached")
        #expect(Title(label: "Heeler", isMainCheckout: true, branch: nil).accessibilityLabel == "Heeler")
        #expect(Title(label: "nest", isMainCheckout: false, branch: .named("feat/nest")).accessibilityLabel
            == "nest, worktree, branch feat/nest")
        #expect(Title(label: "nest", isMainCheckout: false, branch: .named("nest")).accessibilityLabel
            == "nest, worktree")
        #expect(Title(label: "ipad", isMainCheckout: false, branch: .detached).accessibilityLabel
            == "ipad, worktree, detached")
        #expect(Title(title: "Docs").accessibilityLabel == "Docs")
    }

    @Test func aCheckoutTakesTheBranchOnlyFromAReadOfThatCheckout() {
        func read(_ path: String, _ branch: CheckoutHead.Branch) -> CheckoutChanges {
            CheckoutChanges(
                checkout: CheckoutLocation(
                    topLevel: Data(path.utf8), isLinkedWorktree: false, displayPath: path),
                head: CheckoutHead(branch: branch, commit: nil, latestCommit: nil),
                files: [])
        }
        let reads = [read("/src/other", .named("elsewhere")), read("/src/heeler", .named("main"))]
        #expect(ConsoleCheckoutTitle.branch(at: "/src/heeler", in: reads) == .named("main"))
        #expect(ConsoleCheckoutTitle.branch(at: "/src/missing", in: reads) == nil)
        #expect(ConsoleCheckoutTitle.branch(at: nil, in: reads) == nil)
    }

    @Test func workspaceGroupsReprojectNamesStatusesMembershipAndMissingLabels() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let store = ConsoleListPresentationStore(defaults: defaults)
        let original = consoleAgent(host: host, paneID: "p1", status: .working)
        #expect(store.workspaceSections(hosts: [host], agents: [original]).first?.title == "w1")
        let updated = consoleAgent(host: host, paneID: "p1", status: .done, label: "Website")
        let added = consoleAgent(host: host, paneID: "p2", status: .blocked, label: "Website")
        let groups = store.workspaceSections(hosts: [host], agents: [added, updated])
        #expect(groups.first?.title == "Website")
        #expect(groups.first?.statusCounts == .init(blocked: 1, done: 1))
        #expect(groups.first?.agents.map(\.id) == [added.id, updated.id])
        #expect(store.workspaceSections(hosts: [host], agents: []).isEmpty)
        let unnamed = consoleAgent(host: host, paneID: "p3", status: .idle, workspaceID: "", label: " \n")
        #expect(store.workspaceSections(hosts: [host], agents: [unnamed]).first?.title == "Unknown Workspace")
    }

    @Test func presentationModeDefaultsToFlatAndPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = ConsoleListPresentationStore(defaults: defaults)
        #expect(store.mode == .flat)

        store.select(.grouped)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == .grouped)

        store.select(.flat)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == .flat)
    }

    @Test func collapsedStatePersistsAndIsIsolatedPerHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostA = Host.fixture(name: "alpha", address: "alpha.example")
        let hostB = Host.fixture(name: "beta", address: "beta.example")

        let store = ConsoleListPresentationStore(defaults: defaults)
        store.setCollapsed(true, for: hostA.id)

        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        #expect(reloaded.isCollapsed([hostA.id]))
        #expect(!reloaded.isCollapsed([hostB.id]))

        reloaded.toggleCollapsed([hostB.id])
        reloaded.toggleCollapsed([hostA.id])
        let reloadedAgain = ConsoleListPresentationStore(defaults: defaults)
        #expect(!reloadedAgain.isCollapsed([hostA.id]))
        #expect(reloadedAgain.isCollapsed([hostB.id]))
    }

    @Test func sectionsFollowCatalogOrderAndFilterToSelectedHosts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "zeta", address: "zeta.example")
        let second = Host.fixture(name: "alpha", address: "alpha.example")
        let third = Host.fixture(name: "beta", address: "beta.example")
        let hosts = [first, second, third]
        let agents = [
            consoleAgent(host: third, paneID: "p3", status: .working),
            consoleAgent(host: second, paneID: "p2", status: .working),
            consoleAgent(host: first, paneID: "p1", status: .done),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)

        let all = store.sections(hosts: hosts, agents: agents)
        #expect(all.map(\.hostID) == [first.id, second.id, third.id])

        let filtered = store.sections(
            hosts: hosts, agents: agents, filteredHostIDs: [second.id])
        #expect(filtered.map(\.hostID) == [second.id])

        let missing = store.sections(
            hosts: hosts, agents: agents, filteredHostIDs: [UUID()])
        #expect(missing.isEmpty)

        let selected: Set<Host.ID> = [third.id, first.id]
        #expect(store.sections(hosts: hosts, agents: agents, filteredHostIDs: selected)
            .map(\.hostID) == [first.id, third.id])
        #expect(store.workspaceSections(hosts: hosts, agents: agents, filteredHostIDs: selected)
            .map(\.id.hostID) == [first.id, third.id])
        store.toggleStatusFilter(.working)
        #expect(store.sections(hosts: hosts, agents: agents, filteredHostIDs: selected)
            .flatMap(\.agents).map(\.id) == [agents[0].id])
        #expect(store.workspaceSections(hosts: hosts, agents: agents, filteredHostIDs: selected)
            .flatMap(\.agents).map(\.id) == [agents[0].id])
    }

    @Test func sectionsPreserveTheSuppliedAgentOrderWithinEachHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostA = Host.fixture(name: "alpha", address: "alpha.example")
        let hostB = Host.fixture(name: "beta", address: "beta.example")
        let aIdle = consoleAgent(host: hostA, paneID: "opaque-A", status: .idle)
        let bBlocked = consoleAgent(host: hostB, paneID: "%opaque-B", status: .blocked)
        let aDone = consoleAgent(host: hostA, paneID: "opaque-C", status: .done)
        let bWorking = consoleAgent(host: hostB, paneID: "opaque-D", status: .working)
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sections(
            hosts: [hostA, hostB],
            agents: [aIdle, bBlocked, aDone, bWorking])

        #expect(sections[0].agents.map(\.agent.paneID) == ["opaque-A", "opaque-C"])
        #expect(sections[1].agents.map(\.agent.paneID) == ["%opaque-B", "opaque-D"])
    }

    @Test func changedInputsReprojectMembershipAndReadiness() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "studio")
        let working = consoleAgent(host: host, paneID: "pane-1", status: .working)
        let done = consoleAgent(host: host, paneID: "pane-2", status: .done)
        let store = ConsoleListPresentationStore(defaults: defaults)

        let loading = store.sections(
            hosts: [host],
            agents: [working],
            hostStatuses: [host.id: .connected],
            hostsAwaitingSnapshot: [host.id])
        #expect(loading[0].agents.map(\.id) == [working.id])
        #expect(loading[0].servers.first?.isAwaitingSnapshot == true)
        #expect(loading[0].issues.first?.message == "Loading Agents from studio…")

        let refreshed = store.sections(
            hosts: [host],
            agents: [done],
            hostStatuses: [host.id: .connected])
        #expect(refreshed[0].agents.map(\.id) == [done.id])
        #expect(refreshed[0].servers.first?.isAwaitingSnapshot == false)
        #expect(refreshed[0].issues.isEmpty)
    }

    @Test func emptyAndDisconnectedHostsRemainSections() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let empty = Host.fixture(name: "empty", address: "empty.example")
        let disconnected = Host.fixture(name: "offline", address: "offline.example")
        let failure = TransportError.sshUnreachable(detail: "connection refused")
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sections(
            hosts: [empty, disconnected],
            agents: [],
            hostStatuses: [
                empty.id: .connected,
                disconnected.id: .failed(failure),
            ])

        #expect(sections.count == 2)
        #expect(sections[0].agents.isEmpty)
        #expect(sections[1].agents.isEmpty)
        #expect(sections[0].servers.first?.connectionStatus == .connected)
        #expect(sections[0].issues.isEmpty)
        #expect(sections[1].servers.first?.connectionStatus == .failed(failure))
        #expect(sections[1].issues.first?.hostID == disconnected.id)
    }

    @Test func statusCountsMatchLiveActivityStatusesEvenWhenCollapsed() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            consoleAgent(host: host, paneID: "blocked", status: .blocked),
            consoleAgent(host: host, paneID: "done", status: .done),
            consoleAgent(host: host, paneID: "working", status: .working),
            consoleAgent(host: host, paneID: "idle", status: .idle),
            consoleAgent(
                host: host, paneID: "unknown", status: AgentStatus(rawValue: "future")),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.setCollapsed(true, for: host.id)

        let section = try #require(store.sections(hosts: [host], agents: agents).first)
        #expect(section.isCollapsed)
        #expect(section.statusCounts == .init(blocked: 1, working: 1, done: 1))
        #expect(section.statusCounts.items.map(\.status) == [.blocked, .working, .done])
    }
}

@Suite("Agent card presentation")
struct AgentCardPresentationTests {
    @Test func defaultsShowWorkspaceThenAgentWithoutTheOldDirectoryRow() {
        let card = AgentCardPresentation(agent: agent(workspace: "Project"))
        #expect(card.headline == "Project")
        #expect(card.additionalRows == ["reviewer"])
    }

    @Test func configuredTitlesAndPluginTextStayLiteralAndRetainStyles() throws {
        let layout = AgentRowLayout(rows: [
            [.init(.stateIcon), .init(.terminalTitleStripped, fg: HexColor("#abc"), bold: true)],
            [.init(.custom("note")), .init(.agent)],
        ])
        let card = AgentCardPresentation(agent: agent(), layout: layout)
        #expect(card.headline == "Task title")
        #expect(card.additionalRows == ["**literal** [link](url) · reviewer"])
        let first = try #require(card.rows.first?.first)
        #expect(first.fg == HexColor("#abc") && first.bold == true)
    }

    @Test func kindOverridesReplaceAllRowsAndSkipEmptyStatusRows() {
        let layout = AgentRowLayout(rows: [[.init(.workspace)]], rowsByAgent: [
            "claude": [[.init(.stateText)], [.init(.terminalTitle)], [.init(.custom("missing"))]],
        ])
        let card = AgentCardPresentation(agent: agent(), layout: layout)
        #expect(card.headline == "◑ Task title")
        #expect(card.additionalRows.isEmpty)
    }

    @Test func emptyLayoutsAndMissingValuesKeepAnIdentifiableAgent() {
        for layout in [AgentRowLayout(rows: []), AgentRowLayout(rows: [[], [.init(.custom("absent"))]])] {
            let card = AgentCardPresentation(agent: agent(), layout: layout)
            #expect(card.headline == "reviewer")
            #expect(card.additionalRows.isEmpty)
        }
        #expect(AgentCardPresentation(agent: agent()).headline == "reviewer")
    }

    /// A card already names its Agent under the default layout's second row,
    /// so cards sharing Row 1 need a program name only under a layout that
    /// never shows the Agent field.
    @Test func rowsSharingTheirTitleGetTheProgramOnlyWhenTheCardDoesNotNameIt() {
        let agents = [
            programAgent(pane: "p1", kind: "omp"),
            programAgent(pane: "p2", kind: "pi"),
            programAgent(pane: "p3", kind: "pi", workspace: "docs"),
        ]
        func qualifiers(_ layout: AgentRowLayout) -> [String?] {
            let found = AgentTitleQualifier.qualifiers(for: agents) { agent in
                let card = AgentCardPresentation(agent: agent, layout: layout)
                return .init(
                    title: card.headline, namesAgent: card.namesAgent(inFirst: card.rows.count))
            }
            return agents.map { found[$0.id] }
        }
        #expect(qualifiers(AgentRowLayout.heelerDefault.withHeelerRow()) == [nil, nil, nil])
        #expect(qualifiers(.consoleDefault) == ["OMP", "Pi", nil])
        let workspaceOnly = AgentRowLayout(rows: [[.init(.workspace)], [.init(.directory)]])
        #expect(qualifiers(workspaceOnly) == ["OMP", "Pi", nil])
    }

    /// A row that leads with its program's mark is named by it, so only
    /// kinds without a mark get the program after a shared title.
    @Test func aMarkNamesItsProgramSoOnlyUnmarkedKindsGetQualified() {
        let agents = [
            programAgent(pane: "p1", kind: "claude"),
            programAgent(pane: "p2", kind: "codex"),
            programAgent(pane: "p3", kind: "omp"),
        ]
        let workspaceOnly = AgentRowLayout(rows: [[.init(.workspace)], [.init(.directory)]])
        func qualifiers(leadsWithMark: Bool) -> [String?] {
            let found = AgentTitleQualifier.qualifiers(for: agents) { agent in
                let card = AgentCardPresentation(agent: agent, layout: workspaceOnly, leadsWithMark: leadsWithMark)
                return .init(
                    title: card.headline, namesAgent: card.namesAgent(inFirst: card.rows.count))
            }
            return agents.map { found[$0.id] }
        }
        #expect(qualifiers(leadsWithMark: false) == ["Claude", "Codex", "OMP"])
        #expect(qualifiers(leadsWithMark: true) == [nil, nil, "OMP"])
    }

    /// A card that shows every other field elsewhere keeps the kind word as
    /// configured, not the unstyled fallback name.
    @Test func aKindWordLeftAloneByTheCardKeepsItsStyle() {
        let layout = AgentRowLayout(rows: [[.init(.workspace), .init(.agent, dim: true)]])
        let card = AgentCardPresentation(
            agent: programAgent(pane: "p1", kind: "claude"), layout: layout, hiding: [.workspace],
            leadsWithMark: true)
        #expect(card.rows == [[RenderedToken(token: .agent, text: "claude", fg: nil, bold: nil, dim: true)]])
    }

    private func programAgent(pane: String, kind: String, workspace: String = "proj-omp")
        -> ConsoleAgent
    {
        ConsoleAgent(
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_\(pane)", kind: kind, title: "", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: pane, cwd: "/work", revision: 1),
            workspaceLabel: workspace, repositoryCheckout: nil)
    }

    private func agent(workspace: String? = nil) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "devbox",
            agent: Agent(
                terminalID: "terminal", kind: "claude", title: "Old title", status: .blocked,
                workspaceID: "w", tabID: "t", paneID: "p", cwd: "/work/project", revision: 1,
                name: "reviewer", terminalTitle: "◑ Task title", terminalTitleStripped: "Task title",
                tokens: ["note": "**literal** [link](url)"]),
            workspaceLabel: workspace, repositoryCheckout: nil)
    }
}
