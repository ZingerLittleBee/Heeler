import Foundation
import HeelerSSH

/// A connected Rex Host (ADR 0049): one SSH connection, and on it a control
/// link to the Rex server's socket. Everything Heeler asks of the server goes
/// over the control link, except terminal data, which takes a data link on a
/// channel of its own to the same socket.
protocol RexTransport: Sendable {
    /// The route that won the dial; nil when there was only ever one way in.
    nonisolated var routeID: UUID? { get }

    /// The socket this transport reached.
    nonisolated var socket: RexSocket { get }

    /// The socket connecting looked up because the Host stored none, for the
    /// Host to keep. Nil when the stored one was used.
    nonisolated var foundSocket: RexSocket? { get }

    /// Whether the SSH connection is up, whatever became of the server.
    var isConnected: Bool { get async }

    /// The control link: the one opened by connecting, or by the last
    /// `reconnectControl`.
    var control: RexControlLink { get async }

    /// Replaces the control link with a new one on a fresh channel. Resuming,
    /// it drops the old link without a close frame, so the server keeps its
    /// client for a while, and the new hello carries the old link's reconnect
    /// token; the new link's `resumed` says whether the server took the client
    /// back. Otherwise it closes the old link and says a plain hello. Either
    /// way, events sent in between are lost, so inventory needs a fresh read.
    /// Throws `TransportError`.
    func reconnectControl(resuming: Bool) async throws -> RexControlLink

    /// Opens one more channel to the same socket, for a data link, under one
    /// of the connection's attach slots until it closes. Throws `TransportError`.
    func openDataChannel() async throws -> any HeelerSSHAPIChannel

    /// Closes the control link with a close frame, so the server forgets this
    /// client at once, then the SSH connection and every channel on it.
    func close() async
}

extension RexTransport {
    /// Replaces the control link, resuming its client.
    func reconnectControl() async throws -> RexControlLink {
        try await reconnectControl(resuming: true)
    }
}

/// What a Rex Host uses of its SSH connection. `HeelerSSHTransport` is the
/// production one; tests script one.
protocol RexHostConnection: ServerKindDetectionConnection {
    nonisolated var routeID: UUID? { get }

    var isConnected: Bool { get async }

    /// A channel to the socket under the connection's one events slot, for
    /// the control link. SSH refusing it throws `.streamLocalOpenFailed`.
    func openRexControlChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel

    /// A channel to the socket under an attach slot, for a data link. SSH
    /// refusing it throws `.streamLocalOpenFailed`.
    func openRexDataChannel(socketPath: String) async throws -> any HeelerSSHAPIChannel

    /// Runs a `RexSocketCheck` script in one bounded exec.
    func runRexSocketCheck(_ script: Data) async throws -> GitExecResult
}

/// A Rex Host over SSH: direct-streamlocal channels to the server's socket.
/// It never runs `rex`, and connecting starts no server.
actor RexSSHTransport: RexTransport {
    nonisolated let routeID: UUID?
    nonisolated let socket: RexSocket
    nonisolated let foundSocket: RexSocket?
    private nonisolated let connection: any RexHostConnection
    private let options: RexControlLink.Options
    private let sleep: RexControlLink.Sleep
    private let nonce: @Sendable () -> String
    private(set) var control: RexControlLink
    private var reconnecting: Task<RexControlLink, any Error>?

    private init(
        connection: any RexHostConnection, socket: RexSocket, foundSocket: RexSocket?, control: RexControlLink,
        options: RexControlLink.Options, sleep: @escaping RexControlLink.Sleep, nonce: @escaping @Sendable () -> String
    ) {
        routeID = connection.routeID
        self.connection = connection
        self.socket = socket
        self.foundSocket = foundSocket
        self.control = control
        self.options = options
        self.sleep = sleep
        self.nonce = nonce
    }

    /// Reaches `socket`, or the socket a lookup finds when it is nil, and says
    /// hello, with `previous`'s reconnect token when there is one, so a client
    /// whose SSH connection went down can be taken back over a new one. Owns
    /// `connection` from here: when connecting fails, it is closed. Throws
    /// `TransportError`.
    static func connect(
        over connection: any RexHostConnection,
        socket stored: RexSocket?,
        resuming previous: RexControlLink? = nil,
        options: RexControlLink.Options = RexControlLink.Options(),
        sleep: @escaping RexControlLink.Sleep = { try await Task.sleep(for: $0) },
        nonce: @escaping @Sendable () -> String = { UUID().uuidString }
    ) async throws -> RexSSHTransport {
        do {
            let socket: RexSocket
            if let stored {
                socket = stored
            } else {
                socket = try await lookUp(over: connection, nonce: nonce())
            }
            let control = try await openControl(
                over: connection, socket: socket, resuming: previous, options: options, sleep: sleep, nonce: nonce)
            return RexSSHTransport(
                connection: connection, socket: socket, foundSocket: stored == nil ? socket : nil, control: control,
                options: options, sleep: sleep, nonce: nonce)
        } catch {
            try? await connection.close()
            throw Self.transportError(error)
        }
    }

    var isConnected: Bool {
        get async { await connection.isConnected }
    }

    func reconnectControl(resuming: Bool) async throws -> RexControlLink {
        if let reconnecting { return try await reconnecting.value }
        let previous = control
        let task = Task { [connection, socket, options, sleep, nonce] in
            // The old link's channel holds the events slot until it closes.
            if resuming {
                await previous.disconnect()
            } else {
                await previous.close()
            }
            return try await Self.openControl(
                over: connection, socket: socket, resuming: resuming ? previous : nil, options: options, sleep: sleep,
                nonce: nonce)
        }
        reconnecting = task
        defer { reconnecting = nil }
        do {
            let link = try await task.value
            control = link
            return link
        } catch {
            throw Self.transportError(error)
        }
    }

    func openDataChannel() async throws -> any HeelerSSHAPIChannel {
        do {
            return try await connection.openRexDataChannel(socketPath: socket.path)
        } catch TransportError.streamLocalOpenFailed {
            throw await Self.refusal(of: socket, over: connection, nonce: nonce())
        }
    }

    func close() async {
        await control.close()
        try? await connection.close()
    }

    // MARK: Connecting

    /// A fresh look for the socket, as detection makes, for a Host that
    /// stores none.
    private static func lookUp(over connection: any RexHostConnection, nonce: String) async throws -> RexSocket {
        let finding: ServerKindDetection.RexFinding
        do {
            finding = try await RexProbe.run(over: connection, nonce: nonce)
        } catch TransportError.malformedResponse {
            // The probe's exec failed: as unreadable as output it cannot parse.
            throw TransportError.rexLookupFailed(
                reason: String(localized: "Heeler could not read whether Rex is on this Host."))
        }
        switch finding {
        case .socketFound(let path):
            guard let socket = RexSocket(path: path) else {
                throw TransportError.rexLookupFailed(
                    reason: String(localized: "The Rex socket found has a path Heeler cannot use."))
            }
            return socket
        case .notInstalled:
            throw TransportError.rexNotInstalled
        case .notRunning:
            throw TransportError.rexServerNotRunning(socketPath: nil)
        case .notUsable(let path):
            throw TransportError.rexAccountRefused(socketPath: path)
        case .unsupported:
            throw TransportError.rexLookupFailed(reason: String(localized: "Heeler finds Rex on macOS and Linux Hosts only."))
        case .unreadable:
            throw TransportError.rexLookupFailed(
                reason: String(localized: "Heeler could not read whether Rex is on this Host."))
        }
    }

    private static func openControl(
        over connection: any RexHostConnection, socket: RexSocket, resuming previous: RexControlLink?,
        options: RexControlLink.Options, sleep: @escaping RexControlLink.Sleep, nonce: @Sendable () -> String
    ) async throws -> RexControlLink {
        let channel: any HeelerSSHAPIChannel
        do {
            channel = try await connection.openRexControlChannel(socketPath: socket.path)
        } catch TransportError.streamLocalOpenFailed {
            throw await refusal(of: socket, over: connection, nonce: nonce())
        }
        return try await RexControlLink.open(over: channel, resuming: previous, options: options, sleep: sleep)
    }

    /// Why SSH refused the socket, as far as the Host can say.
    private static func refusal(
        of socket: RexSocket, over connection: any RexHostConnection, nonce: String
    ) async -> TransportError {
        var answer = RexSocketCheck.Answer.unknown
        if let script = RexSocketCheck.script(socketPath: socket.path, nonce: nonce),
            let result = try? await connection.runRexSocketCheck(Data(script.utf8)), result.exitStatus == 0
        {
            answer = RexSocketCheck.parse(stdout: result.stdout, nonce: nonce)
        }
        switch answer {
        case .missing, .notListening: return .rexServerNotRunning(socketPath: socket.path)
        case .listening: return .rexForwardingRefused(socketPath: socket.path)
        case .unknown: return .rexSocketUnreachable(socketPath: socket.path)
        }
    }

    private static func transportError(_ error: any Error) -> any Error {
        switch error {
        case let error as RexControlError: TransportError(rexControl: error)
        case is CancellationError: TransportError.cancelled
        default: error
        }
    }
}

extension TransportError {
    /// A control link's failure as the user reads it. Rex's own words in an
    /// error response pass through as they came.
    init(rexControl error: RexControlError) {
        switch error {
        case .upgradeRefused(let status) where status == 403:
            self = .rexAccountRefused(socketPath: nil)
        case .upgradeRefused(let status):
            self = .channelFailed(detail: String(localized: "Rex refused the connection with HTTP status \(status)."))
        case .upgradeFailed:
            self = .channelFailed(detail: String(localized: "Rex did not finish opening the connection."))
        case .welcomeTimedOut, .deadlineExceeded:
            self = .timedOut
        case .unsupportedVersion(let offer):
            self = .rexUnsupportedRevision(offered: offer.newestRevision)
        case .server(let error):
            self = .rexRejected(code: error.code, message: error.message)
        case .requestTooLarge:
            self = .channelFailed(detail: String(localized: "The request was larger than Rex accepts, so it was not sent."))
        case .requestUnencodable:
            self = .channelFailed(detail: String(localized: "Heeler could not write the request to Rex."))
        case .unreadableResult:
            self = .rexAnswerUnreadable(String(localized: "Rex's answer could not be read."))
        case .linkEnded(let reason):
            self = .channelFailed(detail: Self.rexLinkEndedDetail(reason))
        }
    }

    /// Why a control link ended, where the user can tell one ending from
    /// another. Each is retried: the next link reads the Host again.
    private static func rexLinkEndedDetail(_ reason: RexControlEnding) -> String {
        switch reason {
        case .droppedByServer:
            String(localized: "Rex dropped the connection because too many events were waiting for Heeler.")
        case .messageTooBig:
            String(localized:
                "A message was too large for the connection to Rex. If this keeps happening, check the Rex version on the Host.")
        case .protocolFailure:
            String(localized:
                "Rex and Heeler did not agree on the connection's protocol. If this keeps happening, check the Rex version on the Host.")
        case .closedHere, .serverWentAway, .linkLost:
            String(localized: "The connection to Rex ended.")
        }
    }
}
