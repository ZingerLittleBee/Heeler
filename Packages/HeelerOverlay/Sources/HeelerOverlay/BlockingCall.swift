import Foundation

/// Runs a blocking native call on its own thread, never on the cooperative
/// pool, and lets the awaiting task give up on it.
///
/// Native overlay calls (a tsnet dial, a libzt connect) cannot always be
/// interrupted. When the deadline passes or the task is cancelled first, the
/// awaiting task resumes at once with `OverlayError.timedOut` or
/// `.cancelled`, `onGiveUp` runs so the caller can nudge the native side, and
/// the call's eventual result goes to `abandon` — which must release
/// anything it holds, such as a descriptor that arrived too late.
enum BlockingCall {
    static func run<Value: Sendable>(
        name: String,
        timeout: Duration?,
        onGiveUp: @escaping @Sendable () -> Void = {},
        abandon: @escaping @Sendable (Value) -> Void = { _ in },
        _ body: @escaping @Sendable () -> Value
    ) async throws -> Value {
        let race = Race<Value>(abandon: abandon, onGiveUp: onGiveUp)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let thread = Thread {
                    race.finish(body())
                }
                thread.name = "dev.bybee.heeler.overlay.\(name)"
                thread.start()

                if let timeout {
                    let nanoseconds = max(0, timeout.nanoseconds)
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + .nanoseconds(Int(clamping: nanoseconds))
                    ) {
                        race.giveUp(OverlayError.timedOut)
                    }
                }
            }
        } onCancel: {
            race.giveUp(OverlayError.cancelled)
        }
    }

    /// Runs a blocking call that is expected to return promptly, with no
    /// deadline or cancellation, off the cooperative pool.
    static func run<Value: Sendable>(
        name: String,
        _ body: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: body())
            }
            thread.name = "dev.bybee.heeler.overlay.\(name)"
            thread.start()
        }
    }

    /// Waits for `task` for at most `timeout`, or until the waiting task is
    /// cancelled. Giving up leaves `task` running; its result is dropped
    /// here, so the task must record anything that outlives the wait itself.
    static func wait<Value: Sendable>(
        for task: Task<Value, Never>,
        timeout: Duration
    ) async throws -> Value {
        let race = Race<Value>(abandon: { _ in }, onGiveUp: {})
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                Task.detached {
                    race.finish(await task.value)
                }
                let nanoseconds = max(0, timeout.nanoseconds)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + .nanoseconds(Int(clamping: nanoseconds))
                ) {
                    race.giveUp(OverlayError.timedOut)
                }
            }
        } onCancel: {
            race.giveUp(OverlayError.cancelled)
        }
    }

    /// Runs a prompt blocking call on `queue`, a dedicated serial queue the
    /// caller owns, so frequent polling does not spawn a thread per call.
    static func run<Value: Sendable>(
        on queue: DispatchQueue,
        _ body: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    /// First of {result, timeout, cancellation} wins; the rest are ignored,
    /// except that a losing result is handed to `abandon`.
    private final class Race<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, any Error>?
        private var pendingFailure: (any Error)?
        private var settled = false
        private let abandon: @Sendable (Value) -> Void
        private let onGiveUp: @Sendable () -> Void

        init(abandon: @escaping @Sendable (Value) -> Void, onGiveUp: @escaping @Sendable () -> Void) {
            self.abandon = abandon
            self.onGiveUp = onGiveUp
        }

        func install(_ continuation: CheckedContinuation<Value, any Error>) {
            lock.lock()
            if let pendingFailure {
                // Cancelled before the continuation existed.
                lock.unlock()
                continuation.resume(throwing: pendingFailure)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ value: Value) {
            lock.lock()
            if settled {
                lock.unlock()
                abandon(value)
                return
            }
            settled = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }

        func giveUp(_ error: OverlayError) {
            lock.lock()
            if settled {
                lock.unlock()
                return
            }
            settled = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                pendingFailure = error
            }
            lock.unlock()
            onGiveUp()
            continuation?.resume(throwing: error)
        }
    }
}

extension Duration {
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return seconds < 0 ? .min : .max }
        let (total, overflowTotal) = scaled.addingReportingOverflow(attoseconds / 1_000_000_000)
        if overflowTotal { return seconds < 0 ? .min : .max }
        return total
    }

    var milliseconds: Int {
        Int(clamping: nanoseconds / 1_000_000)
    }
}

/// A point in time a multi-step operation must finish by.
struct OverlayDeadline: Sendable {
    let instant: ContinuousClock.Instant

    init(after timeout: Duration) {
        instant = ContinuousClock.now.advanced(by: max(.zero, timeout))
    }

    var remaining: Duration {
        max(.zero, ContinuousClock.now.duration(to: instant))
    }

    var hasPassed: Bool {
        ContinuousClock.now >= instant
    }

    /// Sleeps for `interval` or until the deadline, whichever is sooner.
    /// Throws `.timedOut` once the deadline has passed and `.cancelled` when
    /// the task is cancelled.
    func pause(_ interval: Duration) async throws {
        guard !hasPassed else { throw OverlayError.timedOut }
        do {
            try await Task.sleep(for: min(interval, remaining))
        } catch {
            throw OverlayError.cancelled
        }
    }
}
