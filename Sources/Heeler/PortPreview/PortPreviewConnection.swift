import Foundation

/// What a port preview uses of the SSH connection it dials for itself: TCP
/// connections to the Host's loopback interface, and one read of what listens
/// there. The connection carries nothing else, and nothing else carries a
/// preview's pages (ADR 0062).
protocol PortPreviewConnection: Sendable {
    /// One TCP connection to `port` on the Host's loopback interface. Throws
    /// a `PortPreviewFailure`.
    func openLoopbackStream(port: UInt16) async throws -> any PortPreviewStream

    /// One bounded exec that prints the Host's listening TCP ports, for
    /// `HostListeningPorts` to read. A Host that is not macOS or Linux
    /// throws `TransportError.hostFeatureUnavailable`.
    func runListeningPortsRead(_ script: Data) async throws -> GitExecResult

    /// Whether the Host still answers on this connection, asked with one
    /// small exec and a short wait.
    func answers() async -> Bool

    var isConnected: Bool { get async }

    func close() async throws
}

/// One TCP connection to the Host's loopback interface.
protocol PortPreviewStream: Sendable {
    /// The next bytes the Host sent, or nil once it closed its side. Waits
    /// for as long as the connection stays quiet.
    func read() async throws -> Data?

    func write(_ data: Data) async throws

    /// Closes the connection. Idempotent, and ends a `read` in progress.
    func close() async
}

/// Why a page's connection could not be made.
enum PortPreviewFailure: Error, Equatable, Sendable {
    /// Nothing on the Host accepted a connection on that port.
    case refused(port: Int)
    /// The Host's SSH server does not open TCP connections for its clients.
    case forwardingDenied
    /// The Host could not be reached, or its connection ended.
    case unreachable(detail: String)

    init(_ error: any Error) {
        if let failure = error as? PortPreviewFailure {
            self = failure
        } else if let error = error as? TransportError {
            self = .unreachable(detail: error.presentation.message)
        } else {
            self = .unreachable(detail: error.localizedDescription)
        }
    }
}

/// The preview's SSH connection to one Host: dialed when a page first needs
/// it, shared by every connection its pages make, and dialed again after it
/// is lost.
///
/// No call here is cancelled once it reaches SSH. A dial runs in a task of
/// its own, and callers are the relay's connection tasks, which end by
/// closing rather than by cancellation: a channel open interrupted part-way
/// costs the whole SSH session when the Host is slow to answer it.
actor PortPreviewLink {
    typealias Connect = @Sendable () async throws -> any PortPreviewConnection

    private let connect: Connect
    private var connection: (any PortPreviewConnection)?
    /// Which dial `connection` came from, so a stale report cannot drop the
    /// connection that replaced it.
    private var generation: UInt64 = 0
    private var dial: Task<any PortPreviewConnection, any Error>?
    private var isClosed = false

    init(connect: @escaping Connect) {
        self.connect = connect
    }

    /// A TCP connection to `port` on the Host's loopback interface, on a new
    /// SSH connection when the one in hand turns out to be gone. Throws a
    /// `PortPreviewFailure`.
    func openStream(port: UInt16) async throws -> any PortPreviewStream {
        var hasRedialed = false
        while true {
            let (connection, generation) = try await live()
            do {
                return try await connection.openLoopbackStream(port: port)
            } catch {
                let failure = PortPreviewFailure(error)
                switch failure {
                case .refused:
                    throw failure
                case .forwardingDenied:
                    // An SSH server reads its settings when a connection
                    // starts. One changed to allow forwarding does so from
                    // the next connection on, so this one goes.
                    drop(generation)
                    throw failure
                case .unreachable:
                    guard !hasRedialed else { throw failure }
                    hasRedialed = true
                    drop(generation)
                }
            }
        }
    }

    /// What listens on the Host, read on the same connection.
    func listeningPorts() async throws -> [HostListeningPort] {
        let (connection, _) = try await live()
        let nonce = HostListeningPorts.makeNonce()
        let result = try await connection.runListeningPortsRead(HostListeningPorts.script(nonce: nonce))
        return try HostListeningPorts.parse(stdout: result.stdout, nonce: nonce)
    }

    /// Makes sure there is a connection, dialing when there is none. Throws
    /// a `PortPreviewFailure`.
    func ensureConnected() async throws {
        _ = try await live()
    }

    /// Whether the connection in hand still answers. One that does not is
    /// dropped, so the next use dials again; having none counts as lost.
    func stillAnswers() async -> Bool {
        guard let connection else { return false }
        let generation = generation
        if await connection.answers() { return true }
        drop(generation)
        return false
    }

    /// Drops the connection when it is one SSH already knows to be gone.
    func dropIfDisconnected() async -> Bool {
        guard let connection else { return true }
        let generation = generation
        if await connection.isConnected { return false }
        drop(generation)
        return true
    }

    /// Ends the link for good: the preview closed.
    func close() {
        isClosed = true
        drop(generation)
    }

    private func live() async throws -> (any PortPreviewConnection, UInt64) {
        while true {
            guard !isClosed else {
                throw PortPreviewFailure.unreachable(detail: String(localized: "The preview is closed."))
            }
            if let connection {
                let generation = generation
                if await connection.isConnected { return (connection, generation) }
                drop(generation)
                continue
            }
            let dialing: Task<any PortPreviewConnection, any Error>
            if let dial {
                dialing = dial
            } else {
                let connect = connect
                dialing = Task { try await connect() }
                dial = dialing
            }
            let dialed: any PortPreviewConnection
            do {
                dialed = try await dialing.value
            } catch {
                if dial == dialing { dial = nil }
                throw PortPreviewFailure(error)
            }
            guard dial == dialing else { continue }
            dial = nil
            if isClosed {
                Task { try? await dialed.close() }
                continue
            }
            generation &+= 1
            connection = dialed
        }
    }

    private func drop(_ dropped: UInt64) {
        guard dropped == generation, let connection else { return }
        self.connection = nil
        Task { try? await connection.close() }
    }
}
