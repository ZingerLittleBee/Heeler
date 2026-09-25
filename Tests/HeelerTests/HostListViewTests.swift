import Foundation
import Testing

@testable import Heeler

@Suite("Host list connection presentation")
struct HostListViewTests {
    @Test func connectedHostShowsRoundedLatency() {
        let presentation = HostConnectionPresentation(
            status: .connected,
            latency: .milliseconds(25) + .microseconds(600))

        #expect(presentation.title == "26 ms")
        #expect(presentation.accessibilityLabel == "Connected, latency 26 ms")
        #expect(presentation.tone == .connected)
    }

    @Test func subMillisecondLatencyStaysMeaningful() {
        let presentation = HostConnectionPresentation(
            status: .connected,
            latency: .microseconds(400))

        #expect(presentation.title == "<1 ms")
    }

    @Test func disconnectedStatesNeverShowStaleLatency() {
        let latency = Duration.milliseconds(42)

        #expect(
            HostConnectionPresentation(
                status: .reconnecting(
                    attempt: 1,
                    delay: .seconds(1),
                    failure: .timedOut),
                latency: latency
            ).title == "Reconnecting…")
        #expect(
            HostConnectionPresentation(
                status: .failed(.authenticationFailed),
                latency: latency
            ).title == "Unavailable")
        #expect(
            HostConnectionPresentation(
                status: .suspended,
                latency: latency
            ).title == "Paused")
        #expect(
            HostConnectionPresentation(
                status: .connecting,
                latency: latency
            ).title == "Connecting…")
        #expect(
            HostConnectionPresentation(
                status: .connecting,
                standingFailure: .streamLocalOpenFailed(path: "/s"),
                latency: latency
            ).title == "Unavailable")
    }

    @Test func pausedAndReconnectingHostsHaveTheirOwnTones() {
        #expect(HostConnectionPresentation(status: .suspended, latency: nil).tone == .paused)
        #expect(
            HostConnectionPresentation(
                status: .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
                latency: nil
            ).tone == .reconnecting)
    }

    /// Headers show the icon alone, so no two states may share a shape and
    /// differ only by color.
    @Test func nilStatusIsTheConstructionWindowAndSaysConnecting() {
        let presentation = HostConnectionPresentation(status: nil, latency: nil)
        #expect(presentation.title == "Connecting…")
        #expect(presentation.accessibilityLabel == "Connecting")
        #expect(presentation.tone == .pending)
    }

    @Test func connectingWithoutAStandingFailureIsPending() {
        let presentation = HostConnectionPresentation(
            status: .connecting, latency: .milliseconds(12))
        #expect(presentation.title == "Connecting…")
        #expect(presentation.accessibilityLabel == "Connecting")
        #expect(presentation.tone == .pending)
    }

    @Test func connectingWithAStandingFailureStaysUnavailable() {
        let presentation = HostConnectionPresentation(
            status: .connecting,
            standingFailure: .authenticationFailed,
            latency: .milliseconds(12))
        #expect(presentation.title == "Unavailable")
        #expect(presentation.accessibilityLabel == "Unavailable")
        #expect(presentation.tone == .unavailable)
    }

    @Test func connectedPresentationIgnoresInventoryAndStaysLatencyBased() {
        let presentation = HostConnectionPresentation(
            status: .connected,
            standingFailure: .streamLocalOpenFailed(path: "/s"),
            latency: .milliseconds(25))
        #expect(presentation.title == "25 ms")
        #expect(presentation.tone == .connected)
        #expect(presentation.accessibilityLabel == "Connected, latency 25 ms")
    }
}

@Suite("Host card presentation")
struct HostCardPresentationTests {
    private let host = Host.fixture(name: "studio")

    private func card(
        _ status: EventsSessionStatus?, standingFailure: TransportError? = nil,
        inventory: HostInventory? = nil, canRetry: Bool = true
    ) -> HostCardPresentation {
        HostCardPresentation(
            host: host, status: status, standingFailure: standingFailure,
            latency: .milliseconds(148), inventory: inventory, canRetry: canRetry)
    }

    @Test func aConnectedHostShowsLatencyAndWhatItHolds() {
        let inventory = HostInventory(agents: 1, terminals: 13)
        let connected = card(.connected, inventory: inventory)
        #expect(connected.status == "148 ms")
        #expect(connected.tone == .connected)
        #expect(connected.content == .inventory(inventory))
        #expect(!connected.offersRetry)
        #expect(inventory.agentsText == "1 Agent")
        #expect(inventory.terminalsText == "13 Terminals")
    }

    @Test func aProblemTakesTheConnectionSheetsWords() {
        let stopped = card(.failed(.authenticationFailed))
        #expect(stopped.status == "Can't Connect")
        #expect(stopped.tone == .unavailable)
        guard case .problem(let problem) = stopped.content else {
            Issue.record("A stopped Host explains itself")
            return
        }
        #expect(problem.recoverySuggestion != nil)

        let recovering = card(.reconnecting(attempt: 4, delay: .seconds(8), failure: .timedOut))
        #expect(recovering.status == "Reconnecting")
        guard case .problem(let running) = recovering.content else {
            Issue.record("A reconnecting Host explains itself")
            return
        }
        #expect(running.recoverySuggestion == nil)
    }

    @Test func retryIsOfferedOnlyOnceNothingElseWillTry() {
        #expect(card(.failed(.timedOut)).offersRetry)
        #expect(card(.connecting, standingFailure: .timedOut).offersRetry)
        #expect(!card(.reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut)).offersRetry)
        #expect(!card(.connecting).offersRetry)
        #expect(!card(.failed(.timedOut), canRetry: false).offersRetry)
    }

    @Test func quietStatesStateThemselvesAndNothingMore() {
        #expect(card(.suspended).content == .quiet)
        #expect(card(.suspended).status == "Paused")
        #expect(card(.connecting).content == .quiet)
        #expect(card(nil).status == "Connecting…")
    }

    @Test func onlyAKnownInventoryIsCounted() {
        let live = Host.fixture(name: "live")
        let loading = Host.fixture(name: "loading")
        let down = Host.fixture(name: "down")
        let agent = ConsoleAgent(
            hostID: live.id, hostName: live.displayName,
            agent: Agent(.fixture(paneID: "w1:p1")),
            workspaceLabel: nil, repositoryCheckout: nil)
        let inventories = HostInventory.known(
            statuses: [live.id: .connected, loading.id: .connected, down.id: .failed(.timedOut)],
            awaitingSnapshot: [loading.id],
            agents: [agent],
            terminals: [])
        #expect(inventories == [live.id: HostInventory(agents: 1, terminals: 0)])
    }
}
