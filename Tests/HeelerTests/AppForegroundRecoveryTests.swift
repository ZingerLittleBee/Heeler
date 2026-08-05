import Foundation
import Testing

@testable import Heeler

/// Foreground recovery (#141): what the app does to its Host connections when
/// it returns from the background, driven through the same activity events
/// `ContentView` subscribes to.
///
/// The failure these pin is silent by construction. A link that dies while the
/// app is away produces no error, because nothing is attempting anything: the
/// reconnect loop is parked on an events stream that a frozen socket never
/// ends. So the session comes back reporting `.connected`, the Console keeps
/// listing its Agents, and the Attach terminal keeps rendering `.live` with no
/// overlay — a blank screen that never transitions and never retries.
///
/// The trigger is a return *without an intervening suspension*: the grace
/// period absorbed the trip, or the process was frozen before its grace timer
/// could fire. Either way the app is back holding a connection nothing tore
/// down, and `resume()` alone has nothing to re-activate.
@MainActor
@Suite("App foreground recovery")
struct AppForegroundRecoveryTests {
    /// Reconnect fast so these never wait on real backoff.
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    @Test func foregroundingSurfacesALinkThatDiedWhileTheAppWasAway() async throws {
        let host = Host.fixture()
        // The connection the app was holding when it went away, and what it
        // gets on the repair attempt. Keepalive is off on purpose: recovery
        // must come from the foreground transition itself, not from a timer
        // that happened to be due.
        let stale = ScriptedTransport(snapshot: .openSession)
        let store = makeStore(attempts: ConnectionAttemptQueue([
            .success(stale),
            .failure(.sshUnreachable(detail: "the Host is unreachable")),
        ]))
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: GrantingBackgroundExecutionGranter())
        let driver = Task {
            await ConsoleActivityDriver(activity: activity, console: store).run()
        }
        defer { driver.cancel() }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should come up connected") {
            store.hostStatuses[host.id] == .connected
        }
        try await waitUntil("its Agent should arrive") { store.agents.count == 1 }

        // The app is out of the picture and the link dies. Nothing errors:
        // as far as this process knows the events stream is still open, and
        // the next thing anyone asks the connection is the ping below.
        await stale.failPing(atCall: 2, with: .timedOut)

        // Away and back inside the grace period, so no suspension is ever
        // emitted — the app returns still believing it is connected.
        activity.didEnterBackground()
        activity.didBecomeActive()
        #expect(activity.phase == .active)

        try await waitUntil("the dead link must become visible, not stay blank") {
            switch store.hostStatuses[host.id] {
            case .reconnecting, .failed: true
            default: false
            }
        }
        store.setHosts([])
    }

    @Test func foregroundingReplacesTheTransportSoTheTerminalRebuilds() async throws {
        let host = Host.fixture()
        let stale = ScriptedTransport(snapshot: .fixture())
        let repaired = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(attempts: ConnectionAttemptQueue([
            .success(stale), .success(repaired),
        ]))
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: GrantingBackgroundExecutionGranter())
        let driver = Task {
            await ConsoleActivityDriver(activity: activity, console: store).run()
        }
        defer { driver.cancel() }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should come up connected") {
            store.hostStatuses[host.id] == .connected
        }
        let generation = try #require(store.hostConnectionGenerations[host.id])

        await stale.failPing(atCall: 2, with: .timedOut)
        activity.didEnterBackground()
        activity.didBecomeActive()

        // The generation is what rebuilds the Attach terminal's pipeline; a
        // repair the terminal never hears about leaves it blank on a channel
        // that will never speak again.
        try await waitUntil("the repaired connection should advance the generation") {
            (store.hostConnectionGenerations[host.id] ?? generation) > generation
        }
        try await waitUntil("and the Host should end up connected again") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(await repaired.isConnected)
        store.setHosts([])
    }

    /// The other half of the contract: proving the connection must not
    /// disturb one that is fine. A quick trip out of the app leaves the
    /// events session and its Attach terminal exactly where they were.
    @Test func aBounceOutOfTheAppLeavesAHealthyConnectionAlone() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(attempts: ConnectionAttemptQueue([.success(transport)]))
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: GrantingBackgroundExecutionGranter())
        let driver = Task {
            await ConsoleActivityDriver(activity: activity, console: store).run()
        }
        defer { driver.cancel() }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should come up connected") {
            store.hostStatuses[host.id] == .connected
        }
        let generation = try #require(store.hostConnectionGenerations[host.id])

        activity.didEnterBackground()
        activity.didBecomeActive()
        try await waitUntil("the activation should re-prove the connection") {
            await transport.pingCount >= 2
        }

        #expect(store.hostStatuses[host.id] == .connected)
        #expect(store.hostConnectionGenerations[host.id] == generation)
        #expect(!(await transport.isClosed))
        store.setHosts([])
    }

    /// A store whose session factory hands out scripted transports in order.
    private func makeStore(attempts: ConnectionAttemptQueue) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { try await attempts.next() },
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

private extension SessionSnapshot {
    /// One Agent on one workspace: the Console has a row, and the user has a
    /// session open on it.
    static let openSession = SessionSnapshot.fixture(
        agents: [.fixture(paneID: "w1:p1")],
        workspaces: [.fixture(workspaceID: "w1", label: "work")])
}

/// Scripts the connections the session factory hands out, in order.
private actor ConnectionAttemptQueue {
    private var remaining: [Result<ScriptedTransport, TransportError>]

    init(_ attempts: [Result<ScriptedTransport, TransportError>]) {
        remaining = attempts
    }

    func next() throws -> ScriptedTransport {
        guard !remaining.isEmpty else {
            throw TransportError.sshUnreachable(detail: "connection queue exhausted")
        }
        return try remaining.removeFirst().get()
    }
}

/// Grants background time and never reclaims it, so the grace period runs to
/// the length the test asked for instead of the system's whim.
@MainActor
private final class GrantingBackgroundExecutionGranter: BackgroundExecutionGranting {
    private var nextRawValue = 1

    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        defer { nextRawValue += 1 }
        return BackgroundExecutionToken(rawValue: nextRawValue)
    }

    func end(_ token: BackgroundExecutionToken) {}
}
