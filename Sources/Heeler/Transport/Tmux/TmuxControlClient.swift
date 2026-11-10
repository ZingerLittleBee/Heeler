import Foundation

/// One tmux control-mode client on one exec (ADR 0043). Commands go out a
/// line each in the order they were sent; tmux replies in that order, so the
/// client hands each reply to the command that asked by order alone. The
/// pane output and notifications between replies are delivered in between,
/// in the order tmux printed them.
///
/// The exec runs a shell that execs tmux, so nothing is written until tmux has
/// printed: a line written earlier could be read by the shell instead. The
/// client ends once, for every command still waiting and every event reader.
actor TmuxControlClient {
    enum Event: Equatable, Sendable {
        case output(pane: String, bytes: Data)
        case notification(TmuxControlNotification)
        /// The reply to a command sent with `send(_:tag:)`.
        case replied(tag: UInt64, TmuxControlReply)
        /// The last event.
        case ended(End)
    }

    enum End: Equatable, Sendable {
        /// tmux ended the client with `%exit`: it was detached, its session
        /// ended, or the server exited. tmux gives a reason for some of these.
        case exited(reason: String?)
        /// The exec ended without tmux saying so: tmux died or never started.
        case channelEnded
        case failed(TransportError)
        /// Heeler closed the client.
        case closed
    }

    /// What a command still waiting gets once the client ended.
    struct Ended: Error, Equatable {
        let end: End
    }

    private enum Waiter {
        case tagged(UInt64)
        /// A `run`, answered through `runs` while it still waits there.
        case run(UInt64)
    }

    nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation
    private let lines: AsyncStream<Data>
    private let lineSink: AsyncStream<Data>.Continuation
    private let channel: any WindowsTerminalExecChannel
    private let readTimeout: Duration
    private let writeTimeout: Duration
    private var reader: TmuxControlReader
    private var waiters: [Waiter] = []
    private var runs: [UInt64: CheckedContinuation<TmuxControlReply, any Error>] = [:]
    private var nextRun: UInt64 = 0
    private var repliedToClient = false
    private var writer: Task<Void, Never>?

    /// The replies of the commands the client was started with, one block each
    /// with no client flag, as far as they ran before the first reply to a
    /// command the client wrote. A failed one stopped the rest.
    private(set) var startReplies: [TmuxControlReply] = []
    private(set) var end: End?

    init(
        channel: any WindowsTerminalExecChannel,
        readTimeout: Duration = .seconds(30),
        writeTimeout: Duration = .seconds(10),
        reader: TmuxControlReader = TmuxControlReader()
    ) {
        self.channel = channel
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
        self.reader = reader
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
        (lines, lineSink) = AsyncStream.makeStream(of: Data.self)
        Task { await self.read() }
    }

    /// Commands written or waiting to be, whose replies have not come.
    var waitingCommands: Int { waiters.count }

    /// Whether tmux printed and the client began writing.
    var isWriting: Bool { writer != nil }

    /// Sends `command`; its reply arrives in `events` as `.replied(tag:)`, in
    /// order with the output around it.
    func send(_ command: TmuxControlCommand, tag: UInt64) throws {
        if let end { throw Ended(end: end) }
        waiters.append(.tagged(tag))
        lineSink.yield(Self.line(command))
    }

    /// Sends `command` and waits for its reply. A run that times out or is
    /// cancelled still has its reply coming, and keeps its place in line.
    func run(_ command: TmuxControlCommand, timeout: Duration) async throws -> TmuxControlReply {
        if let end { throw Ended(end: end) }
        nextRun += 1
        let id = nextRun
        waiters.append(.run(id))
        lineSink.yield(Self.line(command))
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.stopWaiting(id, with: TransportError.timedOut)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { runs[id] = $0 }
        } onCancel: {
            Task { await self.stopWaiting(id, with: CancellationError()) }
        }
    }

    /// Ends the client and closes its exec: tmux reads the end of its input
    /// and detaches the client.
    func close() async {
        finish(.closed, closingChannel: false)
        try? await channel.close(timeout: Self.closeTimeout)
    }

    private static func line(_ command: TmuxControlCommand) -> Data {
        Data((command.line + "\n").utf8)
    }

    private func stopWaiting(_ id: UInt64, with error: any Error) {
        runs.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: Reading

    private func read() async {
        while end == nil {
            let bytes: Data?
            do {
                bytes = try await channel.read(maximumBytes: 64 * 1024, timeout: readTimeout)
            } catch TransportError.timedOut {
                continue
            } catch {
                finish(.failed(Self.transportError(error)))
                return
            }
            guard end == nil else { return }
            guard let bytes else {
                finish(.channelEnded)
                return
            }
            guard !bytes.isEmpty else { continue }
            startWriting()
            let read: [TmuxControlReader.Event]
            do {
                read = try reader.read(bytes)
            } catch {
                finish(
                    .failed(.malformedResponse(String(localized: "tmux: The control client printed a line too long to read."))))
                return
            }
            for event in read {
                take(event)
                if end != nil { return }
            }
        }
    }

    private func take(_ event: TmuxControlReader.Event) {
        switch event {
        case .reply(let reply):
            guard reply.fromClient else {
                if !repliedToClient { startReplies.append(reply) }
                return
            }
            repliedToClient = true
            guard !waiters.isEmpty else {
                finish(.failed(.malformedResponse(String(localized: "tmux: A reply came that no command asked for."))))
                return
            }
            switch waiters.removeFirst() {
            case .tagged(let tag): eventSink.yield(.replied(tag: tag, reply))
            case .run(let id): runs.removeValue(forKey: id)?.resume(returning: reply)
            }
        case .output(let pane, let bytes):
            eventSink.yield(.output(pane: pane, bytes: bytes))
        case .notification(let notification):
            eventSink.yield(.notification(notification))
        case .exit(let reason):
            finish(.exited(reason: reason))
        }
    }

    // MARK: Writing

    private func startWriting() {
        guard writer == nil, end == nil else { return }
        writer = Task { [lines, channel, writeTimeout] in
            for await line in lines {
                do {
                    try await channel.write(line, timeout: writeTimeout)
                } catch {
                    await self.finish(.failed(Self.transportError(error)))
                    return
                }
            }
        }
    }

    // MARK: Ending

    private func finish(_ end: End, closingChannel: Bool = true) {
        guard self.end == nil else { return }
        self.end = end
        waiters = []
        let waiting = runs
        runs = [:]
        for continuation in waiting.values { continuation.resume(throwing: Ended(end: end)) }
        lineSink.finish()
        eventSink.yield(.ended(end))
        eventSink.finish()
        if closingChannel {
            Task { [channel] in try? await channel.close(timeout: Self.closeTimeout) }
        }
    }

    private static func transportError(_ error: any Error) -> TransportError {
        error as? TransportError ?? .channelFailed(detail: String(describing: error))
    }

    private static let closeTimeout = Duration.seconds(2)
}
