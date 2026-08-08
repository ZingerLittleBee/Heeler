import Foundation

enum AsyncDeadlineError: Error, Equatable {
    case timedOut
}

/// Runs one asynchronous operation against a wall-clock deadline.
enum AsyncDeadline {
    static func run<Value: Sendable>(
        for timeout: Duration,
        onTimeout: @escaping @Sendable () async -> Void = {},
        onCancel: @escaping @Sendable () async -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let resolution = AsyncDeadlineResolution<Value>()
        let operationTask = Task {
            let result: Result<Value, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            await resolution.resolve(with: result)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            if await resolution.resolve(with: .failure(AsyncDeadlineError.timedOut)) {
                operationTask.cancel()
                Task { await onTimeout() }
            }
        }

        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }
        return try await withTaskCancellationHandler {
            let value = try await resolution.value()
            try Task.checkCancellation()
            return value
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            Task {
                await resolution.resolve(with: .failure(CancellationError()))
                await onCancel()
            }
        }
    }
}

/// A single-winner handoff for `AsyncDeadline`.
///
/// The operation and timer are deliberately unstructured: structured task
/// groups cannot leave scope until a child finishes, which turns a deadline
/// back into an unbounded wait when a stalled SSH operation does not return
/// promptly on cancellation.
private actor AsyncDeadlineResolution<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiter: CheckedContinuation<Value, any Error>?

    func value() async throws -> Value {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    @discardableResult
    func resolve(with result: Result<Value, any Error>) -> Bool {
        guard self.result == nil else { return false }
        self.result = result
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        }
        return true
    }
}
