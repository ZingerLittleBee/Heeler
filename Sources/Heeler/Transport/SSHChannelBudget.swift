import Foundation

/// Owns the Host's bounded pool of ordinary SSH session channels.
///
/// Callers describe one channel lifetime with `withChannel`; capacity,
/// cancellation-safe FIFO admission, and exactly-once release stay inside
/// this module. Dedicated Events and Attach channels remain outside this pool,
/// with the configured capacity reserving their MaxSessions headroom.
actor SSHChannelBudget {
    static let opensshDefaultSessionLimit = 10
    static let dedicatedChannelReservation = 2
    static let defaultOrdinaryChannelCapacity =
        opensshDefaultSessionLimit - dedicatedChannelReservation

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let capacity: Int
    private var channelsInUse = 0
    private var waiters: [Waiter] = []
    private var cancelledRequests: Set<UInt64> = []
    private var pendingRequests: Set<UInt64> = []
    private var nextRequestID: UInt64 = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func withChannel<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        nextRequestID &+= 1
        let requestID = nextRequestID
        pendingRequests.insert(requestID)
        defer {
            pendingRequests.remove(requestID)
            cancelledRequests.remove(requestID)
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledRequests.contains(requestID) {
                    continuation.resume(throwing: CancellationError())
                } else if channelsInUse < capacity {
                    channelsInUse += 1
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: requestID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            channelsInUse -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(requestID: UInt64) {
        guard pendingRequests.contains(requestID) else { return }
        if let index = waiters.firstIndex(where: { $0.id == requestID }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelledRequests.insert(requestID)
        }
    }
}
