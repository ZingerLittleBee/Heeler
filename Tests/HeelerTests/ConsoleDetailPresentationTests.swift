import Foundation
import Testing

@testable import Heeler

/// What the session screen's detail column says when the selected Agent is no
/// longer in the Console list (#146).
///
/// Two situations empty that list and the screen has to tell them apart. Every
/// non-`.connected` status runs `invalidateSnapshot()`, so a Host that failed
/// clears `agentsByPane` exactly as a closed pane does — and the placeholder
/// then blamed the Agent for the Host's failure while `connectionGuidance`,
/// the only text naming the action the user can take, rendered solely in the
/// Console list behind the screen.
///
/// #142 is what made that routine rather than rare: every foreground return
/// re-proves the connection, so a herdr stopped while the app was away takes
/// the Host terminally to `.failed` on return. That behaviour is intended and
/// `herdrStoppedWhileAwayFailsTheHostWithItsSetupGuidance` pins it; the
/// guidance being right is what makes it worse that it was unreadable.
@MainActor
@Suite("Console detail presentation")
struct ConsoleDetailPresentationTests {
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    private static let socketGuidance =
        "herdr is not running on this Host. If it is running, check SSH stream-local forwarding."

    private static let paneGoneMessage = "This Agent's pane is no longer reported."

    /// The case the ticket names: a Host actually driven to `.failed`, and
    /// what the screen renders once its Agent list has emptied.
    @Test func aFailedHostShowsItsGuidanceInsteadOfBlamingTheAgent() async throws {
        let host = Host.fixture()
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        let transport = ScriptedTransport(snapshot: .fixture())
        // herdr is not running: the connect-path ping opens a stream-local
        // channel onto a socket nothing is serving, which is
        // configuration-class and stops the session outright.
        await transport.failPing(
            atCall: 1, with: .streamLocalOpenFailed(path: socketPath))
        let store = makeStore(transport: transport)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should stop on a failure no retry clears") {
            store.hostStatuses[host.id]
                == .failed(.streamLocalOpenFailed(path: socketPath))
        }
        // The list is empty, so the screen is on exactly the path that used to
        // say the Agent's pane was gone.
        #expect(store.agents.isEmpty)

        // Built from the store's own live state, as the detail column does.
        let presentation = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
            hostStatuses: store.hostStatuses,
            hosts: [host])

        #expect(presentation.cause == .hostFailed)
        #expect(presentation.title == "Host Unavailable")
        #expect(presentation.message == "\(host.displayName): \(Self.socketGuidance)")
        // Not the Agent's fault, and not both stories at once.
        #expect(!presentation.message.contains("pane is no longer reported"))
        store.setHosts([])
    }

    /// The other half: with the Host fine, the placeholder means what it says.
    @Test func aVanishedPaneOnAHealthyHostStillSaysTheAgentIsGone() {
        let host = Host.fixture()
        let presentation = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
            hostStatuses: [host.id: .connected],
            hosts: [host])

        #expect(presentation.cause == .paneGone)
        #expect(presentation.title == "Agent Gone")
        #expect(presentation.message == Self.paneGoneMessage)
        // A healthy Host must not be described as a Host problem.
        #expect(!presentation.message.contains("herdr"))
    }

    /// The selection's own Host decides. Reading any-failed-Host, or the first
    /// entry in the map, would put one Host's outage on another Host's screen.
    @Test func onlyTheSelectedAgentsOwnHostDecidesWhatTheScreenSays() {
        let healthy = Host.fixture(name: "healthy", address: "healthy.example")
        let broken = Host.fixture(name: "broken", address: "broken.example")
        let statuses: [Host.ID: EventsSessionStatus] = [
            healthy.id: .connected,
            broken.id: .failed(.streamLocalOpenFailed(path: "/s")),
        ]

        let onHealthy = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: healthy.id, paneID: "w1:p1"),
            hostStatuses: statuses, hosts: [healthy, broken])
        #expect(onHealthy.cause == .paneGone)
        #expect(onHealthy.message == Self.paneGoneMessage)

        let onBroken = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: broken.id, paneID: "w1:p1"),
            hostStatuses: statuses, hosts: [healthy, broken])
        #expect(onBroken.cause == .hostFailed)
        #expect(onBroken.message == "\(broken.displayName): \(Self.socketGuidance)")
    }

    /// `.reconnecting` must not borrow the failed Host's guidance. It is
    /// emitted solely past a `guard failure.isRetryable`, so the session is
    /// working on it and the text naming a user action would be a lie about
    /// who has to act — the same split the Console list already makes.
    @Test func aReconnectingOrPausedHostDoesNotBorrowTheFailedGuidance() {
        let host = Host.fixture()
        let inFlight: [EventsSessionStatus?] = [
            .reconnecting(attempt: 2, delay: .seconds(1), failure: .timedOut),
            .reconnecting(
                attempt: 1, delay: .seconds(1),
                failure: .sshUnreachable(detail: "the Host is unreachable")),
            .suspended,
            .connected,
            nil,
        ]
        for status in inFlight {
            let presentation = MissingAgentPresentation(
                agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
                hostStatuses: status.map { [host.id: $0] } ?? [:],
                hosts: [host])
            #expect(presentation.cause == .paneGone)
            #expect(presentation.message == Self.paneGoneMessage)
        }
    }

    /// The approved socket wording is what reaches the screen, unabbreviated
    /// and never replaced by socket-implementation language.
    @Test func theApprovedSocketWordingIsWhatReachesTheScreen() {
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        // Pinned here as well as at its source: this screen is now one of the
        // two places it renders, and the two must not drift apart.
        #expect(
            TransportError.streamLocalOpenFailed(path: socketPath).connectionGuidance
                == Self.socketGuidance)

        let host = Host.fixture()
        for failure in [
            TransportError.streamLocalOpenFailed(path: socketPath),
            .socketNotFound(path: socketPath),
        ] {
            // No Host record for the id, so the message is the guidance alone.
            let presentation = MissingAgentPresentation(
                agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
                hostStatuses: [host.id: .failed(failure)],
                hosts: [])

            #expect(presentation.cause == .hostFailed)
            // A guidance that renders empty would leave the screen saying
            // nothing at all, which is worse than the wrong message it
            // replaced.
            #expect(!presentation.message.isEmpty)
            #expect(presentation.message == failure.connectionGuidance)
            #expect(
                !presentation.message.lowercased()
                    .contains("remote socket is not listening"))
        }
    }

    /// The two causes stay two. Nothing here may end up shared between them —
    /// a single message covering both is the defect restated.
    @Test func theTwoCausesNeverCollapseIntoOneAnswer() {
        let host = Host.fixture()
        let agentID = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let failed = MissingAgentPresentation(
            agentID: agentID,
            hostStatuses: [host.id: .failed(.streamLocalOpenFailed(path: "/s"))],
            hosts: [host])
        let gone = MissingAgentPresentation(
            agentID: agentID, hostStatuses: [host.id: .connected], hosts: [host])

        #expect(failed.cause != gone.cause)
        #expect(failed.title != gone.title)
        #expect(failed.message != gone.message)
        #expect(failed.systemImage != gone.systemImage)
    }

    /// A changed host key is a security refusal, not an ordinary outage, and
    /// carries the same icon the Console list gives it.
    @Test func aHostKeyMismatchCarriesTheSecurityIcon() {
        let host = Host.fixture()
        let agentID = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let mismatch = MissingAgentPresentation(
            agentID: agentID,
            hostStatuses: [
                host.id: .failed(
                    .hostKeyMismatch(
                        known: HostKeyFingerprint(publicKeyBlob: Data("known".utf8)),
                        presented: HostKeyFingerprint(
                            publicKeyBlob: Data("presented".utf8))))
            ],
            hosts: [host])
        #expect(mismatch.systemImage == "exclamationmark.shield.fill")

        let outage = MissingAgentPresentation(
            agentID: agentID,
            hostStatuses: [host.id: .failed(.streamLocalOpenFailed(path: "/s"))],
            hosts: [host])
        #expect(outage.systemImage == "exclamationmark.triangle.fill")
    }

    /// A store whose session factory routes every Host to `transport`.
    private func makeStore(transport: ScriptedTransport) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }
    }

    /// Polls until `condition` holds, yielding so the store's tasks progress.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}
