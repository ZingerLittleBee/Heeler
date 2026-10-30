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

    func advance(_ duration: Duration) {
        let woken = lock.withLock {
            elapsed += duration
            let due = parked.filter { $0.wakeAt <= elapsed }
            parked.removeAll { $0.wakeAt <= elapsed }
            return due
        }
        for sleep in woken { sleep.continuation.resume() }
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
