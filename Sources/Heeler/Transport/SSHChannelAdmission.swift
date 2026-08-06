import Foundation
import Synchronization

/// Separates OpenSSH forwarding and session admission while enforcing one
/// finite ceiling over every live SSH channel on a Host connection.
///
/// Session categories leave headroom under sshd's default `MaxSessions` of 10
/// (ADR 0011). That server-side limit is the real binding constraint for exec,
/// PTY, and SFTP channels, and the app cannot observe it: an abandoned channel
/// teardown still releases the app admission lease unconditionally, while the
/// server session slot can remain occupied (#148). App counters and
/// `isConnected` may therefore still look available after the server has
/// already spent the slot; they cannot promise MaxSessions safety.
actor SSHChannelAdmission {
    enum ChannelClass: Sendable {
        case ordinaryForwarding
        case events
        case ordinarySession
        case attach
    }

    struct Limits: Sendable, Equatable {
        let ordinaryForwarding: Int
        let events: Int
        let ordinarySession: Int
        let attach: Int
        let connection: Int

        /// Production budgets. `connection` restates the sum of the four
        /// category budgets (8+1+8+1), so the connection-level guard does not
        /// bind under these categories — it only constrains a future category
        /// that would otherwise grow without a connection cap. Per-category
        /// budgets are the live admission limits today; do not treat 18 as a
        /// tighter guarantee than those budgets or than server `MaxSessions`.
        static let production = Limits(
            ordinaryForwarding: 8,
            events: 1,
            ordinarySession: 8,
            attach: 1,
            connection: 18)
    }

    struct Snapshot: Sendable, Equatable {
        let ordinaryForwarding: Int
        let events: Int
        let ordinarySession: Int
        let attach: Int
        let connection: Int
    }

    private struct Waiter {
        let id: UInt64
        let channelClass: ChannelClass
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limits: Limits
    private var counts = Snapshot(
        ordinaryForwarding: 0,
        events: 0,
        ordinarySession: 0,
        attach: 0,
        connection: 0)
    private var waiters: [Waiter] = []
    private var pendingRequests: Set<UInt64> = []
    private var cancelledRequests: Set<UInt64> = []
    private var nextRequestID: UInt64 = 0

    init(limits: Limits = .production) {
        precondition(limits.ordinaryForwarding > 0)
        precondition(limits.events > 0)
        precondition(limits.ordinarySession > 0)
        precondition(limits.attach > 0)
        precondition(limits.connection > 0)
        self.limits = limits
    }

    func withChannel<Value: Sendable>(
        _ channelClass: ChannelClass,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let lease = try await acquire(channelClass)
        do {
            let value = try await operation()
            await lease.release()
            return value
        } catch {
            await lease.release()
            throw error
        }
    }

    func acquire(_ channelClass: ChannelClass) async throws -> SSHChannelAdmissionLease {
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
                } else if canAcquire(channelClass) {
                    increment(channelClass)
                    continuation.resume()
                } else {
                    waiters.append(Waiter(
                        id: requestID,
                        channelClass: channelClass,
                        continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }

        if Task.isCancelled {
            release(channelClass)
            throw CancellationError()
        }
        return SSHChannelAdmissionLease(admission: self, channelClass: channelClass)
    }

    func snapshot() -> Snapshot { counts }

    fileprivate func release(_ channelClass: ChannelClass) {
        decrement(channelClass)
        resumeEligibleWaiters()
    }

    private func cancel(requestID: UInt64) {
        guard pendingRequests.contains(requestID) else { return }
        if let index = waiters.firstIndex(where: { $0.id == requestID }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelledRequests.insert(requestID)
        }
    }

    private func resumeEligibleWaiters() {
        while let index = waiters.firstIndex(where: { canAcquire($0.channelClass) }) {
            let waiter = waiters.remove(at: index)
            increment(waiter.channelClass)
            waiter.continuation.resume()
        }
    }

    private func canAcquire(_ channelClass: ChannelClass) -> Bool {
        guard counts.connection < limits.connection else { return false }
        switch channelClass {
        case .ordinaryForwarding:
            return counts.ordinaryForwarding < limits.ordinaryForwarding
        case .events:
            return counts.events < limits.events
        case .ordinarySession:
            return counts.ordinarySession < limits.ordinarySession
        case .attach:
            return counts.attach < limits.attach
        }
    }

    private func increment(_ channelClass: ChannelClass) {
        counts = Snapshot(
            ordinaryForwarding: counts.ordinaryForwarding
                + (channelClass == .ordinaryForwarding ? 1 : 0),
            events: counts.events + (channelClass == .events ? 1 : 0),
            ordinarySession: counts.ordinarySession
                + (channelClass == .ordinarySession ? 1 : 0),
            attach: counts.attach + (channelClass == .attach ? 1 : 0),
            connection: counts.connection + 1)
    }

    private func decrement(_ channelClass: ChannelClass) {
        precondition(counts.connection > 0)
        counts = Snapshot(
            ordinaryForwarding: counts.ordinaryForwarding
                - (channelClass == .ordinaryForwarding ? 1 : 0),
            events: counts.events - (channelClass == .events ? 1 : 0),
            ordinarySession: counts.ordinarySession
                - (channelClass == .ordinarySession ? 1 : 0),
            attach: counts.attach - (channelClass == .attach ? 1 : 0),
            connection: counts.connection - 1)
    }
}

final class SSHChannelAdmissionLease: Sendable {
    private let admission: SSHChannelAdmission
    private let channelClass: SSHChannelAdmission.ChannelClass
    private let released = Mutex(false)

    fileprivate init(
        admission: SSHChannelAdmission,
        channelClass: SSHChannelAdmission.ChannelClass
    ) {
        self.admission = admission
        self.channelClass = channelClass
    }

    func release() async {
        let shouldRelease = released.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { await admission.release(channelClass) }
    }

    deinit {
        let admission = admission
        let channelClass = channelClass
        let shouldRelease = released.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease {
            Task { await admission.release(channelClass) }
        }
    }
}
