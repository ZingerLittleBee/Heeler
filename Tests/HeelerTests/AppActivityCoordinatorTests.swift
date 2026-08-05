import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("App activity coordinator")
struct AppActivityCoordinatorTests {
    @Test func backgroundingStaysActiveForTheGracePeriod() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground()

        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.phase == .active)
        #expect(granter.liveTokenCount == 1)
    }

    @Test func returningInsideTheGracePeriodNeverSuspends() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground()
        coordinator.didBecomeActive()

        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.phase == .active)
        // The assertion goes back as soon as it is no longer needed;
        // holding one while in the foreground is pure battery waste.
        #expect(granter.liveTokenCount == 0)
        #expect(granter.beginCount == 1)
    }

    @Test func gracePeriodElapsingSuspends() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .milliseconds(20), granter: granter)

        coordinator.didEnterBackground()

        try await waitUntil("the grace period should expire into a suspension") {
            coordinator.phase == .suspended
        }
        // Still held: the teardown it just triggered needs the time.
        #expect(granter.liveTokenCount == 1)

        coordinator.didFinishSuspending()
        #expect(granter.liveTokenCount == 0)
    }

    @Test func foregroundingAfterASuspensionReactivates() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .milliseconds(20), granter: granter)

        coordinator.didEnterBackground()
        try await waitUntil("the grace period should expire into a suspension") {
            coordinator.phase == .suspended
        }
        coordinator.didBecomeActive()

        #expect(coordinator.phase == .active)
        #expect(granter.liveTokenCount == 0)
    }

    @Test func systemReclaimingItsTimeSuspendsAndReturnsTheAssertion() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground()
        granter.expireAll()

        try await waitUntil("expiration should force a suspension") {
            coordinator.phase == .suspended
        }
        // Holding an expired assertion is how an app gets killed, so it is
        // returned before the teardown rather than after it.
        #expect(granter.liveTokenCount == 0)
    }

    @Test func refusedBackgroundTimeSuspendsImmediately() {
        let granter = FakeBackgroundExecutionGranter()
        granter.grantsTime = false
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground()

        #expect(coordinator.phase == .suspended)
        #expect(granter.liveTokenCount == 0)
    }

    @Test func repeatedBackgroundingDoesNotStackAssertions() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground()
        coordinator.didEnterBackground()

        #expect(granter.beginCount == 1)
        #expect(granter.liveTokenCount == 1)
    }

    /// The transitions are delivered as events, not inferred from the phase.
    /// A whole background→foreground round trip can land between two looks at
    /// `phase` — it happens while the app is in the background drawing
    /// nothing — and a consumer that compares values would see no change at
    /// all, tearing nothing down and resuming nothing (#141).
    @Test func everyTransitionIsDeliveredEvenWhenNothingWatchesThePhase() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .milliseconds(20), granter: granter)
        var events = coordinator.events.makeAsyncIterator()

        coordinator.didEnterBackground()
        try await waitUntil("the grace period should expire into a suspension") {
            coordinator.phase == .suspended
        }
        coordinator.didBecomeActive()

        #expect(coordinator.phase == .active)
        #expect(await events.next() == .suspended)
        #expect(await events.next() == .activated)
    }

    /// A return the grace period absorbed still reports an activation: the
    /// connection may have died while the app was away, and nothing else in
    /// the app is going to ask it.
    @Test func aBounceInsideTheGracePeriodStillReportsAnActivation() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)
        var events = coordinator.events.makeAsyncIterator()

        coordinator.didEnterBackground()
        coordinator.didBecomeActive()

        #expect(await events.next() == .activated)
    }

    /// Polls until `condition` holds, yielding so the coordinator's grace
    /// task progresses.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), comment)
    }
}

@MainActor
private final class FakeBackgroundExecutionGranter: BackgroundExecutionGranting {
    var grantsTime = true
    private(set) var beginCount = 0
    private var live: [BackgroundExecutionToken: @MainActor @Sendable () -> Void] = [:]
    private var nextRawValue = 1

    var liveTokenCount: Int { live.count }

    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        guard grantsTime else { return nil }
        beginCount += 1
        let token = BackgroundExecutionToken(rawValue: nextRawValue)
        nextRawValue += 1
        live[token] = onExpiration
        return token
    }

    func end(_ token: BackgroundExecutionToken) {
        live[token] = nil
    }

    /// Stands in for the system reclaiming its background time.
    func expireAll() {
        for handler in live.values {
            handler()
        }
    }
}
