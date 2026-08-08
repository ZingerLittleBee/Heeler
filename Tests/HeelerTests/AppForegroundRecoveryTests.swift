import Foundation
import Testing

@testable import Heeler

/// Foreground recovery (#142): what the app does to its Host connections when
/// it returns from the background, driven through the same activity events
/// `ContentView` subscribes to.
///
/// A link that dies while the app is away produces no error at the moment it
/// dies, because nothing is attempting anything: the reconnect loop is parked
/// on an events stream that a frozen socket never ends. So the session comes
/// back reporting `.connected`, the Console keeps listing its Agents, and the
/// Attach terminal keeps rendering `.live` with no overlay.
///
/// What re-proving on return buys is **latency, not recovery that would
/// otherwise never happen**. The keepalive is still armed across the freeze —
/// this trip never suspends the session, so `stopKeepalive()` never runs — and
/// `ContinuousClock` advances while a process is frozen, so its expired sleep
/// returns promptly on thaw and the same `keepaliveDidFail` path notices the
/// dead link within its interval plus the request timeout. Foregrounding makes
/// that immediate, at the moment a user is looking at whatever the answer
/// means.
///
/// That mechanism rests on **code inspection, not measurement**. A simulator
/// never suspends the process, so nothing here — or anywhere in the suite —
/// demonstrates that the keepalive really survives a real iOS suspension and
/// fires on thaw. The "up to 45 s without this fix" figure is therefore read
/// off the tree (30 s interval plus the request timeout), not observed on a
/// device; anyone relying on the number should measure it before trusting it.
///
/// These tests therefore run in the **production keepalive shape**
/// (`.default`, 30 s), not with the keepalive disabled: every case here
/// settles in well under a second, so a 30 s timer provably cannot be what
/// recovered it, and removing `revalidate()` turns them red rather than
/// slower. That is what distinguishes the two mechanisms without putting a
/// test on the clock.
///
/// The trigger is a return *without an intervening suspension*: the grace
/// period absorbed the trip, or the process was frozen before its grace timer
/// could fire. Either way the app is back holding a connection nothing tore
/// down, and `resume()` alone has nothing to re-activate.
///
/// The adjacent state is a Host already stopped on a non-retryable failure
/// (#147). There `resume()` no-ops for the same reason — the reconnect loop
/// returned with the phase still `.active` — and the ping has nothing left to
/// ping, so on such a return nothing asks that Host again and the user's
/// natural recovery (restart herdr, come back) does nothing. The window is the
/// same one this whole file is about, and no wider: an absence past
/// `AppActivityCoordinator.defaultGracePeriod` suspends the session, and the
/// `resume()` that follows already restarted it. The return asks it once more.
/// That is a single attempt on an explicit user action, not a softening of the
/// classification: `herdrStoppedWhileAwayFailsTheHostWithItsSetupGuidance`
/// still pins that a stopped herdr fails rather than retries, and the cases
/// below pin that a still-broken Host lands straight back on `.failed` and
/// that a Host merely *reconnecting* is left alone entirely.
///
/// The remaining status a return can meet is `.suspended` — the ordinary case
/// once the grace period elapses, which the trips above deliberately stay
/// inside. There `resume()` is already dialling, and the re-prove must leave
/// that dial alone: widening the guard to `.failed, .suspended` restarts the
/// session over its own in-flight dial, and the return costs two dials
/// instead of one (#158). The statuses hide it — the Host still ends up
/// `.connected` — so the case below counts dials instead.
@MainActor
@Suite("App foreground recovery")
struct AppForegroundRecoveryTests {
    /// Reconnect fast so these never wait on real backoff.
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    /// Instant on the first attempt and effectively parked on the second, so a
    /// reconnecting Host can be inspected while it is provably mid-cycle
    /// instead of racing its own retries.
    private static nonisolated let parkedSecondAttemptPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 1000, maxDelay: .seconds(10))

    @Test func foregroundingSurfacesALinkThatDiedWhileTheAppWasAway() async throws {
        let host = Host.fixture()
        // The connection the app was holding when it went away, and what it
        // gets on the repair attempt.
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
        // The repaired transport is the one now carrying the events channel,
        // and the dead one was closed rather than left open behind it.
        #expect(!(await repaired.capturedSubscriptions.isEmpty))
        #expect(await stale.isClosed)
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

    /// The class a severed link actually produces post-#138 is
    /// `.sshUnreachable`, not the `.timedOut` the other cases script: #138
    /// classifies a stream-local open that failed on a dead connection by its
    /// errno, and connection loss lands there. Reporting only `.timedOut` out
    /// of `revalidate()` would leave the real production failure swallowed and
    /// every other test here green, so the class is pinned explicitly.
    @Test func foregroundingSurfacesALinkThatDiedUnreachableNotOnlyOneThatTimedOut()
        async throws
    {
        let host = Host.fixture()
        let stale = ScriptedTransport(snapshot: .openSession)
        let repaired = ScriptedTransport(snapshot: .openSession)
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

        await stale.failPing(
            atCall: 2, with: .sshUnreachable(detail: "the Host is unreachable"))
        activity.didEnterBackground()
        activity.didBecomeActive()

        try await waitUntil("an unreachable link must be repaired, not swallowed") {
            (store.hostConnectionGenerations[host.id] ?? generation) > generation
        }
        try await waitUntil("and the Host should end up connected again") {
            store.hostStatuses[host.id] == .connected
        }
        store.setHosts([])
    }

    /// herdr stopped while the app was away, SSH itself fine: the ping opens a
    /// stream-local channel, herdr refuses it, and the transport's probe
    /// reports the configuration-class `.streamLocalOpenFailed` (or
    /// `.socketNotFound`). Both are non-retryable, so re-proving on return
    /// takes the Host terminally to `.failed` carrying the setup guidance
    /// instead of reconnecting forever against a server that is not there.
    /// That is the intended outcome — nothing an automatic retry can fix — and
    /// it is decided here rather than left implicit, because unlike the
    /// severed-link lane #138 moved, this one is reached on every foreground
    /// return while herdr is down.
    @Test func herdrStoppedWhileAwayFailsTheHostWithItsSetupGuidance() async throws {
        let host = Host.fixture()
        let stale = ScriptedTransport(snapshot: .openSession)
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        let store = makeStore(attempts: ConnectionAttemptQueue([.success(stale)]))
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

        await stale.failPing(atCall: 2, with: .streamLocalOpenFailed(path: socketPath))
        activity.didEnterBackground()
        activity.didBecomeActive()

        try await waitUntil("a stopped herdr should fail the Host, not retry it") {
            store.hostStatuses[host.id] == .failed(.streamLocalOpenFailed(path: socketPath))
        }
        // And it stops there: no reconnect attempt follows a failure only the
        // user can clear.
        #expect(await stale.pingCount == 2)
        store.setHosts([])
    }

    /// Every Host is re-proved at once. The ping `revalidate()` sends is
    /// bounded only by the transport's request timeout, and a frozen Host is
    /// exactly the case that runs it out; awaiting them one Host at a time
    /// would hold the store's lifecycle chain — and with it any queued
    /// `suspend()`, and the background assertion its completion releases —
    /// for N times that bound.
    @Test func everyHostIsReProvedConcurrently() async throws {
        let first = Host.fixture(name: "first")
        let second = Host.fixture(name: "second")
        let firstTransport = ScriptedTransport(snapshot: .fixture())
        let secondTransport = ScriptedTransport(snapshot: .fixture())
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) {
            host, subscriptions in
            let transport = host.id == first.id ? firstTransport : secondTransport
            return EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: Self.fastPolicy,
                keepalive: .default)
        }

        store.setHosts([first, second])
        await store.resume()
        try await waitUntil("both Hosts should come up connected") {
            store.hostStatuses[first.id] == .connected
                && store.hostStatuses[second.id] == .connected
        }

        // Park both re-proving pings. A ping records its arrival before
        // waiting, so a serial revalidation could never reach the second Host
        // while the first is still parked.
        let firstPing = ScriptedTransportCallGate()
        let secondPing = ScriptedTransportCallGate()
        await firstTransport.gateNextPing(using: firstPing)
        await secondTransport.gateNextPing(using: secondPing)

        let completion = LifecycleCompletionProbe()
        let reactivation = Task {
            await store.reactivate()
            await completion.finish()
        }
        try await waitUntil("both Hosts should be in flight at once") {
            let firstReached = await firstTransport.pingCount == 2
            let secondReached = await secondTransport.pingCount == 2
            return firstReached && secondReached
        }

        // Concurrent, but still *structured*: with both pings parked the
        // activation has not returned, so a suspend() the user triggers by
        // leaving again — and the didFinishSuspending() that releases the
        // background assertion — queues behind the re-proving rather than
        // racing it. Fire-and-forget would satisfy the check above and fail
        // here.
        #expect(!(await completion.isFinished))

        await firstPing.open()
        await secondPing.open()
        await reactivation.value
        #expect(store.hostStatuses[first.id] == .connected)
        #expect(store.hostStatuses[second.id] == .connected)
        store.setHosts([])
    }

    /// The recovery #147 adds: a Host correctly stopped on a non-retryable
    /// failure is asked once more when the user comes back, so fixing the Host
    /// and returning is enough on its own.
    ///
    /// Without it nothing asks the Host again on this return. `run()` returned
    /// with the phase still `.active`, so `resume()` no-ops; `liveStream` is
    /// nil, so the ping no-ops. The trip out here is inside the grace period,
    /// which is the case that was stranded — a longer absence suspends the
    /// session and the return's `resume()` already restarts it. Inside the
    /// window only the Retry button was left, and a user who has just
    /// restarted herdr has no reason to expect they need it.
    @Test func aFailedHostIsAskedAgainOnTheNextForegroundReturn() async throws {
        let host = Host.fixture()
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        let stopped = ScriptedTransport(snapshot: .openSession)
        let restarted = ScriptedTransport(snapshot: .openSession)
        let store = makeStore(attempts: ConnectionAttemptQueue([
            .success(stopped), .success(restarted),
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

        // herdr stops while the app is away. The return's ping opens a
        // stream-local channel onto a socket nothing is serving, which is
        // configuration-class and correctly stops the reconnect loop.
        await stopped.failPing(atCall: 2, with: .streamLocalOpenFailed(path: socketPath))
        activity.didEnterBackground()
        activity.didBecomeActive()
        try await waitUntil("the stopped herdr should fail the Host") {
            store.hostStatuses[host.id] == .failed(.streamLocalOpenFailed(path: socketPath))
        }

        // The user does exactly what the guidance asks — restarts herdr — and
        // comes back to the app. No Retry tap, no Host edit, nothing else.
        activity.didEnterBackground()
        activity.didBecomeActive()

        try await waitUntil("coming back should ask the repaired Host again") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(await restarted.pingCount == 1)
        store.setHosts([])
    }

    /// The same return against a Host that is still broken: it must land back
    /// on `.failed` carrying the same guidance, having shown nothing in
    /// between that reads as recovery, and must make exactly one attempt per
    /// return rather than looping.
    @Test func aStillBrokenHostReturnsToFailedWithoutAFlickerOfRecovery() async throws {
        let host = Host.fixture()
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        let failure = TransportError.streamLocalOpenFailed(path: socketPath)
        let stopped = ScriptedTransport(snapshot: .openSession)
        let stillStopped = ScriptedTransport(snapshot: .openSession)
        // Every dial after the first finds herdr still down, however many the
        // app makes — so the count below measures the app's cadence rather
        // than the end of a scripted queue.
        for ordinal in 1...10 {
            await stillStopped.failPing(atCall: ordinal, with: failure)
        }
        let connector = SequencedTransportConnector([stopped, stillStopped])
        let store = makeStore(connector: connector)
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

        await stopped.failPing(atCall: 2, with: failure)
        activity.didEnterBackground()
        activity.didBecomeActive()
        try await waitUntil("the stopped herdr should fail the Host") {
            store.hostStatuses[host.id] == .failed(failure)
        }

        // Back again, with the Host still broken.
        activity.didEnterBackground()
        activity.didBecomeActive()
        try await waitUntil("the return should make its one attempt") {
            await stillStopped.pingCount == 1
        }
        await settle()

        #expect(store.hostStatuses[host.id] == .failed(failure))
        #expect(
            failure.connectionGuidance == """
                herdr is not running on this Host. If it is running, check SSH \
                stream-local forwarding.
                """)
        // No *reconnection* happened: the return's attempt got no further than
        // the dial, so nothing was ever installed as this Host's transport and
        // nothing was ever subscribed on it.
        //
        // That is strictly weaker than "no status flicker", and must not be
        // read as it. The generation tracks transport installs, and
        // `EventsSession` advances it nowhere near every `.connected` — a
        // subscription-only reconnect reuses the same transport and leaves it
        // alone (see `transportGeneration`'s own doc). A session that yielded
        // a bogus `.connected` without reconnecting would leave both of these
        // untouched and the Console would still flash "connected". The status
        // sequence itself is pinned by
        // `aStillBrokenHostNeverPublishesConnectedOnItsWayBackToFailed`.
        #expect(store.hostConnectionGenerations[host.id] == generation)
        #expect(await stillStopped.capturedSubscriptions.isEmpty)
        // One attempt, not a loop: the initial dial plus this return's.
        #expect(await connector.connectCount == 2)

        // And one *per return* — a second return makes exactly one more.
        activity.didEnterBackground()
        activity.didBecomeActive()
        try await waitUntil("the second return should make one more attempt") {
            await stillStopped.pingCount == 2
        }
        await settle()
        #expect(await stillStopped.pingCount == 2)
        #expect(store.hostStatuses[host.id] == .failed(failure))
        store.setHosts([])
    }

    /// The recovery is keyed on the Host being `.failed`, not on which failure
    /// stopped it, so it is pinned across genuinely different non-retryable
    /// classes rather than one instance of one of them. A guard narrowed to
    /// any subset of `TransportError`'s twelve non-retryable cases — one, or
    /// the two the socket path produces — strands the rest forever with every
    /// other case here still green.
    ///
    /// The three below are deliberately unrelated in cause: a named session
    /// whose socket is gone, credentials the Host will not take, and a host
    /// key that no longer matches what was trusted. Each is injected where it
    /// really arises, on the dial rather than on a ping — a `ping` cannot
    /// produce an authentication or host-key failure, and scripting one there
    /// would prove the guard against a shape production never sees.
    @Test(arguments: [
        TransportError.socketNotFound(
            path: "/home/dev/.config/herdr/sessions/work/herdr.sock"),
        TransportError.authenticationFailed,
        TransportError.hostKeyMismatch(
            known: HostKeyFingerprint(
                digest: Data(repeating: 0x11, count: 32), algorithm: "ssh-ed25519"),
            presented: HostKeyFingerprint(
                digest: Data(repeating: 0x22, count: 32), algorithm: "ssh-ed25519")),
    ])
    func aFailedHostIsAskedAgainWhicheverNonRetryableClassStoppedIt(
        failure: TransportError
    ) async throws {
        let host = Host.fixture()
        let stopped = ScriptedTransport(snapshot: .openSession)
        let restarted = ScriptedTransport(snapshot: .openSession)
        let store = makeStore(attempts: ConnectionAttemptQueue([
            .success(stopped), .failure(failure), .success(restarted),
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

        // The link goes away while the app is out, and the re-dial that
        // follows is refused for a reason no reconnect can repair.
        try await stopped.close()
        try await waitUntil("the refused dial should fail the Host") {
            store.hostStatuses[host.id] == .failed(failure)
        }

        activity.didEnterBackground()
        activity.didBecomeActive()
        try await waitUntil("coming back should ask this Host again too") {
            store.hostStatuses[host.id] == .connected
        }
        store.setHosts([])
    }

    /// The recovery must not reach a Host that is already *reconnecting*.
    /// `EventsSession.revalidate()` says why in its own doc — "one already
    /// reconnecting is visibly working on it" — and restarting such a session
    /// instead would reset its backoff to the first attempt and throw away the
    /// dial already in flight. Every foreground bounce would then re-dial from
    /// zero, which is exactly the retry cadence #147 refuses to introduce.
    @Test func aReconnectingHostKeepsItsBackoffAcrossAForegroundReturn() async throws {
        let host = Host.fixture()
        let alive = ScriptedTransport(snapshot: .openSession)
        let refusing = ScriptedTransport(snapshot: .openSession)
        // Two refusals and then a healthy Host. One refusal is what parks the
        // session on its second backoff; the second exists so that a return
        // which restarted the session would visibly *escape* that backoff and
        // reconnect early, instead of quietly landing on the same attempt
        // number again and leaving the status assertion below vacuous.
        for ordinal in 1...2 {
            await refusing.failPing(atCall: ordinal, with: .timedOut)
        }
        let connector = SequencedTransportConnector([alive, refusing])
        let store = makeStore(
            connector: connector, reconnectPolicy: Self.parkedSecondAttemptPolicy)
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

        // The link drops, the first re-dial is refused, and the session parks
        // on its second backoff with that dial's replacement still pending.
        try await alive.close()
        let backoff = EventsSessionStatus.reconnecting(
            attempt: 2, delay: .seconds(10), failure: .timedOut)
        try await waitUntil("the Host should park on its second backoff") {
            store.hostStatuses[host.id] == backoff
        }
        #expect(await connector.connectCount == 2)

        activity.didEnterBackground()
        activity.didBecomeActive()
        await settle()

        // Untouched: the dial already in flight was not thrown away, and the
        // Host is still waiting out the backoff it earned rather than having
        // been dragged out of it by a foreground bounce.
        #expect(await connector.connectCount == 2)
        #expect(store.hostStatuses[host.id] == backoff)
        store.setHosts([])
    }

    /// The `.suspended` half of the revalidation guard's dimension (#158); the
    /// `.reconnecting` half is pinned above. A return past the grace period is
    /// the ordinary case, and there `resume()` is already dialling: it
    /// activates the session and returns once the run task is spawned, before
    /// `.connected` is published, so the projection's status is still
    /// `.suspended` when `revalidate()` looks at it. The guard must leave that
    /// session to the dial it already has in flight — `session.revalidate()`
    /// no-ops on it, having no live channel to ping.
    ///
    /// Widening the guard to `.failed, .suspended` sends this return through
    /// `retry()` → `restart()` instead, which winds the fresh activation down
    /// — cancelling the run task over its own dial — and dials again. The
    /// statuses hide it: the Host still ends up `.connected`, and the widening
    /// measured green on the full lane. What shows it is the dial count, so
    /// that is what is counted: one dial to come up, none for the suspension,
    /// and exactly one more for the return.
    @Test func aReturnFromSuspensionCostsExactlyTheDialsResumeNeeds() async throws {
        let host = Host.fixture()
        let first = ScriptedTransport(snapshot: .fixture())
        let second = ScriptedTransport(snapshot: .fixture())
        let connector = SequencedTransportConnector([first, second])
        let store = makeStore(connector: connector)
        // Short enough that the absence below really suspends: what the
        // return's revalidation then meets is a `.suspended` status, not a
        // connection the grace period kept.
        let activity = AppActivityCoordinator(
            gracePeriod: .milliseconds(100), granter: GrantingBackgroundExecutionGranter())
        let driver = Task {
            await ConsoleActivityDriver(activity: activity, console: store).run()
        }
        defer { driver.cancel() }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should come up connected") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(await connector.connectCount == 1)

        activity.didEnterBackground()
        try await waitUntil("the absence should suspend the Host") {
            store.hostStatuses[host.id] == .suspended
        }
        // Tearing down is not a dial.
        #expect(await connector.connectCount == 1)

        activity.didBecomeActive()
        try await waitUntil("the return should bring the Host back") {
            store.hostStatuses[host.id] == .connected
        }
        // A restart's extra dial belongs to the mutation, not to anything the
        // wait above had to observe; give it room to happen before counting.
        await settle()

        #expect(await connector.connectCount == 2)
        store.setHosts([])
    }

    /// The `.failed` branch is *awaited*, like the ping branch beside it.
    /// `everyHostIsReProvedConcurrently` pins that invariant only on the ping,
    /// so a fire-and-forget `Task { await session.retry() }` on this branch
    /// leaves the whole suite green while breaking the lifecycle chain:
    /// `reactivate()` would return before the restart was even enqueued, and a
    /// `suspend()` the user triggers by leaving again could overtake it, so
    /// the session re-activates after the app has declared itself suspended.
    ///
    /// The hold point is the restart's own teardown rather than its dial:
    /// `EventsSession.restart()` winds the stopped activation down and then
    /// calls `activate()`, which only spawns the run task, so gating the
    /// connect would not hold `reactivate()` even in the correct
    /// implementation and could not tell the two shapes apart.
    @Test func aFailedHostsRestartHoldsTheForegroundActivation() async throws {
        let host = Host.fixture()
        let failure = TransportError.streamLocalOpenFailed(
            path: "/home/dev/.config/herdr/herdr.sock")
        let stopped = ScriptedTransport(snapshot: .openSession)
        let restarted = ScriptedTransport(snapshot: .openSession)
        let store = makeStore(attempts: ConnectionAttemptQueue([
            .success(stopped), .success(restarted),
        ]))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should come up connected") {
            store.hostStatuses[host.id] == .connected
        }

        await stopped.failEventStream(failure)
        try await waitUntil("the stopped herdr should fail the Host") {
            store.hostStatuses[host.id] == .failed(failure)
        }

        // Park the restart inside the teardown it has to do before it can dial
        // again: the stopped connection is still installed and gets closed
        // explicitly.
        let closeGate = ScriptedTransportCallGate()
        await stopped.gateNextClose(using: closeGate)
        let completion = LifecycleCompletionProbe()
        let reactivation = Task {
            await store.reactivate()
            await completion.finish()
        }
        try await waitUntil("the restart should reach that teardown") {
            await closeGate.entryCount == 1
        }
        // The correct shape is provably parked here, so waiting changes
        // nothing for it; a detached retry needs the room to have finished
        // its activation for the assertion to mean anything.
        await settle()
        #expect(!(await completion.isFinished))

        await closeGate.open()
        await reactivation.value
        try await waitUntil("and the repaired Host should come back") {
            store.hostStatuses[host.id] == .connected
        }
        store.setHosts([])
    }

    /// The genuine no-flicker guarantee, measured as a status sequence rather
    /// than inferred from counters: the Console must never publish
    /// `.connected` on a still-broken Host's way back to `.failed`.
    ///
    /// This is the assertion
    /// `aStillBrokenHostReturnsToFailedWithoutAFlickerOfRecovery` cannot
    /// make. That case observes the *transport*, and a session that
    /// yielded a bogus `.connected` without reconnecting would leave every
    /// counter there untouched. What the user sees is the projection's own
    /// published status, so that is what is recorded — every value the Console
    /// would have rendered, in order, through the projection's change hook.
    @Test func aStillBrokenHostNeverPublishesConnectedOnItsWayBackToFailed()
        async throws
    {
        let host = Host.fixture()
        let failure = TransportError.streamLocalOpenFailed(
            path: "/home/dev/.config/herdr/herdr.sock")
        let stopped = ScriptedTransport(snapshot: .openSession)
        let stillStopped = ScriptedTransport(snapshot: .openSession)
        for ordinal in 1...10 {
            await stillStopped.failPing(atCall: ordinal, with: failure)
        }
        let connector = SequencedTransportConnector([stopped, stillStopped])
        let session = EventsSession(
            subscriptions: HostConsoleProjection.subscriptions(paneIDs: []),
            connect: { try await connector.connect() },
            reconnectPolicy: Self.fastPolicy,
            keepalive: .default)
        let recorder = PublishedStatusRecorder()
        let projection = HostConsoleProjection(
            host: host, session: session, snapshotRetryDelay: .milliseconds(10)
        ) { [recorder] in
            recorder.record()
        }
        recorder.projection = projection
        projection.start(isActive: false)
        defer { projection.end() }

        await projection.resume()
        try await waitUntil("the Host should come up connected") {
            projection.status == .connected
        }

        await stopped.failEventStream(failure)
        try await waitUntil("the stopped herdr should fail the Host") {
            projection.status == .failed(failure)
        }
        let beforeTheReturn = recorder.statuses.count

        // The foreground return's one attempt, against a Host that is still
        // broken.
        await projection.revalidate()
        try await waitUntil("the return should make its one attempt") {
            await stillStopped.pingCount == 1
        }
        try await waitUntil("and land straight back on the same failure") {
            projection.status == .failed(failure)
        }
        await settle()

        #expect(!recorder.statuses[beforeTheReturn...].contains(.connected))
        #expect(recorder.statuses.last == .failed(failure))
    }

    /// A store whose session factory hands out scripted transports in order,
    /// in the keepalive shape production uses (`ConsoleStore.sshSessionFactory`
    /// takes the default): 30 s, far longer than any of these tests live.
    private func makeStore(attempts: ConnectionAttemptQueue) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { try await attempts.next() },
                reconnectPolicy: Self.fastPolicy,
                keepalive: .default)
        }
    }

    /// The same store over a connector that repeats its last transport, for
    /// cases that must count how many attempts the app makes rather than run
    /// a scripted queue dry.
    private func makeStore(
        connector: SequencedTransportConnector,
        reconnectPolicy: ReconnectPolicy = AppForegroundRecoveryTests.fastPolicy
    ) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { try await connector.connect() },
                reconnectPolicy: reconnectPolicy,
                keepalive: .default)
        }
    }

    /// Gives any further attempt room to happen before asserting that none
    /// did. Absence cannot be polled for: a count that must stay at one is
    /// only meaningful once the work that would have raised it has had time
    /// to run. Everything here is in-memory on a fast reconnect policy, so a
    /// loop would overshoot this many times over.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
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

/// Records every status a `HostConsoleProjection` publishes, in order, by
/// standing in for the change hook `ConsoleStore` normally supplies. Runs of
/// the same status collapse — the projection publishes on latency and snippet
/// changes too — but any transition between two different statuses survives,
/// which is what a flicker is.
@MainActor
private final class PublishedStatusRecorder {
    var projection: HostConsoleProjection?
    private(set) var statuses: [EventsSessionStatus] = []

    func record() {
        guard let status = projection?.status, statuses.last != status else { return }
        statuses.append(status)
    }
}

/// Records whether the reactivation Task has returned yet.
private actor LifecycleCompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
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
