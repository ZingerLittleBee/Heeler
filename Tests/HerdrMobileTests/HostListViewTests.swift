import Foundation
import Testing

@testable import HerdrMobile

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
    }
}
