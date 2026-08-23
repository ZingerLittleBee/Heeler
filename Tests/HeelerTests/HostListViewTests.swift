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
