import Foundation
import Network
import Synchronization

/// What carries a preview's pages. For each port a page is opened on, it
/// listens on the same port of this device's loopback interface for as long
/// as the preview is open, and carries every connection made there to that
/// port on the Host's loopback interface over the preview's SSH connection.
/// The page finds the Host's program where its address says it is: a web
/// view on a device connects to `localhost` itself, whatever proxy it was
/// given (ADR 0062).
final class PortPreviewRelay: Sendable {
    /// This device could not listen on the port: something else here holds it.
    struct PortTaken: Error, Equatable {
        let port: Int
    }

    private struct Ports {
        /// Every port asked for, listening or not: what `listenAgain` restores.
        var wanted: Set<UInt16> = []
        var listening: [UInt16: NWListener] = [:]
        var opening: [UInt16: Task<Void, any Error>] = [:]
        var isStopped = false
    }

    private let carrier: Carrier
    private let ports = Mutex(Ports())

    /// `onLinkLost` hears, possibly more than once, that a page's connection
    /// ended because the SSH connection under it did.
    init(link: PortPreviewLink, onLinkLost: @escaping @Sendable () -> Void) {
        carrier = Carrier(link: link, onLinkLost: onLinkLost)
    }

    /// Listens on `port` of this device's loopback interface until the relay
    /// stops. A port already listened on stays as it is. Throws `PortTaken`.
    func listen(on port: UInt16) async throws {
        let opening: Task<Void, any Error>? = ports.withLock { ports in
            guard !ports.isStopped else { return nil }
            ports.wanted.insert(port)
            if ports.listening[port] != nil { return nil }
            if let opening = ports.opening[port] { return opening }
            let opening = Task { try await self.open(port) }
            ports.opening[port] = opening
            return opening
        }
        try await opening?.value
    }

    /// Replaces every listener with a new one. iOS may take a listening
    /// socket from an app it suspended, and does not always say so.
    func listenAgain() async {
        let stale = ports.withLock { ports in
            defer { ports.listening = [:] }
            return (Array(ports.listening.values), ports.wanted)
        }
        for listener in stale.0 {
            listener.cancel()
        }
        for port in stale.1 {
            try? await listen(on: port)
        }
    }

    /// Why the latest connection to `port` could not be made, when that was
    /// moments ago: what a page that just failed to load ran into.
    func recentFailure(port: Int) -> PortPreviewFailure? {
        carrier.recentFailure(port: port)
    }

    /// Stops listening and ends every connection in progress.
    func stop() {
        let listeners = ports.withLock { ports in
            ports.isStopped = true
            defer { ports.listening = [:] }
            return Array(ports.listening.values)
        }
        for listener in listeners {
            listener.cancel()
        }
        carrier.stop()
    }

    deinit {
        stop()
    }

    private func open(_ port: UInt16) async throws {
        let listener = try? await Self.listener(on: port, carrier: carrier)
        let isKept = ports.withLock { ports in
            ports.opening[port] = nil
            guard let listener, !ports.isStopped else { return false }
            ports.listening[port] = listener
            return true
        }
        guard let listener else { throw PortTaken(port: Int(port)) }
        // Stopped while this one was starting: there is no page left to tell.
        if !isKept { listener.cancel() }
    }

    private static let queue = DispatchQueue(label: "dev.bybee.heeler.port-preview-relay")

    private static func listener(on port: UInt16, carrier: Carrier) async throws -> NWListener {
        guard let localPort = NWEndpoint.Port(rawValue: port) else { throw PortTaken(port: Int(port)) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: localPort)
        // A port this app let go of a moment ago is free to take again.
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { carrier.accept($0, port: port) }
        let (states, continuation) = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { state in
            continuation.yield(state)
            if case .cancelled = state { continuation.finish() }
        }
        listener.start(queue: queue)
        for await state in states {
            switch state {
            case .ready:
                return listener
            case .failed(let error), .waiting(let error):
                listener.cancel()
                throw error
            default:
                continue
            }
        }
        listener.cancel()
        throw PortTaken(port: Int(port))
    }

    /// Serves the connections the listeners accept.
    ///
    /// Each one runs in a task that is never cancelled and ends when either
    /// side closes. A channel open cancelled part-way holds the session's
    /// open slot until the Host answers, and costs the whole SSH connection
    /// when the answer takes more than two seconds. A web view drops
    /// requests all the time: when a page navigates away, an open in
    /// progress runs to its end and the channel is closed after.
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
        private let onLinkLost: @Sendable () -> Void
        private let state = Mutex(State())

        init(link: PortPreviewLink, onLinkLost: @escaping @Sendable () -> Void) {
            self.link = link
            self.onLinkLost = onLinkLost
        }

        func accept(_ connection: NWConnection, port: UInt16) {
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
            connection.start(queue: PortPreviewRelay.queue)
            Task {
                await carry(RelayClient(connection: connection), to: port)
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

        /// The web view has its connection before the Host has answered for
        /// the port. A failure closes it with nothing sent, and the page that
        /// results reads the reason back from `recentFailure`.
        private func carry(_ client: RelayClient, to port: UInt16) async {
            let stream: any PortPreviewStream
            do {
                stream = try await link.openStream(port: port)
            } catch {
                let failure = PortPreviewFailure(error)
                state.withLock { $0.failures[Int(port)] = (failure, .now) }
                if case .unreachable = failure { onLinkLost() }
                return
            }
            let isStopped = state.withLock { state in
                state.failures[Int(port)] = nil
                return state.isStopped
            }
            guard !isStopped else {
                await stream.close()
                return
            }
            await pump(client, stream)
        }

        private func pump(_ client: RelayClient, _ stream: any PortPreviewStream) async {
            let upload = Task {
                do {
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
    }
}

/// One accepted connection, as a sequence of awaits.
private struct RelayClient: Sendable {
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
