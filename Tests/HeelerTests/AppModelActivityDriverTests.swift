import Testing

@testable import Heeler

/// The wiring #167 pins: `HeelerAppModel.start()` running
/// `ConsoleActivityDriver` is the only path that turns an app suspension
/// into a Console teardown (spec #20) and a foreground return into a
/// re-probe (#142). Deleting those lines used to leave the whole suite
/// green, because no test could reach the stores the composition root builds
/// inside itself. The injection seam on `HeelerAppModel.init` exists so this
/// test can hand the real model a volatile Host catalog, a scripted Console,
/// and a fast coordinator, start it the way every window does, and watch the
/// injected stores for the driver's effects.
@MainActor
@Suite("App model activity driver")
struct AppModelActivityDriverTests {
    /// Backgrounding past the grace period must suspend the Host's
    /// connection: the coordinator emits `.suspended`, and only the driver
    /// consuming it calls `console.suspend()`. Both halves of that
    /// consumption are asserted on the injected stores — the connection's
    /// published status, and the background assertion the driver hands back
    /// via `didFinishSuspending()` once the teardown has returned.
    @Test func backgroundingPastTheGracePeriodSuspendsTheConsoleConnection() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: .default)
        }
        let granter = RecordingBackgroundExecutionGranter()
        let activity = AppActivityCoordinator(
            gracePeriod: .milliseconds(100), granter: granter)

        let app = HeelerAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: HostStore(volatileHosts: [host]),
            console: console,
            activity: activity)
        // A second window starting the app again must not start a second
        // driver: the activity stream has exactly one consumer.
        app.start()
        app.start()

        // Start aligns the injected Console with the injected catalog and
        // resumes it.
        try await waitUntil("the injected Host should come up connected") {
            console.hostStatuses[host.id] == .connected
        }

        app.scenePhaseDidChange(.background)

        // The grace period elapses and the coordinator emits `.suspended`.
        // Only the driver turns that into a Console teardown — deleting it
        // leaves the Host `.connected` and this wait red.
        try await waitUntil("the driver should suspend the Host's connection") {
            console.hostStatuses[host.id] == .suspended
        }
        // `console.suspend()` publishes `.suspended` *before* the driver
        // calls `didFinishSuspending()` and ends the assertion. Sampling
        // the granter on the same turn as the status flip is a flake —
        // wait for the second half the same way as the first.
        try await waitUntil("the driver should release the background assertion") {
            granter.endedTokens == granter.beginTokens && granter.endedTokens.count == 1
        }
        console.setHosts([])
    }

    /// The Host catalog feeds the Console through the model's own
    /// observation, not through any window: a Host added after start, with
    /// no view rendering, still reaches the Console.
    @Test func hostsAddedAfterStartReachTheConsoleWithoutAWindow() async throws {
        let first = Host.fixture()
        let second = Host.fixture()
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, subscriptions in
            let transport = ScriptedTransport(snapshot: .fixture())
            return EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: .default)
        }
        let hostStore = HostStore(volatileHosts: [first])
        let app = HeelerAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(),
            hostStore: hostStore,
            console: console,
            activity: AppActivityCoordinator(
                gracePeriod: .seconds(60), granter: RecordingBackgroundExecutionGranter()))
        app.start()
        try await waitUntil("the initial Host should connect") {
            console.hostStatuses[first.id] == .connected
        }

        try hostStore.add(second)

        try await waitUntil("the added Host should connect") {
            console.hostStatuses[second.id] == .connected
        }
        console.setHosts([])
    }

    /// Browser sign-in can return either side of the grace period. Its
    /// resume callback must run in both cases, after any overlay teardown
    /// already in progress has finished, even with no Host to reconnect it.
    @Test(arguments: [false, true])
    func pendingSignInResumesAfterSuspensionTeardown(crossesGracePeriod: Bool) async throws {
        let activity = AppActivityCoordinator(
            gracePeriod: crossesGracePeriod ? .milliseconds(20) : .seconds(60),
            granter: RecordingBackgroundExecutionGranter())
        let callbacks = RecordingActivityCallbacks()
        let driver = Task {
            await ConsoleActivityDriver(
                activity: activity,
                console: ConsoleStore(),
                afterSuspend: { await callbacks.suspend() },
                afterResume: { await callbacks.resume() }
            ).run()
        }
        defer {
            callbacks.finishSuspending()
            driver.cancel()
        }

        activity.didEnterBackground()
        if crossesGracePeriod {
            try await waitUntil("overlay teardown should start before the foreground return") {
                callbacks.events == ["suspend started"]
            }
        }
        activity.didBecomeActive()

        if crossesGracePeriod {
            // The foreground event is queued while overlay teardown still
            // owns the lifecycle. It must not resume a node in parallel.
            await Task.yield()
            #expect(callbacks.events == ["suspend started"])
            callbacks.finishSuspending()
        }
        try await waitUntil("pending browser sign-in should resume on foreground return") {
            callbacks.events.last == "resumed"
        }
        #expect(
            callbacks.events == (crossesGracePeriod
                ? ["suspend started", "suspend finished", "resumed"]
                : ["resumed"]))
    }

    /// Polls until `condition` holds, yielding so the model's tasks progress.
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

/// Holds overlay teardown open across a foreground return so event ordering
/// is exercised without timing a native node shutdown.
@MainActor
private final class RecordingActivityCallbacks {
    private(set) var events: [String] = []
    private var suspension: CheckedContinuation<Void, Never>?

    func suspend() async {
        events.append("suspend started")
        await withCheckedContinuation { suspension = $0 }
        events.append("suspend finished")
    }

    func finishSuspending() {
        suspension?.resume()
        suspension = nil
    }

    func resume() {
        events.append("resumed")
    }
}

/// Grants background time and records its lifecycle, so the test can see the
/// driver hand the assertion back (`didFinishSuspending`) once the Console's
/// teardown has returned.
@MainActor
private final class RecordingBackgroundExecutionGranter: BackgroundExecutionGranting {
    private(set) var beginTokens: [BackgroundExecutionToken] = []
    private(set) var endedTokens: [BackgroundExecutionToken] = []
    private var nextRawValue = 1

    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        let token = BackgroundExecutionToken(rawValue: nextRawValue)
        nextRawValue += 1
        beginTokens.append(token)
        return token
    }

    func end(_ token: BackgroundExecutionToken) {
        endedTokens.append(token)
    }
}
