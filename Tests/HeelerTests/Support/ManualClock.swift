import Foundation

@testable import Heeler

/// Time that passes only when the card sleeps, so windows and the grace
/// run instantly and the same way every time.
///
/// `parkedSleep` is the other way to use it: a deadline that must stay armed
/// until the test says time passed, so it waits for `advance`.
final class ManualClock: @unchecked Sendable {
    private struct ParkedSleep {
        let id: UInt64
        let wakeAt: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct ParkWatcher {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed: Duration = .zero
    private var recorded: [Duration] = []
    private var nextParkID: UInt64 = 0
    private var parked: [ParkedSleep] = []
    private var parkWatchers: [ParkWatcher] = []

    var sleeps: [Duration] { lock.withLock { recorded } }

    /// Moves time on and wakes every parked sleep it passed, earliest
    /// deadline first (ties in the order they parked), as a real clock
    /// would. Returns how many woke, so a test can tell that a deadline it
    /// passed had nothing armed. A woken sleeper still resumes on its own
    /// executor: a test that needs one deadline's effect before the next
    /// passes them one at a time.
    @discardableResult
    func advance(_ duration: Duration) -> Int {
        let woken = lock.withLock {
            elapsed += duration
            let due = parked.filter { $0.wakeAt <= elapsed }
                .sorted { ($0.wakeAt, $0.id) < ($1.wakeAt, $1.id) }
            parked.removeAll { $0.wakeAt <= elapsed }
            return due
        }
        for sleep in woken { sleep.continuation.resume() }
        return woken.count
    }

    var clock: BlockedCardClock {
        BlockedCardClock(
            now: { [self] in lock.withLock { start + elapsed } },
            sleep: { [self] duration in
                lock.withLock {
                    elapsed += duration
                    recorded.append(duration)
                }
                await Task.yield()
            })
    }

    /// Suspends until `advance` has moved time past `duration`. Cancellation wakes it.
    @Sendable func parkedSleep(for duration: Duration) async throws {
        let id = lock.withLock {
            nextParkID += 1
            return nextParkID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let refused = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    parked.append(ParkedSleep(id: id, wakeAt: elapsed + duration, continuation: continuation))
                    let met = parkWatchers.filter { $0.count <= parked.count }
                    parkWatchers.removeAll { $0.count <= parked.count }
                    for watcher in met { watcher.continuation.resume() }
                    return false
                }
                if refused { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> ParkedSleep? in
                guard let index = parked.firstIndex(where: { $0.id == id }) else { return nil }
                return parked.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Whether a sleep of exactly `duration` from now is parked.
    func isParked(for duration: Duration) -> Bool {
        lock.withLock { parked.contains { $0.wakeAt == elapsed + duration } }
    }

    /// Returns once a sleep of exactly `duration` from now is parked, when others
    /// may be parked beside it.
    func untilParked(for duration: Duration) async {
        while !isParked(for: duration) {
            await Task.yield()
        }
    }

    /// Waits for a sleep of exactly `duration` from now to park, so a timer
    /// started by a task that has yet to run counts. False when none parks
    /// within `timeout`: a timer that is never armed fails the test instead
    /// of hanging it.
    func parks(for duration: Duration, within timeout: Duration = .seconds(5)) async -> Bool {
        var budget = PollBudget(timeout)
        while !isParked(for: duration) {
            guard budget.hasTimeLeft else { return false }
            try? await Task.sleep(for: .milliseconds(1))
            budget.charge()
        }
        return true
    }

    /// Passes the deadline of a sleep of `duration` armed now, once it parks
    /// (see ``parks(for:within:)``). False, with time left where it was,
    /// when it never does.
    func pass(_ duration: Duration, within timeout: Duration = .seconds(5)) async -> Bool {
        guard await parks(for: duration, within: timeout) else { return false }
        advance(duration)
        return true
    }

    /// Returns once at least `count` sleeps are parked, so a test can advance
    /// time knowing the deadline it means to pass is armed.
    func untilParked(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let met = lock.withLock { () -> Bool in
                if parked.count >= count { return true }
                parkWatchers.append(ParkWatcher(count: count, continuation: continuation))
                return false
            }
            if met { continuation.resume() }
        }
    }
}
