import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Console list presentation store")
struct ConsoleListPresentationStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-list-presentation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func consoleAgent(
        host: Host,
        paneID: String,
        status: AgentStatus,
        workspaceLabel: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status)),
            workspaceLabel: workspaceLabel,
            repositoryCheckout: nil)
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
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")

        let store = ConsoleListPresentationStore(defaults: defaults)
        store.setCollapsed(true, for: hostA.id)

        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        #expect(reloaded.isCollapsed(hostA.id))
        #expect(!reloaded.isCollapsed(hostB.id))

        reloaded.toggleCollapsed(hostB.id)
        reloaded.toggleCollapsed(hostA.id)
        let reloadedAgain = ConsoleListPresentationStore(defaults: defaults)
        #expect(!reloadedAgain.isCollapsed(hostA.id))
        #expect(reloadedAgain.isCollapsed(hostB.id))
    }

    @Test func sectionsFollowCatalogOrderAndFilterToAtMostOneHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "zeta")
        let second = Host.fixture(name: "alpha")
        let store = ConsoleListPresentationStore(defaults: defaults)

        let all = store.sections(hosts: [first, second], agents: [])
        #expect(all.map(\.hostID) == [first.id, second.id])

        let filtered = store.sections(
            hosts: [first, second], agents: [], filteredHostID: second.id)
        #expect(filtered.map(\.hostID) == [second.id])

        let missing = store.sections(
            hosts: [first, second], agents: [], filteredHostID: UUID())
        #expect(missing.isEmpty)
    }

    @Test func sectionsPreserveTheSuppliedAgentOrderWithinEachHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")
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
        #expect(loading[0].isAwaitingSnapshot)
        #expect(loading[0].statusPresentation?.message == "Loading Agents from studio…")

        let refreshed = store.sections(
            hosts: [host],
            agents: [done],
            hostStatuses: [host.id: .connected])
        #expect(refreshed[0].agents.map(\.id) == [done.id])
        #expect(!refreshed[0].isAwaitingSnapshot)
        #expect(refreshed[0].statusPresentation == nil)
    }

    @Test func emptyAndDisconnectedHostsRemainSections() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let empty = Host.fixture(name: "empty")
        let disconnected = Host.fixture(name: "offline")
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
        #expect(sections[0].connectionStatus == .connected)
        #expect(sections[0].statusPresentation == nil)
        #expect(sections[1].connectionStatus == .failed(failure))
        #expect(sections[1].statusPresentation?.hostID == disconnected.id)
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

    @Test func byHostWorkspaceModePersistsAcrossRecreation() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = ConsoleListPresentationStore(defaults: defaults)
        store.select(.byHostWorkspace)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == .byHostWorkspace)
        #expect(ConsoleListPresentationMode.byHostWorkspace.title == "By Host, By Workspace")
    }

    @Test func byHostWorkspaceSectionsNestWorkspaceGroupsInKnownOrder() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")
        // The incoming (already-sorted) sequence interleaves hosts and
        // workspaces; each group must preserve its host's exact relative
        // agent order without re-sorting.
        let agents = [
            consoleAgent(host: hostA, paneID: "a-pay-1", status: .blocked, workspaceLabel: "Payments"),
            consoleAgent(host: hostB, paneID: "b-app-1", status: .working, workspaceLabel: "App"),
            consoleAgent(host: hostA, paneID: "a-app-1", status: .done, workspaceLabel: "App"),
            consoleAgent(host: hostB, paneID: "b-pay-1", status: .idle, workspaceLabel: "Payments"),
            consoleAgent(host: hostA, paneID: "a-pay-2", status: .working, workspaceLabel: "Payments"),
        ]
        let workspacesByHost = [
            hostA.id: [
                ConsoleWorkspace(id: "w1", label: "App"),
                ConsoleWorkspace(id: "w2", label: "Payments"),
            ],
            hostB.id: [
                ConsoleWorkspace(id: "w1", label: "App"),
                ConsoleWorkspace(id: "w2", label: "Payments"),
            ],
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sectionsByHostThenWorkspace(
            hosts: [hostA, hostB],
            agents: agents,
            workspacesByHost: workspacesByHost)

        #expect(sections.map(\.id) == [hostA.id, hostB.id])
        // The Host part is the exact projection the "By Host" mode produces.
        #expect(sections.map(\.host) == store.sections(hosts: [hostA, hostB], agents: agents))

        let alpha = try #require(sections.first)
        #expect(alpha.workspaceGroups.map(\.label) == ["App", "Payments"])
        #expect(alpha.workspaceGroups[0].agents.map(\.agent.paneID) == ["a-app-1"])
        #expect(alpha.workspaceGroups[1].agents.map(\.agent.paneID) == ["a-pay-1", "a-pay-2"])

        let beta = try #require(sections.last)
        #expect(beta.workspaceGroups.map(\.label) == ["App", "Payments"])
        #expect(beta.workspaceGroups[0].agents.map(\.agent.paneID) == ["b-app-1"])
        #expect(beta.workspaceGroups[1].agents.map(\.agent.paneID) == ["b-pay-1"])
    }

    @Test func linkedWorktreeWorkspacesNestUnderTheirReposMainWorkspace() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha")
        // Live snapshot shape: one repo (Heeler) with the main checkout's
        // workspace and two linked-worktree workspaces.
        let heeler = RepositoryCheckout(
            repoKey: "/src/Heeler/.git", repoName: "Heeler", repoRoot: "/src/Heeler",
            checkoutPath: "/src/Heeler", isLinkedWorktree: false)
        let testflightCheckout = RepositoryCheckout(
            repoKey: heeler.repoKey, repoName: "Heeler", repoRoot: "/src/Heeler",
            checkoutPath: "/src/Heeler/testflight", isLinkedWorktree: true)
        let indexCheckout = RepositoryCheckout(
            repoKey: heeler.repoKey, repoName: "Heeler", repoRoot: "/src/Heeler",
            checkoutPath: "/src/Heeler/index-worktree", isLinkedWorktree: true)
        let workspaces = [
            ConsoleWorkspace(id: "w11", label: "Waycar", checkout: heeler),
            ConsoleWorkspace(id: "w1D", label: "testflight", checkout: testflightCheckout),
            ConsoleWorkspace(id: "w1E", label: "index-worktree", checkout: indexCheckout),
        ]
        let agents = [
            consoleAgent(
                host: host, paneID: "a-index", status: .working,
                workspaceLabel: "index-worktree"),
            consoleAgent(host: host, paneID: "a-main", status: .idle, workspaceLabel: "Waycar"),
            consoleAgent(
                host: host, paneID: "a-tf", status: .blocked, workspaceLabel: "testflight"),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sectionsByHostThenWorkspace(
            hosts: [host], agents: agents, workspacesByHost: [host.id: workspaces])

        let groups = sections[0].workspaceGroups
        // Worktree workspaces are children of the main-checkout workspace,
        // not sibling top-level groups.
        #expect(groups.map(\.label) == ["Waycar"])
        #expect(groups[0].agents.map(\.agent.paneID) == ["a-main"])
        #expect(groups[0].worktrees.map(\.label) == ["testflight", "index-worktree"])
        #expect(groups[0].worktrees[0].agents.map(\.agent.paneID) == ["a-tf"])
        #expect(groups[0].worktrees[1].agents.map(\.agent.paneID) == ["a-index"])

        // Parent and children collapse independently (host defaults: all
        // collapsed).
        #expect(groups[0].isCollapsed)
        #expect(groups[0].worktrees.map(\.isCollapsed) == [true, true])
        store.setExpanded(true, for: host.id, workspaceLabel: "index-worktree")
        let reexpanded = store.sectionsByHostThenWorkspace(
            hosts: [host], agents: agents, workspacesByHost: [host.id: workspaces])
        #expect(reexpanded[0].workspaceGroups[0].isCollapsed)
        #expect(reexpanded[0].workspaceGroups[0].worktrees.map(\.isCollapsed) == [true, false])
    }

    @Test func worktreeWithoutAMainCheckoutWorkspaceStaysTopLevel() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha")
        // Only the linked worktree is known to the Host (its main checkout
        // workspace is closed): no parent to nest under.
        let checkout = RepositoryCheckout(
            repoKey: "/src/Heeler/.git", repoName: "Heeler", repoRoot: "/src/Heeler",
            checkoutPath: "/src/Heeler/index-worktree", isLinkedWorktree: true)
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: [
                consoleAgent(
                    host: host, paneID: "a-1", status: .working,
                    workspaceLabel: "index-worktree"),
            ],
            workspacesByHost: [host.id: [
                ConsoleWorkspace(id: "w1E", label: "index-worktree", checkout: checkout),
            ]])

        let groups = sections[0].workspaceGroups
        #expect(groups.map(\.label) == ["index-worktree"])
        #expect(groups[0].worktrees.isEmpty)
        #expect(groups[0].agents.map(\.agent.paneID) == ["a-1"])
    }

    @Test func agentlessMainWorkspaceStillParentsItsWorktrees() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha")
        let checkout = RepositoryCheckout(
            repoKey: "/src/Heeler/.git", repoName: "Heeler", repoRoot: "/src/Heeler",
            checkoutPath: "/src/Heeler", isLinkedWorktree: false)
        let worktreeCheckout = RepositoryCheckout(
            repoKey: "/src/Heeler/.git", repoName: "Heeler", repoRoot: "/src/Heeler",
            checkoutPath: "/src/Heeler/testflight", isLinkedWorktree: true)
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: [
                consoleAgent(
                    host: host, paneID: "a-tf", status: .working,
                    workspaceLabel: "testflight"),
            ],
            workspacesByHost: [host.id: [
                ConsoleWorkspace(id: "w11", label: "Waycar", checkout: checkout),
                ConsoleWorkspace(id: "w1D", label: "testflight", checkout: worktreeCheckout),
            ]])

        let groups = sections[0].workspaceGroups
        // The main workspace has no Agents of its own but still parents its
        // worktree so the tree stays rooted at the repo.
        #expect(groups.map(\.label) == ["Waycar"])
        #expect(groups[0].agents.isEmpty)
        #expect(groups[0].worktrees.map(\.label) == ["testflight"])
    }

    @Test func unknownWorkspaceAgentsFallIntoTheFinalBucket() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha")
        let agents = [
            consoleAgent(host: host, paneID: "no-workspace", status: .working, workspaceLabel: nil),
            consoleAgent(host: host, paneID: "orphan", status: .done, workspaceLabel: "Orphaned"),
            consoleAgent(host: host, paneID: "known", status: .idle, workspaceLabel: "App"),
            consoleAgent(host: host, paneID: "blank", status: .blocked, workspaceLabel: ""),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: agents,
            workspacesByHost: [
                host.id: [ConsoleWorkspace(id: "w1", label: "App")],
            ])

        let section = try #require(sections.first)
        #expect(section.workspaceGroups.map(\.label) == ["App", "Orphaned", "Unassigned"])
        #expect(section.workspaceGroups[0].agents.map(\.agent.paneID) == ["known"])
        #expect(section.workspaceGroups[1].agents.map(\.agent.paneID) == ["orphan"])
        #expect(section.workspaceGroups[2].agents.map(\.agent.paneID) == ["no-workspace", "blank"])
    }

    @Test func byHostWorkspaceModeMatchesByHostForEmptyHosts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let empty = Host.fixture(name: "empty")
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sectionsByHostThenWorkspace(hosts: [empty], agents: [])
        #expect(sections.count == 1)
        #expect(sections[0].host.agents.isEmpty)
        #expect(sections[0].workspaceGroups.isEmpty)
    }

    @Test func hostWithOnlyAShellPaneListsItAsARowInGroupedModes() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha")
        let shell = ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(
                shellPane: PaneInfo(
                    agentStatus: .unknown, focused: false, paneID: "w1:p1", revision: 1,
                    tabID: "w1:t1", terminalID: "term-1", workspaceID: "w1",
                    cwd: "/srv/app"),
                name: "Default Shell"),
            workspaceLabel: "Scratch",
            repositoryCheckout: nil)
        let store = ConsoleListPresentationStore(defaults: defaults)

        let byHost = try #require(
            store.sections(
                hosts: [host], agents: [shell], hostStatuses: [host.id: .connected]
            ).first)
        #expect(byHost.agents.map(\.id) == [shell.id])
        // A shell is a row, so its Host is not an empty one.
        #expect(ConsoleHostSectionHeaderPresentation.readinessText(for: byHost) == "Connected")
        // It has no Agent Status to count.
        #expect(byHost.statusCounts.items.isEmpty)

        let byWorkspace = try #require(
            store.sectionsByHostThenWorkspace(
                hosts: [host], agents: [shell],
                workspacesByHost: [host.id: [ConsoleWorkspace(id: "w1", label: "Scratch")]]
            ).first)
        #expect(byWorkspace.workspaceGroups.map(\.label) == ["Scratch"])
        #expect(byWorkspace.workspaceGroups[0].agents.map(\.id) == [shell.id])
    }

    @Test func byHostWorkspaceGroupsDefaultToCollapsedAndExpansionPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha")
        let other = Host.fixture(name: "beta")
        let store = ConsoleListPresentationStore(defaults: defaults)

        var sections = store.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: [
                consoleAgent(host: host, paneID: "a-1", status: .working, workspaceLabel: "App"),
            ],
            workspacesByHost: [host.id: [ConsoleWorkspace(id: "w1", label: "App")]])
        // A brand-new workspace key is collapsed by default.
        #expect(sections[0].workspaceGroups.map(\.isCollapsed) == [true])

        store.setExpanded(true, for: host.id, workspaceLabel: "App")
        sections = store.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: [
                consoleAgent(host: host, paneID: "a-1", status: .working, workspaceLabel: "App"),
            ],
            workspacesByHost: [host.id: [ConsoleWorkspace(id: "w1", label: "App")]])
        #expect(sections[0].workspaceGroups.map(\.isCollapsed) == [false])

        // Expansion persists across store recreation.
        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        let reloadedSections = reloaded.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: [
                consoleAgent(host: host, paneID: "a-1", status: .working, workspaceLabel: "App"),
            ],
            workspacesByHost: [host.id: [ConsoleWorkspace(id: "w1", label: "App")]])
        #expect(reloadedSections[0].workspaceGroups.map(\.isCollapsed) == [false])

        // Expansion is scoped to the host+workspace pair.
        let otherSections = reloaded.sectionsByHostThenWorkspace(
            hosts: [other],
            agents: [
                consoleAgent(host: other, paneID: "b-1", status: .working, workspaceLabel: "App"),
            ],
            workspacesByHost: [other.id: [ConsoleWorkspace(id: "w2", label: "App")]])
        #expect(otherSections[0].workspaceGroups.map(\.isCollapsed) == [true])
    }

    @Test func movingIntoAWorkspaceExpandsTheDestinationGroup() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha")
        let store = ConsoleListPresentationStore(defaults: defaults)

        // Before the move the destination workspace has no Agents, so its
        // group does not even project — the group the Agent will arrive in
        // starts collapsed like any workspace never seen before.
        var sections = store.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: [
                consoleAgent(host: host, paneID: "a-1", status: .working, workspaceLabel: "Old"),
            ],
            workspacesByHost: [host.id: [
                ConsoleWorkspace(id: "w-old", label: "Old"),
                ConsoleWorkspace(id: "w-new", label: "New"),
            ]])
        #expect(sections[0].workspaceGroups.map(\.label) == ["Old"])

        // The move lands; the Console view calls setExpanded for the
        // moved-to group so the arriving Agent is visible without a tap.
        store.setExpanded(true, for: host.id, workspaceLabel: "New")
        sections = store.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: [
                consoleAgent(host: host, paneID: "a-1", status: .working, workspaceLabel: "New"),
            ],
            workspacesByHost: [host.id: [
                ConsoleWorkspace(id: "w-old", label: "Old"),
                ConsoleWorkspace(id: "w-new", label: "New"),
            ]])
        #expect(sections[0].workspaceGroups.map(\.label) == ["New"])
        #expect(sections[0].workspaceGroups.map(\.isCollapsed) == [false])
        #expect(sections[0].workspaceGroups[0].agents.map(\.id.paneID) == ["a-1"])
    }

    @Test func byHostWorkspaceCollapseStateIsIsolatedPerHostPair() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha")
        let store = ConsoleListPresentationStore(defaults: defaults)

        store.setExpanded(true, for: host.id, workspaceLabel: "App")
        // Re-collapsing clears the expanded key.
        store.setExpanded(false, for: host.id, workspaceLabel: "App")
        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        let reloadedSections = reloaded.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: [
                consoleAgent(host: host, paneID: "a-1", status: .working, workspaceLabel: "App"),
            ],
            workspacesByHost: [host.id: [ConsoleWorkspace(id: "w1", label: "App")]])
        #expect(reloadedSections[0].workspaceGroups.map(\.isCollapsed) == [true])
    }

    @Test func collapsedHostStillProjectsWorkspaceGroupsAsHidden() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "alpha")
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.setCollapsed(true, for: host.id)
        store.setExpanded(true, for: host.id, workspaceLabel: "App")

        let sections = store.sectionsByHostThenWorkspace(
            hosts: [host],
            agents: [
                consoleAgent(host: host, paneID: "a-1", status: .working, workspaceLabel: "App"),
            ],
            workspacesByHost: [host.id: [ConsoleWorkspace(id: "w1", label: "App")]])

        #expect(sections[0].host.isCollapsed)
        #expect(sections[0].workspaceGroups.map(\.label) == ["App"])
        #expect(sections[0].workspaceGroups.map(\.isCollapsed) == [false])
        #expect(sections[0].workspaceGroups[0].agents.map(\.agent.paneID) == ["a-1"])
        #expect(sections[0].host.statusCounts.working == 1)
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
