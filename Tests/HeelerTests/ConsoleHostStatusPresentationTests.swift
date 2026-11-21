import Foundation
import Observation
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
                syncError: "Could not sync this Host. Retrying…"))
        #expect(presentation.message == "studio: Could not sync this Host. Retrying…")
        #expect(presentation.sectionMessage == "Could not sync this Host. Retrying…")
        #expect(presentation.systemImage == "arrow.trianglehead.2.clockwise")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    /// Under the Host's own section header the row need not name it again.
    /// Only a "studio: " prefix goes; a sentence that names the Host in
    /// passing still reads as one.
    @Test func aSectionRowDropsOnlyTheHostNamePrefix() throws {
        let failure = TransportError.authenticationFailed
        let failed = try #require(
            ConsoleHostStatusPresentation(host: host, status: .failed(failure), syncError: nil))
        #expect(failed.message == "studio: \(failure.presentation.message)")
        #expect(failed.sectionMessage == failure.presentation.message)

        let retrying = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .connecting, standingFailure: failure, syncError: nil))
        #expect(retrying.sectionMessage == failure.presentation.message)

        let quiet = [
            ConsoleHostStatusPresentation(host: host, status: .suspended, syncError: nil),
            ConsoleHostStatusPresentation(host: host, status: .connecting, syncError: nil),
            ConsoleHostStatusPresentation(
                host: host, status: .connected, isAwaitingSnapshot: true, syncError: nil),
            ConsoleHostStatusPresentation(
                host: host,
                status: .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
                syncError: nil),
        ]
        for row in quiet {
            let row = try #require(row)
            #expect(row.sectionMessage == row.message)
        }
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

@Suite("Console host conditions per Host")
struct ConsoleHostConditionsPerHostTests {
    private let tmux = Host(
        name: "m3", address: "m3.example", username: "dev", serverKind: .tmux, sessionName: "default")
    private let rex = Host(name: "m3", address: "m3.example", username: "dev", serverKind: .rex)
    private let win = Host(name: "win", address: "win.example", username: "dev")
    private let reconnecting = EventsSessionStatus.reconnecting(
        attempt: 1, delay: .seconds(1), failure: .timedOut)

    private func conditions(
        _ statuses: [Host.ID: EventsSessionStatus]
    ) -> [ConsoleHostStatusPresentation] {
        ConsoleHostStatusPresentation.perHost(
            [tmux, rex, win], statuses: statuses, standingFailures: [:], awaitingSnapshot: [],
            syncErrors: [:])
    }

    /// The connection is the Host's (ADR 0058): its Servers take one
    /// condition between them, under the Host's name alone.
    @Test func aHostTakesOneConditionWhateverServersItHasOn() throws {
        let down = conditions([tmux.id: reconnecting, rex.id: reconnecting, win.id: reconnecting])
        #expect(down.map(\.hostName) == ["m3", "win"])
        #expect(down.map(\.hostID) == [tmux.id, win.id])
        #expect(down.first?.message == "Reconnecting to m3: Connection timed out")
        #expect(ConsoleHostIssueSummary(issues: down)?.title == "2 Hosts not connected")

        // A failure of the connection leads one Server's own, and the
        // sheet it opens explains that one under the Host's name.
        let stopped: [Host.ID: EventsSessionStatus] = [
            tmux.id: .failed(.tmuxServerNotRunning(socketName: "default")), rex.id: .failed(.timedOut),
        ]
        #expect(conditions(stopped).map(\.serverID) == [rex.id])
        #expect(conditions(stopped).map(\.hostID) == [tmux.id])
        let m3 = try #require(ConsoleHostSectionGroup.grouping([tmux, rex]).first)
        let detail = try #require(
            HostConnectionDetailPresentation(group: m3, statuses: stopped, standingFailures: [:]))
        #expect(detail.hostName == "m3")
        #expect(detail.failure == .timedOut)
        #expect(!detail.canStop)

        // Stop Connecting reaches every Server, so it is offered while one
        // still tries, though a stopped one explains the Host.
        let trying: [Host.ID: EventsSessionStatus] = [
            tmux.id: .failed(.tmuxServerNotRunning(socketName: "default")), rex.id: reconnecting,
        ]
        let stoppable = try #require(
            HostConnectionDetailPresentation(group: m3, statuses: trying, standingFailures: [:]))
        #expect(stoppable.failure == .tmuxServerNotRunning(socketName: "default"))
        #expect(stoppable.canStop)

        // One connected Server proves the Host connected.
        let partly: [Host.ID: EventsSessionStatus] = [
            tmux.id: .connected, rex.id: reconnecting, win.id: .connected,
        ]
        #expect(conditions(partly).isEmpty)
        #expect(HostConnectionDetailPresentation(group: m3, statuses: partly, standingFailures: [:]) == nil)
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
        #expect(summary.title == "4 Hosts not connected")
        #expect(
            summary.counts == [
                .init(tone: .unavailable, text: "2 can't connect"),
                .init(tone: .reconnecting, text: "2 reconnecting"),
            ])
        #expect(summary.detail == "2 can't connect, 2 reconnecting")
        #expect(summary.tone == .unavailable)
    }

    /// A connected Host that is loading or out of sync is not "not
    /// connected", so the title says less.
    @Test func aConnectedHostMakesTheTitleNotReady() throws {
        let loading = ConsoleHostStatusPresentation(
            host: Host.fixture(name: "b"), status: .connected, isAwaitingSnapshot: true,
            syncError: nil)
        let issues = [issue("a", .failed(.timedOut)), loading].compactMap { $0 }
        let summary = try #require(ConsoleHostIssueSummary(issues: issues))
        #expect(summary.title == "2 Hosts not ready")
    }
}

@Suite("Console host issue corner presentation", .serialized)
struct ConsoleHostIssueCornerPresentationTests {
    private let first = Host.fixture(name: "home-mini")
    private let second = Host.fixture(name: "gpu-devbox")

    private func issue(
        _ host: Host,
        _ status: EventsSessionStatus,
        awaitingSnapshot: Bool = false,
        syncError: String? = nil
    ) throws -> ConsoleHostStatusPresentation {
        try #require(
            ConsoleHostStatusPresentation(
                host: host, status: status, isAwaitingSnapshot: awaitingSnapshot,
                syncError: syncError))
    }

    @Test func emptyIssuesProduceNoCornerPresentation() {
        #expect(ConsoleHostIssueCornerPresentation(issues: []) == nil)
    }

    @Test func singleReconnectingHostAnimatesBarWithoutCollapsedBadge() throws {
        let reconnecting = try issue(
            first, .reconnecting(attempt: 2, delay: .seconds(2), failure: .timedOut))
        let corner = try #require(ConsoleHostIssueCornerPresentation(issues: [reconnecting]))

        #expect(corner.expandedTitle == "home-mini")
        #expect(corner.expandedStatus == "Reconnecting…")
        #expect(corner.tone == .reconnecting)
        #expect(corner.animatesBar)
        #expect(corner.badgeText(isExpanded: true) == nil)
        #expect(corner.badgeText(isExpanded: false) == nil)
        #expect(corner.action == .openHost(first.id))
        #expect(corner.accessibilityLabel == reconnecting.message)
    }

    @Test func singleFailedHostStopsBarAndShowsExclamationWhenCollapsed() throws {
        let failed = try issue(first, .failed(.authenticationFailed))
        let corner = try #require(ConsoleHostIssueCornerPresentation(issues: [failed]))

        #expect(corner.expandedTitle == "home-mini")
        #expect(corner.expandedStatus == "Can't connect")
        #expect(corner.tone == .unavailable)
        #expect(!corner.animatesBar)
        #expect(corner.badgeText(isExpanded: true) == nil)
        #expect(corner.badgeText(isExpanded: false) == "!")
        #expect(corner.action == .openHost(first.id))
    }

    @Test func multipleIssuesShowCountBadgeAndOpenSummary() throws {
        let reconnecting = try issue(
            first, .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut))
        let secondReconnecting = try issue(
            second, .reconnecting(attempt: 3, delay: .seconds(4), failure: .sshUnreachable(detail: "down")))
        let bothReconnecting = try #require(
            ConsoleHostIssueCornerPresentation(issues: [reconnecting, secondReconnecting]))
        #expect(bothReconnecting.animatesBar)
        #expect(bothReconnecting.badgeText(isExpanded: true) == "2")
        #expect(bothReconnecting.badgeText(isExpanded: false) == "2")
        #expect(bothReconnecting.action == .showAll)

        let failed = try issue(second, .failed(.timedOut))
        let mixed = try #require(
            ConsoleHostIssueCornerPresentation(issues: [reconnecting, failed]))
        #expect(mixed.tone == .unavailable)
        #expect(!mixed.animatesBar)
        #expect(mixed.badgeText(isExpanded: false) == "2")
        #expect(mixed.action == .showAll)
    }

    @Test func quietInformationalHostTogglesExpandedWithoutOpeningSheet() throws {
        let connecting = try issue(first, .connecting)
        let corner = try #require(ConsoleHostIssueCornerPresentation(issues: [connecting]))
        #expect(corner.animatesBar)
        #expect(corner.action == .toggleExpanded)
        #expect(corner.accessibilityHint == nil)

        let paused = try issue(first, .suspended)
        let pausedCorner = try #require(ConsoleHostIssueCornerPresentation(issues: [paused]))
        #expect(!pausedCorner.animatesBar)
        #expect(pausedCorner.action == .toggleExpanded)
    }
}
