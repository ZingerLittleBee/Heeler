import Foundation
import Network
import Synchronization

/// The SOCKS5 proxy a preview's web view sends `localhost` to. It listens on
/// this device's loopback interface for as long as the preview is open,
/// admits only a client that presents the credentials made for this preview,
/// and carries each connection to the same port on the Host's loopback
/// interface over the preview's SSH connection. A request for any other
/// place is refused: this is not a way onto the Host's network (ADR 0062).
final class PortPreviewProxy: Sendable {
    /// Where the web view finds the proxy, and what it presents there.
    struct Access: Sendable, Equatable {
        let port: UInt16
        let username: String
        let password: String
    }

    let access: Access
    private let listener: NWListener
    private let carrier: Carrier

    private init(access: Access, listener: NWListener, carrier: Carrier) {
        self.access = access
        self.listener = listener
        self.carrier = carrier
    }

    /// Starts listening. `onLinkLost` hears, possibly more than once, that a
    /// page's connection ended because the SSH connection under it did.
    static func start(
        link: PortPreviewLink, onLinkLost: @escaping @Sendable () -> Void
    ) async throws -> PortPreviewProxy {
        let username = randomToken()
        let password = randomToken()
        let carrier = Carrier(
            link: link, username: Array(username.utf8), password: Array(password.utf8), onLinkLost: onLinkLost)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { carrier.accept($0) }
        let (states, continuation) = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { state in
            continuation.yield(state)
            if case .cancelled = state { continuation.finish() }
        }
        listener.start(queue: queue)
        for await state in states {
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else { break }
                return PortPreviewProxy(
                    access: Access(port: port, username: username, password: password),
                    listener: listener, carrier: carrier)
            case .failed(let error), .waiting(let error):
                listener.cancel()
                throw error
            default:
                continue
            }
        }
        listener.cancel()
        throw CocoaError(.featureUnsupported)
    }

    /// Why the latest connection to `port` could not be made, when that was
    /// moments ago: what a page that just failed to load ran into.
    func recentFailure(port: Int) -> PortPreviewFailure? {
        carrier.recentFailure(port: port)
    }

    /// Stops listening and ends every connection in progress.
    func stop() {
        listener.cancel()
        carrier.stop()
    }

    deinit {
        listener.cancel()
        carrier.stop()
    }

    private static let queue = DispatchQueue(label: "dev.bybee.heeler.port-preview-proxy")

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    /// Serves the connections the listener accepts.
    ///
    /// Each one runs in a task that is never cancelled and ends when either
    /// side closes. A channel open that is cancelled part-way costs the whole
    /// SSH connection, and a web view drops requests all the time: when a
    /// page navigates away, an open in progress runs to its end and the
    /// channel is closed after.
    private final class Carrier: Sendable {
        /// More than a page opens at once to one origin, by a wide margin.
        private static let clientCap = 64
        /// How long a refusal stays the explanation for a page that failed.
        private static let failureMemory = Duration.seconds(15)

        private struct State {
            var clients: [ObjectIdentifier: NWConnection] = [:]
            var failures: [Int: (failure: PortPreviewFailure, at: ContinuousClock.Instant)] = [:]
            var isStopped = false
        }

        private let link: PortPreviewLink
        private let username: [UInt8]
        private let password: [UInt8]
        private let onLinkLost: @Sendable () -> Void
        private let state = Mutex(State())

        init(link: PortPreviewLink, username: [UInt8], password: [UInt8], onLinkLost: @escaping @Sendable () -> Void) {
            self.link = link
            self.username = username
            self.password = password
            self.onLinkLost = onLinkLost
        }

        func accept(_ connection: NWConnection) {
            let id = ObjectIdentifier(connection)
            let isAdmitted = state.withLock { state in
                guard !state.isStopped, state.clients.count < Self.clientCap else { return false }
                state.clients[id] = connection
                return true
            }
            guard isAdmitted else {
                connection.cancel()
                return
            }
            connection.start(queue: PortPreviewProxy.queue)
            Task {
                await carry(ProxyClient(connection: connection))
                connection.cancel()
                state.withLock { _ = $0.clients.removeValue(forKey: id) }
            }
        }

        func recentFailure(port: Int) -> PortPreviewFailure? {
            state.withLock { state in
                guard let noted = state.failures[port],
                      ContinuousClock.now - noted.at < Self.failureMemory
                else { return nil }
                return noted.failure
            }
        }

        func stop() {
            let clients = state.withLock { state in
                state.isStopped = true
                defer { state.clients = [:] }
                return Array(state.clients.values)
            }
            for client in clients {
                client.cancel()
            }
        }

        private func carry(_ client: ProxyClient) async {
            var received: [UInt8] = []
            let port: UInt16
            do {
                let methods = try await Self.next(SOCKS5.greeting, from: client, received: &received)
                guard methods.contains(SOCKS5.usernamePasswordMethod) else {
                    try await client.send(SOCKS5.methodSelection(SOCKS5.noAcceptableMethod))
                    return
                }
                try await client.send(SOCKS5.methodSelection(SOCKS5.usernamePasswordMethod))
                let credentials = try await Self.next(SOCKS5.credentials, from: client, received: &received)
                let isAccepted = credentials.matches(username: username, password: password)
                try await client.send(SOCKS5.authenticationStatus(accepted: isAccepted))
                guard isAccepted else { return }
                let request = try await Self.next(SOCKS5.request, from: client, received: &received)
                switch request.loopbackPort {
                case .success(let asked):
                    port = asked
                case .failure(let refusal):
                    try await client.send(SOCKS5.reply(refusal.reply))
                    return
                }
            } catch {
                return
            }

            let stream: any PortPreviewStream
            do {
                stream = try await link.openStream(port: port)
            } catch {
                let failure = PortPreviewFailure(error)
                state.withLock { $0.failures[Int(port)] = (failure, .now) }
                try? await client.send(SOCKS5.reply(failure.reply))
                if case .unreachable = failure { onLinkLost() }
                return
            }
            let isStopped = state.withLock { state in
                state.failures[Int(port)] = nil
                return state.isStopped
            }
            guard !isStopped, (try? await client.send(SOCKS5.reply(.succeeded))) != nil else {
                await stream.close()
                return
            }
            await pump(client, stream, pipelined: received)
        }

        private func pump(_ client: ProxyClient, _ stream: any PortPreviewStream, pipelined: [UInt8]) async {
            let upload = Task {
                do {
                    if !pipelined.isEmpty { try await stream.write(Data(pipelined)) }
                    while let data = try await client.receive() {
                        try await stream.write(data)
                    }
                } catch {}
                // The web view is done with this connection, or the Host
                // stopped taking it: either way no reply is worth waiting for.
                await stream.close()
            }
            var endedByFailure = false
            do {
                while let data = try await stream.read() {
                    try await client.send(data)
                }
                await client.finish()
            } catch {
                endedByFailure = true
            }
            client.close()
            await stream.close()
            await upload.value
            if endedByFailure, await link.dropIfDisconnected() {
                onLinkLost()
            }
        }

        /// Reads until `parse` has a whole message, and takes it off the front.
        private static func next<Value: Sendable & Equatable>(
            _ parse: ([UInt8]) -> SOCKS5.Step<Value>, from client: ProxyClient, received: inout [UInt8]
        ) async throws -> Value {
            while true {
                switch parse(received) {
                case .parsed(let value, let consumed):
                    received.removeFirst(consumed)
                    return value
                case .malformed:
                    throw SOCKS5.Refusal(reply: .generalFailure)
                case .incomplete:
                    // A handshake is a few hundred bytes at most.
                    guard received.count < 1024, let data = try await client.receive() else {
                        throw SOCKS5.Refusal(reply: .generalFailure)
                    }
                    received.append(contentsOf: data)
                }
            }
        }
    }
}

extension PortPreviewFailure {
    /// What the proxy tells the web view. The page that results shows this
    /// failure itself, read back from the proxy, not the reply's wording.
    fileprivate var reply: SOCKS5.Reply {
        switch self {
        case .refused: .connectionRefused
        case .forwardingDenied: .notAllowed
        case .unreachable: .hostUnreachable
        }
    }
}

/// One accepted connection, as a sequence of awaits.
private struct ProxyClient: Sendable {
    let connection: NWConnection

    /// The next bytes, or nil once the web view closed its side.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// Tells the web view the Host has no more to send.
    func finish() async {
        await withCheckedContinuation { continuation in
            connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func close() {
        connection.cancel()
    }
}
