import Foundation
import Testing

@testable import Heeler

@Suite("Console host section header presentation")
struct ConsoleHostSectionHeaderPresentationTests {
    private let host = Host.fixture(name: "studio")

    private func section(
        status: EventsSessionStatus?,
        isAwaitingSnapshot: Bool = false,
        statusPresentation: ConsoleHostStatusPresentation? = nil,
        agents: [ConsoleAgent] = [],
        isCollapsed: Bool = false,
        statusCounts: ConsoleHostAgentStatusCounts = .init()
    ) -> ConsoleHostSection {
        ConsoleHostSection(
            hostID: host.id,
            hostDisplayName: host.displayName,
            connectionStatus: status,
            isAwaitingSnapshot: isAwaitingSnapshot,
            statusPresentation: statusPresentation,
            agents: agents,
            isCollapsed: isCollapsed,
            statusCounts: statusCounts)
    }

    private func consoleAgent(paneID: String, status: AgentStatus) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status)),
            workspaceLabel: nil,
            repositoryCheckout: nil)
    }

    @Test func readinessDistinguishesConnectedEmptyFromLoadingAndFailed() throws {
        let empty = ConsoleHostSectionHeaderPresentation(
            section: section(status: .connected))
        #expect(empty.readiness.text == "No Agents")

        let loading = ConsoleHostSectionHeaderPresentation(
            section: section(status: .connected, isAwaitingSnapshot: true))
        #expect(loading.readiness.text == "Loading Agents…")

        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        let failedPresentation = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(failure), syncError: nil))
        let failed = ConsoleHostSectionHeaderPresentation(
            section: section(
                status: .failed(failure),
                statusPresentation: failedPresentation))
        #expect(failed.readiness.text == "Unavailable")

        let connected = ConsoleHostSectionHeaderPresentation(
            section: section(
                status: .connected,
                agents: [consoleAgent(paneID: "p1", status: .working)]))
        #expect(connected.readiness.text == "Connected")
    }

    @Test func readinessMatchesHostChipLanguageForPendingStates() {
        #expect(
            ConsoleHostSectionHeaderPresentation(
                section: section(status: .connecting)).readiness.text == "Connecting…")
        #expect(
            ConsoleHostSectionHeaderPresentation(
                section: section(
                    status: .reconnecting(
                        attempt: 1, delay: .seconds(1), failure: .timedOut))
            ).readiness.text == "Reconnecting…")
        #expect(
            ConsoleHostSectionHeaderPresentation(
                section: section(status: .suspended)).readiness.text == "Paused")
    }

    @Test func readinessToneSeparatesHealthyWorkingAndStoppedHosts() {
        func tone(
            _ status: EventsSessionStatus?,
            severity: ConsoleHostStatusPresentation.Severity? = nil,
            awaiting: Bool = false
        ) -> HostConnectionTone {
            ConsoleHostSectionHeaderPresentation.readiness(
                connectionStatus: status, isAwaitingSnapshot: awaiting, statusSeverity: severity,
                isEmpty: false, inventoryNoun: "Agents"
            ).tone
        }
        #expect(tone(.connected) == .connected)
        #expect(tone(.connected, awaiting: true) == .pending)
        #expect(tone(.connected, severity: .warning) == .warning)
        #expect(tone(.connecting) == .pending)
        #expect(tone(nil) == .pending)
        #expect(
            tone(.reconnecting(attempt: 3, delay: .seconds(4), failure: .timedOut)) == .reconnecting)
        #expect(tone(.failed(.authenticationFailed)) == .unavailable)
        #expect(tone(.connecting, severity: .critical) == .unavailable)
        #expect(tone(.suspended) == .paused)
    }

    @Test func statusPillsAreCollapsedOnlyButVoiceOverKeepsTheBreakdown() {
        let counts = ConsoleHostAgentStatusCounts(blocked: 1, working: 2, done: 3)
        let expanded = ConsoleHostSectionHeaderPresentation(
            section: section(
                status: .connected,
                isCollapsed: false,
                statusCounts: counts))
        #expect(!expanded.showsStatusPills)
        #expect(expanded.statusItems.map(\.status) == [.blocked, .working, .done])
        #expect(expanded.statusItems.map(\.count) == [1, 2, 3])
        #expect(expanded.statusText == "1 blocked, 2 working, 3 done")
        #expect(expanded.accessibilityLabel.contains("1 blocked, 2 working, 3 done"))
        #expect(expanded.accessibilityValue == "Expanded")
        #expect(expanded.accessibilityHint == "Collapses this Host.")
        #expect(expanded.disclosureSystemImage == "chevron.down")

        let collapsed = ConsoleHostSectionHeaderPresentation(
            section: section(
                status: .connected,
                isCollapsed: true,
                statusCounts: counts))
        #expect(collapsed.showsStatusPills)
        #expect(collapsed.statusText == "1 blocked, 2 working, 3 done")
        #expect(collapsed.accessibilityValue == "Collapsed")
        #expect(collapsed.accessibilityHint == "Expands this Host.")
        #expect(collapsed.disclosureSystemImage == "chevron.right")
    }

    @Test func accessibilityLabelNamesHostAndReadiness() {
        let presentation = ConsoleHostSectionHeaderPresentation(
            section: section(status: .connected))
        #expect(presentation.accessibilityLabel.hasPrefix("studio, No Agents"))
    }
}

@Suite("Console list presentation routing")
struct ConsoleListPresentationRoutingTests {
    @Test func groupedModeShowsSectionsInsteadOfFlatEmptyClaim() {
        #expect(
            ConsoleAgentsSurface(
                hostCount: 2,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 0) == .noAgents)
        #expect(
            ConsoleAgentsSurface(
                hostCount: 2,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 0,
                presentationMode: .grouped,
                projectedSectionCount: 2) == .rows)
        #expect(
            ConsoleAgentsSurface(
                hostCount: 1,
                filteredHostName: "studio",
                filteredAgentCount: 0,
                visibleIssueCount: 0) == .noAgentsOnHost("studio"))
        #expect(
            ConsoleAgentsSurface(
                hostCount: 1,
                filteredHostName: "studio",
                filteredAgentCount: 0,
                visibleIssueCount: 0,
                presentationMode: .grouped,
                projectedSectionCount: 1) == .rows)
    }

    @Test func hostIssuePlacementFollowsPresentationMode() {
        #expect(ConsoleHostIssuePlacement(mode: .flat) == .flatIssueRows)
        #expect(ConsoleHostIssuePlacement(mode: .grouped) == .sectionHeaders)
    }

    @Test func presentationModeTitlesAreStableForTheSwitcher() {
        #expect(ConsoleListPresentationMode.flat.title == "All Agents")
        #expect(ConsoleListPresentationMode.grouped.title == "By Host")
    }

    @Test func readinessNamesTheInventoryItDescribes() {
        func readiness(_ status: EventsSessionStatus?, awaiting: Bool = false) -> String {
            ConsoleHostSectionHeaderPresentation.readiness(
                connectionStatus: status, isAwaitingSnapshot: awaiting, statusSeverity: nil,
                isEmpty: true, inventoryNoun: "Terminals"
            ).text
        }
        #expect(readiness(.connected) == "No Terminals")
        #expect(readiness(.connected, awaiting: true) == "Loading Terminals…")
        #expect(
            ConsoleHostSectionHeaderPresentation.readiness(
                connectionStatus: .connecting, isAwaitingSnapshot: false, statusSeverity: .critical,
                isEmpty: true, inventoryNoun: "Terminals")
                == HostReadiness(text: "Unavailable", tone: .unavailable))
    }
}
