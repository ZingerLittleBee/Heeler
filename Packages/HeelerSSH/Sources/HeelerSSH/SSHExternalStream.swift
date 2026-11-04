import Darwin
import Foundation

/// A connected byte stream to an SSH server that something outside this
/// package opened — an in-process overlay network node, for example. The
/// package only ever sees one connected, stream-oriented descriptor: the
/// session driver takes it for the handshake and closes it with the session.
///
/// `release` runs once the session no longer needs the stream (close, abort,
/// or a failed handshake) so the provider can stop whatever pumps the other
/// end. It must not block; long work belongs in the provider's own task.
public final class SSHExternalStream: SSHByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var release: (@Sendable () -> Void)?

    /// Takes ownership of `descriptor`, which must already be connected. It
    /// is switched to non-blocking mode with `SO_NOSIGPIPE`, as libssh2 and
    /// the session driver expect. Throws, closing the descriptor, if either
    /// option cannot be set.
    public init(descriptor: Int32, release: (@Sendable () -> Void)? = nil) throws {
        guard descriptor >= 0 else { throw SSHError.connectionFailed }
        var enabled: Int32 = 1
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard
            flags >= 0,
            fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            Darwin.close(descriptor)
            release?()
            throw SSHError.connectionFailed
        }
        self.descriptor = descriptor
        self.release = release
    }

    func takeDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw SSHError.connectionInvalidated }
        let taken = descriptor
        descriptor = -1
        return taken
    }

    func close(timeout: Duration) async throws {
        abort()
    }

    func abort() {
        lock.lock()
        let unused = descriptor
        descriptor = -1
        let release = release
        self.release = nil
        lock.unlock()
        if unused >= 0 { Darwin.close(unused) }
        release?()
    }

    deinit {
        abort()
    }
}
