import Foundation
import Synchronization

/// What an open Rex terminal hears of its block and its connection (ADR 0051).
enum RexTerminalSignal: Sendable, Equatable {
    /// The block closed, or its session went.
    case blockClosed
    /// Another client owns the block now, or none does, and the server's
    /// reason, such as `take`, or `lost` for an owner whose link dropped.
    case ownerChanged(String?, reason: String?)
    /// An event the block's creator raised, such as a title or process change.
    case blockEvent(name: String, payload: JSONValue?)
    /// The connection the terminal opened on is gone, or its control client
    /// was replaced by one with no attachments: a new attach starts afresh.
    case connectionReset
    /// Another server answers on the socket, not one that restored the last
    /// one's sessions.
    case serverChanged
}

/// How a Rex terminal's attach ended, as its runner tells the view.
enum RexTerminalEnding: Error, Sendable, Equatable {
    /// The block closed, its session went, or its program exited.
    case finished
    /// Another server answers on the socket: the block was the last one's.
    case serverGone
    /// The connection under the attach was lost or replaced, or the server
    /// forgot the session's attach. A new attach takes the next connection,
    /// attaches again where needed, and paints afresh.
    case connectionReset
    /// The block's output stopped, and starting it again did not bring it back.
    case outputUnavailable
    /// The block's history is too long to paint.
    case historyTooLong
    /// Input may have reached the terminal with no answer, or the server
    /// refused it. Nothing typed after it was sent, and it is never sent
    /// again, so nothing lands twice or out of order.
    case inputFailed
}

/// One terminal's hold on its Rex Host's connection, for as long as the
/// terminal is open (ADR 0051).
struct RexTerminalConnection: Sendable {
    let address: RexPaneAddress
    /// The server the terminal opened on. Another one ends it.
    let server: RexServerStatus
    /// The SSH connection the terminal opened on. A new one ends it.
    let generation: UInt64
    /// This side's control client, as the server names it in a block's owner.
    let clientID: String?
    /// The block's events and what became of the connection, in order.
    let signals: AsyncStream<RexTerminalSignal>
    /// Tickets and reads on the control link while it is still this server
    /// on this connection; channels under the connection's attach slots.
    let route: RexDataRoute
    let options: RexTerminalAttach.Options
    let sleep: RexTerminalStream.Sleep
    /// Makes sure the control client is attached to the block's session,
    /// sending `session.attach` only when it is not; no data link opens
    /// without it.
    let attachSession: @Sendable () async throws -> Void
    /// The server refused the block's stream for want of an attach: the
    /// next `attachSession` sends `session.attach` again.
    let forgetAttachment: @Sendable () async -> Void
    /// Sends one request about the block on the current control link.
    let call: @Sendable (_ method: String, _ payload: JSONValue) async throws -> Void
    /// Sends one request of the view's, its input or taking and giving back
    /// its size, on the live control link while it is still the terminal's:
    /// the same server, SSH connection and control client, which a link that
    /// resumed the client keeps. It never waits for a link; with none, the
    /// request is not sent. `deadline` is how long the link may stay silent
    /// once it is written, and how long it may wait in all, before its
    /// outcome counts as unknown.
    let deliver: @Sendable (_ method: String, _ payload: JSONValue, _ deadline: RexDeliveryDeadline) async
        -> RexDelivery
    /// The largest request the terminal's control link accepts, in bytes.
    let maxMessageBytes: Int
    /// The block's input lane, which Chat's input to it shares (ADR 0055).
    let lanes: RexBlockLanes
    /// What an earlier attach of the block on this control client claimed of
    /// its size and did not give back (ADR 0053), which this one gives back
    /// as if it had claimed it itself.
    let sizeClaim: RexSizeClaim?
    /// Keeps what this attach claims of the block's size, nil once it is
    /// given back, for whatever comes after it on the same control client.
    let noteSizeClaim: @Sendable (RexSizeClaim?) -> Void
    /// Whether a server answers on the connection the terminal opened on now:
    /// the same server, SSH connection and control client.
    let isCurrent: @Sendable () async -> Bool
}

/// What a control client claimed of a Rex block's size (ADR 0053).
enum RexSizeClaim: Sendable, Equatable {
    /// This client took it, or a take may have arrived: it is given back.
    case taken
    /// The server passed the block to the client because its owner's link
    /// dropped: it stays as the server made it.
    case handed
}

/// Hands each open Rex terminal what concerns it: its block's events, which
/// the inventory follower passes on as it reads them, and what became of the
/// connection (ADR 0051). Nothing here changes the inventory.
final class RexTerminalHub: Sendable {
    private struct Subscriber: Sendable {
        let address: RexPaneAddress
        let server: RexServerStatus
        let continuation: AsyncStream<RexTerminalSignal>.Continuation
    }

    private struct State {
        var subscribers: [UUID: Subscriber] = [:]
        /// Those waiting for the last open terminal to end.
        var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    func subscribe(
        _ address: RexPaneAddress, server: RexServerStatus
    ) -> (id: UUID, signals: AsyncStream<RexTerminalSignal>) {
        let (signals, continuation) = AsyncStream.makeStream(of: RexTerminalSignal.self)
        let id = UUID()
        state.withLock {
            $0.subscribers[id] = Subscriber(address: address, server: server, continuation: continuation)
        }
        return (id, signals)
    }

    func unsubscribe(_ id: UUID) {
        let (removed, idle) = state.withLock { state in
            let removed = state.subscribers.removeValue(forKey: id)
            guard state.subscribers.isEmpty else { return (removed, [CheckedContinuation<Void, Never>]()) }
            let idle = Array(state.idleWaiters.values)
            state.idleWaiters = [:]
            return (removed, idle)
        }
        removed?.continuation.finish()
        for waiter in idle { waiter.resume() }
    }

    /// The sessions open terminals on `server` belong to, whichever of its
    /// instances they opened on.
    func openSessions(on server: RexServerStatus) -> Set<String> {
        state.withLock {
            Set($0.subscribers.values.filter { $0.server.isSameServer(as: server) }.map(\.address.sessionID))
        }
    }

    var openTerminalCount: Int { state.withLock { $0.subscribers.count } }

    /// Returns once no terminal is open, or once the caller is cancelled.
    func untilNoneOpen() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waits = state.withLock { state in
                    // Checked under the lock the cancellation handler takes,
                    // so a cancellation never misses the waiter.
                    guard !state.subscribers.isEmpty, !Task.isCancelled else { return false }
                    state.idleWaiters[id] = continuation
                    return true
                }
                if !waits { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.idleWaiters.removeValue(forKey: id) }?.resume()
        }
    }

    /// One update from the control link, as the inventory follower read it.
    func observe(_ update: RexControlUpdate) {
        guard case .event(let event) = update else { return }
        signal { Self.signal(for: event, to: $0.address) }
    }

    /// A new control link answered for `server`. A terminal on another server
    /// hears so; the others carry on only on a link that resumed their client
    /// on their connection, and one on an earlier instance of the same
    /// server opens again, as on a new client.
    func linkChanged(to server: RexServerStatus, carriesOn: Bool) {
        signal { subscriber in
            if !subscriber.server.isSameServer(as: server) { return .serverChanged }
            if subscriber.server != server { return .connectionReset }
            return carriesOn ? nil : .connectionReset
        }
    }

    /// The connection went away under every open terminal.
    func resetAll() {
        signal { _ in .connectionReset }
    }

    private func signal(_ choose: (Subscriber) -> RexTerminalSignal?) {
        let chosen = state.withLock { state in
            state.subscribers.values.compactMap { subscriber in
                choose(subscriber).map { (subscriber.continuation, $0) }
            }
        }
        for (continuation, signal) in chosen { continuation.yield(signal) }
    }

    static func signal(for event: RexControlEvent, to address: RexPaneAddress) -> RexTerminalSignal? {
        if case .sessionDestroyed(let sessionID) = event.body {
            return sessionID == address.sessionID ? .blockClosed : nil
        }
        // A block's events come wrapped in its session.
        guard event.sessionID == nil || event.sessionID == address.sessionID else { return nil }
        switch event.body {
        case .blockClosed(let blockID) where blockID == address.blockID:
            return .blockClosed
        case .blockOwnerChanged(let blockID, let owner, _, let reason) where blockID == address.blockID:
            return .ownerChanged(owner, reason: reason)
        case .blockEvent(let blockID, _, let name, let payload) where blockID == address.blockID:
            return .blockEvent(name: name, payload: payload)
        default:
            return nil
        }
    }
}

/// One view of a Rex terminal block (ADRs 0051 and 0052): the stream's paints and output
/// become the view's bytes, the view's input goes out one request at a time,
/// the view's grid is asked for, and the ways it ends become
/// `RexTerminalEnding`.
///
/// Size (ADR 0053): shown means fitted. An attach opened for a view that
/// shows the terminal takes the block's size before its stream starts, so the
/// first paint comes at the view's grid; the view takes it again when it is
/// shown again, and at the user's tap. Nothing else owns the block: not a new
/// link or client on its own, not its owner going. The view gives back what
/// it took when it stops showing the terminal and when the attach ends,
/// unless the server has since passed the block to this client because its
/// owner's link dropped: that one stays as the server made it, so the owner
/// gets it back when it resumes, and a take on its own leaves it alone.
/// Taking and giving back go out one at a time, each once, through the same
/// gate as input. Another client's take after this one's is counted in the
/// size report, so the view leaves the size with it.
///
/// Nothing reaches the view before the first paint, which starts with a full
/// reset, as every later paint does; a paint arrives as one write, so the view
/// replaces what it showed in one go. The title follows the inventory's, and
/// the colors stay Heeler's.
///
/// Input: one queue per view takes keys, pastes, scrolling, focus, the Keys
/// panel and Stop alike, and sends one request at a time, each waiting for its
/// answer, since Rex may apply requests out of order when several are out.
/// Its requests take turns with Chat's input to the same block in the block's
/// lane (ADR 0055). Typed bytes go to the terminal's `write` as text, read by
/// `RexTerminalKeyReader`; keystrokes that queued meanwhile join the next
/// write, and pastes and events go as `block.event`. The gate opens with the
/// first paint and closes for good when the block closes, the program ends or
/// the attach ends. Input that finds no link that is the terminal's, as while
/// a dropped one resumes, is not sent and not kept, and the attach ends as a
/// connection reset, so the view reconnects. A request that may have arrived
/// with no answer, or that the server refused, is never sent again: what
/// queued behind it is dropped and the attach ends with `inputFailed`, so the
/// view says so.
actor RexTerminalAttach {
    struct Options: Sendable {
        var stream = RexTerminalStream.Options()
        /// How long the view's grid must hold before it is asked for.
        var sizeSettle: Duration = .milliseconds(150)
        /// How long the data link may outlast its block's close event before
        /// the attach ends anyway. Rex closes the link itself once the block's
        /// last output is out, so the view keeps that output.
        var closeGrace: Duration = .seconds(1)
        /// How long the control link may stay silent, once a request of input
        /// is written, before its outcome counts as unknown. Its answer may
        /// wait behind other messages as long as they keep arriving, up to
        /// the limit: a server that keeps sending but never answers holds
        /// the input queue no longer than that. Taking the size waits as long.
        var inputDeadline = RexDeliveryDeadline(silence: .seconds(10), limit: .seconds(60))
        /// How long giving the size back may wait. Short, since the attach
        /// waits for it as it ends.
        var giveBackDeadline = RexDeliveryDeadline(silence: .seconds(2), limit: .seconds(10))

        init() {}
    }

    typealias Grid = TerminalSizeReport.Grid

    private let connection: RexTerminalConnection
    private let stream: RexTerminalStream
    private let reports: AsyncStream<TerminalSizeReport>.Continuation
    private var report: TerminalSizeReport
    /// The grid last asked for, so the same one is never asked for twice.
    private var asked: Grid?
    private var sizeTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    private var ending: RexTerminalEnding?
    private var blockClosed = false
    private var stopped = false
    private let input: TerminalAttachInputQueue
    private var keys: RexTerminalKeyReader
    /// The first paint reached the view, so input may follow.
    private var painted = false
    /// The block's stream ended, or input failed: nothing more is sent.
    private var inputClosed = false
    /// This client took the size, so it is in line for the block and may own
    /// it: set once a take was answered or may have arrived, and cleared once
    /// a give back was answered. An attach starts with what an earlier one on
    /// the same control client left.
    private var claimed = false
    /// The server passed the block to this client because its owner's link
    /// dropped, as when the client that took it back from this one did: it
    /// stays as it is, for that owner to get back when it resumes. One its
    /// owner let go of or left is given back like any size this client took.
    private var handed = false
    /// Counts what said who owns the block: owner events and the stream's
    /// grids. A take or give back whose answer comes after more of them
    /// leaves the owner to them, since they may be newer than the answer.
    private var ownerNews: UInt64 = 0
    /// The claim last kept with the Host session.
    private var keptClaim: RexSizeClaim?
    /// The last take or give back, which the next one waits for, so they
    /// never overlap and go out in the order they were asked.
    private var ownershipTail: Task<Void, Never>?
    /// The take still out or waiting, which stopping lets go of.
    private var pendingTake: Task<TerminalSizeTake, Never>?
    /// The give back stopping started, which every stop waits for.
    private var finalGiveBack: Task<Void, Never>?
    /// A take of this client's is out, so whether an owner change heard
    /// meanwhile came before or after it is not known yet.
    private var takeOut = false
    /// Another client's take was heard while this client's was out, and no
    /// owner change to this client after it: once this one's answer comes,
    /// the other came last.
    private var takenWhileOut = false
    /// The take the attach made on its own as it opened, for a view that
    /// shows it; nil when it made none.
    private var openingFit: Task<TerminalSizeTake, Never>?
    /// The stream waits for the opening take, so its snapshot, its first
    /// grid and the redraw the first paint reads are at the size it took.
    private var streamHeld = false

    private init(
        connection: RexTerminalConnection, input: TerminalAttachInputQueue, columns: Int, rows: Int,
        reports: AsyncStream<TerminalSizeReport>.Continuation
    ) {
        self.connection = connection
        self.input = input
        self.reports = reports
        stream = RexTerminalStream(
            session: connection.address.sessionID, block: connection.address.blockID, route: connection.route,
            options: connection.options.stream, sleep: connection.sleep)
        report = TerminalSizeReport(local: Grid(columns: columns, rows: rows), client: connection.clientID)
        keys = RexTerminalKeyReader(budget: Self.textBudget(connection))
        claimed = connection.sizeClaim != nil
        handed = connection.sizeClaim == .handed
        keptClaim = connection.sizeClaim
    }

    /// Opens the block's stream for a view of `columns` by `rows`, and asks
    /// for that size. `fitting` takes the block's size for the view first,
    /// for a view that shows the terminal (ADR 0053), and the stream starts
    /// once that take has ended. The session must be attached already.
    static func session(
        on connection: RexTerminalConnection, columns: Int, rows: Int, fitting: Bool = false
    ) async -> TerminalAttachSession {
        let (reports, continuation) = AsyncStream.makeStream(
            of: TerminalSizeReport.self, bufferingPolicy: .bufferingNewest(1))
        let input = TerminalAttachInputQueue()
        let attach = RexTerminalAttach(
            connection: connection, input: input, columns: columns, rows: rows, reports: continuation)
        await attach.start(fitting: fitting)
        let pump = Task {
            try? await input.pump(
                write: { bytes in try await attach.write(bytes) },
                resize: { columns, rows in await attach.resize(columns: columns, rows: rows) })
        }
        let paster = TerminalAttachPaster(
            refusal: { text in Self.pasteRefusal(text, on: connection) },
            paste: { text in input.perform { await attach.paste(text) } })
        let ownership = TerminalSizeOwnership(
            take: { await attach.take() },
            fit: { await attach.fit() },
            opened: { await attach.openingFitOutcome() },
            viewerLeft: { Task { await attach.viewerLeft() } })
        return TerminalAttachSession(
            output: { AsyncThrowingStream { try await attach.read() } },
            input: input,
            inputBeginsWithOutput: true,
            paster: paster,
            sizeReports: reports,
            sizeOwnership: ownership
        ) {
            input.finish()
            pump.cancel()
            await attach.stop()
        }
    }

    private func start(fitting: Bool) async {
        reports.yield(report)
        let signals = connection.signals
        signalTask = Task { [weak self] in
            for await signal in signals {
                await self?.receive(signal)
            }
        }
        if fitting {
            // The server applies a take's size before it answers, so a stream
            // that starts after the answer starts at the view's grid. A take
            // that goes through asks for that grid as the block's owner.
            openingFit = enqueueTake(automatic: true)
            streamHeld = true
        } else {
            askForSize(afterSettling: false)
            await stream.start()
        }
    }

    // MARK: Output

    /// The view's next bytes: a paint or the program's output. Nil once the
    /// view stopped the attach; throws how it ended otherwise.
    func read() async throws -> Data? {
        if streamHeld, let openingFit {
            _ = await openingFit.value
            streamHeld = false
            // A take that did not go through, or that found the block this
            // client's already, asked for no grid: it is asked for now, as
            // the stream starts.
            if asked == nil { askForSize(afterSettling: false) }
        }
        while true {
            guard let instruction = await stream.next() else {
                if let ending { throw ending }
                return nil
            }
            switch instruction {
            case .grid(let grid):
                report.server = Grid(columns: grid.columns, rows: grid.rows)
                report.owner = grid.owner
                ownerNews &+= 1
                reports.yield(report)
            case .paint(let bytes, _):
                guard !bytes.isEmpty else { continue }
                painted = true
                return bytes
            case .feed(let bytes):
                if !bytes.isEmpty { return bytes }
            case .title:
                // The title follows the inventory's title.
                continue
            case .theme(let theme):
                // The terminal's own default colors, as the server has them.
                return theme.sequences
            case .exited:
                await end(.finished)
            case .restarting:
                // The screen may show what the program has moved on from, so
                // nothing typed at it is sent until the next paint.
                painted = false
                _ = turnAway()
            case .ended(let end):
                inputClosed = true
                if let ending { throw ending }
                switch end {
                case .closedHere:
                    return nil
                case .blockClosed:
                    throw RexTerminalEnding.finished
                case .notAttached where !blockClosed:
                    // The server no longer counts the session as attached for
                    // this client, so the attach this side remembers is stale:
                    // the next one attaches again and paints afresh.
                    await connection.forgetAttachment()
                    throw RexTerminalEnding.connectionReset
                case .redrawTooLarge where !blockClosed:
                    throw RexTerminalEnding.historyTooLong
                case .connectionLost:
                    throw blockClosed ? RexTerminalEnding.finished : RexTerminalEnding.connectionReset
                case .paintFailed, .notAttached, .streamUnavailable, .redrawTooLarge:
                    if blockClosed { throw RexTerminalEnding.finished }
                    // A stream that gave up while its connection went, or was
                    // replaced, ended with the connection, not on Rex's side:
                    // the view reconnects.
                    if await !connection.isCurrent() { throw RexTerminalEnding.connectionReset }
                    throw RexTerminalEnding.outputUnavailable
                }
            }
        }
    }

    /// Ends the attach for `reason`. Output queued before it still reaches
    /// the view; the stream then closes with 1000.
    private func end(_ reason: RexTerminalEnding) async {
        guard ending == nil, !stopped else { return }
        ending = reason
        await stream.stop()
    }

    /// The view let go: the stream closes with 1000, a size the view took is
    /// given back, and this returns once both are done, so the block is free
    /// for its next data link.
    func stop() async {
        if !stopped {
            stopped = true
            sizeTask?.cancel()
            closeTask?.cancel()
            signalTask?.cancel()
            reports.finish()
            // A take still out is let go of; whether it may have arrived
            // decides whether there is anything to give back.
            pendingTake?.cancel()
            openingFit?.cancel()
            finalGiveBack = enqueueGiveBack()
        }
        await stream.stop()
        await finalGiveBack?.value
    }

    // MARK: Input

    /// Input may go out: the first paint is in, and the block, its program and
    /// the attach are all still there.
    private var inputIsOpen: Bool {
        painted && !inputClosed && !blockClosed && ending == nil && !stopped
    }

    /// Sends one write of the view's, with the keystrokes queued behind it
    /// joined in where they fit. Throws `TerminalAttachInputError.notSent`
    /// for input not sent, which the queue skips, and `.sessionEnded` once
    /// nothing more will be.
    func write(_ bytes: Data) async throws {
        guard inputIsOpen else { throw turnAway() }
        var pieces = keys.read(bytes)
        for queued in input.takeQueuedKeystrokes() {
            pieces += keys.read(queued)
        }
        try await send(RexTerminalKeyReader.merged(pieces, budget: keys.budget))
    }

    /// Sends a paste whole, for the server to frame as its terminal's modes say.
    func paste(_ text: String) async {
        guard inputIsOpen else {
            _ = turnAway()
            return
        }
        try? await send([.paste(text)])
    }

    /// Input the gate turns away is dropped, with the keystrokes queued
    /// behind it: none of it was sent, and none is kept for later.
    private func turnAway() -> TerminalAttachInputError {
        _ = input.takeQueuedKeystrokes()
        return .notSent
    }

    /// One write's pieces go together in the block's lane, so Chat's input to
    /// the block never comes between them, nor theirs between Chat's.
    private func send(_ pieces: [RexTerminalInputPiece]) async throws {
        guard !pieces.isEmpty else { return }
        do {
            try await connection.lanes.enter(connection.address)
        } catch {
            throw turnAway()
        }
        defer { connection.lanes.leave(connection.address) }
        for piece in pieces {
            guard inputIsOpen else { throw turnAway() }
            let request = Self.request(for: piece, at: connection.address)
            switch await connection.deliver(request.method, request.payload, connection.options.inputDeadline) {
            case .answered:
                continue
            case .notSent:
                if stopped || Task.isCancelled { throw turnAway() }
                // No link is the terminal's, as while a dropped one resumes.
                // Nothing was sent and nothing is kept, so the view must not
                // look live meanwhile: it reconnects and paints afresh.
                closeInput()
                await end(.connectionReset)
                throw TerminalAttachInputError.sessionEnded
            case .refused(let failure) where failure.kind == .notFound:
                closeInput()
                await end(.finished)
                throw TerminalAttachInputError.sessionEnded
            case .refused, .unknown:
                closeInput()
                await failInput()
                throw TerminalAttachInputError.sessionEnded
            }
        }
    }

    /// Nothing more is sent, and what queued is dropped.
    private func closeInput() {
        inputClosed = true
        input.abandon()
    }

    /// Ends the attach for input that may have arrived unanswered, or was
    /// refused, so the view says so. It wins over a reset the view has not
    /// heard of yet, after which a new attach would carry on as if nothing
    /// was lost.
    private func failInput() async {
        guard !stopped else { return }
        if ending == nil || ending == .connectionReset { ending = .inputFailed }
        await stream.stop()
    }

    /// The most JSON one text write may carry, under the control link's limit
    /// with room for the rest of the request.
    static func textBudget(_ connection: RexTerminalConnection) -> Int {
        let address = connection.address
        return connection.maxMessageBytes - 1024 - 6 * (address.sessionID.utf8.count + address.blockID.utf8.count)
    }

    /// Why `text` cannot go to the terminal as one paste, or nil when it can:
    /// its request would pass the control link's limit. A paste is never cut.
    static func pasteRefusal(_ text: String, on connection: RexTerminalConnection) -> String? {
        let request = Self.request(for: .paste(text), at: connection.address)
        let probe = JSONValue.object([
            "type": .string("request"), "id": .string("h\(UInt64.max)"), "method": .string(request.method),
            "payload": request.payload,
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let bytes = try? encoder.encode(probe).count, bytes <= connection.maxMessageBytes else {
            return String(localized:
                "This paste is too large to send to a Rex terminal in one piece. Paste less at a time.")
        }
        return nil
    }

    /// The request that carries `piece` to the block at `address`.
    static func request(
        for piece: RexTerminalInputPiece, at address: RexPaneAddress
    ) -> (method: String, payload: JSONValue) {
        var payload: [String: JSONValue] = [
            "session_id": .string(address.sessionID), "block_id": .string(address.blockID),
        ]
        switch piece {
        case .text(let text):
            payload["args"] = .object(["data": .string(text)])
            return (RexInventoryWire.terminalMethod("write"), .object(payload))
        case .paste(let text):
            payload["event"] = .object(["type": .string("paste"), "payload": .object(["text": .string(text)])])
            return ("block.event", .object(payload))
        case .event(let type, let eventPayload):
            payload["event"] = .object(["type": .string(type), "payload": eventPayload])
            return ("block.event", .object(payload))
        }
    }

    // MARK: Signals

    private func receive(_ signal: RexTerminalSignal) async {
        guard !stopped else { return }
        switch signal {
        case .blockClosed:
            guard !blockClosed else { return }
            blockClosed = true
            let grace = connection.options.closeGrace
            closeTask = Task { [weak self, sleep = connection.sleep] in
                do { try await sleep(grace) } catch { return }
                await self?.end(.finished)
            }
        case .ownerChanged(let owner, let reason):
            report.owner = owner
            ownerNews &+= 1
            if owner == nil || owner != connection.clientID {
                handed = false
            } else if reason == Self.lostReason {
                // The server passed the block on because its owner's link
                // dropped: that owner gets it back when it resumes, unless
                // the block's owner changes meanwhile.
                handed = true
            }
            noteOwnerChange(to: owner, reason: reason)
            keepClaim()
            reports.yield(report)
            // A size asked for while another client owned the block is not
            // applied when it lets go, so it is asked for again.
            if owner == nil {
                asked = nil
                askForSize(afterSettling: false)
            }
        case .blockEvent:
            break
        case .connectionReset:
            await end(.connectionReset)
        case .serverChanged:
            await end(.serverGone)
        }
    }

    // MARK: Size

    /// The view's grid changed. It is asked for once it holds for a moment,
    /// so a rotation or a keyboard is one request.
    func resize(columns: Int, rows: Int) {
        guard !stopped else { return }
        report.local = Grid(columns: columns, rows: rows)
        reports.yield(report)
        askForSize(afterSettling: true)
    }

    private func askForSize(afterSettling: Bool) {
        sizeTask?.cancel()
        let settle = connection.options.sizeSettle
        sizeTask = Task { [weak self, sleep = connection.sleep] in
            if afterSettling {
                do { try await sleep(settle) } catch { return }
            }
            await self?.sendSize()
        }
    }

    /// Asks the server for the view's grid. Rex applies it only while no
    /// client owns the block, or this one does.
    private func sendSize() async {
        guard !stopped, ending == nil, let wanted = report.local, wanted != asked,
            Self.sizeRange.contains(wanted.columns), Self.sizeRange.contains(wanted.rows)
        else { return }
        asked = wanted
        do {
            try await connection.call(
                RexInventoryWire.terminalMethod("resize"),
                Self.resizePayload(connection.address, columns: wanted.columns, rows: wanted.rows))
        } catch {
            // Asked again with the next change, or when the owner lets go.
            if asked == wanted { asked = nil }
        }
    }

    /// The sizes Rex accepts.
    static let sizeRange = 1...65_535

    static func resizePayload(_ address: RexPaneAddress, columns: Int, rows: Int) -> JSONValue {
        .object([
            "session_id": .string(address.sessionID), "block_id": .string(address.blockID),
            "args": .object(["columns": .number(Double(columns)), "rows": .number(Double(rows))]),
        ])
    }

    // MARK: Taking the size

    static let takeMethod = "session.own_block"
    static let giveBackMethod = "session.disown_block"
    /// The reasons Rex gives for an owner change that this client made by
    /// taking, and for a block passed on because its owner's link dropped.
    static let takeReason = "take"
    static let lostReason = "lost"

    /// Takes the block's size for the view, at the user's tap: this client
    /// owns the block, and the view's grid is asked for as its owner. Waits
    /// for a take or give back before it, and is never sent again.
    func take() async -> TerminalSizeTake {
        guard !stopped else { return .notSent }
        return await enqueueTake(automatic: false).value
    }

    /// Takes the block's size for a view that shows the terminal again, on
    /// its own: as `take`, through the same queue, gate and deadlines, but
    /// nothing goes out while this client owns the block already.
    func fit() async -> TerminalSizeTake {
        guard !stopped else { return .notSent }
        return await enqueueTake(automatic: true).value
    }

    /// How the take the attach made on its own as it opened ended, once it
    /// has; nil when it made none.
    func openingFitOutcome() async -> TerminalSizeTake? {
        await openingFit?.value
    }

    private func enqueueTake(automatic: Bool) -> Task<TerminalSizeTake, Never> {
        let previous = ownershipTail
        let operation = Task { () -> TerminalSizeTake in
            await previous?.value
            return await self.performTake(automatic: automatic)
        }
        pendingTake = operation
        ownershipTail = Task { _ = await operation.value }
        return operation
    }

    /// The view stopped showing the terminal: a size it took is given back
    /// once the take or give back before it is done.
    func viewerLeft() {
        guard !stopped else { return }
        enqueueGiveBack()
    }

    @discardableResult
    private func enqueueGiveBack() -> Task<Void, Never> {
        let previous = ownershipTail
        let operation = Task {
            await previous?.value
            await self.performGiveBack()
        }
        ownershipTail = operation
        return operation
    }

    private func performTake(automatic: Bool) async -> TerminalSizeTake {
        guard !stopped, ending == nil, !blockClosed, !Task.isCancelled else { return .notSent }
        // A take on its own leaves a block this client owns as it is: one the
        // server handed over after its owner's link dropped stays as the
        // server made it, and one this client took needs nothing more.
        if automatic, handed || (connection.clientID != nil && report.owner == connection.clientID) {
            return .taken
        }
        let news = ownerNews
        takeOut = true
        takenWhileOut = false
        let delivery = await connection.deliver(
            Self.takeMethod, Self.ownershipPayload(connection.address, take: true), connection.options.inputDeadline)
        takeOut = false
        switch delivery {
        case .answered(let response):
            claimed = true
            handed = false
            noteTakenWhileOut()
            noteOwner(in: response, unless: news)
            keepClaim()
            await sendTakenSize()
            return .taken
        case .refused:
            takenWhileOut = false
            return .refused
        case .notSent:
            takenWhileOut = false
            return .notSent
        case .unknown:
            // It may have arrived, so this client may own the block: what
            // gives back a size the view took gives this one back too.
            claimed = true
            handed = false
            noteTakenWhileOut()
            keepClaim()
            return .unknown
        }
    }

    /// Counts another client's take of the block from this one (ADR 0053):
    /// one heard while this client held the size, or after a take of its own
    /// went out and before an owner change to it. Rex follows a take that
    /// moves the block with its owner change before the answer, so one heard
    /// while a take is out is settled once its answer comes.
    private func noteOwnerChange(to owner: String?, reason: String?) {
        guard let client = connection.clientID, let owner else { return }
        if owner == client {
            takenWhileOut = false
        } else if reason == Self.takeReason {
            if takeOut {
                takenWhileOut = true
            } else if claimed {
                report.takenAway += 1
            }
        }
    }

    /// Another client's take came after this client's last one.
    private func noteTakenWhileOut() {
        guard takenWhileOut else { return }
        takenWhileOut = false
        report.takenAway += 1
        if !stopped { reports.yield(report) }
    }

    /// Keeps what this client claims of the block with the Host session, so
    /// a give back that could not go out before the attach ended is made by
    /// the next attach on the same control client, or by the session once a
    /// link takes the client back.
    private func keepClaim() {
        let claim: RexSizeClaim? = claimed ? (handed ? .handed : .taken) : nil
        guard claim != keptClaim else { return }
        keptClaim = claim
        connection.noteSizeClaim(claim)
    }

    /// Asks for the view's grid as the block's owner, so it applies at once
    /// even when the server had another size in mind for this client.
    private func sendTakenSize() async {
        guard let wanted = report.local, Self.sizeRange.contains(wanted.columns), Self.sizeRange.contains(wanted.rows)
        else { return }
        asked = wanted
        let delivery = await connection.deliver(
            RexInventoryWire.terminalMethod("resize"),
            Self.resizePayload(connection.address, columns: wanted.columns, rows: wanted.rows),
            connection.options.inputDeadline)
        if case .answered = delivery { return }
        // Asked again with the next change.
        if asked == wanted { asked = nil }
    }

    /// Gives back a size this client took: the block passes to the next client
    /// in line, or keeps its size with no owner; one this client no longer
    /// owns only takes it out of line. A block the server passed to this
    /// client because its owner's link dropped is left alone. Sent once; one
    /// that was not sent, or had no answer, stays for the next give back to
    /// try.
    private func performGiveBack() async {
        guard claimed else { return }
        guard !blockClosed else {
            // A closed block has no size to give back.
            claimed = false
            keepClaim()
            return
        }
        if handed, report.owner == connection.clientID { return }
        let news = ownerNews
        let delivery = await connection.deliver(
            Self.giveBackMethod, Self.ownershipPayload(connection.address, take: false),
            connection.options.giveBackDeadline)
        switch delivery {
        case .answered(let response):
            claimed = false
            noteOwner(in: response, unless: news)
        case .refused:
            claimed = false
        case .notSent, .unknown:
            break
        }
        keepClaim()
    }

    /// The block's owner as an answer to a take or give back lists it,
    /// unless owner news came after `news` while the answer was on its way.
    private func noteOwner(in response: RexResponse, unless news: UInt64) {
        guard ownerNews == news, let answer = try? response.result(RexOwnershipAnswer.self),
            let block = answer.blocks?.first(where: { $0.blockID == connection.address.blockID })
        else { return }
        report.owner = block.owner
        if block.owner != connection.clientID { handed = false }
        keepClaim()
        if !stopped { reports.yield(report) }
    }

    /// One block, named so: an empty list would claim or give up every
    /// block in the session.
    static func ownershipPayload(_ address: RexPaneAddress, take: Bool) -> JSONValue {
        var payload: [String: JSONValue] = [
            "session_id": .string(address.sessionID), "block_ids": .array([.string(address.blockID)]),
        ]
        if take { payload["mode"] = .string(Self.takeReason) }
        return .object(payload)
    }
}

/// What Rex answers a take or give back with: each block and its owner after
/// it, with no owner left out.
private struct RexOwnershipAnswer: Decodable {
    struct Block: Decodable {
        let blockID: String?
        let owner: String?

        enum CodingKeys: String, CodingKey {
            case blockID = "block_id"
            case owner
        }
    }

    let blocks: [Block]?
}
