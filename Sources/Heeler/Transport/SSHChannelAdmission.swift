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
        /// category budgets (8+1+4+5), so the connection-level guard does not
        /// bind under these categories — it only constrains a future category
        /// that would otherwise grow without a connection cap. Per-category
        /// budgets are the live admission limits today; do not treat 18 as a
        /// tighter guarantee than those budgets or than server `MaxSessions`.
        static let production = Limits(
            ordinaryForwarding: 8,
            events: 1,
            ordinarySession: 4,
            attach: 5,
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
    private var windowsSessionBudget = false
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

    /// Requests waiting for a slot.
    func waitingRequests() -> Int { waiters.count }

    /// Opens a herdr-core link's channel under the long-lived events slot, one
    /// per connection. The slot stays taken until the channel closes.
    func admitCoreLink(
        open: @escaping @Sendable () async throws -> any HeelerSSHAPIChannel
    ) async throws -> any HeelerSSHAPIChannel {
        let lease = try await acquire(.events)
        do {
            return AdmittedCoreLinkChannel(channel: try await open(), lease: lease)
        } catch {
            await lease.release()
            throw error
        }
    }

    /// `admitCoreLink` for a native Windows Host, whose link is one exec session.
    func admitCoreExec(
        open: @escaping @Sendable () async throws -> any WindowsTerminalExecChannel
    ) async throws -> any WindowsTerminalExecChannel {
        try await admitCoreExec(.events, open: open)
    }

    /// One long call's own exec beside that link. A core Host's Terminals ride the
    /// link, so the attach slots are free there: waiting for the events slot would
    /// never end while the link lives, and the session slots are for Chat and reads.
    func admitCoreCallExec(
        open: @escaping @Sendable () async throws -> any WindowsTerminalExecChannel
    ) async throws -> any WindowsTerminalExecChannel {
        try await admitCoreExec(.attach, open: open)
    }

    /// One long exec under an ordinary session slot, as a tmux Host's inventory
    /// loop is (ADR 0043). The slot stays taken until the channel closes, which
    /// leaves three for one-shot commands.
    func admitSessionExec(
        open: @escaping @Sendable () async throws -> any WindowsTerminalExecChannel
    ) async throws -> any WindowsTerminalExecChannel {
        try await admitCoreExec(.ordinarySession, open: open)
    }

    private func admitCoreExec(
        _ channelClass: ChannelClass,
        open: @escaping @Sendable () async throws -> any WindowsTerminalExecChannel
    ) async throws -> any WindowsTerminalExecChannel {
        let lease = try await acquire(channelClass)
        do {
            return AdmittedCoreLinkExec(channel: try await open(), lease: lease)
        } catch {
            await lease.release()
            throw error
        }
    }

    /// Windows RPC and Events are exec sessions as well. Leave one slot of
    /// headroom below OpenSSH's default MaxSessions=10 across all categories.
    func useWindowsSessionBudget() {
        windowsSessionBudget = true
    }

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
        if windowsSessionBudget, counts.connection >= 9 { return false }
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

/// A core link's channel with the slot it was admitted under.
private struct AdmittedCoreLinkChannel: HeelerSSHAPIChannel {
    let channel: any HeelerSSHAPIChannel
    let lease: SSHChannelAdmissionLease

    func write(_ data: Data, timeout: Duration) async throws {
        try await channel.write(data, timeout: timeout)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        try await channel.read(maximumBytes: maximumBytes, timeout: timeout)
    }

    func close(timeout: Duration) async throws {
        do {
            try await channel.close(timeout: timeout)
        } catch {
            await lease.release()
            throw error
        }
        await lease.release()
    }
}

/// A native Windows core link's exec with the slot it was admitted under.
private struct AdmittedCoreLinkExec: WindowsTerminalExecChannel {
    let channel: any WindowsTerminalExecChannel
    let lease: SSHChannelAdmissionLease

    func write(_ data: Data, timeout: Duration) async throws {
        try await channel.write(data, timeout: timeout)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        try await channel.read(maximumBytes: maximumBytes, timeout: timeout)
    }

    func exitStatus(timeout: Duration) async throws -> Int32 {
        try await channel.exitStatus(timeout: timeout)
    }

    func close(timeout: Duration) async throws {
        do {
            try await channel.close(timeout: timeout)
        } catch {
            await lease.release()
            throw error
        }
        await lease.release()
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
