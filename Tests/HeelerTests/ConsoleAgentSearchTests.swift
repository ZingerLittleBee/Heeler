import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Console agent search")
struct ConsoleAgentSearchTests {
    private func makeAgent(
        host: Host,
        paneID: String,
        cwd: String = "/work/w1",
        title: String = "Task",
        name: String? = nil,
        terminalTitle: String? = nil,
        terminalTitleStripped: String? = nil,
        paneTitle: String? = nil,
        workspaceLabel: String? = nil,
        tabLabel: String? = nil,
        paneLabel: String? = nil
    ) -> ConsoleAgent {
        let agent = Agent(
            terminalID: "term_\(paneID)", kind: "codex", title: title, status: .idle,
            workspaceID: "w1", tabID: "w1:t1", paneID: paneID, cwd: cwd, revision: 1,
            name: name, terminalTitle: terminalTitle,
            terminalTitleStripped: terminalTitleStripped, paneTitle: paneTitle)
        return ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: agent,
            workspaceLabel: workspaceLabel,
            repositoryCheckout: nil,
            tabLabel: tabLabel,
            paneLabel: paneLabel)
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-agent-search-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func emptyQueryMatchesEveryAgent() {
        let host = Host.fixture(name: "studio")
        let agent = makeAgent(host: host, paneID: "w1:p1")
        #expect(agent.matchesAgentSearch(""))
        #expect(agent.matchesAgentSearch("   "))
    }

    @Test func matchesWorkingDirectorySubstringCaseInsensitively() {
        let host = Host.fixture(name: "studio")
        let agent = makeAgent(host: host, paneID: "w1:p1", cwd: "/work/Heeler-Checkout")
        #expect(agent.matchesAgentSearch("heeler"))
        #expect(agent.matchesAgentSearch("HEELER-CHECK"))
        #expect(!agent.matchesAgentSearch("definitely-absent"))
    }

    @Test func matchesEachTitleAndVisibleTextField() {
        let host = Host.fixture(name: "studio")
        let marker = "QuarryQuartz"
        let agents = [
            makeAgent(host: host, paneID: "w1:p1", workspaceLabel: "ws-\(marker)"),
            makeAgent(host: host, paneID: "w1:p2", tabLabel: "tab-\(marker)"),
            makeAgent(host: host, paneID: "w1:p3", paneLabel: "pane-\(marker)"),
            makeAgent(host: host, paneID: "w1:p4", title: "title-\(marker)"),
            makeAgent(host: host, paneID: "w1:p5", paneTitle: "ptitle-\(marker)"),
            makeAgent(host: host, paneID: "w1:p6", name: "name-\(marker)"),
            makeAgent(host: host, paneID: "w1:p7", terminalTitle: "term-\(marker)"),
            makeAgent(
                host: host, paneID: "w1:p8", terminalTitleStripped: "stripped-\(marker)"),
        ]
        for agent in agents {
            #expect(agent.matchesAgentSearch(marker.lowercased()))
        }
    }
    @Test func skipsNilAndEmptyFieldsWithoutMatching() {
        let host = Host.fixture(name: "studio")
        let agent = makeAgent(
            host: host, paneID: "w1:p1", cwd: "", title: "",
            terminalTitle: "", terminalTitleStripped: "", paneTitle: "")
        #expect(!agent.matchesAgentSearch("definitely-absent"))
        #expect(agent.matchesAgentSearch(""))
    }

    @Test func searchComposesWithHostFilter() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ConsoleListPresentationStore(defaults: defaults)
        let hostA = Host.fixture(name: "studio")
        let hostB = Host.fixture(name: "laptop")
        let agents = [
            makeAgent(host: hostA, paneID: "w1:p1", title: "Alpha work"),
            makeAgent(host: hostB, paneID: "w1:p2", title: "Beta work"),
        ]

        let filteredToMatchingHost = store.sections(
            hosts: [hostA, hostB], agents: agents,
            filteredHostID: hostA.id, searchQuery: "alpha")
        #expect(filteredToMatchingHost.count == 1)
        #expect(filteredToMatchingHost.first?.agents.count == 1)

        let filteredToOtherHost = store.sections(
            hosts: [hostA, hostB], agents: agents,
            filteredHostID: hostA.id, searchQuery: "beta")
        #expect(filteredToOtherHost.isEmpty)

        let unfiltered = store.sections(
            hosts: [hostA, hostB], agents: agents, searchQuery: "beta")
        #expect(unfiltered.count == 1)
        #expect(unfiltered.first?.hostID == hostB.id)
    }

    @Test func groupedModeHidesEmptySectionsOnlyWhileSearching() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ConsoleListPresentationStore(defaults: defaults)
        let hostA = Host.fixture(name: "studio")
        let hostB = Host.fixture(name: "laptop")
        let agents = [makeAgent(host: hostA, paneID: "w1:p1", title: "Alpha work")]

        let withoutQuery = store.sections(hosts: [hostA, hostB], agents: agents)
        #expect(withoutQuery.count == 2)

        let whileSearching = store.sections(
            hosts: [hostA, hostB], agents: agents, searchQuery: "alpha")
        #expect(whileSearching.count == 1)
        #expect(whileSearching.first?.hostID == hostA.id)

        // Empty or not, a query-free projection never drops a catalog Host.
        let unqueried = store.sections(
            hosts: [hostA, hostB], agents: agents,
            hostStatuses: [
                hostB.id: .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut)
            ])
        #expect(unqueried.map(\.hostID) == [hostA.id, hostB.id])
    }

    /// An empty section survives a search only because its Host is
    /// reconnecting: the section's status row is where the Console reports
    /// that, so it must not be tidied away with the other empty sections.
    @Test func reconnectingHostKeepsItsSectionWhileSearching() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ConsoleListPresentationStore(defaults: defaults)
        let hostA = Host.fixture(name: "studio")
        let hostB = Host.fixture(name: "laptop")
        let agents = [makeAgent(host: hostA, paneID: "w1:p1", title: "Alpha work")]

        let whileSearching = store.sections(
            hosts: [hostA, hostB], agents: agents,
            hostStatuses: [
                hostB.id: .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut)
            ],
            searchQuery: "alpha")

        #expect(whileSearching.map(\.hostID) == [hostA.id, hostB.id])
        #expect(whileSearching.last?.agents.isEmpty == true)
        #expect(whileSearching.last?.statusPresentation?.severity == .warning)
    }

    @Test func failedHostKeepsItsSectionWhileSearching() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ConsoleListPresentationStore(defaults: defaults)
        let hostA = Host.fixture(name: "studio")
        let hostB = Host.fixture(name: "laptop")
        let hostC = Host.fixture(name: "tablet")
        let agents = [makeAgent(host: hostA, paneID: "w1:p1", title: "Alpha work")]

        let whileSearching = store.sections(
            hosts: [hostA, hostB, hostC], agents: agents,
            hostStatuses: [
                hostB.id: .failed(.authenticationFailed),
                hostC.id: .failed(
                    .hostKeyMismatch(
                        known: HostKeyFingerprint(digest: Data(repeating: 1, count: 32)),
                        presented: HostKeyFingerprint(digest: Data(repeating: 2, count: 32)))),
            ],
            searchQuery: "alpha")

        #expect(whileSearching.map(\.hostID) == [hostA.id, hostB.id, hostC.id])
        let warned = try #require(whileSearching.first { $0.hostID == hostB.id })
        let critical = try #require(whileSearching.first { $0.hostID == hostC.id })
        #expect(warned.statusPresentation?.severity == .warning)
        #expect(critical.statusPresentation?.severity == .critical)
    }

    /// Nominal Hosts — no status row at all, or one that only reports a
    /// pause, a connection attempt, or a snapshot load — still leave the
    /// list while searching, so an idle catalog does not fill with empty
    /// sections.
    @Test func nominalHostSectionsLeaveWhileSearching() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ConsoleListPresentationStore(defaults: defaults)
        let hostA = Host.fixture(name: "studio")
        let hostB = Host.fixture(name: "laptop")
        let hostC = Host.fixture(name: "tablet")
        let agents = [makeAgent(host: hostA, paneID: "w1:p1", title: "Alpha work")]

        let whileSearching = store.sections(
            hosts: [hostA, hostB, hostC], agents: agents,
            hostStatuses: [hostB.id: .connected, hostC.id: .suspended],
            searchQuery: "alpha")

        #expect(whileSearching.map(\.hostID) == [hostA.id])
    }

    @Test func flatSurfaceSelectsNoSearchResultsWhileSearching() {
        let searching = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 0,
            visibleIssueCount: 0, searchQuery: "alpha")
        #expect(searching == .noSearchResults)
        #expect(searching != .noAgents)

        let idle = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 0,
            visibleIssueCount: 0)
        #expect(idle == .noAgents)

        let searchingOnFilteredHost = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: "studio", filteredAgentCount: 0,
            visibleIssueCount: 0, searchQuery: "alpha")
        #expect(searchingOnFilteredHost == .noSearchResults)

        let searchingWithVisibleIssues = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 0,
            visibleIssueCount: 1, searchQuery: "alpha")
        #expect(searchingWithVisibleIssues == .rows)
    }

    @Test func groupedSurfaceSelectsNoSearchResultsWhileSearching() {
        let searching = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 0,
            visibleIssueCount: 0, presentationMode: .grouped,
            projectedSectionCount: 0, searchQuery: "alpha")
        #expect(searching == .noSearchResults)

        let idle = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 0,
            visibleIssueCount: 0, presentationMode: .grouped,
            projectedSectionCount: 0)
        #expect(idle == .noHosts)

        let withSections = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 1,
            visibleIssueCount: 0, presentationMode: .grouped,
            projectedSectionCount: 1, searchQuery: "alpha")
        #expect(withSections == .rows)
    }
}
