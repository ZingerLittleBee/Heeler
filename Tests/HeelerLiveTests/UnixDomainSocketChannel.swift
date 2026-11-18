import Darwin
import Foundation
import HeelerSSH

@testable import Heeler

/// A local Unix-domain socket standing in for an SSH direct-streamlocal
/// channel, so a live test can run the app's WebSocket code against a server
/// on this Mac. It only connects to a socket that already exists; nothing
/// here listens.
final class UnixDomainSocketChannel: HeelerSSHAPIChannel, @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var isShutDown = false

    init(path: String) throws {
        descriptor = try Self.connected(to: path)
    }

    deinit {
        Darwin.close(descriptor)
    }

    func write(_ data: Data, timeout: Duration) async throws {
        let descriptor = descriptor
        try await Self.blocking {
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Self.posixError()
                    }
                    offset += written
                }
            }
        }
    }

    /// Waits up to `timeout` for bytes, then throws `SSHError.timedOut` as the
    /// SSH channel's read poll does.
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        let descriptor = descriptor
        let milliseconds = Int32(clamping: timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return try await Self.blocking {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, milliseconds)
            if ready == 0 { throw SSHError.timedOut }
            if ready < 0 {
                if errno == EINTR { throw SSHError.timedOut }
                throw Self.posixError()
            }
            var buffer = [UInt8](repeating: 0, count: maximumBytes)
            let count = Darwin.read(descriptor, &buffer, maximumBytes)
            if count < 0 { throw Self.posixError() }
            return count == 0 ? nil : Data(buffer[0..<count])
        }
    }

    /// Shuts the socket down, which ends a read that waits. The descriptor
    /// itself closes with the object, so it is never reused under a reader.
    func close(timeout: Duration) async throws {
        lock.withLock {
            guard !isShutDown else { return }
            isShutDown = true
            shutdown(descriptor, SHUT_RDWR)
        }
    }

    private static func connected(to path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = posixError()
            Darwin.close(descriptor)
            throw error
        }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
