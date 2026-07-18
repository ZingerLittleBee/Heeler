import Foundation
import Synchronization

/// In-test fake herdr server: a Unix-socket listener speaking herdr's wire
/// format — read one request line, write the scripted reply lines, close.
/// Real sshd and real socat sit in front of it in e2e tests; the only faked
/// piece is herdr itself.
final class FakeHerdrServer: Sendable {
    struct ReceivedRequest: Sendable, Equatable {
        let id: String
        let method: String
    }

    /// Returns the NDJSON lines to write back, without trailing newlines.
    /// One line for a plain response; several lines model the
    /// ack-then-event-lines shape of subscription replies.
    typealias Script = @Sendable (ReceivedRequest) -> [String]

    enum ServerError: Error {
        case socketSetupFailed(step: String, errno: Int32)
    }

    let socketPath: String
    private let listenerFD: Int32
    private let script: Script
    private let state = StateBox()

    /// Reference wrapper because Mutex itself is noncopyable and needs to be
    /// shared with the accept-loop thread.
    private final class StateBox: Sendable {
        let mutex = Mutex(State())
    }

    private struct State {
        var requests: [ReceivedRequest] = []
        var connections = 0
        var stopped = false
    }

    var receivedRequests: [ReceivedRequest] { state.mutex.withLock { $0.requests } }
    /// Number of accepted connections; herdr serves one request per
    /// connection, so this equals the number of exec+socat channels opened.
    var connectionCount: Int { state.mutex.withLock { $0.connections } }

    init(script: @escaping Script) throws {
        // Short path: sun_path caps at 104 bytes and the simulator's
        // NSTemporaryDirectory is far longer than that.
        self.socketPath = "/tmp/herdr-fake-\(UUID().uuidString.prefix(8)).sock"
        self.script = script

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketSetupFailed(step: "socket", errno: errno) }
        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.socketSetupFailed(step: "bind", errno: errno)
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw ServerError.socketSetupFailed(step: "listen", errno: errno)
        }
        self.listenerFD = fd

        let thread = Thread { [listenerFD = fd, script, state] in
            while true {
                let connection = accept(listenerFD, nil, nil)
                guard connection >= 0 else { break }
                if state.mutex.withLock({ $0.stopped }) {
                    close(connection)
                    break
                }
                Self.handle(connection: connection, script: script, state: state)
            }
        }
        thread.name = "FakeHerdrServer(\(socketPath))"
        thread.start()
    }

    /// Idempotent. Wakes the accept loop with a dummy connection: on macOS,
    /// closing a listening socket does not reliably unblock accept(2).
    func stop() {
        let alreadyStopped = state.mutex.withLock { state in
            defer { state.stopped = true }
            return state.stopped
        }
        guard !alreadyStopped else { return }

        let wakeFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if wakeFD >= 0 {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = socketPath.utf8CString
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
            }
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(wakeFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            close(wakeFD)
        }
        close(listenerFD)
        unlink(socketPath)
    }

    deinit {
        stop()
    }

    private static func handle(connection: Int32, script: Script, state: StateBox) {
        defer { close(connection) }
        state.mutex.withLock { $0.connections += 1 }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !received.contains(0x0A) {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            received.append(contentsOf: buffer[0..<count])
        }

        guard
            let newline = received.firstIndex(of: 0x0A),
            let object = try? JSONSerialization.jsonObject(with: received.prefix(upTo: newline)),
            let fields = object as? [String: Any],
            let id = fields["id"] as? String,
            let method = fields["method"] as? String
        else { return }

        let request = ReceivedRequest(id: id, method: method)
        state.mutex.withLock { $0.requests.append(request) }

        for line in script(request) {
            writeAll(connection, bytes: Array((line + "\n").utf8))
        }
    }

    private static func writeAll(_ fd: Int32, bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            guard written > 0 else { return }
            offset += written
        }
    }
}
