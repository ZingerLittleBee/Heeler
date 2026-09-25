import Foundation
import Testing

@testable import Heeler

@Suite("Console host status presentation")
struct ConsoleHostStatusPresentationTests {
    private let host = Host.fixture(name: "studio")

    @Test func reconnectingRowsUseTheStandaloneSummary() throws {
        let cases: [(TransportError, String)] = [
            (.sshUnreachable(detail: "down"), "SSH unavailable"),
            (.timedOut, "Connection timed out"),
            (.cancelled, "Connection cancelled"),
            (.channelFailed(detail: "reset"), "Connection dropped"),
            (.apiRejected(code: "busy", message: "later"), "herdr rejected the request"),
        ]
        for (failure, summary) in cases {
            let presentation = try #require(
                ConsoleHostStatusPresentation(
                    host: host,
                    status: .reconnecting(attempt: 1, delay: .seconds(1), failure: failure),
                    syncError: nil))
            #expect(presentation.message == "Reconnecting to studio: \(summary)")
            #expect(presentation.systemImage == "wifi.exclamationmark")
            #expect(presentation.severity == .warning)
            #expect(presentation.navigates)
            #expect(presentation.hostName == "studio")
        }
    }

    @Test func aJumpHostOutageNamesTheJumpHostRatherThanConnectionFailed() throws {
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .reconnecting(
                    attempt: 2, delay: .seconds(2),
                    failure: .jumpHostFailed(.timedOut)),
                syncError: nil))
        #expect(presentation.message == "Reconnecting to studio: The Jump Host did not answer in time")
        #expect(!presentation.message.contains("connection failed"))
        #expect(presentation.navigates)
        #expect(presentation.severity == .warning)
    }

    @Test func aFailedHostRendersTheWholePresentation() throws {
        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .failed(failure),
                syncError: nil))
        #expect(presentation.message == "studio: \(failure.presentation.message)")
        #expect(presentation.systemImage == "exclamationmark.triangle.fill")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    @Test func aHostKeyMismatchIsCritical() throws {
        let failure = TransportError.hostKeyMismatch(
            known: HostKeyFingerprint(publicKeyBlob: Data("known".utf8)),
            presented: HostKeyFingerprint(publicKeyBlob: Data("presented".utf8)))
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .failed(failure),
                syncError: nil))
        #expect(presentation.systemImage == "exclamationmark.shield.fill")
        #expect(presentation.severity == .critical)
        #expect(presentation.navigates)
    }

    @Test func aJumpHostKeyMismatchIsCritical() throws {
        let failure = TransportError.jumpHostFailed(
            .hostKeyMismatch(
                known: HostKeyFingerprint(publicKeyBlob: Data("known".utf8)),
                presented: HostKeyFingerprint(publicKeyBlob: Data("presented".utf8))))
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .failed(failure),
                syncError: nil))
        #expect(presentation.systemImage == "exclamationmark.shield.fill")
        #expect(presentation.severity == .critical)
        #expect(presentation.navigates)
    }

    @Test func aConnectedHostWithASyncErrorKeepsTheSnapshotRow() throws {
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                syncError: "Could not sync this Host's Agents. Retrying…"))
        #expect(presentation.message == "studio: Could not sync this Host's Agents. Retrying…")
        #expect(presentation.systemImage == "arrow.trianglehead.2.clockwise")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    @Test func endedOrUnknownStatusesWithoutASyncErrorProduceNoRow() {
        let quiet: [EventsSessionStatus?] = [.ended, nil]
        for status in quiet {
            #expect(
                ConsoleHostStatusPresentation(
                    host: host,
                    status: status,
                    syncError: nil) == nil)
        }
    }

    @Test func quietConditionRowsAreInformationalAndDoNotNavigate() throws {
        let paused = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .suspended, syncError: nil))
        #expect(paused.message == "Connection to studio is paused.")
        #expect(paused.severity == .informational)
        #expect(!paused.navigates)

        let connecting = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .connecting, syncError: nil))
        #expect(connecting.message == "Connecting to studio…")
        #expect(connecting.severity == .informational)
        #expect(!connecting.navigates)

        let loading = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                isAwaitingSnapshot: true,
                syncError: nil))
        #expect(loading.message == "Loading Agents from studio…")
        #expect(loading.severity == .informational)
        #expect(!loading.navigates)
    }

    @Test func connectingWithAStandingFailureLooksLikeFailure() throws {
        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connecting,
                standingFailure: failure,
                syncError: nil))
        #expect(presentation.message == "studio: \(failure.presentation.message)")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    @Test func aConnectedHostWithKnownInventoryAndNoSyncErrorProducesNoRow() {
        #expect(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                isAwaitingSnapshot: false,
                syncError: nil) == nil)
    }

    @Test func unknownInventoryNeverClaimsNoAgents() {
        let conditions: [EventsSessionStatus] = [
            .connecting,
            .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
            .suspended,
            .failed(.streamLocalOpenFailed(path: "/s")),
        ]
        for status in conditions {
            let row = ConsoleHostStatusPresentation(
                host: host, status: status, syncError: nil)
            #expect(row != nil)
            #expect(
                ConsoleAgentsSurface(
                    hostCount: 1,
                    filteredHostName: nil,
                    filteredAgentCount: 0,
                    visibleIssueCount: 1) == .rows)
            #expect(
                ConsoleAgentsSurface(
                    hostCount: 1,
                    filteredHostName: "studio",
                    filteredAgentCount: 0,
                    visibleIssueCount: 1) == .rows)
        }
        #expect(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                isAwaitingSnapshot: true,
                syncError: nil) != nil)
    }

    @Test func knownEmptyInventoryMayClaimNoAgents() {
        #expect(
            ConsoleAgentsSurface(
                hostCount: 0,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 0) == .noHosts)
        #expect(
            ConsoleAgentsSurface(
                hostCount: 1,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 0) == .noAgents)
        #expect(
            ConsoleAgentsSurface(
                hostCount: 2,
                filteredHostName: "studio",
                filteredAgentCount: 0,
                visibleIssueCount: 0) == .noAgentsOnHost("studio"))
        #expect(
            ConsoleAgentsSurface(
                hostCount: 2,
                filteredHostName: nil,
                filteredAgentCount: 1,
                visibleIssueCount: 1) == .rows)
    }

    @Test func eachConditionHasACompactStatusAndBadge() throws {
        func issue(
            _ status: EventsSessionStatus?, standingFailure: TransportError? = nil,
            awaiting: Bool = false, syncError: String? = nil
        ) throws -> (HostConnectionTone, String) {
            let presentation = try #require(
                ConsoleHostStatusPresentation(
                    host: host, status: status, standingFailure: standingFailure,
                    isAwaitingSnapshot: awaiting, syncError: syncError))
            return (presentation.tone, presentation.status)
        }
        #expect(try issue(.suspended) == (.paused, "Paused"))
        #expect(try issue(.connecting) == (.pending, "Connecting…"))
        #expect(try issue(.connecting, standingFailure: .timedOut) == (.unavailable, "Can't connect"))
        #expect(
            try issue(.reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut))
                == (.reconnecting, "Reconnecting…"))
        #expect(try issue(.failed(.authenticationFailed)) == (.unavailable, "Can't connect"))
        #expect(try issue(.connected, awaiting: true) == (.pending, "Loading Agents…"))
        #expect(try issue(.connected, syncError: "boom") == (.warning, "Sync issue"))
    }
}

@Suite("Console host issue summary")
struct ConsoleHostIssueSummaryTests {
    private func issue(_ name: String, _ status: EventsSessionStatus)
        -> ConsoleHostStatusPresentation?
    {
        ConsoleHostStatusPresentation(
            host: Host.fixture(name: name), status: status, syncError: nil)
    }

    @Test func aSingleConditionKeepsItsOwnRow() {
        let one = [issue("a", .failed(.timedOut))].compactMap { $0 }
        #expect(ConsoleHostIssueSummary(issues: one) == nil)
        #expect(ConsoleHostIssueSummary(issues: []) == nil)
    }

    @Test func severalConditionsFoldIntoCountsWorstFirst() throws {
        let reconnecting = EventsSessionStatus.reconnecting(
            attempt: 1, delay: .seconds(1), failure: .timedOut)
        let issues = [
            issue("a", reconnecting), issue("b", .failed(.timedOut)),
            issue("c", reconnecting), issue("d", .failed(.authenticationFailed)),
        ].compactMap { $0 }
        let summary = try #require(ConsoleHostIssueSummary(issues: issues))
        #expect(summary.title == "4 Hosts")
        #expect(summary.detail == "2 can't connect · 2 reconnecting")
        #expect(summary.tone == .unavailable)
    }
}
