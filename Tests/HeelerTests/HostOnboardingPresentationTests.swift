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

    /// Opened from a "Sync issue" row, the detail says what went wrong.
    @Test func aConnectedHostExplainsItsSyncIssue() {
        let issue = "herdr rejected the Console sync: boom. Retrying…"
        let outOfSync = HostOnboardingConnectionPresentation(
            status: .connected, syncIssue: issue, isManualReconnectInFlight: false)
        #expect(outOfSync.footerMessage == issue)
        #expect(outOfSync.isSyncIssue)

        let reconnectPressed = HostOnboardingConnectionPresentation(
            status: .connected, syncIssue: issue, isManualReconnectInFlight: true)
        #expect(reconnectPressed.footerMessage == nil)

        let inSync = HostOnboardingConnectionPresentation(
            status: .connected, isManualReconnectInFlight: false)
        #expect(inSync.footerMessage == nil)
        #expect(!inSync.isSyncIssue)

        let failure = TransportError.authenticationFailed
        let stopped = HostOnboardingConnectionPresentation(
            status: .failed(failure), syncIssue: issue, isManualReconnectInFlight: false)
        #expect(stopped.footerMessage == failure.presentation.message)
        #expect(!stopped.isSyncIssue)
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

    /// The Console never prompts for trust: once onboarding pins the key and
    /// the preflight passes, a Console failed on that key retries once.
    @Test func passingPreflightRetriesOnlyAConsoleFailedOnHostKeyTrust() {
        let key = HostKeyFingerprint(publicKeyBlob: Data("presented".utf8))
        let rejected = TransportError.hostKeyRejected(presented: key)
        let mismatch = TransportError.hostKeyMismatch(
            known: HostKeyFingerprint(publicKeyBlob: Data("known".utf8)), presented: key)
        let rows: [(Bool, EventsSessionStatus?, Bool, HostOnboardingConsoleRecovery.Action)] = [
            (true, .failed(rejected), false, .retry),
            (true, .failed(mismatch), false, .retry),
            (true, .failed(.jumpHostFailed(rejected)), false, .retry),
            // A route that cannot reach another machine failed on the key.
            (
                true,
                .failed(
                    .noRouteReached([
                        RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: .timedOut),
                        RouteFailure(route: "box over Home", mayNameAnotherMachine: false, error: mismatch),
                    ])), false, .retry
            ),
            // Only a LAN address failed on the key: another machine elsewhere.
            (
                true,
                .failed(
                    .noRouteReached([
                        RouteFailure(route: "192.168.1.5", mayNameAnotherMachine: true, error: mismatch),
                        RouteFailure(route: "box over Home", mayNameAnotherMachine: false, error: .timedOut),
                    ])), false, .disarm
            ),
            // A manual Reconnect is already retrying: decide after it.
            (true, .failed(rejected), true, .wait),
            // The Console has not settled yet.
            (true, .connecting, false, .wait),
            (true, .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut), false, .wait),
            // Any other settled state spends the proof without a retry.
            (true, .connected, false, .disarm),
            (true, .failed(.authenticationFailed), false, .disarm),
            (true, .failed(.jumpHostFailed(.authenticationFailed)), false, .disarm),
            (true, .suspended, false, .disarm),
            (true, nil, false, .disarm),
            // No passing preflight to act on.
            (false, .failed(rejected), false, .wait),
        ]
        for (isArmed, status, inFlight, expected) in rows {
            let input = HostOnboardingConsoleRecovery.Input(
                isArmed: isArmed, status: status, isManualReconnectInFlight: inFlight)
            #expect(HostOnboardingConsoleRecovery.action(for: input) == expected)
        }
    }

    /// The check prints the fingerprint of the host key file sshd serves for
    /// the presented key's algorithm.
    @Test func changedKeyCheckNamesTheHostKeyFileOfThePresentedAlgorithm() {
        let rows: [(algorithm: String, file: String)] = [
            ("ssh-ed25519", "ssh_host_ed25519_key.pub"),
            ("ecdsa-sha2-nistp256", "ssh_host_ecdsa_key.pub"),
            ("rsa-sha2-512", "ssh_host_rsa_key.pub"),
            ("ssh-rsa", "ssh_host_rsa_key.pub"),
            (HostKeyFingerprint.unknownAlgorithm, "ssh_host_ed25519_key.pub"),
        ]
        for (algorithm, file) in rows {
            let replacement = HostKeyReplacement(
                known: HostKeyFingerprint(digest: Data(repeating: 0, count: 32)),
                presented: HostKeyFingerprint(
                    digest: Data(repeating: 1, count: 32), algorithm: algorithm))
            #expect(replacement.fingerprintCommand == "ssh-keygen -lf /etc/ssh/\(file)")
        }
    }
}

@Suite("Host detail route status")
struct HostRouteStatusPresentationTests {
    private let home = HostRoute(address: "192.168.1.20")
    private let away = HostRoute(address: "box.example.com", port: 2222)

    private func presentation(
        _ status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        connectedRouteID: HostRoute.ID? = nil
    ) -> HostRouteStatusPresentation {
        HostRouteStatusPresentation(
            status: status,
            standingFailure: standingFailure,
            connectedRouteID: connectedRouteID,
            routes: [home, away],
            describe: { _ in "Direct" })
    }

    @Test func connectedNamesTheRouteItReached() {
        let connected = presentation(.connected, connectedRouteID: away.id)
        #expect(connected.tone == .connected)
        #expect(connected.subtitle == "box.example.com:2222 · Direct")
        #expect(connected.inUseRouteID == away.id)
        #expect(connected.routeFailures.isEmpty)
    }

    /// A route id from before the Host was edited names nothing now.
    @Test func connectedThroughAnUnknownRouteMarksNone() {
        let connected = presentation(.connected, connectedRouteID: UUID())
        #expect(connected.subtitle == nil)
        #expect(connected.inUseRouteID == nil)
    }

    @Test func noRouteReachedTagsEachRouteWithItsOwnFailure() {
        let failure = TransportError.noRouteReached([
            RouteFailure(
                route: "192.168.1.20", mayNameAnotherMachine: true, error: .timedOut,
                routeID: home.id),
            RouteFailure(
                route: "box.example.com:2222", mayNameAnotherMachine: false,
                error: .authenticationFailed, routeID: away.id),
        ])
        for status: EventsSessionStatus in [
            .failed(failure), .reconnecting(attempt: 1, delay: .seconds(1), failure: failure),
        ] {
            let failed = presentation(status)
            #expect(failed.inUseRouteID == nil)
            #expect(
                failed.routeFailures == [
                    home.id: TransportError.timedOut.presentation.summary,
                    away.id: TransportError.authenticationFailed.presentation.summary,
                ])
        }
        let standing = presentation(.connecting, standingFailure: failure)
        #expect(standing.routeFailures.count == 2)
    }

    /// With each route's failure on its row and the Summary on the card,
    /// the footer adds only the Recovery Suggestion.
    @Test func itemizedRoutesLeaveTheFooterOnlyTheSuggestion() throws {
        let failure = TransportError.noRouteReached([
            RouteFailure(
                route: "192.168.1.20", mayNameAnotherMachine: true, error: .timedOut,
                routeID: home.id)
        ])
        let suggestion = try #require(failure.presentation.recoverySuggestion)
        let failed = HostOnboardingConnectionPresentation(
            status: .failed(failure), isManualReconnectInFlight: false, itemizesRoutes: true)
        #expect(failed.footerMessage == suggestion)
        let retrying = HostOnboardingConnectionPresentation(
            status: .reconnecting(attempt: 1, delay: .seconds(1), failure: failure),
            isManualReconnectInFlight: false, itemizesRoutes: true)
        #expect(retrying.footerMessage == nil)
        let single = HostOnboardingConnectionPresentation(
            status: .failed(.timedOut), isManualReconnectInFlight: false, itemizesRoutes: true)
        #expect(single.footerMessage == TransportError.timedOut.presentation.message)
    }

    /// One route's failure is the card's to say; the row stays untagged.
    @Test func aSingleFailureTagsNoRoute() {
        let failed = presentation(.failed(.timedOut))
        #expect(failed.tone == .failed)
        #expect(failed.subtitle == TransportError.timedOut.presentation.summary)
        #expect(failed.routeFailures.isEmpty)
    }

    /// A Reconnect press shows on the card alone, before the status moves.
    @Test func aManualReconnectReadsAsConnecting() {
        let failure = TransportError.noRouteReached([
            RouteFailure(
                route: "192.168.1.20", mayNameAnotherMachine: true, error: .timedOut,
                routeID: home.id)
        ])
        for status: EventsSessionStatus in [.connected, .failed(failure)] {
            let pressed = HostRouteStatusPresentation(
                status: status, connectedRouteID: home.id, isManualReconnectInFlight: true,
                routes: [home, away], describe: { _ in "Direct" })
            #expect(pressed.tone == .connecting)
            #expect(pressed.title == "Connecting…")
            #expect(pressed.inUseRouteID == nil)
            #expect(pressed.routeFailures.isEmpty)
        }
    }

    @Test func idleStatusesSayNotConnected() {
        for status: EventsSessionStatus? in [nil, .suspended, .ended] {
            let idle = presentation(status, connectedRouteID: home.id)
            #expect(idle.tone == .idle)
            #expect(idle.inUseRouteID == nil)
        }
    }
}
