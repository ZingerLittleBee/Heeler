import Foundation
import Testing

@testable import Heeler

@Suite("Host detail routes")
struct HostRoutesPresentationTests {
    private let home = HostRoute(address: "192.168.1.20")
    private let away = HostRoute(address: "box.example.com", port: 2222)

    private func server(
        _ status: EventsSessionStatus?, reached route: HostRoute? = nil
    ) -> HostRoutesPresentation.Server {
        HostRoutesPresentation.Server(routes: [home, away], status: status, routeID: route?.id)
    }

    private func presentation(
        _ servers: [HostRoutesPresentation.Server], isManualReconnectInFlight: Bool = false
    ) -> HostRoutesPresentation {
        HostRoutesPresentation(
            hostName: "Studio", routeCount: 2, servers: servers,
            isManualReconnectInFlight: isManualReconnectInFlight)
    }

    private var noRouteReached: TransportError {
        .noRouteReached([
            RouteFailure(
                route: "192.168.1.20", mayNameAnotherMachine: true, error: .timedOut, routeID: home.id),
            RouteFailure(
                route: "box.example.com:2222", mayNameAnotherMachine: false,
                error: .sshUnreachable(detail: "refused"), routeID: away.id),
        ])
    }

    @Test func aConnectedHostMarksTheOneRouteItsServersHold() {
        let connected = presentation([server(.connected, reached: away), server(.connected, reached: away)])

        #expect(connected.inUse == 1)
        #expect(connected.failures.isEmpty)
        #expect(!connected.isDialing)
        #expect(connected.offersReconnect)
        guard case .note = connected.footer else {
            Issue.record("a connected Host's footer is a note")
            return
        }
    }

    /// Each record gives the same route an id of its own.
    @Test func theRouteInUseIsFoundByTheServersOwnRecord() {
        let sibling = HostRoutesPresentation.Server(
            routes: [HostRoute(address: "192.168.1.20"), HostRoute(address: "box.example.com", port: 2222)],
            status: .connected, routeID: nil)
        let own = HostRoute(address: "box.example.com", port: 2222)
        let reached = HostRoutesPresentation.Server(
            routes: [HostRoute(address: "192.168.1.20"), own], status: .connected, routeID: own.id)

        #expect(presentation([reached, sibling]).inUse == 1)
        // A route id from before the Host was edited names nothing now.
        #expect(presentation([server(.connected, reached: HostRoute(address: "gone"))]).inUse == nil)
    }

    @Test func noRouteReachedTagsEachRouteAndSaysSoInRed() {
        let failed = presentation([server(.failed(noRouteReached)), server(.failed(noRouteReached))])

        #expect(failed.inUse == nil)
        #expect(
            failed.failures == [
                0: TransportError.timedOut.presentation.summary,
                1: TransportError.sshUnreachable(detail: "refused").presentation.summary,
            ])
        #expect(!failed.isDialing)
        #expect(
            failed.footer
                == .problem(
                    "Heeler tried all 2 routes and none reached Studio. Check that it is awake and on a network this device can reach."
                ))
    }

    /// While it retries, the tags stay and the footer does not turn red.
    @Test func aHostRetryingKeepsTheTagsOfItsLastDial() {
        let retrying = presentation([
            server(.reconnecting(attempt: 2, delay: .seconds(2), failure: noRouteReached))
        ])

        #expect(retrying.isDialing)
        #expect(retrying.failures.count == 2)
        guard case .note = retrying.footer else {
            Issue.record("a retrying Host's footer is a note")
            return
        }
    }

    /// A Server that is missing or stopped is not the connection's failure,
    /// whether it stopped or retries in the background.
    @Test func aServersOwnFailureLeavesTheRoutesAlone() {
        let stopped = TransportError.socketNotFound(path: "/tmp/herdr.sock")
        let rexNotRunning = EventsSessionStatus.reconnecting(
            attempt: 4, delay: .seconds(8), failure: .rexServerNotRunning(socketPath: nil))
        let retryingStopped = HostRoutesPresentation.Server(
            routes: [home, away], status: .connecting, routeID: nil, standingFailure: stopped)

        let beside = presentation([
            server(.failed(stopped)),
            server(rexNotRunning),
            retryingStopped,
            server(.connected, reached: home),
        ])
        #expect(beside.inUse == 0)
        #expect(!beside.isDialing)
        #expect(beside.failures.isEmpty)

        for single in [server(.failed(stopped)), server(rexNotRunning), retryingStopped] {
            let alone = presentation([single])
            #expect(alone.inUse == nil)
            #expect(!alone.isDialing)
            #expect(alone.failures.isEmpty)
            guard case .note(let text) = alone.footer else {
                Issue.record("a Server's own failure leaves the footer a note")
                return
            }
            #expect(!text.hasPrefix("Not connected."))
        }
    }

    /// One Server still dialing beside a connected one: the Host is
    /// connected, and its action is Stop.
    @Test func aServerDialingBesideAConnectedOneOffersStop() {
        let mixed = presentation([
            server(.connected, reached: home),
            server(.reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut)),
        ])

        #expect(mixed.inUse == 0)
        #expect(mixed.isDialing)
    }

    @Test func aFailureOfTheWholeConnectionReadsInTheFooter() {
        let failed = presentation([server(.failed(.authenticationFailed))])

        #expect(failed.failures.isEmpty)
        #expect(failed.footer == .problem(TransportError.authenticationFailed.presentation.message))
    }

    @Test func aHostWithOneRouteTagsItWithTheFailure() {
        let failed = HostRoutesPresentation(
            hostName: "Studio", routeCount: 1,
            servers: [HostRoutesPresentation.Server(routes: [home], status: .failed(.timedOut), routeID: nil)])

        #expect(failed.failures == [0: TransportError.timedOut.presentation.summary])
        #expect(failed.footer == .problem(TransportError.timedOut.presentation.message))

        let connected = HostRoutesPresentation(
            hostName: "Studio", routeCount: 1,
            servers: [HostRoutesPresentation.Server(routes: [home], status: .connected, routeID: home.id)])
        #expect(connected.inUse == 0)
        #expect(connected.footer == .none)
    }

    /// A Reconnect press reads as dialing at once, before the status moves.
    @Test func aManualReconnectReadsAsDialing() {
        for status: EventsSessionStatus in [.connected, .failed(noRouteReached)] {
            let pressed = presentation([server(status, reached: home)], isManualReconnectInFlight: true)
            #expect(pressed.isDialing)
            #expect(pressed.inUse == nil)
            #expect(pressed.failures.isEmpty)
        }
    }

    @Test func stoppedServersSayNotConnected() {
        for status: EventsSessionStatus? in [nil, .suspended, .ended] {
            let idle = presentation([server(status, reached: home)])
            #expect(idle.inUse == nil)
            #expect(!idle.isDialing)
            guard case .note(let text) = idle.footer else {
                Issue.record("a stopped Host's footer is a note")
                continue
            }
            #expect(text.hasPrefix("Not connected."))
        }
    }

    @Test func aHostWithNoServerOnHasNothingToReconnect() {
        let empty = presentation([])

        #expect(!empty.offersReconnect)
        #expect(!empty.isDialing)
        guard case .note(let text) = empty.footer else {
            Issue.record("a Host with no Server on keeps the note")
            return
        }
        #expect(!text.hasPrefix("Not connected."))
    }

    /// The Console never asks about a key, so Host detail looks, which asks.
    @Test func aDialStoppedAtAnUnconfirmedKeyAsksForALook() {
        let key = HostKeyFingerprint(publicKeyBlob: Data([1, 2, 3]))
        let unconfirmedJumpHost = TransportError.noRouteReached([
            RouteFailure(
                route: "192.168.1.20", mayNameAnotherMachine: true,
                error: .sshUnreachable(detail: "refused"), routeID: home.id),
            RouteFailure(
                route: "box.example.com:2222", mayNameAnotherMachine: false,
                error: .jumpHostFailed(.hostKeyRejected(presented: key)), routeID: away.id),
        ])
        let one = UUID()

        let retrying = EventsSessionStatus.reconnecting(attempt: 3, delay: .seconds(4), failure: unconfirmedJumpHost)
        #expect(HostLookFollowUp(servers: [(id: one, status: retrying)]).asksForKey)
        #expect(HostLookFollowUp(servers: [(id: one, status: .failed(.hostKeyRejected(presented: key)))]).asksForKey)
        #expect(!HostLookFollowUp(servers: [(id: one, status: .failed(noRouteReached))]).asksForKey)
        #expect(!HostLookFollowUp(servers: [(id: one, status: .connected)]).asksForKey)
    }

    /// A look that reached the Host leaves nothing to wait out a backoff for.
    @Test func aLookThatReachedTheHostRedialsTheServersWaitingOnTheConnection() {
        let stopped = UUID()
        let retrying = UUID()
        let followUp = HostLookFollowUp(servers: [
            (id: stopped, status: .failed(noRouteReached)),
            (id: retrying, status: .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut)),
            (id: UUID(), status: .connected),
            (id: UUID(), status: .connecting),
            // The user stopped it.
            (id: UUID(), status: .suspended),
            // Its own Server is missing, which the connection cannot mend.
            (id: UUID(), status: .failed(.socketNotFound(path: "/tmp/herdr.sock"))),
            (id: UUID(), status: nil),
        ])

        #expect(followUp.redials == [stopped, retrying])
    }

    @Test func aServersRowSaysItsOwnStateAndNeverTheConnections() {
        let found = FoundServer(key: HostServerKey(kind: .tmux, name: "default"), isRunning: true, version: "3.5a")
        let stopped = TransportError.tmuxServerNotRunning(socketName: "default")

        let connected = HostServerStateLine(found: found, status: .connected)
        #expect(connected.text == "Running · 3.5a")
        #expect(!connected.isProblem)
        #expect(HostServerStateLine(found: nil, status: .connected).text == "Running")
        #expect(HostServerStateLine(found: found, status: .connected, syncIssue: "boom").text == "Sync issue")

        let failed = HostServerStateLine(found: found, status: .failed(stopped))
        #expect(failed.text == stopped.presentation.summary)
        #expect(failed.isProblem)

        // The route failed, not the Server: its row stays as it was seen.
        let unreachable = HostServerStateLine(found: found, status: .failed(noRouteReached))
        #expect(unreachable.text == "Running · 3.5a")
        #expect(!unreachable.isProblem)
        #expect(HostServerStateLine(found: nil, status: .failed(noRouteReached)).text == nil)

        let dialing = HostServerStateLine(found: found, status: .connecting, standingFailure: stopped)
        #expect(dialing.text == stopped.presentation.summary)
        #expect(!dialing.isProblem)
    }
}
