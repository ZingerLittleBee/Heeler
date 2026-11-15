import Foundation
import Synchronization

/// What an open Rex terminal hears of its block and its connection (ADR 0049).
enum RexTerminalSignal: Sendable, Equatable {
    /// The block closed, or its session went.
    case blockClosed
    /// Another client owns the block now, or none does.
    case ownerChanged(String?)
    /// An event the block's creator raised, such as a title or process change.
    case blockEvent(name: String, payload: JSONValue?)
    /// The connection the terminal opened on is gone, or its control client
    /// was replaced by one with no attachments: a new attach starts afresh.
    case connectionReset
    /// Another server instance answers on the socket.
    case serverChanged
}

/// How a Rex terminal's attach ended, as its runner tells the view.
enum RexTerminalEnding: Error, Sendable, Equatable {
    /// The block closed, its session went, or its program exited.
    case finished
    /// Another server answers on the socket: the block was the last one's.
    case serverGone
    /// The connection under the attach was lost or replaced. A new attach
    /// takes the next one and paints afresh.
    case connectionReset
    /// The block's output stopped, and starting it again did not bring it back.
    case outputUnavailable
}

/// One terminal's hold on its Rex Host's connection, for as long as the
/// terminal is open (ADR 0049).
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
    /// Attaches the control client to the block's session with
    /// `session.attach` unless it already is. Data links need it.
    let attachSession: @Sendable () async throws -> Void
    /// Sends one request about the block on the current control link.
    let call: @Sendable (_ method: String, _ payload: JSONValue) async throws -> Void
}

/// Hands each open Rex terminal what concerns it: its block's events, which
/// the inventory follower passes on as it reads them, and what became of the
/// connection (ADR 0049). Nothing here changes the inventory.
final class RexTerminalHub: Sendable {
    private struct Subscriber: Sendable {
        let address: RexPaneAddress
        let server: RexServerStatus
        let continuation: AsyncStream<RexTerminalSignal>.Continuation
    }

    private let subscribers = Mutex<[UUID: Subscriber]>([:])

    func subscribe(
        _ address: RexPaneAddress, server: RexServerStatus
    ) -> (id: UUID, signals: AsyncStream<RexTerminalSignal>) {
        let (signals, continuation) = AsyncStream.makeStream(of: RexTerminalSignal.self)
        let id = UUID()
        subscribers.withLock { $0[id] = Subscriber(address: address, server: server, continuation: continuation) }
        return (id, signals)
    }

    func unsubscribe(_ id: UUID) {
        subscribers.withLock { $0.removeValue(forKey: id) }?.continuation.finish()
    }

    /// The sessions open terminals on `server` belong to.
    func openSessions(on server: RexServerStatus) -> Set<String> {
        subscribers.withLock { Set($0.values.filter { $0.server == server }.map(\.address.sessionID)) }
    }

    var openTerminalCount: Int { subscribers.withLock { $0.count } }

    /// One update from the control link, as the inventory follower read it.
    func observe(_ update: RexControlUpdate) {
        guard case .event(let event) = update else { return }
        signal { Self.signal(for: event, to: $0.address) }
    }

    /// A new control link answered for `server`. A terminal on another server
    /// hears so; the others carry on only on a link that resumed their client
    /// on their connection.
    func linkChanged(to server: RexServerStatus, carriesOn: Bool) {
        signal { subscriber in
            if subscriber.server != server { return .serverChanged }
            return carriesOn ? nil : .connectionReset
        }
    }

    /// The connection went away under every open terminal.
    func resetAll() {
        signal { _ in .connectionReset }
    }

    private func signal(_ choose: (Subscriber) -> RexTerminalSignal?) {
        let chosen = subscribers.withLock { subscribers in
            subscribers.values.compactMap { subscriber in choose(subscriber).map { (subscriber.continuation, $0) } }
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
        case .blockOwnerChanged(let blockID, let owner, _, _) where blockID == address.blockID:
            return .ownerChanged(owner)
        case .blockEvent(let blockID, _, let name, let payload) where blockID == address.blockID:
            return .blockEvent(name: name, payload: payload)
        default:
            return nil
        }
    }
}

/// One view of a Rex terminal block (ADR 0049): the stream's paints and output
/// become the view's bytes, the view's grid is asked for and the block never
/// owned, and the ways it ends become `RexTerminalEnding`.
///
/// Nothing reaches the view before the first paint, which starts with a full
/// reset, as every later paint does; a paint arrives as one write, so the view
/// replaces what it showed in one go. The title follows the inventory's, and
/// the colors stay Heeler's. Input stays shut behind `RexTerminalInput`.
actor RexTerminalAttach {
    struct Options: Sendable {
        var stream = RexTerminalStream.Options()
        /// How long the view's grid must hold before it is asked for.
        var sizeSettle: Duration = .milliseconds(150)
        /// How long the data link may outlast its block's close event before
        /// the attach ends anyway. Rex closes the link itself once the block's
        /// last output is out, so the view keeps that output.
        var closeGrace: Duration = .seconds(1)

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

    private init(
        connection: RexTerminalConnection, columns: Int, rows: Int,
        reports: AsyncStream<TerminalSizeReport>.Continuation
    ) {
        self.connection = connection
        self.reports = reports
        stream = RexTerminalStream(
            session: connection.address.sessionID, block: connection.address.blockID, route: connection.route,
            options: connection.options.stream, sleep: connection.sleep)
        report = TerminalSizeReport(local: Grid(columns: columns, rows: rows), client: connection.clientID)
    }

    /// Opens the block's stream for a view of `columns` by `rows`, and asks
    /// for that size. The session must be attached already.
    static func session(on connection: RexTerminalConnection, columns: Int, rows: Int) async -> TerminalAttachSession {
        let (reports, continuation) = AsyncStream.makeStream(
            of: TerminalSizeReport.self, bufferingPolicy: .bufferingNewest(1))
        let attach = RexTerminalAttach(connection: connection, columns: columns, rows: rows, reports: continuation)
        await attach.start()
        let input = TerminalAttachInputQueue()
        let pump = Task {
            try? await input.pump(
                // Input is shut (`RexTerminalInput`): the view has no writer,
                // and nothing written here anyway leaves.
                write: { _ in },
                resize: { columns, rows in await attach.resize(columns: columns, rows: rows) })
        }
        return TerminalAttachSession(
            output: { AsyncThrowingStream { try await attach.read() } },
            input: input,
            acceptsInput: RexTerminalInput.isOpen,
            sizeReports: reports
        ) {
            input.finish()
            pump.cancel()
            await attach.stop()
        }
    }

    private func start() async {
        reports.yield(report)
        let signals = connection.signals
        signalTask = Task { [weak self] in
            for await signal in signals {
                await self?.receive(signal)
            }
        }
        askForSize(afterSettling: false)
        await stream.start()
    }

    // MARK: Output

    /// The view's next bytes: a paint or the program's output. Nil once the
    /// view stopped the attach; throws how it ended otherwise.
    func read() async throws -> Data? {
        while true {
            guard let instruction = await stream.next() else {
                if let ending { throw ending }
                return nil
            }
            switch instruction {
            case .grid(let grid):
                report.server = Grid(columns: grid.columns, rows: grid.rows)
                report.owner = grid.owner
                reports.yield(report)
            case .paint(let bytes, _), .feed(let bytes):
                if !bytes.isEmpty { return bytes }
            case .title, .theme:
                // The title follows the inventory's title, and Heeler keeps
                // its own colors.
                continue
            case .exited:
                await end(.finished)
            case .ended(let end):
                if let ending { throw ending }
                switch end {
                case .closedHere:
                    return nil
                case .blockClosed:
                    throw RexTerminalEnding.finished
                case .paintFailed, .notAttached, .streamUnavailable:
                    throw blockClosed ? RexTerminalEnding.finished : RexTerminalEnding.outputUnavailable
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

    /// The view let go: the stream closes with 1000, and this returns once
    /// nothing of it is left, so the block is free for its next data link.
    func stop() async {
        if !stopped {
            stopped = true
            sizeTask?.cancel()
            closeTask?.cancel()
            signalTask?.cancel()
            reports.finish()
        }
        await stream.stop()
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
        case .ownerChanged(let owner):
            report.owner = owner
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
    /// client owns the block; Heeler never takes ownership.
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
}
