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
        attentionCount: Int = 0
    ) -> ConsoleHostSection {
        ConsoleHostSection(
            hostID: host.id,
            hostDisplayName: host.displayName,
            connectionStatus: status,
            isAwaitingSnapshot: isAwaitingSnapshot,
            statusPresentation: statusPresentation,
            agents: agents,
            isCollapsed: isCollapsed,
            attentionCount: attentionCount)
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
        #expect(empty.readinessText == "No Agents")

        let loading = ConsoleHostSectionHeaderPresentation(
            section: section(status: .connected, isAwaitingSnapshot: true))
        #expect(loading.readinessText == "Loading Agents…")

        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        let failedPresentation = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(failure), syncError: nil))
        let failed = ConsoleHostSectionHeaderPresentation(
            section: section(
                status: .failed(failure),
                statusPresentation: failedPresentation))
        #expect(failed.readinessText == "Unavailable")

        let connected = ConsoleHostSectionHeaderPresentation(
            section: section(
                status: .connected,
                agents: [consoleAgent(paneID: "p1", status: .working)]))
        #expect(connected.readinessText == "Connected")
    }

    @Test func readinessMatchesHostChipLanguageForPendingStates() {
        #expect(
            ConsoleHostSectionHeaderPresentation(
                section: section(status: .connecting)).readinessText == "Connecting…")
        #expect(
            ConsoleHostSectionHeaderPresentation(
                section: section(
                    status: .reconnecting(
                        attempt: 1, delay: .seconds(1), failure: .timedOut))
            ).readinessText == "Reconnecting…")
        #expect(
            ConsoleHostSectionHeaderPresentation(
                section: section(status: .suspended)).readinessText == "Paused")
    }

    @Test func attentionBadgeIsCollapsedOnlyButVoiceOverKeepsTheCount() {
        let expanded = ConsoleHostSectionHeaderPresentation(
            section: section(
                status: .connected,
                isCollapsed: false,
                attentionCount: 2))
        #expect(!expanded.showsAttentionBadge)
        #expect(expanded.attentionText == "2 Agents need attention")
        #expect(expanded.accessibilityLabel.contains("2 Agents need attention"))
        #expect(expanded.accessibilityValue == "Expanded")
        #expect(expanded.accessibilityHint == "Collapses this Host.")
        #expect(expanded.disclosureSystemImage == "chevron.down")

        let collapsed = ConsoleHostSectionHeaderPresentation(
            section: section(
                status: .connected,
                isCollapsed: true,
                attentionCount: 1))
        #expect(collapsed.showsAttentionBadge)
        #expect(collapsed.attentionText == "1 Agent needs attention")
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
        #expect(ConsoleListPresentationMode.flat.title == "Status order")
        #expect(ConsoleListPresentationMode.grouped.title == "By Host")
    }
}
