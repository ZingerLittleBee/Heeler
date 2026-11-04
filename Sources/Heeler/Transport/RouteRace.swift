import Foundation

/// Races a Host's Routes (ADR 0022): the first attempt to succeed wins and
/// every other one is cancelled. Immediate attempts start at once; deferred
/// ones start after `stagger`, or as soon as every immediate attempt has
/// failed, so a reachable LAN address wins without an overlay node or Jump
/// Host ever being started, and an unreachable one costs only the stagger.
///
/// Attempts run as unstructured tasks: the winner returns without waiting
/// for a cancelled attempt to unwind, and an attempt that succeeds after the
/// race is decided hands its value to `discard`.
enum RouteRace {
    /// Every attempt failed; `failures` holds each error in attempt order.
    struct Failure: Error {
        let failures: [any Error]
    }

    /// The winning attempt's index and value. Throws `Failure` when every
    /// attempt failed and `CancellationError` when the caller was cancelled.
    static func first<Value: Sendable>(
        count: Int,
        isDeferred: (Int) -> Bool,
        stagger: Duration,
        attempt: @escaping @Sendable (Int) async throws -> Value,
        discard: @escaping @Sendable (Value) async -> Void
    ) async throws -> (index: Int, value: Value) {
        let deferred = (0..<count).filter(isDeferred)
        let coordinator = Coordinator<Value>(
            count: count,
            immediate: (0..<count).filter { !isDeferred($0) },
            deferred: deferred,
            attempt: attempt,
            discard: discard)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { await coordinator.start(continuation, stagger: stagger) }
            }
        } onCancel: {
            Task { await coordinator.cancel() }
        }
        switch outcome {
        case .won(let index, let value):
            return (index, value)
        case .failed(let failures):
            throw Failure(failures: failures)
        case .cancelled:
            throw CancellationError()
        }
    }

    fileprivate enum Outcome<Value: Sendable>: Sendable {
        case won(Int, Value)
        case failed([any Error])
        case cancelled
    }

    private actor Coordinator<Value: Sendable> {
        private let count: Int
        private let immediate: [Int]
        private var deferred: [Int]
        private let attempt: @Sendable (Int) async throws -> Value
        private let discard: @Sendable (Value) async -> Void
        private var continuation: CheckedContinuation<Outcome<Value>, Never>?
        private var tasks: [Task<Void, Never>] = []
        private var failures: [Int: any Error] = [:]
        private var isDecided = false

        init(
            count: Int,
            immediate: [Int],
            deferred: [Int],
            attempt: @escaping @Sendable (Int) async throws -> Value,
            discard: @escaping @Sendable (Value) async -> Void
        ) {
            self.count = count
            self.immediate = immediate
            self.deferred = deferred
            self.attempt = attempt
            self.discard = discard
        }

        func start(_ continuation: CheckedContinuation<Outcome<Value>, Never>, stagger: Duration) {
            guard !isDecided else {
                // Cancelled before the race began.
                continuation.resume(returning: .cancelled)
                return
            }
            self.continuation = continuation
            guard count > 0 else {
                decide(.failed([]))
                return
            }
            immediate.forEach(launch)
            if immediate.isEmpty {
                startDeferred()
            } else if !deferred.isEmpty {
                tasks.append(
                    Task {
                        try? await Task.sleep(for: stagger)
                        guard !Task.isCancelled else { return }
                        self.startDeferred()
                    })
            }
        }

        func cancel() {
            decide(.cancelled)
        }

        private func launch(_ index: Int) {
            tasks.append(
                Task {
                    do {
                        let value = try await attempt(index)
                        if !self.won(index, value) {
                            await discard(value)
                        }
                    } catch {
                        self.failed(index, error)
                    }
                })
        }

        private func startDeferred() {
            guard !isDecided else { return }
            let starting = deferred
            deferred = []
            starting.forEach(launch)
        }

        private func won(_ index: Int, _ value: Value) -> Bool {
            guard !isDecided else { return false }
            decide(.won(index, value))
            return true
        }

        private func failed(_ index: Int, _ error: any Error) {
            guard !isDecided else { return }
            failures[index] = error
            if failures.count == count {
                decide(.failed((0..<count).compactMap { failures[$0] }))
            } else if immediate.allSatisfy({ failures[$0] != nil }) {
                // Nothing direct is left to wait for.
                startDeferred()
            }
        }

        private func decide(_ outcome: Outcome<Value>) {
            guard !isDecided else { return }
            isDecided = true
            tasks.forEach { $0.cancel() }
            tasks = []
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }
}

/// Serializes host-key verification across one connect's Routes, so two
/// Routes never ask the user to confirm a key at once, and a Route that
/// arrives second sees the trust the first one just stored instead of
/// prompting again. A waiter that is cancelled leaves the queue at once.
actor HostKeyVerificationGate {
    private var isHeld = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !isHeld {
                    isHeld = true
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.dropWaiter(id) }
        }
    }

    private func dropWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            // The lock passes straight to the next waiter.
            waiters.removeFirst().continuation.resume()
        }
    }
}
