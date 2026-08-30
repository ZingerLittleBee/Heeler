import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The wiring #167 pins: `ContentView`'s `.task` running
/// `ConsoleActivityDriver` is the only path that turns an app suspension
/// into a Console teardown (spec #20) and a foreground return into a
/// re-probe (#142). Deleting those three lines used to leave the whole suite
/// green, because no test could reach the stores `ContentView` builds inside
/// itself. The injection seam on `ContentView.init` exists so this test can
/// hand the real view a volatile Host catalog, a scripted Console, and a
/// fast coordinator, host it, and watch the injected stores for the
/// driver's effects.
@MainActor
@Suite("ContentView activity driver")
struct ContentViewActivityDriverTests {
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

        let controller = UIHostingController(
            rootView: ContentView(
                pushRegistration: PushRegistrationStore(
                    client: ScriptedPushRegistrationClient(), environment: .sandbox),
                notificationRouter: AgentNotificationRouter(),
                hostStore: HostStore(volatileHosts: [host]),
                console: console,
                activity: activity))
        // Bind the hosted view to the test app's connected scene so SwiftUI
        // owns a valid lifecycle for the `.task` modifiers under test.
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }

        // The view's own first `.task` aligns the injected Console with the
        // injected catalog and resumes it.
        try await waitUntil("the injected Host should come up connected") {
            console.hostStatuses[host.id] == .connected
        }

        activity.didEnterBackground()

        // The grace period elapses and the coordinator emits `.suspended`.
        // Only the driver's `.task` turns that into a Console teardown —
        // deleting it leaves the Host `.connected` and this wait red.
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

    /// Polls until `condition` holds, yielding so the view's tasks progress.
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
