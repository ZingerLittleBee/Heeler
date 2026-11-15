import Foundation
import HeelerSSH

/// Why a link could not open, or why it ended. Every call after the end
/// throws the same error, except where a case says otherwise.
enum WebSocketError: Error, Sendable {
    /// The server answered the upgrade with this HTTP status instead of 101.
    case upgradeRefused(status: Int)
    case upgradeInvalid(WebSocketUpgradeProblem)
    /// No whole answer to the upgrade arrived within the handshake deadline.
    case handshakeTimedOut
    /// The peer sent a close frame, with this code and reason.
    case closedByPeer(WebSocketClose)
    /// This side closed the link, or a cancelled `receive` ended it.
    case closedLocally
    /// The peer broke the protocol, so this side closed with the violation's code.
    case protocolViolation(WebSocketViolation)
    /// Nothing at all arrived within the deadline after a keepalive ping.
    case pongTimedOut
    /// The channel failed, or ended without a close frame (status 1006).
    /// The underlying error is nil for end of file.
    case connectionLost((any Error)?)
    /// Thrown only by the `send` whose message was being written when the
    /// link ended: the peer may have received some or all of it.
    case sendInterrupted
}

/// A WebSocket client connection (RFC 6455) over one duplex SSH channel, such
/// as a direct-streamlocal channel to a server's Unix socket.
///
/// `connect` sends the upgrade for one subprotocol and checks the answer.
/// Then `send` writes whole text or binary messages, `receive` returns whole
/// messages in order, and the link answers the peer's pings by itself.
/// Nothing is compressed: the upgrade offers no extension and fails when the
/// server picks one.
///
/// One writer task sends frames in order, each masked with a fresh random
/// key. A pong goes ahead of messages still queued. A write that fails,
/// partly written or not, ends the link, and nothing more is written.
///
/// Read-ahead and backpressure: the reader keeps reading while the messages
/// that have arrived but not been received total less than `readAheadBytes`.
/// At that limit it stops reading the channel, so the SSH window fills and
/// the server stops sending, and it starts again once `receive` brings the
/// total back under the limit. A message in progress always finishes, so at
/// most `readAheadBytes + maximumMessageBytes` plus one read is buffered.
/// The trade-off: a stopped reader reads no pings either, so a consumer that
/// stays behind long enough makes the link miss the server's pings, and a
/// server that closes connections which miss pings closes this one. The
/// caller then reconnects. A link whose consumer must never fall behind, such
/// as a control connection, sets a limit it never reaches. This link's own
/// keepalive waits while the reader is stopped, because the server did not
/// fall silent. A stopped reader does not see the channel end either, so a
/// link dropped while stopped never ends on its own (see Ending).
///
/// Ending: `close` sends a close frame and waits briefly for the peer's
/// answer. A peer's close frame is answered with its own code, and once the
/// messages that arrived before it are received, `receive` throws
/// `.closedByPeer` with the peer's code and reason. `disconnect`, or a
/// cancelled `receive`, ends the link at once, with no close frame. However
/// it ends, the reader and writer stop and the channel is closed. Ending is
/// explicit: a link the caller lets go of stays open. Its reader keeps
/// reading until the channel ends, unless read-ahead has stopped it; then
/// nothing reads again, and the link and its channel live until the SSH
/// session closes. End every link you are done with by `close`,
/// `disconnect`, or cancelling a `receive`.
actor WebSocketLink {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    struct Options: Sendable {
        struct Keepalive: Sendable {
            /// How long after the last ping the next one goes out.
            var interval: Duration
            /// How long after a ping something must arrive, a pong or anything else.
            var pongDeadline: Duration
        }

        /// The `Host` header. Over a Unix socket any name works.
        var host = "localhost"
        /// A larger message from the peer closes the link with 1009.
        var maximumMessageBytes = 1024 * 1024
        /// Received-but-unclaimed message bytes at which the reader stops reading.
        var readAheadBytes = 1024 * 1024
        var handshakeDeadline: Duration = .seconds(10)
        /// How long `close` and an answered close frame wait to finish the closing handshake.
        var closeDeadline: Duration = .seconds(2)
        /// Client pings, so a dead server is noticed. Nil sends none.
        var keepalive: Keepalive?

        init() {}
    }

    private enum OutboundKind {
        case upgrade
        case message
        case ping
        case pong
        case close
    }

    private struct Outbound {
        let id: UInt64
        let kind: OutboundKind
        let bytes: Data
        var completion: CheckedContinuation<Void, any Error>?
    }

    private struct Receiver {
        let id: UInt64
        let continuation: CheckedContinuation<WebSocketMessage, any Error>
    }

    private static let readChunkBytes = 64 * 1024
    private static let readPoll: Duration = .seconds(1)
    private static let minimumWriteTimeout: Duration = .seconds(30)
    private static let slowestWriteBytesPerSecond = 64 * 1024
    private static let channelCloseTimeout: Duration = .seconds(2)

    private let channel: any HeelerSSHAPIChannel
    private let options: Options
    private let sleep: Sleep
    private let handshake: WebSocketHandshake

    /// What has arrived of the upgrade answer; nil once frames began.
    private var handshakeBuffer: Data? = Data()
    private var handshakeWaiter: CheckedContinuation<Void, any Error>?
    private var reader: WebSocketMessageReader
    /// Set by a violation: nothing more that arrives is read.
    private var inputBroken = false

    private var inbox: [WebSocketMessage] = []
    private var inboxHead = 0
    private var inboxBytes = 0
    private var receivers: [Receiver] = []
    private var readerPause: CheckedContinuation<Void, Never>?

    private var outbox: [Outbound] = []
    private var inFlight: Outbound?
    private var writerWaiter: CheckedContinuation<Outbound?, Never>?
    private var nextID: UInt64 = 0

    /// What every call reports once the link ended; nil while it is open.
    private var ending: WebSocketError?
    private var peerClose: WebSocketClose?
    private var closeQueued = false
    private var closeWritten = false
    /// This side started the closing handshake and waits for the peer's close frame.
    private var awaitsPeerClose = false
    private var heardSincePing = false
    /// Bytes read from the channel so far, frames and all: it grows while
    /// anything arrives, however long one message takes to.
    private(set) var receivedByteCount: UInt64 = 0

    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    /// Set once the link finished: the channel is closing or closed.
    private var closeTask: Task<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    private init(channel: any HeelerSSHAPIChannel, options: Options, sleep: @escaping Sleep, handshake: WebSocketHandshake) {
        self.channel = channel
        self.options = options
        self.sleep = sleep
        self.handshake = handshake
        reader = WebSocketMessageReader(role: .client, maximumMessageBytes: options.maximumMessageBytes)
    }

    /// Upgrades a fresh channel to a WebSocket for `subprotocol` at `path`.
    /// The link owns the channel from here: a failed or cancelled upgrade
    /// closes it and throws.
    static func connect(
        over channel: any HeelerSSHAPIChannel,
        path: String,
        subprotocol: String,
        options: Options = Options(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) async throws -> WebSocketLink {
        let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let handshake: WebSocketHandshake
        do {
            handshake = try WebSocketHandshake(path: path, host: options.host, subprotocol: subprotocol, nonce: nonce)
        } catch {
            try? await channel.close(timeout: channelCloseTimeout)
            throw error
        }
        let link = WebSocketLink(channel: channel, options: options, sleep: sleep, handshake: handshake)
        try await link.open()
        return link
    }

    /// How long one write may take: a whole message has to cross a slow link.
    private static func writeTimeout(forBytes count: Int) -> Duration {
        max(minimumWriteTimeout, .seconds(count / slowestWriteBytesPerSecond))
    }

    /// False once the link ended, on its own or by `close`. It never reopens.
    var isOpen: Bool { ending == nil }

    /// True while the reader has stopped because unclaimed messages reached `readAheadBytes`.
    var isReadAheadFull: Bool { readerPause != nil }

    // MARK: Messages

    /// Sends one text message, returning once it is written.
    func send(text: String) async throws {
        try await send(.text, payload: Data(text.utf8))
    }

    /// Sends one binary message, returning once it is written.
    func send(binary: Data) async throws {
        try await send(.binary, payload: binary)
    }

    /// The next whole message. After the link ended, the messages that
    /// arrived before the end come first, then this throws the ending, except
    /// after `close` or a cancelled receive, which drop what was unclaimed.
    /// Cancelling a receive that waits ends the link without a close frame.
    func receive() async throws -> WebSocketMessage {
        if inboxHead < inbox.count { return takeFromInbox() }
        if let ending { throw ending }
        if Task.isCancelled {
            abandon()
            throw CancellationError()
        }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receivers.append(Receiver(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.receiveCancelled(id) }
        }
    }

    /// Starts the closing handshake with `code` and `reason`, then waits for
    /// the peer's close frame or `closeDeadline`, and closes the channel.
    /// Returns the close frame the peer sent, if one arrived before the end.
    /// A code that may not be sent goes out as a close frame without one.
    @discardableResult
    func close(_ code: WebSocketCloseCode = .normalClosure, reason: String = "") async -> WebSocketClose? {
        if ending == nil {
            end(.closedLocally)
            awaitsPeerClose = true
            queueClose(code.mayBeSent ? code : nil, reason: reason)
        }
        while closeTask == nil {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        await closeTask?.value
        return peerClose
    }

    /// Ends the link at once with no close frame, as a connection that
    /// dropped does, and returns once its channel is closed. A server that
    /// keeps a client whose connection dropped, as Rex does for a while,
    /// still keeps this one. A link that already finished only waits; one
    /// still waiting for the peer's answer to its close frame stops waiting.
    func disconnect() async {
        if closeTask == nil { abandon() }
        await closeTask?.value
    }

    private func send(_ opcode: WebSocketOpcode, payload: Data) async throws {
        if let ending { throw ending }
        try Task.checkCancellation()
        let bytes = WebSocketFrame(opcode: opcode, payload: payload).encoded(maskKey: Self.maskKey())
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enqueue(Outbound(id: id, kind: .message, bytes: bytes, completion: continuation))
            }
        } onCancel: {
            Task { await self.sendCancelled(id) }
        }
    }

    private func takeFromInbox() -> WebSocketMessage {
        let message = inbox[inboxHead]
        inboxHead += 1
        if inboxHead == inbox.count {
            inbox = []
            inboxHead = 0
        } else if inboxHead >= 64, inboxHead * 2 >= inbox.count {
            inbox.removeFirst(inboxHead)
            inboxHead = 0
        }
        inboxBytes -= message.byteCount
        if !reachedReadAheadLimit, let readerPause {
            self.readerPause = nil
            readerPause.resume()
        }
        return message
    }

    /// Unclaimed messages have reached `readAheadBytes`. With none unclaimed
    /// the consumer is not behind, so the reader always reads.
    private var reachedReadAheadLimit: Bool {
        inboxHead < inbox.count && inboxBytes >= options.readAheadBytes
    }

    private func receiveCancelled(_ id: UInt64) {
        guard let index = receivers.firstIndex(where: { $0.id == id }) else { return }
        receivers.remove(at: index).continuation.resume(throwing: CancellationError())
        abandon()
    }

    /// A send that has not reached the writer is dropped. One being written finishes.
    private func sendCancelled(_ id: UInt64) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        outbox.remove(at: index).completion?.resume(throwing: CancellationError())
    }

    // MARK: Opening

    private func open() async throws {
        readerTask = Task { await runReader() }
        writerTask = Task { await runWriter() }
        enqueue(Outbound(id: 0, kind: .upgrade, bytes: handshake.request))
        deadlineTask = Task { [sleep, deadline = options.handshakeDeadline] in
            do { try await sleep(deadline) } catch { return }
            self.handshakeExpired()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if let ending {
                    continuation.resume(throwing: ending)
                } else if Task.isCancelled {
                    // Cancelled before the waiter was in place, so the
                    // handler below found nothing to end.
                    continuation.resume(throwing: CancellationError())
                    abandon()
                } else {
                    handshakeWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.openCancelled() }
        }
    }

    private func upgraded() {
        deadlineTask?.cancel()
        deadlineTask = nil
        if let keepalive = options.keepalive {
            keepaliveTask = Task { await runKeepalive(keepalive) }
        }
        handshakeWaiter?.resume()
        handshakeWaiter = nil
    }

    private func handshakeExpired() {
        guard handshakeBuffer != nil, closeTask == nil else { return }
        end(.handshakeTimedOut)
        finish()
    }

    private func openCancelled() {
        guard let handshakeWaiter else { return }
        self.handshakeWaiter = nil
        handshakeWaiter.resume(throwing: CancellationError())
        abandon()
    }

    // MARK: Reader

    private func runReader() async {
        while closeTask == nil {
            if ending == nil, handshakeBuffer == nil, reachedReadAheadLimit {
                await withCheckedContinuation { readerPause = $0 }
                continue
            }
            let chunk: Data?
            do {
                chunk = try await channel.read(maximumBytes: Self.readChunkBytes, timeout: Self.readPoll)
            } catch SSHError.timedOut {
                continue
            } catch {
                lost(error)
                return
            }
            guard let chunk else {
                lost(nil)
                return
            }
            ingest(chunk)
        }
    }

    private func ingest(_ chunk: Data) {
        guard closeTask == nil, !inputBroken else { return }
        heardSincePing = true
        receivedByteCount &+= UInt64(chunk.count)
        var frames = chunk
        if var buffer = handshakeBuffer {
            buffer.append(chunk)
            do throws(WebSocketError) {
                guard let rest = try handshake.response(from: buffer) else {
                    handshakeBuffer = buffer
                    return
                }
                handshakeBuffer = nil
                frames = rest
                upgraded()
            } catch {
                end(error)
                finish()
                return
            }
        }
        guard !frames.isEmpty else { return }
        reader.append(frames)
        do throws(WebSocketViolation) {
            while closeTask == nil, peerClose == nil, let inbound = try reader.next() {
                handle(inbound)
            }
        } catch {
            violated(error)
        }
    }

    private func handle(_ inbound: WebSocketInbound) {
        switch inbound {
        case .message(let message):
            guard ending == nil else { return }
            if receivers.isEmpty {
                inbox.append(message)
                inboxBytes += message.byteCount
            } else {
                receivers.removeFirst().continuation.resume(returning: message)
            }
        case .ping(let payload):
            guard ending == nil else { return }
            enqueueControl(Outbound(
                id: 0, kind: .pong,
                bytes: WebSocketFrame(opcode: .pong, payload: payload).encoded(maskKey: Self.maskKey())))
        case .pong:
            break
        case .close(let close):
            peerClosed(close)
        }
    }

    private func peerClosed(_ close: WebSocketClose) {
        peerClose = close
        if ending == nil {
            end(.closedByPeer(close))
            queueClose(close.code.mayBeSent ? close.code : nil, reason: "")
        } else if !closeQueued || closeWritten {
            finish()
        }
        // Otherwise this side's close frame is still queued; finish once it is written.
    }

    private func violated(_ violation: WebSocketViolation) {
        inputBroken = true
        guard ending == nil else {
            finish()
            return
        }
        end(.protocolViolation(violation))
        queueClose(violation.closeCode, reason: "")
    }

    private func lost(_ error: (any Error)?) {
        if ending == nil { end(.connectionLost(error)) }
        finish()
    }

    // MARK: Writer

    private func enqueue(_ item: Outbound) {
        if let writerWaiter {
            self.writerWaiter = nil
            inFlight = item
            writerWaiter.resume(returning: item)
        } else {
            outbox.append(item)
        }
    }

    /// Ahead of queued messages. A newer ping's pong replaces an unsent one.
    private func enqueueControl(_ item: Outbound) {
        guard writerWaiter == nil else {
            enqueue(item)
            return
        }
        if item.kind == .pong, let index = outbox.firstIndex(where: { $0.kind == .pong }) {
            outbox[index] = item
            return
        }
        outbox.insert(item, at: outbox.firstIndex(where: { $0.kind == .message }) ?? outbox.endIndex)
    }

    private func queueClose(_ code: WebSocketCloseCode?, reason: String) {
        closeQueued = true
        enqueue(Outbound(
            id: 0, kind: .close, bytes: WebSocketFrame.close(code, reason: reason).encoded(maskKey: Self.maskKey())))
        deadlineTask?.cancel()
        deadlineTask = Task { [sleep, deadline = options.closeDeadline] in
            do { try await sleep(deadline) } catch { return }
            self.finish()
        }
    }

    private func nextOutbound() async -> Outbound? {
        guard closeTask == nil else { return nil }
        guard outbox.isEmpty else {
            let item = outbox.removeFirst()
            inFlight = item
            return item
        }
        return await withCheckedContinuation { writerWaiter = $0 }
    }

    private func runWriter() async {
        while let item = await nextOutbound() {
            do {
                try await channel.write(item.bytes, timeout: Self.writeTimeout(forBytes: item.bytes.count))
            } catch {
                inFlight?.completion?.resume(throwing: WebSocketError.sendInterrupted)
                inFlight = nil
                lost(error)
                return
            }
            inFlight?.completion?.resume()
            inFlight = nil
            if item.kind == .close { closeFrameWritten() }
        }
    }

    private func closeFrameWritten() {
        closeWritten = true
        if awaitsPeerClose, peerClose == nil { return }
        finish()
    }

    // MARK: Keepalive

    private func runKeepalive(_ keepalive: Options.Keepalive) async {
        var count: UInt32 = 0
        while ending == nil {
            do { try await sleep(keepalive.interval) } catch { return }
            guard ending == nil else { return }
            count &+= 1
            heardSincePing = false
            enqueueControl(Outbound(
                id: 0, kind: .ping,
                bytes: WebSocketFrame(opcode: .ping, payload: Self.bytes(count)).encoded(maskKey: Self.maskKey())))
            while true {
                do { try await sleep(keepalive.pongDeadline) } catch { return }
                guard ending == nil else { return }
                if heardSincePing { break }
                // A stopped reader hears nothing: the consumer is behind, not the server.
                if readerPause != nil { continue }
                end(.pongTimedOut)
                finish()
                return
            }
        }
    }

    // MARK: Teardown

    /// Records why the link ended and fails what can no longer happen: queued
    /// sends never left, and nothing more is read for a local end.
    private func end(_ error: WebSocketError) {
        guard ending == nil else { return }
        ending = error
        let queued = outbox
        outbox = []
        for item in queued { item.completion?.resume(throwing: error) }
        if case .closedLocally = error {
            inbox = []
            inboxHead = 0
            inboxBytes = 0
        }
        let waiting = receivers
        receivers = []
        for receiver in waiting { receiver.continuation.resume(throwing: error) }
        keepaliveTask?.cancel()
        if let readerPause {
            self.readerPause = nil
            readerPause.resume()
        }
    }

    private func abandon() {
        end(.closedLocally)
        finish()
    }

    /// Stops everything and closes the channel. Idempotent.
    private func finish() {
        guard closeTask == nil else { return }
        let error = ending ?? .closedLocally
        if ending == nil { end(error) }
        inFlight?.completion?.resume(throwing: WebSocketError.sendInterrupted)
        inFlight = nil
        let queued = outbox
        outbox = []
        for item in queued { item.completion?.resume(throwing: error) }
        writerWaiter?.resume(returning: nil)
        writerWaiter = nil
        readerPause?.resume()
        readerPause = nil
        handshakeWaiter?.resume(throwing: error)
        handshakeWaiter = nil
        readerTask?.cancel()
        writerTask?.cancel()
        keepaliveTask?.cancel()
        deadlineTask?.cancel()
        closeTask = Task { [channel] in try? await channel.close(timeout: Self.channelCloseTimeout) }
        let waiters = finishWaiters
        finishWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private static func maskKey() -> UInt32 {
        UInt32.random(in: .min ... .max)
    }

    private static func bytes(_ value: UInt32) -> Data {
        Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }
}
