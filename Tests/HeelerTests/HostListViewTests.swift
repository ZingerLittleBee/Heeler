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

@Suite("Host row presentation")
struct HostRowPresentationTests {
    private let host = Host.fixture(name: "studio")

    private func row(
        _ status: EventsSessionStatus?, standingFailure: TransportError? = nil,
        canRetry: Bool = true
    ) -> HostRowPresentation {
        HostRowPresentation(
            host: host, status: status, standingFailure: standingFailure,
            latency: .milliseconds(148), canRetry: canRetry)
    }

    @Test func hostsGroupByWhatTheyNeedFromTheUser() {
        #expect(row(.failed(.timedOut)).group == .cannotConnect)
        #expect(row(.connecting, standingFailure: .timedOut).group == .cannotConnect)
        #expect(row(.reconnecting(attempt: 2, delay: .seconds(2), failure: .timedOut)).group == .trying)
        #expect(row(.connecting).group == .trying)
        #expect(row(nil).group == .trying)
        #expect(row(.connected).group == .connected)
        #expect(row(.suspended).group == .notConnected)
        #expect(HostHealthGroup.allCases.sorted() == [.cannotConnect, .trying, .connected, .notConnected])
    }

    @Test func aStoppedHostNamesItsProblemBesideRetry() {
        let stopped = row(.failed(.authenticationFailed))
        #expect(stopped.detail == TransportError.authenticationFailed.presentation.summary)
        #expect(stopped.isProblem)
        #expect(stopped.offersRetry)
        #expect(stopped.tone == .unavailable)
        #expect(!row(.failed(.timedOut), canRetry: false).offersRetry)
    }

    @Test func theUsersOwnRetryStaysInPlaceWhileItDials() {
        let dialing = row(.connecting, standingFailure: .timedOut)
        #expect(dialing.isDialing)
        #expect(dialing.offersRetry)
        #expect(!dialing.isProblem)
    }

    @Test func recoveryStatesItsAttemptWithoutRetry() {
        let recovering = row(.reconnecting(attempt: 4, delay: .seconds(8), failure: .timedOut))
        #expect(recovering.detail == "\(TransportError.timedOut.presentation.summary) · Attempt 4")
        #expect(!recovering.offersRetry)
        #expect(row(.connecting).detail == "Connecting…")
    }

    @Test func aConnectedHostShowsItsAddressAndLatency() {
        let connected = row(.connected)
        #expect(connected.detail == "\(host.username)@\(host.address)")
        #expect(connected.trailing == "148 ms")
        #expect(row(.failed(.timedOut)).trailing == nil)
    }

    @Test func onlyNonEmptyGroupsShowInOrder() {
        let entries = [
            HostListEntry(host: Host.fixture(name: "a"), presentation: row(.connected)),
            HostListEntry(host: Host.fixture(name: "b"), presentation: row(.failed(.timedOut))),
            HostListEntry(host: Host.fixture(name: "c"), presentation: row(.connected)),
        ]
        let sections = HostListEntry.grouped(entries)
        #expect(sections.map(\.group) == [.cannotConnect, .connected])
        #expect(sections.last?.entries.map(\.host.displayName) == ["a", "c"])
    }

    @Test func collapsedGroupsSurviveARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "HostHealthGroupTests-\(UUID())"))
        #expect(HostHealthGroup.collapsed(in: defaults).isEmpty)
        HostHealthGroup.save([.connected, .cannotConnect], in: defaults)
        #expect(HostHealthGroup.collapsed(in: defaults) == [.connected, .cannotConnect])
    }
}
