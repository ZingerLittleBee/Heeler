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
        /// The request's params object re-serialized with sorted keys, so
        /// tests can assert exact wire shapes; "" when params are absent.
        let params: String
    }

    /// How one connection answers its request. `nil` models a hung herdr:
    /// the connection is held open without a response until the peer goes
    /// away.
    enum Response: Sendable, ExpressibleByArrayLiteral {
        /// Write these NDJSON lines (no trailing newlines) and close — the
        /// one-request-per-connection RPC shape. Array literals convert.
        case lines([String])
        /// Subscription shape: run the steps, then hold the connection open
        /// until the peer closes it — `events.subscribe` never closes
        /// server-side.
        case streamThenHold([Step])

        enum Step: Sendable {
            case write(String)
            case pause(Duration)
        }

        init(arrayLiteral elements: String...) {
            self = .lines(elements)
        }
    }

    typealias Script = @Sendable (ReceivedRequest) -> Response?

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
        var closedConnections = 0
        var stopped = false
    }

    var receivedRequests: [ReceivedRequest] { state.mutex.withLock { $0.requests } }
    /// Number of accepted connections; herdr serves one request per
    /// connection, so this equals the number of exec+socat channels opened.
    var connectionCount: Int { state.mutex.withLock { $0.connections } }
    /// Number of connections that have ended. A held-open (`nil`-scripted)
    /// connection only ends when its socat dies, so this observes the
    /// transport closing an exec channel from the server side.
    var closedConnectionCount: Int { state.mutex.withLock { $0.closedConnections } }

    /// Polls until `condition` holds; false if `timeout` elapses first.
    func wait(
        for condition: @Sendable (FakeHerdrServer) -> Bool,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(self) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(self)
    }

    /// `socketPath` defaults to a fresh path under /tmp: sun_path caps at 104
    /// bytes and the simulator's NSTemporaryDirectory is far longer than
    /// that. Pass an explicit path to model a real herdr socket layout.
    init(socketPath: String? = nil, script: @escaping Script) throws {
        self.socketPath = socketPath ?? "/tmp/herdr-fake-\(UUID().uuidString.prefix(8)).sock"
        self.script = script

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketSetupFailed(step: "socket", errno: errno) }
        unlink(self.socketPath)

        let bindResult = UnixSockets.withSockaddr(path: self.socketPath) { bind(fd, $0, $1) }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.socketSetupFailed(step: "bind", errno: errno)
        }
        // Backlog sized for the transport's concurrent-channel bound plus
        // slack; the accept loop drains fast, but a burst must never bounce
        // off the queue and masquerade as "connection refused".
        guard listen(fd, 32) == 0 else {
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
                // One thread per connection: a held-open (`nil`-scripted)
                // connection must not block the accept loop.
                Thread {
                    Self.handle(connection: connection, script: script, state: state)
                }.start()
            }
        }
        thread.name = "FakeHerdrServer(\(self.socketPath))"
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
            _ = UnixSockets.withSockaddr(path: socketPath) { connect(wakeFD, $0, $1) }
            close(wakeFD)
        }
        close(listenerFD)
        unlink(socketPath)
    }

    deinit {
        stop()
    }

    private static func handle(connection: Int32, script: Script, state: StateBox) {
        defer {
            close(connection)
            state.mutex.withLock { $0.closedConnections += 1 }
        }
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

        let params: String
        if let object = fields["params"],
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        {
            params = String(decoding: data, as: UTF8.self)
        } else {
            params = ""
        }

        let request = ReceivedRequest(id: id, method: method, params: params)
        state.mutex.withLock { $0.requests.append(request) }

        switch script(request) {
        case nil:
            // Hung herdr: hold the connection open until the peer's socat
            // dies, which is how an explicit exec channel close reaches us.
            while read(connection, &buffer, buffer.count) > 0 {}
        case .lines(let lines):
            for line in lines {
                writeAll(connection, bytes: Array((line + "\n").utf8))
            }
        case .streamThenHold(let steps):
            for step in steps {
                switch step {
                case .write(let line):
                    writeAll(connection, bytes: Array((line + "\n").utf8))
                case .pause(let duration):
                    Thread.sleep(forTimeInterval: duration.timeInterval)
                }
            }
            while read(connection, &buffer, buffer.count) > 0 {}
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

extension Duration {
    /// Seconds as a TimeInterval, for Thread.sleep in the blocking handler.
    fileprivate var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
