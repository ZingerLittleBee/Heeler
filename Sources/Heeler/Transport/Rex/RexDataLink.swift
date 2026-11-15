import Foundation
import HeelerSSH

/// How a data link ended, and what may follow it.
enum RexDataEnding: Sendable, Equatable {
    /// This side dropped the connection with no close frame, by `disconnect`
    /// or a cancelled receive. The stream waits on the server for a resume.
    case disconnectedHere
    /// This side closed with 1000, which ends the stream on the server.
    case closedHere
    /// 4000: the block is gone, and so is its stream.
    case blockClosed
    /// The server ended the stream (1001, `data provider canceled`); one
    /// cause is the control client that asked for it going away. Only a
    /// fresh ticket, from a control link attached to the session, opens
    /// another.
    case providerCanceled
    /// The server answered the handshake with a REJECT.
    case refused(RexDataRefusal)
    /// Any other close code: 1000 for a stream that is over, 1001 for a
    /// client that went quiet on pings, 1008 or 1011 for a data source that
    /// is missing or broken.
    case serverWentAway(code: UInt16)
    /// 1013: this stream cannot go on and a new one must start, as when the
    /// server could not hold all the output that came while this side was
    /// away.
    case tryAgainLater
    /// One side broke the protocol, or the handshake's answer was unreadable.
    case protocolFailure
    /// The connection ended with no close frame, or went silent.
    case linkLost

    enum Recovery: Sendable, Equatable {
        /// A RESUME on a new connection may continue the stream.
        case resume
        /// Only a new stream, from a new ticket and a HELLO, goes on.
        case startOver
        /// Nothing goes on.
        case stop
    }

    /// The way on after this ending. Rex (0.1.0-preview.14, API revision 12)
    /// keeps a stream whose connection dropped for its retention time, and
    /// documents 1001 `keepalive timeout` as resumable too. A resume it
    /// refuses costs a new stream, never more.
    var recovery: Recovery {
        switch self {
        case .disconnectedHere, .linkLost: .resume
        case .serverWentAway(let code) where code == WebSocketCloseCode.goingAway.rawValue: .resume
        case .blockClosed, .closedHere: .stop
        case .providerCanceled, .refused, .serverWentAway, .tryAgainLater, .protocolFailure: .startOver
        }
    }

    init(_ error: WebSocketError) {
        switch error {
        case .closedLocally:
            self = .disconnectedHere
        case .closedByPeer(let close):
            switch close.code.rawValue {
            case Self.blockClosedCode:
                self = .blockClosed
            case WebSocketCloseCode.goingAway.rawValue where close.reason == Self.providerCanceledReason:
                self = .providerCanceled
            case WebSocketCloseCode.tryAgainLater.rawValue:
                self = .tryAgainLater
            case WebSocketCloseCode.protocolError.rawValue, WebSocketCloseCode.unsupportedData.rawValue,
                WebSocketCloseCode.invalidPayload.rawValue, WebSocketCloseCode.messageTooBig.rawValue:
                self = .protocolFailure
            default:
                self = .serverWentAway(code: close.code.rawValue)
            }
        case .protocolViolation, .upgradeRefused, .upgradeInvalid:
            self = .protocolFailure
        case .handshakeTimedOut, .pongTimedOut, .connectionLost, .sendInterrupted:
            self = .linkLost
        }
    }

    static let blockClosedCode: UInt16 = 4000
    /// 1001 means two things on a data connection, and only this reason, as
    /// Rex 0.1.0-preview.14 writes it, tells them apart. Another reason reads
    /// as a resumable 1001; a resume the server refuses costs a new stream.
    static let providerCanceledReason = "data provider canceled"
}

/// Why a data link could not open or resume. None of them carries a ticket
/// or a resume token.
enum RexDataLinkError: Error, Sendable {
    /// `data.connect` failed, or the control link to ask it on did.
    case ticketUnavailable(RexControlError)
    /// `data.connect` answered without a ticket Heeler can read.
    case ticketUnreadable
    /// The server answered the WebSocket upgrade with this HTTP status.
    case upgradeRefused(status: Int)
    /// The upgrade's answer did not arrive in time, or was not one.
    case upgradeFailed
    /// No WELCOME or REJECT arrived in time after the HELLO or RESUME.
    case answerTimedOut
    /// The link ended, or the handshake was refused (`.refused`).
    case ended(RexDataEnding)
    /// This link may not be resumed: it ended in a way that allows no
    /// resume, or its RESUME already went out once, whatever came of it.
    case notResumable(RexDataEnding?)
    /// The server welcomed a RESUME with another stream's nonce.
    case resumedAnotherStream
}

/// Where a data link gets its ticket and its channel. The control link must
/// be attached to the block's session with `session.attach`, which the
/// caller makes sure of.
struct RexDataRoute: Sendable {
    let control: @Sendable () async throws -> RexControlLink
    let openChannel: @Sendable () async throws -> any HeelerSSHAPIChannel

    init(
        control: @escaping @Sendable () async throws -> RexControlLink,
        openChannel: @escaping @Sendable () async throws -> any HeelerSSHAPIChannel
    ) {
        self.control = control
        self.openChannel = openChannel
    }

    /// The transport's current control link, and channels under its attach slots.
    init(transport: any RexTransport) {
        control = { await transport.control }
        openChannel = { try await transport.openDataChannel() }
    }
}

/// One connection of a Rex terminal's data stream (ADR 0051): a WebSocket
/// for `rex.data.terminal.v1` at `/api/data`, on a channel of its own to the
/// server's socket.
///
/// `open` opens a channel, asks `data.connect` for a ticket, upgrades the
/// channel, sends the HELLO at once (Rex drops a connection that stays silent for a few
/// seconds) and waits for the WELCOME. `receive` returns the stream's bytes
/// in order, one server message at a time, and counts every byte it returns.
/// That count, across every connection of the stream, is what a RESUME
/// carries: bytes the WebSocket read ahead but no caller received are not
/// counted, and are sent again after a resume.
///
/// Read-ahead is bounded: once `Options.readAheadBytes` of messages wait
/// unreceived, the link stops reading its channel, so the SSH window fills
/// and the server holds the rest.
///
/// Ending: `disconnect` drops the connection with no close frame, so the
/// server keeps the stream and `resume` can continue it. `close` sends 1000,
/// which ends the stream for good; nothing that may be resumed is ever ended
/// that way. A link the caller lets go of stays open: end every link with
/// `disconnect`, `close`, or by cancelling a `receive`.
///
/// Resuming: each link's RESUME goes out at most once. Rex (0.1.0-preview.14,
/// API revision 12) makes a stream unusable after refusing one RESUME, so
/// after any refusal, or a RESUME whose answer never came, the only way on
/// is a new stream from `open`.
actor RexDataLink {
    typealias Sleep = WebSocketLink.Sleep

    struct Options: Sendable {
        /// The largest message accepted. Rex sends at most 64 KiB in one.
        var maximumMessageBytes = 1024 * 1024
        /// Unreceived message bytes at which the link stops reading.
        var readAheadBytes = 256 * 1024
        /// How long the WELCOME may take after the HELLO or RESUME.
        var answerDeadline: Duration = .seconds(10)
        /// The deadline of `data.connect`.
        var ticketDeadline: Duration = .seconds(30)
        /// Client pings, so a connection that went silent is noticed. The
        /// server answers them, and pings this side every 120 seconds.
        var keepalive: WebSocketLink.Options.Keepalive? = .init(interval: .seconds(30), pongDeadline: .seconds(30))

        var webSocket: WebSocketLink.Options {
            var options = WebSocketLink.Options()
            options.maximumMessageBytes = maximumMessageBytes
            options.readAheadBytes = readAheadBytes
            options.keepalive = keepalive
            return options
        }

        init() {}
    }

    /// Marks the stream's own control sequences. The same after a resume.
    nonisolated let nonce: UInt64
    /// How long a dropped stream waits on the server for a resume.
    nonisolated let retention: Duration
    /// This connection continues a stream an earlier one opened.
    nonisolated let resumed: Bool

    private let webSocket: WebSocketLink
    private let token: RexDataResumeToken
    private let options: Options
    private let sleep: Sleep
    /// Stream bytes returned by `receive`, on this connection and every
    /// earlier one of the stream.
    private(set) var receivedByteCount: UInt64
    private var ending: RexDataEnding?
    /// Set once this link's RESUME went out, or was about to.
    private var resumeSpent = false

    private init(
        webSocket: WebSocketLink, welcome: RexDataWelcome, receivedByteCount: UInt64, resumed: Bool,
        options: Options, sleep: @escaping Sleep
    ) {
        self.webSocket = webSocket
        nonce = welcome.nonce
        retention = welcome.retention
        token = welcome.resumeToken
        self.receivedByteCount = receivedByteCount
        self.resumed = resumed
        self.options = options
        self.sleep = sleep
    }

    // MARK: Opening

    /// Opens a channel on `route`, asks for a ticket for `block`'s terminal
    /// data, and says HELLO. The session must be attached on the route's
    /// control link. Throws `RexDataLinkError` (`.ended(.refused)` for a
    /// REJECT), what opening the channel throws, or `CancellationError`.
    ///
    /// The channel comes first: waiting for an attach slot can outlast a
    /// ticket, which Rex honors for a minute. Rex (0.1.0-preview.14, API
    /// revision 12) kept a connection that sent nothing for 10 seconds before
    /// its upgrade, and a ticket takes a round trip on the control link,
    /// which can queue behind other terminals' redraw pages. When the
    /// connection ended before its upgrade was answered, the unused ticket
    /// goes once more on a new channel. A channel the ticket never comes for
    /// is closed.
    static func open(
        session: String, block: String, route: RexDataRoute, options: Options = Options(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) async throws -> RexDataLink {
        let channel = try await route.openChannel()
        let ticket: RexDataTicket
        do {
            ticket = try await Self.ticket(
                session: session, block: block, route: route, deadline: options.ticketDeadline)
        } catch {
            try? await channel.close(timeout: Self.channelCloseTimeout)
            throw error
        }
        let webSocket: WebSocketLink
        do {
            webSocket = try await upgrade(channel, options: options, sleep: sleep)
        } catch RexDataLinkError.ended(.linkLost) {
            webSocket = try await upgrade(try await route.openChannel(), options: options, sleep: sleep)
        }
        let welcome = try await exchange(RexDataHandshake.hello(ticket), on: webSocket, options: options, sleep: sleep)
        return RexDataLink(
            webSocket: webSocket, welcome: welcome, receivedByteCount: 0, resumed: false, options: options,
            sleep: sleep)
    }

    /// How long closing a channel that never carried a WebSocket may take.
    private static let channelCloseTimeout: Duration = .seconds(2)

    private struct TicketRequest: Encodable, Sendable {
        let sessionID: String
        let blockID: String
        let dataRefID = RexDataProtocol.terminalDataSource
        let subprotocol = RexDataProtocol.terminalSubprotocol

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case blockID = "block_id"
            case dataRefID = "data_ref_id"
            case subprotocol
        }
    }

    private struct TicketAnswer: Decodable {
        let ticket: String?
    }

    private static func ticket(session: String, block: String, route: RexDataRoute, deadline: Duration)
        async throws -> RexDataTicket
    {
        let answer: TicketAnswer
        do {
            let control = try await route.control()
            let response = try await control.call(
                "data.connect", payload: TicketRequest(sessionID: session, blockID: block), deadline: deadline)
            answer = try response.result(TicketAnswer.self)
        } catch let error as RexControlError {
            if case .unreadableResult = error { throw RexDataLinkError.ticketUnreadable }
            throw RexDataLinkError.ticketUnavailable(error)
        }
        guard let ticket = answer.ticket.flatMap(RexDataTicket.init(text:)) else {
            throw RexDataLinkError.ticketUnreadable
        }
        return ticket
    }

    /// Upgrades `channel` for the terminal subprotocol. The WebSocket owns
    /// the channel from here, and closes it when the upgrade fails.
    private static func upgrade(_ channel: any HeelerSSHAPIChannel, options: Options, sleep: @escaping Sleep)
        async throws -> WebSocketLink
    {
        do {
            return try await WebSocketLink.connect(
                over: channel, path: RexDataProtocol.path, subprotocol: RexDataProtocol.terminalSubprotocol,
                options: options.webSocket, sleep: sleep)
        } catch let error as WebSocketError {
            switch error {
            case .upgradeRefused(let status): throw RexDataLinkError.upgradeRefused(status: status)
            case .upgradeInvalid, .handshakeTimedOut: throw RexDataLinkError.upgradeFailed
            default: throw RexDataLinkError.ended(RexDataEnding(error))
            }
        }
    }

    /// Sends the HELLO or RESUME at once and reads the answer. When this
    /// fails, the WebSocket is dropped with no close frame: after a REJECT
    /// the server closes on its own, and nothing is left to resume either way.
    private static func exchange(_ first: Data, on webSocket: WebSocketLink, options: Options, sleep: @escaping Sleep)
        async throws -> RexDataWelcome
    {
        do {
            do {
                try await webSocket.send(binary: first)
            } catch let error as WebSocketError {
                throw RexDataLinkError.ended(RexDataEnding(error))
            }
            switch try await answer(on: webSocket, deadline: options.answerDeadline, sleep: sleep) {
            case .welcome(let welcome):
                return welcome
            case .refused(let refusal):
                throw RexDataLinkError.ended(.refused(refusal))
            case .unreadable:
                throw RexDataLinkError.ended(.protocolFailure)
            }
        } catch {
            await webSocket.disconnect()
            throw error
        }
    }

    /// The first message after the HELLO or RESUME. Anything but a binary
    /// WELCOME or REJECT is unreadable.
    private static func answer(on webSocket: WebSocketLink, deadline: Duration, sleep: @escaping Sleep) async throws
        -> RexDataHandshake.Answer
    {
        try await withThrowingTaskGroup(of: RexDataHandshake.Answer?.self) { group in
            group.addTask {
                let message: WebSocketMessage
                do {
                    message = try await webSocket.receive()
                } catch let error as WebSocketError {
                    throw RexDataLinkError.ended(RexDataEnding(error))
                }
                guard case .binary(let bytes) = message else { return .unreadable }
                return RexDataHandshake.answer(bytes)
            }
            group.addTask {
                try await sleep(deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let answer = first else {
                try Task.checkCancellation()
                throw RexDataLinkError.answerTimedOut
            }
            return answer
        }
    }

    // MARK: Reading

    /// The stream's next bytes, as one server message brought them. After the
    /// link ended, the messages that arrived before the end come first, then
    /// this throws `RexDataLinkError.ended`. A cancelled receive ends the link
    /// with no close frame and throws `CancellationError`.
    func receive() async throws -> Data {
        // A resume carried the count on; more from here would count twice.
        if resumeSpent { throw RexDataLinkError.ended(ending ?? .disconnectedHere) }
        while true {
            let message: WebSocketMessage
            do {
                message = try await webSocket.receive()
            } catch let error as WebSocketError {
                throw RexDataLinkError.ended(ended(RexDataEnding(error)))
            } catch {
                _ = ended(.disconnectedHere)
                throw error
            }
            // Every binary message after the WELCOME is stream; the server sends nothing else.
            guard case .binary(let bytes) = message else { continue }
            receivedByteCount += UInt64(bytes.count)
            return bytes
        }
    }

    /// The first ending recorded wins: one this side chose stands over what
    /// the WebSocket reports for it.
    private func ended(_ reason: RexDataEnding) -> RexDataEnding {
        let reason = ending ?? reason
        ending = reason
        return reason
    }

    // MARK: Resuming

    /// Continues the stream on a new channel from `route`: drops this link
    /// first, then sends a RESUME with this link's token and byte count.
    /// Nothing more may be received from this link afterwards. Allowed once per link, and only after an ending whose
    /// recovery is `.resume`; a channel or upgrade that failed before the
    /// RESUME went out leaves it allowed. Throws `RexDataLinkError`
    /// (`.ended(.refused)` for a REJECT), what opening the channel throws, or
    /// `CancellationError`.
    func resume(over route: RexDataRoute) async throws -> RexDataLink {
        // Unread messages stay uncounted, so the server sends them again.
        await disconnect()
        guard !resumeSpent, let ending, ending.recovery == .resume else {
            throw RexDataLinkError.notResumable(resumeSpent ? nil : ending)
        }
        resumeSpent = true
        let webSocket: WebSocketLink
        do {
            webSocket = try await Self.upgrade(try await route.openChannel(), options: options, sleep: sleep)
        } catch {
            // The RESUME never went out, so the stream still waits for one.
            resumeSpent = false
            throw error
        }
        let resume = RexDataHandshake.resume(token, receivedByteCount: receivedByteCount)
        let welcome = try await Self.exchange(resume, on: webSocket, options: options, sleep: sleep)
        guard welcome.nonce == nonce else {
            await webSocket.disconnect()
            throw RexDataLinkError.resumedAnotherStream
        }
        return RexDataLink(
            webSocket: webSocket, welcome: welcome, receivedByteCount: receivedByteCount, resumed: true,
            options: options, sleep: sleep)
    }

    // MARK: Ending

    /// How the link ended; nil until it did, or until a receive saw it end.
    var endingReason: RexDataEnding? { ending }

    /// Whether `resume` may still be tried: the link ended in a way that
    /// allows it, or has not ended, and no RESUME went out yet.
    var canResume: Bool { !resumeSpent && (ending?.recovery ?? .resume) == .resume }

    /// Drops the connection with no close frame, so the stream waits on the
    /// server for a resume, and returns once the channel is closed.
    func disconnect() async {
        _ = ended(.disconnectedHere)
        await webSocket.disconnect()
    }

    /// Ends the stream for good with a close frame (1000), and returns once
    /// the channel is closed. The link can no longer be resumed.
    func close() async {
        _ = ended(.closedHere)
        await webSocket.close(.normalClosure)
    }
}
