import Foundation
import Testing

@testable import Heeler

@Suite("Host onboarding connection presentation")
struct HostOnboardingPresentationTests {
    /// The Host detail footer shows Connection Guidance during automatic
    /// `EventsSessionStatus.reconnecting`, and hides it only while a manual
    /// Reconnect request is in flight — including on `.failed` (#160).
    @Test func footerSuppressionFollowsTheManualRequestNotTransportReconnecting() {
        let automatic = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: .timedOut),
            isManualReconnectInFlight: false)
        #expect(automatic.footerMessage == TransportError.timedOut.connectionGuidance)

        let manualDuringReconnect = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: .timedOut),
            isManualReconnectInFlight: true)
        #expect(manualDuringReconnect.footerMessage == nil)

        let manualDuringFailure = HostOnboardingConnectionPresentation(
            status: .failed(.authenticationFailed),
            isManualReconnectInFlight: true)
        #expect(manualDuringFailure.footerMessage == nil)
    }
}
