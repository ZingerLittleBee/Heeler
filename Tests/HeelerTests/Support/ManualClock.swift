import Foundation

@testable import Heeler

/// Time that passes only when the card sleeps, so windows and the grace
/// run instantly and the same way every time.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed: Duration = .zero
    private var recorded: [Duration] = []

    var sleeps: [Duration] { lock.withLock { recorded } }

    func advance(_ duration: Duration) {
        lock.withLock { elapsed += duration }
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
}
