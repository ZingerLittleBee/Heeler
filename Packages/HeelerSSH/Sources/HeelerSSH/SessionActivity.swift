import CHeelerSSHSupport
import CLibSSH2
import Darwin
import Foundation

/// Releases the operations blocked on one libssh2 session as soon as another
/// operation has taken bytes off the socket they share.
///
/// libssh2 multiplexes every channel over a single socket and buffers whatever
/// it decrypts, so an operation reading its own channel also consumes the
/// packets the other channels are blocked on. The socket is then empty and has
/// no edge left to report: a wait armed purely on socket readiness sleeps out
/// its whole deadline on bytes that already arrived. Every wait therefore
/// captures the session's receive count before it lets another operation run,
/// and is released the moment that count moves.
///
/// Counting receives rather than signalling on every handover is what keeps
/// this from becoming a spin. An operation that retries and finds nothing
/// takes no bytes off the socket, so it wakes nobody, and the number of
/// wakeups stays bounded by the traffic that actually arrived.
final class SessionActivity: @unchecked Sendable {
    private struct Registration {
        let waiter: DispatchWaiter
        let token: UInt64
    }

    private let lock = NSLock()
    private var receiveCount: UInt64 = 0
    private var registrations: [ObjectIdentifier: Registration] = [:]

    /// Records the current receive count so a later wait can tell whether the
    /// session moved while it was arming. Callers must capture this before
    /// they release the session to the next operation.
    func watch() -> SessionActivityWatch {
        SessionActivityWatch(activity: self, token: lock.withLock { receiveCount })
    }

    /// Installs the counting receive callback on `session`.
    ///
    /// The pointer handed to libssh2 is unretained: the session belongs to the
    /// driver that owns this object, so libssh2 can never receive on it after
    /// the owner is gone.
    ///
    /// This claims the session's single user abstract slot. Any future use of
    /// the abstract has to share this pointer rather than overwrite it, or the
    /// receive callback will reinterpret whatever replaced it.
    func install(on session: OpaquePointer) {
        guard let abstract = libssh2_session_abstract(session) else { return }
        abstract.pointee = Unmanaged.passUnretained(self).toOpaque()
        heeler_libssh2_set_receive_callback(session, sessionReceive)
    }

    /// Parks `waiter` until the receive count moves past `token`, and reports
    /// whether it did so. False means bytes already moved, so the caller must
    /// retry immediately rather than wait for an edge that will never come.
    func register(_ waiter: DispatchWaiter, since token: UInt64) -> Bool {
        lock.withLock {
            guard receiveCount == token else { return false }
            registrations[ObjectIdentifier(waiter)] = Registration(
                waiter: waiter,
                token: token)
            return true
        }
    }

    func unregister(_ waiter: DispatchWaiter) {
        lock.withLock { registrations.removeValue(forKey: ObjectIdentifier(waiter)) }
    }

    /// Releases every wait armed before the most recent receive. The driver
    /// calls this as it hands the session on, which is the first moment a
    /// released wait can do anything with what it learns.
    func wakeStaleWaiters() {
        let stale: [DispatchWaiter] = lock.withLock {
            let current = receiveCount
            let staleEntries = registrations.filter { $0.value.token != current }
            for key in staleEntries.keys { registrations.removeValue(forKey: key) }
            return staleEntries.values.map(\.waiter)
        }
        for waiter in stale { waiter.finish(.success(())) }
    }

    fileprivate func recordReceive() {
        lock.withLock { receiveCount &+= 1 }
    }
}

/// The receive count one operation observed, paired with the session it
/// observed it on.
struct SessionActivityWatch: Sendable {
    let activity: SessionActivity
    let token: UInt64

    /// Reports false when the session already moved on, meaning the caller
    /// must retry now instead of waiting.
    func register(_ waiter: DispatchWaiter) -> Bool {
        activity.register(waiter, since: token)
    }

    func unregister(_ waiter: DispatchWaiter) {
        activity.unregister(waiter)
    }
}

/// libssh2's own receive, plus a note that this session took bytes off the
/// socket. Blocked operations read that note instead of waiting for a socket
/// edge that a concurrent operation may already have consumed.
private func sessionReceive(
    _ socket: libssh2_socket_t,
    _ buffer: UnsafeMutableRawPointer?,
    _ length: Int,
    _ flags: Int32,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int {
    let received = Darwin.recv(socket, buffer, length, flags)
    guard received >= 0 else {
        // libssh2 reads these as negated errno values, not as its own codes.
        let code = errno
        // EINTR reports as EAGAIN, exactly as upstream's `_libssh2_recv` does:
        // recv leaves its arguments untouched on EINTR but bytes may still be
        // waiting, and -EAGAIN is the only value libssh2's callers retry on.
        // Anything else becomes a fatal LIBSSH2_ERROR_SOCKET_RECV.
        if code == EINTR { return -Int(EAGAIN) }
        if code == EAGAIN || code == EWOULDBLOCK { return -Int(EAGAIN) }
        return -Int(code)
    }
    if received > 0, let context = abstract?.pointee {
        Unmanaged<SessionActivity>.fromOpaque(context).takeUnretainedValue().recordReceive()
    }
    return received
}
