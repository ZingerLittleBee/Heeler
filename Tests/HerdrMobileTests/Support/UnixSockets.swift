import Foundation

/// Unix-domain socket plumbing shared by the e2e support fixtures.
enum UnixSockets {
    enum SetupError: Error {
        case failed(step: String, errno: Int32)
    }

    /// Runs `body` with a `sockaddr` pointer for a Unix socket at `path`.
    /// Traps if the path exceeds the 104-byte `sun_path` limit — test
    /// sockets live under short paths for a reason.
    static func withSockaddr<R>(
        path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) -> R {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// A Unix socket file with no listener behind it — exactly the artifact a
/// stopped herdr server leaves on disk. Connecting to it yields ECONNREFUSED.
struct StaleUnixSocket {
    let path: String

    init() throws {
        path = "/tmp/herdr-stale-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSockets.SetupError.failed(step: "socket", errno: errno) }
        // Bind creates the file; closing without listening or unlinking
        // leaves it stale.
        let bindResult = UnixSockets.withSockaddr(path: path) { bind(fd, $0, $1) }
        close(fd)
        guard bindResult == 0 else {
            throw UnixSockets.SetupError.failed(step: "bind", errno: errno)
        }
    }

    func remove() {
        unlink(path)
    }
}
