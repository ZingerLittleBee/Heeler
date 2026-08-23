import Foundation
import Testing

@testable import Heeler

@Suite("Host onboarding connection presentation")
struct HostOnboardingPresentationTests {
    /// The Host detail footer shows the Explanation during automatic
    /// `EventsSessionStatus.reconnecting`, and hides it only while a manual
    /// Reconnect request is in flight — including on `.failed` (#160).
    @Test func footerSuppressionFollowsTheManualRequestNotTransportReconnecting() {
        let automatic = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: .timedOut),
            isManualReconnectInFlight: false)
        #expect(automatic.footerMessage == TransportError.timedOut.presentation.explanation)

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

    @Test func reconnectingFooterIsExplanationAndNeverTheSuggestion() throws {
        let failure = TransportError.sshUnreachable(detail: "connection refused")
        let presentation = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: failure),
            isManualReconnectInFlight: false)
        #expect(presentation.footerMessage == failure.presentation.explanation)
        #expect(presentation.connectionErrorMessage == failure.presentation.explanation)
        let suggestion = try #require(failure.presentation.recoverySuggestion)
        #expect(!(presentation.footerMessage?.contains(suggestion) ?? true))
    }

    @Test func failedFooterIsTheWholePresentation() {
        let failure = TransportError.authenticationFailed
        let presentation = HostOnboardingConnectionPresentation(
            status: .failed(failure),
            isManualReconnectInFlight: false)
        #expect(presentation.footerMessage == failure.presentation.message)
    }
}
