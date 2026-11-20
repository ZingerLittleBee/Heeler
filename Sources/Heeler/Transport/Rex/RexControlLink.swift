import Foundation
import HeelerSSH

/// How a control link ended. A new link always needs a fresh inventory:
/// events sent while no link was open are lost, even when the client resumes.
enum RexControlEnding: Sendable, Equatable {
    /// This side ended it, by `close` or `disconnect`.
    case closedHere
    /// The server closed it normally, or is going away, with this code. With
    /// 1001 the server may still keep the client, so resuming may work.
    case serverWentAway(code: UInt16)
    /// The server dropped this client by policy, as it does when the events
    /// waiting for it pile up too far: events were lost.
    case droppedByServer
    /// One side broke the protocol, or sent text that is not UTF-8.
    case protocolFailure
    /// A message was larger than the side receiving it accepts.
    case messageTooBig
    /// The connection ended with no close frame, or went silent. The server
    /// may still keep the client for a while, so resuming may work.
    case linkLost

    /// Whether a new link may resume this client instead of starting a new one.
    /// Rex (0.1.0-preview.14, API revision 12) closes a client that stopped
    /// answering its pings with 1001 and keeps it as it keeps a dropped one. A
    /// token the server no longer knows only gets a new client, so trying
    /// costs nothing.
    var mayResume: Bool {
        switch self {
        case .linkLost: true
        case .serverWentAway(let code): code == WebSocketCloseCode.goingAway.rawValue
        default: false
        }
    }

    init(_ error: WebSocketError) {
        switch error {
        case .closedLocally:
            self = .closedHere
        case .closedByPeer(let close):
            switch close.code {
            case .policyViolation: self = .droppedByServer
            case .protocolError, .unsupportedData, .invalidPayload: self = .protocolFailure
            case .messageTooBig: self = .messageTooBig
            default: self = .serverWentAway(code: close.code.rawValue)
            }
        case .protocolViolation(let violation):
            self = violation.closeCode == .messageTooBig ? .messageTooBig : .protocolFailure
        case .upgradeRefused, .upgradeInvalid:
            self = .protocolFailure
        case .handshakeTimedOut, .pongTimedOut, .connectionLost, .sendInterrupted:
            self = .linkLost
        }
    }
}

/// Why a control link could not open, or a call on it failed. None of them
/// carries a reconnect token.
enum RexControlError: Error, Sendable {
    /// The server answered the WebSocket upgrade with this HTTP status.
    case upgradeRefused(status: Int)
    /// The upgrade's answer did not arrive in time, or was not one.
    case upgradeFailed
    /// No welcome arrived in time after the hello.
    case welcomeTimedOut
    /// The server does not speak this build's protocol and API revision.
    case unsupportedVersion(RexServerOffer)
    /// The server answered the request with an error.
    case server(RexServerError)
    /// No answer arrived within the request's deadline. The link stays usable.
    case deadlineExceeded(method: String)
    /// The request is larger than the server accepts, so it was not sent.
    case requestTooLarge(bytes: Int, limit: Int)
    /// The request's payload could not be written as JSON, so it was not sent.
    case requestUnencodable(method: String)
    /// The result did not have the shape the caller asked for.
    case unreadableResult(method: String)
    /// The link ended before the answer arrived.
    case linkEnded(RexControlEnding)
}

/// What became of a request that must never apply twice, such as input to a
/// terminal: whether it may have reached the server decides whether anything
/// may follow it.
enum RexDelivery: Sendable {
    /// The server answered with a result.
    case answered(RexResponse)
    /// The server answered with an error.
    case refused(RexServerError)
    /// It never left this side: the link had ended, the request was too large
    /// or could not be written, or it was cancelled before it was written.
    case notSent
    /// It left, or may have, and no answer came: the link ended, the deadline
    /// passed, or the caller was cancelled first. The server may have applied it.
    case unknown
}

/// How long a delivered request waits for its answer once it is written.
struct RexDeliveryDeadline: Sendable, Equatable {
    /// How long the link may stay silent: an answer queued behind a long
    /// message, such as a page of a terminal's redraw, is still on its way
    /// while that message is.
    var silence: Duration
    /// The longest it waits in all, however much else keeps arriving, so a
    /// server that keeps sending but never answers cannot hold it for ever.
    var limit: Duration

    /// What a read on a control link that also carries redraw pages waits:
    /// half a minute of silence, two minutes in all.
    static let sharedLinkRead = RexDeliveryDeadline(silence: .seconds(30), limit: .seconds(120))
}

/// What a control link's event sequence yields.
enum RexControlUpdate: Sendable, Equatable {
    case event(RexControlEvent)
    /// The seq did not follow on from the last one, so events were lost or
    /// repeated: whatever was built from events needs a fresh read. `received`
    /// is nil for an event that carried no seq this build could read.
    case sequenceBroken(expected: UInt64, received: UInt64?)
}

/// A Rex control connection (ADR 0049): a WebSocket for `rex.control.v1` at
/// `/api/control` over one channel to the server's socket.
///
/// Opening sends the hello at once, since Rex drops a client that stays
/// silent for a few seconds, and accepts only a welcome for this build's
/// protocol and API revision 12. `call` sends one request and returns its
/// response; calls run concurrently, matched to responses by id in whatever
/// order those arrive. `events` yields what the server pushes, in order.
///
/// Ending: `close` sends a close frame, and Rex forgets the client at once.
/// `disconnect` drops the connection without one, so Rex keeps the client
/// for a while and `open(over:resuming:)` can take it back on a new channel.
/// A link the caller lets go of stays open, as a WebSocketLink does: end
/// every link with `close` or `disconnect`.
actor RexControlLink {
    typealias Sleep = WebSocketLink.Sleep

    struct Options: Sendable {
        var identity = RexClientIdentity.heeler
        /// How long the welcome may take after the upgrade.
        var welcomeDeadline: Duration = .seconds(10)
        /// The deadline of a call that names none.
        var requestDeadline: Duration = .seconds(30)
        /// The largest message accepted from the server.
        var maximumInboundBytes = 16 * 1024 * 1024
        /// Client pings, so a connection that went silent is noticed.
        var keepalive: WebSocketLink.Options.Keepalive? = .init(interval: .seconds(30), pongDeadline: .seconds(30))
        var webSocket: WebSocketLink.Options {
            var options = WebSocketLink.Options()
            options.maximumMessageBytes = maximumInboundBytes
            // The link's own reader drains every message as it arrives, so
            // read-ahead never stops reading and pings are always answered.
            options.readAheadBytes = .max
            options.keepalive = keepalive
            return options
        }

        init() {}
    }

    private struct Pending {
        let method: String
        var waiter: CheckedContinuation<RexResponse, any Error>?
        var outcome: Result<RexResponse, any Error>?
        var deadline: Task<Void, Never>?
    }

    /// The server's id for this client, the same after a resume. Nil when the
    /// server named none, as one that cannot resume clients may: it then issues
    /// no token either, and the next link starts a new client.
    nonisolated let clientID: String?
    /// The largest request the server accepts, in bytes.
    nonisolated let maxMessageBytes: Int
    /// This link took back the client an earlier link's token named.
    nonisolated let resumed: Bool
    /// The API revision both sides agreed on.
    nonisolated let apiRevision: Int
    /// What the server pushes, in order. It finishes when the link ends,
    /// throwing `RexControlError.linkEnded` unless this side ended it. One
    /// consumer reads it; nothing is dropped while it falls behind.
    nonisolated let events: AsyncThrowingStream<RexControlUpdate, any Error>

    private nonisolated let reconnectToken: RexReconnectToken?
    private let webSocket: WebSocketLink
    private let options: Options
    private let sleep: Sleep
    private let eventSink: AsyncThrowingStream<RexControlUpdate, any Error>.Continuation
    private var pending: [String: Pending] = [:]
    private var nextRequest: UInt64 = 0
    /// The last event's seq; nil until the first event of a resumed client.
    private var lastSeq: UInt64?
    private var ending: RexControlEnding?
    private var readerTask: Task<Void, Never>?

    private init(webSocket: WebSocketLink, welcome: RexWelcome, options: Options, sleep: @escaping Sleep) {
        self.webSocket = webSocket
        clientID = welcome.clientID
        maxMessageBytes = max(welcome.maxMessageBytes ?? 0, RexControlProtocol.minimumMessageLimit)
        resumed = welcome.resumed
        apiRevision = welcome.apiRevision ?? RexControlProtocol.apiRevision
        reconnectToken = welcome.reconnectToken
        self.options = options
        self.sleep = sleep
        lastSeq = welcome.resumed ? nil : 0
        let stream = AsyncThrowingStream.makeStream(of: RexControlUpdate.self, bufferingPolicy: .unbounded)
        events = stream.stream
        eventSink = stream.continuation
    }

    /// Upgrades `channel`, says hello, and waits for the welcome. The link
    /// owns the channel from here: when opening fails or is cancelled, the
    /// channel is closed.
    ///
    /// With `previous`, an earlier link of the same server, the hello carries
    /// that link's reconnect token, and `resumed` says whether the server
    /// took the client back. `previous` is disconnected first if it is still
    /// open, since a client sending a close frame is forgotten. Throws
    /// `RexControlError` or `CancellationError`.
    static func open(
        over channel: any HeelerSSHAPIChannel,
        resuming previous: RexControlLink? = nil,
        options: Options = Options(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) async throws -> RexControlLink {
        if let previous { await previous.disconnect() }
        let webSocket: WebSocketLink
        do {
            webSocket = try await WebSocketLink.connect(
                over: channel, path: RexControlProtocol.path, subprotocol: RexControlProtocol.subprotocol,
                options: options.webSocket, sleep: sleep)
        } catch let error as WebSocketError {
            switch error {
            case .upgradeRefused(let status): throw RexControlError.upgradeRefused(status: status)
            case .upgradeInvalid, .handshakeTimedOut: throw RexControlError.upgradeFailed
            default: throw RexControlError.linkEnded(RexControlEnding(error))
            }
        }
        let welcome: RexWelcome
        do {
            let hello = RexHello(identity: options.identity, reconnectToken: previous?.reconnectToken)
            do {
                try await webSocket.send(text: hello.encoded().text)
            } catch let error as WebSocketError {
                throw Self.openingFailure(error)
            }
            welcome = try await Self.welcome(on: webSocket, deadline: options.welcomeDeadline, sleep: sleep)
        } catch {
            await webSocket.disconnect()
            throw error
        }
        guard welcome.protocolName == RexControlProtocol.subprotocol,
            welcome.apiRevision == RexControlProtocol.apiRevision
        else {
            await webSocket.close(.normalClosure)
            throw RexControlError.unsupportedVersion(welcome.offer)
        }
        let link = RexControlLink(webSocket: webSocket, welcome: welcome, options: options, sleep: sleep)
        await link.startReading()
        return link
    }

    /// Messages before the welcome are skipped. A server with no revision in
    /// common closes with a policy code instead of welcoming.
    private static func welcome(on webSocket: WebSocketLink, deadline: Duration, sleep: @escaping Sleep) async throws
        -> RexWelcome
    {
        try await withThrowingTaskGroup(of: RexWelcome?.self) { group in
            group.addTask {
                while true {
                    let message: WebSocketMessage
                    do {
                        message = try await webSocket.receive()
                    } catch let error as WebSocketError {
                        throw Self.openingFailure(error)
                    }
                    guard case .text(let text) = message, case .welcome(let welcome) = RexInbound(text: text) else {
                        continue
                    }
                    return welcome
                }
            }
            group.addTask {
                try await sleep(deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let welcome = first else {
                try Task.checkCancellation()
                throw RexControlError.welcomeTimedOut
            }
            return welcome
        }
    }

    /// A WebSocket that ended between the upgrade and the welcome, as the
    /// control link reports it.
    private static func openingFailure(_ error: WebSocketError) -> RexControlError {
        if case .closedByPeer(let close) = error, close.code == .policyViolation {
            return .unsupportedVersion(.unknown)
        }
        return .linkEnded(RexControlEnding(error))
    }

    private func startReading() {
        readerTask = Task { await self.read() }
    }

    // MARK: Requests

    /// Sends `method` with `payload` and waits for its response, at most
    /// `deadline` (the options' request deadline by default). Throws
    /// `RexControlError` (`.server` for an error response) or
    /// `CancellationError`. A call that fails by its deadline or is
    /// cancelled leaves the link usable; a late answer to it is skipped.
    func call(_ method: String, deadline: Duration? = nil) async throws -> RexResponse {
        try await call(method, payload: JSONValue?.none, deadline: deadline)
    }

    func call<Payload: Encodable & Sendable>(_ method: String, payload: Payload?, deadline: Duration? = nil)
        async throws -> RexResponse
    {
        try await exchange(method, payload: payload, wait: .fromNow(deadline ?? options.requestDeadline)).outcome.get()
    }

    /// Sends `method` as `call` does, but times its answer as `deliver` does:
    /// from when it is written, failing with `deadlineExceeded` once the link
    /// stays silent for `deadline.silence`, or after `deadline.limit` in all.
    /// For a request whose answer may queue behind long messages on the
    /// link, such as a terminal redraw's pages, while they keep arriving.
    func call<Payload: Encodable & Sendable>(
        _ method: String, payload: Payload?, waiting deadline: RexDeliveryDeadline
    ) async throws -> RexResponse {
        try await exchange(method, payload: payload, wait: .afterWriting(deadline)).outcome.get()
    }

    /// Sends `method` with `payload` as `call` does, and says whether it was
    /// answered, refused, never sent, or may have reached the server with no
    /// answer. A request that left is never sent again here.
    ///
    /// The deadline counts from when the request is written. It passes after
    /// `deadline.silence` with nothing at all arriving on the link, or after
    /// `deadline.limit` in all, whichever comes first. Writing it is bounded
    /// by the link's own write timeout, which ends the link.
    func deliver<Payload: Encodable & Sendable>(_ method: String, payload: Payload?, deadline: RexDeliveryDeadline)
        async -> RexDelivery
    {
        let exchange = await exchange(method, payload: payload, wait: .afterWriting(deadline))
        switch exchange.outcome {
        case .success(let response): return .answered(response)
        case .failure(RexControlError.server(let failure)): return .refused(failure)
        case .failure: return exchange.left ? .unknown : .notSent
        }
    }

    /// When a request's deadline starts, and what it counts.
    private enum Wait {
        /// From now, whatever arrives: a `call` given a duration.
        case fromNow(Duration)
        /// From when it is written, counting the link's silence: `deliver`'s,
        /// and a `call` given a `RexDeliveryDeadline`.
        case afterWriting(RexDeliveryDeadline)
    }

    /// One request and its outcome. `left` is true once the request was
    /// written, or was being written when the link ended.
    private func exchange<Payload: Encodable & Sendable>(
        _ method: String, payload: Payload?, wait: Wait
    ) async -> (left: Bool, outcome: Result<RexResponse, any Error>) {
        if let ending { return (false, .failure(RexControlError.linkEnded(ending))) }
        if Task.isCancelled { return (false, .failure(CancellationError())) }
        nextRequest += 1
        let id = "h\(nextRequest)"
        guard let text = Self.request(id: id, method: method, payload: payload) else {
            return (false, .failure(RexControlError.requestUnencodable(method: method)))
        }
        let bytes = text.utf8.count
        guard bytes <= maxMessageBytes else {
            return (false, .failure(RexControlError.requestTooLarge(bytes: bytes, limit: maxMessageBytes)))
        }
        // An answer can arrive while the request is still being written, so
        // it is pending from now; a delivery's deadline is armed once it is out.
        var timer: Task<Void, Never>?
        if case .fromNow(let duration) = wait {
            timer = Task { [sleep] in
                do { try await sleep(duration) } catch { return }
                await self.settle(id, .failure(RexControlError.deadlineExceeded(method: method)))
            }
        }
        pending[id] = Pending(method: method, deadline: timer)
        var left = false
        do {
            try await webSocket.send(text: text)
            left = true
            if case .afterWriting(let deadline) = wait { armDeliveryDeadline(id, method: method, deadline: deadline) }
        } catch let error as WebSocketError {
            if case .sendInterrupted = error { left = true }
            settle(id, .failure(RexControlError.linkEnded(ending ?? RexControlEnding(error))))
        } catch {
            settle(id, .failure(error))
        }
        do {
            return (left, .success(try await answer(to: id)))
        } catch {
            return (left, .failure(error))
        }
    }

    /// Fails the request once its silence passes with nothing arriving on the
    /// link, or its limit passes in all, unless it was settled already.
    private func armDeliveryDeadline(_ id: String, method: String, deadline: RexDeliveryDeadline) {
        guard var entry = pending[id], entry.outcome == nil else { return }
        entry.deadline = Task { [sleep, webSocket] in
            var heard = await webSocket.receivedByteCount
            var waited = Duration.zero
            while waited < deadline.limit {
                let step = min(deadline.silence, deadline.limit - waited)
                do { try await sleep(step) } catch { return }
                waited += step
                let now = await webSocket.receivedByteCount
                if now == heard { break }
                heard = now
            }
            await self.settle(id, .failure(RexControlError.deadlineExceeded(method: method)))
        }
        pending[id] = entry
    }

    private func answer(to id: String) async throws -> RexResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var entry = pending[id] else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let outcome = entry.outcome {
                    pending[id] = nil
                    continuation.resume(with: outcome)
                } else {
                    entry.waiter = continuation
                    pending[id] = entry
                }
            }
        } onCancel: {
            Task { await self.settle(id, .failure(CancellationError())) }
        }
    }

    private static func request<Payload: Encodable>(id: String, method: String, payload: Payload?) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let request = RexRequestMessage(id: id, method: method, payload: payload)
        guard let data = try? encoder.encode(request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The first outcome of a request wins; later ones are dropped.
    private func settle(_ id: String, _ outcome: Result<RexResponse, any Error>) {
        guard var entry = pending[id], entry.outcome == nil else { return }
        entry.deadline?.cancel()
        if let waiter = entry.waiter {
            pending[id] = nil
            waiter.resume(with: outcome)
        } else {
            entry.outcome = outcome
            entry.deadline = nil
            pending[id] = entry
        }
    }

    // MARK: Reading

    private func read() async {
        while true {
            let message: WebSocketMessage
            do {
                message = try await webSocket.receive()
            } catch let error as WebSocketError {
                ended(RexControlEnding(error))
                return
            } catch {
                ended(.closedHere)
                return
            }
            guard case .text(let text) = message else { continue }
            handle(RexInbound(text: text))
        }
    }

    private func handle(_ inbound: RexInbound) {
        switch inbound {
        case .response(let id, let seq, let outcome):
            guard let method = pending[id]?.method else { return }
            switch outcome {
            case .result(let message):
                settle(id, .success(RexResponse(method: method, seq: seq ?? 0, message: message)))
            case .error(let error):
                settle(id, .failure(RexControlError.server(error)))
            }
        case .event(let seq, let event):
            guard let seq else {
                eventSink.yield(.sequenceBroken(expected: (lastSeq ?? 0) + 1, received: nil))
                return
            }
            if let lastSeq, seq != lastSeq + 1 {
                eventSink.yield(.sequenceBroken(expected: lastSeq + 1, received: seq))
            }
            lastSeq = seq
            if let event {
                eventSink.yield(.event(RexControlEvent(seq: seq, sessionID: event.sessionID, body: event.body)))
            }
        case .welcome, .skipped:
            break
        }
    }

    private func ended(_ reason: RexControlEnding) {
        let reason = ending ?? reason
        ending = reason
        for id in Array(pending.keys) {
            settle(id, .failure(RexControlError.linkEnded(reason)))
        }
        if reason == .closedHere {
            eventSink.finish()
        } else {
            eventSink.finish(throwing: RexControlError.linkEnded(reason))
        }
    }

    // MARK: Ending

    /// How the link ended; nil while it is open.
    var endingReason: RexControlEnding? { ending }

    var isOpen: Bool { ending == nil }

    /// Leaves for good: sends a close frame, so the server forgets this
    /// client at once, and returns once the channel is closed.
    func close() async {
        if ending == nil { ending = .closedHere }
        await webSocket.close(.normalClosure)
        await readerTask?.value
    }

    /// Drops the connection with no close frame, so the server keeps this
    /// client for a while and a new link may resume it.
    func disconnect() async {
        if ending == nil { ending = .closedHere }
        await webSocket.disconnect()
        await readerTask?.value
    }
}

/// A request as sent: the payload is left out when there is none.
private struct RexRequestMessage<Payload: Encodable>: Encodable {
    let type = "request"
    let id: String
    let method: String
    let payload: Payload?
}
