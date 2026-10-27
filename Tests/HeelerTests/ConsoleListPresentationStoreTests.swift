import Foundation
import Testing

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
            hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status, workspaceID: workspaceID)),
            workspaceLabel: label,
            repositoryCheckout: nil)
    }

    @Test func workspaceGroupsUseHostAndOpaqueIDAndKeepIncomingOrder() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "Studio")
        let second = Host.fixture(name: "Build")
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
            hosts: [first, second], agents: agents, filteredHostID: second.id)
        #expect(filtered.map(\.id) == [.init(hostID: second.id, workspaceID: "w1")])
    }

    @Test func workspaceCollapsePersistsAcrossRenameAndReconnectButNotOtherHosts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "Studio")
        let second = Host.fixture(name: "Build")
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
        let first = Host.fixture(name: "Studio")
        let second = Host.fixture(name: "Build")
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
            case .inset: "-"
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
            "header", "alone p1", "—alone p2", "—checkout nest", "agent p3", "-agent p4",
        ])
        #expect(repository.rows.map(\.isFirst) == [true, false, false, false, false, false])
        #expect(repository.rows.map(\.isLast) == [false, false, false, false, false, true])
        #expect(repository.rows.map(\.followsHeader) == [false, true, false, false, true, false])
        // A Workspace with one Agent is that Agent's card; with several, a header leads.
        #expect(rowShape(cards[1]) == ["alone p5"])
        #expect(rowShape(cards[2]) == ["header", "agent p6", "-agent p7"])
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

    @Test func rowsInACardLeaveTheWorkspaceHostAndCheckoutDirectoryToIt() {
        let host = Host.fixture()
        let atCheckout = checkoutAgent(
            host: host, paneID: "p1", status: .idle, workspaceID: "w1", label: "nest", repo: "heeler", linked: true)
        #expect(ConsoleWorkspaceCard.hiddenTokens(for: atCheckout, showsHost: false) == [.workspace, .host])
        #expect(ConsoleWorkspaceCard.hiddenTokens(for: atCheckout, showsHost: true) == [.workspace])
        let inCheckout = ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(
                terminalID: "term_p2", kind: "claude", title: "Task", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: "p2", cwd: "/wt/nest", revision: 1),
            workspaceLabel: "nest", repositoryCheckout: atCheckout.repositoryCheckout)
        #expect(ConsoleWorkspaceCard.hiddenTokens(for: inCheckout, showsHost: true) == [.workspace, .directory])

        let layout = AgentRowLayout(rows: [
            [.init(.workspace), .init(.host)], [.init(.agent)], [.init(.directory)],
        ])
        let card = AgentCardPresentation(
            agent: inCheckout, layout: layout,
            hiding: ConsoleWorkspaceCard.hiddenTokens(for: inCheckout, showsHost: false))
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
        #expect(qualifiers(.consoleDefault) == [nil, nil, nil])
        let workspaceOnly = AgentRowLayout(rows: [[.init(.workspace)], [.init(.directory)]])
        #expect(qualifiers(workspaceOnly) == ["OMP", "Pi", nil])
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
