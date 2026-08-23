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

    @Test func footerMatrixCoversEveryHostDetailRow() {
        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        let rows: [(
            EventsSessionStatus?, TransportError?, Bool, String?
        )] = [
            (nil, nil, false, nil),
            (.suspended, nil, false, nil),
            (.connected, nil, false, nil),
            (.ended, nil, false, nil),
            (.connecting, nil, false, nil),
            (.connecting, nil, true, nil),
            (.connecting, failure, false, failure.presentation.message),
            (.connecting, failure, true, nil),
            (
                .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
                nil, false, TransportError.timedOut.presentation.explanation
            ),
            (
                .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
                nil, true, nil
            ),
            (.failed(failure), nil, false, failure.presentation.message),
            (.failed(failure), nil, true, nil),
        ]
        for (status, standing, inFlight, expected) in rows {
            let presentation = HostOnboardingConnectionPresentation(
                status: status,
                standingFailure: standing,
                isManualReconnectInFlight: inFlight)
            #expect(presentation.footerMessage == expected)
            if inFlight {
                #expect(presentation.footerMessage == nil)
            }
        }
    }

    @Test func aManualRequestDoesNotRewriteStatusDerivedCopy() {
        let failure = TransportError.authenticationFailed
        let suppressed = HostOnboardingConnectionPresentation(
            status: .failed(failure),
            isManualReconnectInFlight: true)
        #expect(suppressed.footerMessage == nil)
        #expect(suppressed.connectionErrorMessage == failure.presentation.message)

        let automatic = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 2, delay: .seconds(2), failure: .timedOut),
            isManualReconnectInFlight: false)
        #expect(automatic.footerMessage == TransportError.timedOut.presentation.explanation)
        #expect(automatic.connectionErrorMessage == automatic.footerMessage)

        let connectingStanding = HostOnboardingConnectionPresentation(
            status: .connecting,
            standingFailure: failure,
            isManualReconnectInFlight: true)
        #expect(connectingStanding.footerMessage == nil)
        #expect(connectingStanding.connectionErrorMessage == failure.presentation.message)
    }
}
