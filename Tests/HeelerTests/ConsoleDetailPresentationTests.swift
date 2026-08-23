import Foundation
import Testing

@testable import Heeler

/// What the session screen's detail column says when the selected Agent is no
/// longer in the Console list (#146, #154, #155).
///
/// Six situations empty that list and the screen has to tell them apart.
/// Every non-`.connected` status runs `invalidateSnapshot()`, so a Host that
/// failed and a Host that is reconnecting each clear `agentsByPane` exactly as
/// a closed pane does — and the placeholder then blamed the Agent for the
/// Host's trouble, while the text written for the failure rendered only in the
/// Console list behind the screen: the guidance on `.failed`, the shorter
/// phrase that list composes on `.reconnecting`. Which surface renders which
/// text is Transport Error Presentation in `CONTEXT.md`; what this suite
/// pins is what reaches this screen.
///
/// So the tests cover all six causes and the fields that carry them —
/// message, title, icon, and rendering mode — plus which Host the screen
/// reads them from, and that the column reads the live stores rather than a
/// snapshot (#152).
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

    private static let reconnectingSummary = TransportError.timedOut.presentation.summary

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
        #expect(presentation.renderingMode == .staticUnavailable)
        #expect(presentation.message == "\(host.displayName): \(Self.socketGuidance)")
        // Not the Agent's fault, and not both stories at once.
        #expect(!presentation.message.contains("pane is no longer reported"))
        store.setHosts([])
    }

    /// The rule being right is not enough: the detail column has to read the
    /// live collections, and until now nothing checked that it did.
    ///
    /// #146 was exactly that mistake — the rule was correct and the screen
    /// still blamed the Agent, because of *what it was handed*. Passing an
    /// empty `hostStatuses` reproduces it in full with the whole suite green
    /// (measured: 853 tests, exit 0), and no test could catch it because the
    /// detail column cannot be rendered: a hosted `NavigationSplitView` builds
    /// its columns and navigation bar and never the content inside them
    /// (measured under #152).
    ///
    /// So this calls the store-taking initializer the view calls, with both
    /// stores live. It is the reading that is under test here; the rule itself
    /// is covered by the tests around it.
    @Test func theDetailColumnReadsTheLiveHostStatuses() async throws {
        let host = Host.fixture()
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        let transport = ScriptedTransport(snapshot: .fixture())
        await transport.failPing(
            atCall: 1, with: .streamLocalOpenFailed(path: socketPath))
        let console = makeStore(transport: transport)
        let hosts = HostStore(volatileHosts: [host])

        console.setHosts([host])
        await console.resume()
        try await waitUntil("the Host should stop on a failure no retry clears") {
            console.hostStatuses[host.id]
                == .failed(.streamLocalOpenFailed(path: socketPath))
        }
        #expect(console.agents.isEmpty)

        // Exactly what `ConsoleView.detail` builds, by the same call.
        let presentation = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
            console: console,
            hosts: hosts)

        // Reading an empty status map instead of the live one lands on
        // `.paneGone` — the defect, and what this pins against.
        #expect(presentation.cause == .hostFailed)
        #expect(presentation.message == "\(host.displayName): \(Self.socketGuidance)")
        // The Host name proves the other collection is live too: it is read
        // from the `HostStore`, not from the status map.
        #expect(presentation.message.hasPrefix(host.displayName))
        console.setHosts([])
    }

    /// A value-only fixture cannot reach the old precedence bug: unknown
    /// inventory plus `.suspended` used to say "Connecting…". Driving the
    /// live stores after a real suspend is what pins the honest arm.
    @Test func aStoreBackedSuspendedHostWithUnknownInventorySaysPaused() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = makeStore(transport: transport)
        let hosts = HostStore(volatileHosts: [host])

        console.setHosts([host])
        await console.resume()
        try await waitUntil("the Host should come up connected") {
            console.hostStatuses[host.id] == .connected
        }
        try await waitUntil("its Agents should land") {
            !console.agents.isEmpty && !console.hostsAwaitingSnapshot.contains(host.id)
        }

        await console.suspend()
        try await waitUntil("the Host should suspend") {
            console.hostStatuses[host.id] == .suspended
        }
        #expect(console.hostsAwaitingSnapshot.contains(host.id))
        #expect(console.agents.isEmpty)

        let presentation = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
            console: console,
            hosts: hosts)
        #expect(presentation.cause == .hostSuspended)
        #expect(presentation.title == "Connection Paused")
        #expect(presentation.renderingMode == .staticUnavailable)
        console.setHosts([])
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
        #expect(presentation.systemImage == "rectangle.on.rectangle.slash")
        #expect(presentation.message == Self.paneGoneMessage)
        // A healthy Host must not be described as a Host problem.
        #expect(!presentation.message.contains("herdr"))
    }

    /// A resumed Host publishes `.connected` before its replacement snapshot
    /// lands. During that bounded window the selected pane is unknown, not
    /// gone, so the detail must retain a loading presentation instead of
    /// flashing the terminal failure placeholder (#141).
    @Test func aConnectedHostAwaitingItsSnapshotShowsLoading() {
        let host = Host.fixture()
        let presentation = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
            hostStatuses: [host.id: .connected],
            hosts: [host],
            hostsAwaitingSnapshot: [host.id])

        #expect(presentation.cause == .hostLoadingAgents)
        #expect(presentation.title == "Loading Agents…")
        #expect(presentation.renderingMode == .progress)
        #expect(presentation.message == "\(host.displayName): Fetching the latest Agents.")
        #expect(!presentation.message.contains("no longer reported"))
    }

    /// The selection's own Host decides. Reading any-failed-Host, or the first
    /// entry in the map, would put one Host's outage on another Host's screen.
    ///
    /// The reconnecting arm is read with *two* Hosts reconnecting at once,
    /// not one. `hostStatuses` carries one entry per Host, so a connectivity
    /// loss on the phone takes every Host's session into `.reconnecting`
    /// simultaneously — and a rule keyed on how many entries are
    /// reconnecting, rather than on the selection's own, would render "Agent
    /// Gone" for exactly that user. Every other reconnecting fixture in this
    /// file holds a single-entry map, so the multiplicity is pinned here or
    /// nowhere.
    @Test func onlyTheSelectedAgentsOwnHostDecidesWhatTheScreenSays() {
        let healthy = Host.fixture(name: "healthy", address: "healthy.example")
        let broken = Host.fixture(name: "broken", address: "broken.example")
        let dropped = Host.fixture(name: "dropped", address: "dropped.example")
        let recovering = Host.fixture(name: "recovering", address: "recovering.example")
        let statuses: [Host.ID: EventsSessionStatus] = [
            healthy.id: .connected,
            broken.id: .failed(.streamLocalOpenFailed(path: "/s")),
            dropped.id: .reconnecting(
                attempt: 5, delay: .seconds(16), failure: .timedOut),
            recovering.id: .reconnecting(
                attempt: 2, delay: .seconds(2),
                failure: .channelFailed(detail: "events stream ended unexpectedly")),
        ]
        let all = [healthy, broken, dropped, recovering]

        let onHealthy = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: healthy.id, paneID: "w1:p1"),
            hostStatuses: statuses, hosts: all)
        #expect(onHealthy.cause == .paneGone)
        #expect(onHealthy.message == Self.paneGoneMessage)

        let onBroken = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: broken.id, paneID: "w1:p1"),
            hostStatuses: statuses, hosts: all)
        #expect(onBroken.cause == .hostFailed)
        #expect(onBroken.message == "\(broken.displayName): \(Self.socketGuidance)")

        // The reconnecting arm gets the same treatment: with a second Host
        // reconnecting beside it, the selection's own reconnecting Host
        // still says Reconnecting — never Agent Gone.
        let onDropped = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: dropped.id, paneID: "wV:p1H"),
            hostStatuses: statuses, hosts: all)
        #expect(onDropped.cause == .hostReconnecting)
        #expect(onDropped.title == "Reconnecting…")
        #expect(onDropped.message == "\(dropped.displayName): \(Self.reconnectingSummary)")
        #expect(!onDropped.message.contains("no longer reported"))
    }

    /// A reconnecting Host says so, rather than reporting the Agent as gone
    /// at the exact moment the app is recovering (#154).
    ///
    /// This half was split out of
    /// `aReconnectingOrPausedHostDoesNotBorrowTheFailedGuidance`, which used
    /// to assert `.reconnecting` got the placeholder. The property that test
    /// existed to pin — that this screen never borrows the `.failed`
    /// guidance, which names an action the user must take — moves here with
    /// it and is asserted against the underlying failure's own guidance
    /// string, so the split cannot quietly become a deletion.
    ///
    /// All three associated values vary, and two of the three vary over
    /// their *whole* reachable set rather than over a sample.
    ///
    /// `failure` is every retryable kind (`Transport.swift:575-576`, plus
    /// `.jumpHostFailed` delegating to its underlying error at `:587-588`),
    /// because `.reconnecting` is emitted solely past `guard
    /// failure.isRetryable` and so those six are exactly what can reach this
    /// arm. `.channelFailed` is the one that matters most: it is the default
    /// when the events stream ends (`EventsSession.swift:465-466`) and what
    /// any unrecognised error is mapped to (`:655-665`), so a rule that
    /// singled it out would restore #154 for the ordinary reconnect while
    /// connect-path fixtures like `.timedOut` stayed green.
    ///
    /// `delay` is every value `ReconnectPolicy.default` produces — one
    /// second doubling to a thirty-second cap (`EventsSession.swift:11-12`,
    /// `:16-25`), so `{1, 2, 4, 8, 16, 30}` and nothing else, the demo
    /// policy's flat thirty seconds included
    /// (`DemoScreenshotMode.swift:255-256`) — because
    /// `emitReconnectingAndBackOff` puts that exact value into the status
    /// (`:548-554`).
    ///
    /// `attempt` cannot be closed the same way: the policy is documented as
    /// unlimited attempts (`EventsSession.swift:3-5`), so no fixture makes a
    /// rule reading `attempt > N` fail. The delays above are the observable
    /// consequence of the attempt count and are finite, so they are what is
    /// pinned instead.
    @Test func aReconnectingHostSaysSoAndStillBorrowsNoGuidance() {
        let host = Host.fixture()
        // (failure, attempt, delay, pane): every retryable failure kind,
        // paired with the attempt and the delay the default policy pairs it
        // with — 1 s on the first attempt, doubling, then the 30 s cap once
        // the doubling has run out.
        //
        // The pane address moves with them. It is the one input here that is
        // an open-ended string rather than a closed set, so no fixture makes
        // every rule that reads it fail — but the rest of this file's
        // fixtures nearly all use `w1:p1`, and that is only one of the
        // shapes herdr hands out. A live 0.8.0 server answers `agent.list`
        // with ids like `w1:pT`, `w1C:p1`, `wR:pC` and `wV:p1H` —
        // alphanumeric segments, uppercase letters included — so those
        // shapes appear here beside it.
        let inFlight: [(failure: TransportError, attempt: Int, delay: Duration, pane: String)] = [
            (.timedOut, 1, .seconds(1), "w1:p1"),
            (
                .channelFailed(detail: "events stream ended unexpectedly"), 2,
                .seconds(2), "w1:pT"
            ),
            (
                .apiRejected(code: "pane_not_found", message: "no such pane"), 3,
                .seconds(4), "w1C:p1"
            ),
            (
                .sshUnreachable(detail: "the Host is unreachable"), 4,
                .seconds(8), "wR:pC"
            ),
            (.cancelled, 5, .seconds(16), "wV:p1K"),
            (.jumpHostFailed(.timedOut), 7, .seconds(30), "wV:p1H"),
        ]
        for (failure, attempt, delay, pane) in inFlight {
            let presentation = MissingAgentPresentation(
                agentID: ConsoleAgent.ID(hostID: host.id, paneID: pane),
                hostStatuses: [
                    host.id: .reconnecting(
                        attempt: attempt, delay: delay, failure: failure)
                ],
                hosts: [host])

            #expect(presentation.cause == .hostReconnecting)
            #expect(presentation.title == "Reconnecting…")
            #expect(presentation.renderingMode == .progress)
            // Pinned by value, not merely as "some distinct icon": the
            // Console list's `wifi.exclamationmark` is the obvious thing to
            // reach for and the source rejects it on purpose: a progress
            // screen should not open by shouting.
            #expect(presentation.systemImage == "arrow.trianglehead.2.clockwise")
            // A message that renders empty would leave the screen blank at
            // the moment it most needs to explain itself.
            #expect(!presentation.message.isEmpty)
            #expect(
                presentation.message
                    == "\(host.displayName): \(failure.presentation.summary)")
            // The teeth carried over from the test this was split out of: the
            // guidance names a user action, and here the app is the one
            // acting, so none of it may appear. Its being non-empty is
            // asserted rather than assumed, because a failure kind whose
            // guidance rendered empty would leave the line below asserting
            // nothing at all about this arm.
            #expect(!failure.presentation.message.isEmpty)
            #expect(!presentation.message.contains(failure.presentation.message))
            // Nor may it fall back to blaming the Agent.
            #expect(!presentation.message.contains("no longer reported"))
        }
    }

    /// The same Host reconnecting with no Host record for the selection. The
    /// message is the reconnecting text alone, unprefixed — the `.failed`
    /// twin of this is `theApprovedSocketWordingIsWhatReachesTheScreen`, and
    /// without it an arm that fell back to the placeholder whenever the Host
    /// lookup missed would render "Agent Gone" on a recovering Host.
    ///
    /// Both shapes of "no record", because the two are not the same input
    /// and every other fixture in this file holds `hosts` either empty or
    /// containing the selection. A `hosts` that is non-empty and has *moved
    /// on* is the reachable one: the screen reads `hosts.hosts` off the
    /// `HostStore` while the statuses come from the `ConsoleStore`
    /// (`ConsoleView.swift:530-536`), and the two are joined by an
    /// `onChange` that runs after the body it follows
    /// (`ContentView.swift:78-81`), so deleting one of several Hosts while
    /// another reconnects renders at least once with the new list against
    /// the old statuses. A rule reading the list rather than the lookup puts
    /// "Agent Gone" on screen for that frame.
    @Test func aReconnectingHostWithNoRecordStillSaysReconnecting() {
        let host = Host.fixture()
        let survivor = Host.fixture(name: "survivor", address: "survivor.example")
        for hosts in [[], [survivor]] {
            let presentation = MissingAgentPresentation(
                agentID: ConsoleAgent.ID(hostID: host.id, paneID: "wR:pC"),
                hostStatuses: [
                    host.id: .reconnecting(
                        attempt: 3, delay: .seconds(4), failure: .timedOut)
                ],
                hosts: hosts)

            #expect(presentation.cause == .hostReconnecting)
            #expect(presentation.title == "Reconnecting…")
            #expect(presentation.renderingMode == .progress)
            #expect(presentation.systemImage == "arrow.trianglehead.2.clockwise")
            #expect(!presentation.message.isEmpty)
            #expect(presentation.message == TransportError.timedOut.presentation.summary)
            // Unprefixed, because there is no name to prefix it with — not
            // prefixed with something invented in its place, and not with
            // whichever Host the list does still hold.
            #expect(!presentation.message.contains(host.displayName))
            #expect(!presentation.message.contains(survivor.displayName))
            #expect(!presentation.message.contains("no longer reported"))
        }
    }

    /// A healthy, ended, or deleted Host still gets the placeholder. `nil`
    /// stays Agent Gone because it also covers a deleted Host whose
    /// projection is gone from both maps.
    @Test func aHealthyOrDeletedHostStillSaysTheAgentIsGone() {
        let host = Host.fixture()
        let atRest: [EventsSessionStatus?] = [.connected, .ended, nil]
        for status in atRest {
            let presentation = MissingAgentPresentation(
                agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
                hostStatuses: status.map { [host.id: $0] } ?? [:],
                hosts: [host])
            #expect(presentation.cause == .paneGone)
            #expect(presentation.title == "Agent Gone")
            #expect(presentation.renderingMode == .staticUnavailable)
            #expect(presentation.message == Self.paneGoneMessage)
        }
    }

    @Test func aSuspendedHostSaysTheConnectionIsPaused() {
        let host = Host.fixture()
        let presentation = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
            hostStatuses: [host.id: .suspended],
            hosts: [host],
            hostsAwaitingSnapshot: [host.id])
        #expect(presentation.cause == .hostSuspended)
        #expect(presentation.title == "Connection Paused")
        #expect(presentation.renderingMode == .staticUnavailable)
        #expect(
            presentation.message
                == "\(host.displayName): The connection is paused until Heeler becomes active.")
        #expect(!presentation.message.contains("no longer reported"))
        #expect(!presentation.message.contains("Connecting"))
    }

    @Test func connectingWithoutAStandingFailureShowsProgress() {
        let host = Host.fixture()
        let presentation = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
            hostStatuses: [host.id: .connecting],
            hosts: [host])
        #expect(presentation.cause == .hostConnecting)
        #expect(presentation.title == "Connecting…")
        #expect(presentation.renderingMode == .progress)
        #expect(presentation.message == "\(host.displayName): Opening the connection.")
    }

    @Test func connectingWithAStandingFailureKeepsTheFailedPresentation() {
        let host = Host.fixture()
        let failure = TransportError.streamLocalOpenFailed(path: "/s")
        let presentation = MissingAgentPresentation(
            agentID: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1"),
            hostStatuses: [host.id: .connecting],
            hosts: [host],
            hostStandingFailures: [host.id: failure])
        #expect(presentation.cause == .hostFailed)
        #expect(presentation.title == "Host Unavailable")
        #expect(presentation.renderingMode == .staticUnavailable)
        #expect(presentation.message == "\(host.displayName): \(failure.presentation.message)")
    }

    /// The approved socket wording is what reaches the screen, unabbreviated
    /// and never replaced by socket-implementation language.
    @Test func theApprovedSocketWordingIsWhatReachesTheScreen() {
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        // Pinned here as well as at its source: this screen is now one of the
        // two places it renders, and the two must not drift apart.
        #expect(
            TransportError.streamLocalOpenFailed(path: socketPath).presentation.message
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
            #expect(presentation.message == failure.presentation.message)
            #expect(
                !presentation.message.lowercased()
                    .contains("remote socket is not listening"))
        }
    }

    /// The six causes stay distinct on every field the screen renders,
    /// including rendering mode — that is what keeps a progress surface from
    /// being a failure surface.
    @Test func theSixCausesNeverCollapseIntoOneAnswer() {
        let host = Host.fixture()
        let agentID = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        func presentation(
            _ status: EventsSessionStatus,
            standing: TransportError? = nil,
            awaiting: Bool = false
        ) -> MissingAgentPresentation {
            MissingAgentPresentation(
                agentID: agentID,
                hostStatuses: [host.id: status],
                hosts: [host],
                hostsAwaitingSnapshot: awaiting ? [host.id] : [],
                hostStandingFailures: standing.map { [host.id: $0] } ?? [:])
        }
        let all = [
            presentation(.suspended),
            presentation(.connecting),
            presentation(.reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut)),
            presentation(.failed(.streamLocalOpenFailed(path: "/s"))),
            presentation(.connected, awaiting: true),
            presentation(.connected),
        ]

        #expect(Set(all.map(\.cause)).count == 6)
        #expect(Set(all.map(\.title)).count == 6)
        #expect(Set(all.map(\.message)).count == 6)
        #expect(Set(all.map(\.systemImage)).count == 6)
        #expect(
            all.map(\.renderingMode) == [
                .staticUnavailable, .progress, .progress, .staticUnavailable, .progress,
                .staticUnavailable,
            ])
        #expect(presentation(.connecting, standing: .streamLocalOpenFailed(path: "/s")).cause
            == .hostFailed)
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

        let jumpMismatch = MissingAgentPresentation(
            agentID: agentID,
            hostStatuses: [
                host.id: .failed(
                    .jumpHostFailed(
                        .hostKeyMismatch(
                            known: HostKeyFingerprint(publicKeyBlob: Data("known".utf8)),
                            presented: HostKeyFingerprint(
                                publicKeyBlob: Data("presented".utf8)))))
            ],
            hosts: [host])
        #expect(jumpMismatch.systemImage == "exclamationmark.shield.fill")

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
