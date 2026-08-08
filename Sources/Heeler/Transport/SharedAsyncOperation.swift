import Foundation

/// A single-flight async operation whose waiters can leave early (deadline,
/// cancellation) without cancelling the operation itself.
///
/// Exists because `Task.value` cannot be awaited cancellably: a caller racing
/// it against a deadline still hangs until the task finishes. Waiters here
/// park on a continuation that cancellation resumes immediately, while the
/// operation runs in an unstructured Task that is never cancelled. For SSH
/// exec work that is exactly right: a remote command that ignores stdin EOF
/// cannot be ended client-side anyway (sshd holds the channel open until the
/// command exits), so the honest behavior is to let it keep its channel slot
/// accounted for until it really ends and have callers abandon the wait.
actor SharedAsyncOperation<Value: Sendable> {
    /// Whether a successful value is memoized (home resolution) or every
    /// demand after completion starts a fresh run (wake).
    private let cachesSuccess: Bool
    private var cached: Value?
    private var running: Task<Void, Never>?

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Value, any Error>
    }

    private var waiters: [Waiter] = []
    /// Waiter ids whose cancellation raced ahead of parking or resumption;
    /// see the identical bookkeeping on `SSHChannelAdmission`'s waiter queue.
    private var cancelledWaiters: Set<UInt64> = []
    private var pendingWaiters: Set<UInt64> = []
    private var nextWaiterID: UInt64 = 0

    init(cachesSuccess: Bool) {
        self.cachesSuccess = cachesSuccess
    }

    /// Returns the memoized value, or joins the in-flight run (starting one
    /// if idle) and waits for its result. Waiting is cancellation-responsive;
    /// the operation itself is never cancelled. Failures are delivered to
    /// every current waiter and not cached, so the next demand retries.
    func value(
        startingIfNeeded operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let cached { return cached }
        try Task.checkCancellation()
        if running == nil {
            running = Task {
                let result: Result<Value, any Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                self.finish(result)
            }
        }
        nextWaiterID += 1
        let id = nextWaiterID
        pendingWaiters.insert(id)
        defer {
            pendingWaiters.remove(id)
            cancelledWaiters.remove(id)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, any Error>) in
                if cancelledWaiters.contains(id) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func finish(_ result: Result<Value, any Error>) {
        running = nil
        if cachesSuccess, case .success(let value) = result {
            cached = value
        }
        let parked = waiters
        waiters = []
        for waiter in parked {
            waiter.continuation.resume(with: result)
        }
    }

    private func cancelWaiter(id: UInt64) {
        guard pendingWaiters.contains(id) else { return }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelledWaiters.insert(id)
        }
    }
}
