import Foundation

/// One tmux control-mode client on one exec (ADR 0045). Commands go out a
/// line each in the order they were sent; tmux replies in that order, so the
/// client hands each reply to the command that asked by order alone. The
/// pane output and notifications between replies are delivered in between,
/// in the order tmux printed them.
///
/// The exec runs a shell that starts tmux, so nothing is written until tmux
/// has printed: a line written earlier could be read by the shell instead.
/// Closing is the exception, and the shell has already read its `exit`, so
/// that line cannot become a shell command. The client ends once, for every
/// command still waiting and every event reader.
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
        /// A `post`, whose reply nobody reads.
        case dropped
    }

    nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation
    private let lines: AsyncStream<Data>
    private let lineSink: AsyncStream<Data>.Continuation
    private let channel: any WindowsTerminalExecChannel
    private let closeCommand: TmuxControlCommand
    private let readTimeout: Duration
    private let writeTimeout: Duration
    private let closeTimeout: Duration
    private var reader: TmuxControlReader
    private var waiters: [Waiter] = []
    private var runs: [UInt64: CheckedContinuation<TmuxControlReply, any Error>] = [:]
    private var nextRun: UInt64 = 0
    private var repliedToClient = false
    private var writer: Task<Void, Never>?
    private var isClosing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    /// The replies of the commands the client was started with, one block each
    /// with no client flag, as far as they ran before the first reply to a
    /// command the client wrote. A failed one stopped the rest.
    private(set) var startReplies: [TmuxControlReply] = []
    private(set) var end: End?

    init(
        channel: any WindowsTerminalExecChannel,
        closeCommand: TmuxControlCommand,
        readTimeout: Duration = .seconds(30),
        writeTimeout: Duration = .seconds(10),
        closeTimeout: Duration = .seconds(2),
        reader: TmuxControlReader = TmuxControlReader()
    ) {
        self.channel = channel
        self.closeCommand = closeCommand
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
        self.closeTimeout = closeTimeout
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

    /// Sends `command` without waiting for its reply, which is dropped. Its
    /// effects come in order with everything sent before and after it.
    func post(_ command: TmuxControlCommand) throws {
        if let end { throw Ended(end: end) }
        waiters.append(.dropped)
        lineSink.yield(Self.line(command))
    }

    /// Sends `command` and waits for its reply. A run that times out or is
    /// cancelled still has its reply coming, and keeps its place in line. A
    /// run whose task was cancelled before it began sends nothing.
    func run(
        _ command: TmuxControlCommand,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onSent: (@Sendable () -> Void)? = nil
    ) async throws -> TmuxControlReply {
        try await enqueueAndRun(
            line: Self.line(command), leadingDroppedReplies: 0,
            timeout: timeout, sleep: sleep, onSent: onSent)
    }

    /// Sends `setup` and `command` as one `;`-separated command list on a
    /// single control-mode line, drops `setup`'s reply, and waits for
    /// `command`'s reply. `setup` must be a command that cannot fail (such as
    /// `set-buffer -b <name> -- <text>`), so tmux always runs both commands on
    /// the server — or neither if the client's input closes before the newline
    /// arrives — and emits two replies in order.
    func run(
        after setup: TmuxControlCommand,
        _ command: TmuxControlCommand,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onSent: (@Sendable () -> Void)? = nil
    ) async throws -> TmuxControlReply {
        try await enqueueAndRun(
            line: Data((setup.line + " ; " + command.line + "\n").utf8),
            leadingDroppedReplies: 1,
            timeout: timeout, sleep: sleep, onSent: onSent)
    }

    private func enqueueAndRun(
        line: Data,
        leadingDroppedReplies: Int,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        onSent: (@Sendable () -> Void)?
    ) async throws -> TmuxControlReply {
        if let end { throw Ended(end: end) }
        try Task.checkCancellation()
        nextRun += 1
        let id = nextRun
        for _ in 0..<leadingDroppedReplies { waiters.append(.dropped) }
        waiters.append(.run(id))
        lineSink.yield(line)
        onSent?()
        let timer = Task { [weak self] in
            try await sleep(timeout)
            await self?.stopWaiting(id, with: TransportError.timedOut)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A cancel that came before the run waited here has nothing
                // to stop yet.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    runs[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.stopWaiting(id, with: CancellationError()) }
        }
    }

    /// Posts `closeCommand`, keeps reading until `%exit` or the channel ends,
    /// then closes the exec.
    ///
    /// An Attach passes `kill-session -t "=<session>"` so `server_destroy_session`
    /// clears `c->session` synchronously before `CLIENT_EXIT` and before
    /// `session_destroy`: detaching under `destroy-unattached on` leaves
    /// `c->session` pointing at a session whose `curw` is `NULL`, and `CLIENT_EXIT`
    /// with `c->session != NULL` while output is queued aborts `control_append_data`.
    /// Lines already queued are written first. A client that never ends still
    /// closes once `closeTimeout` passes.
    func close() async {
        if !isClosing, end == nil {
            isClosing = true
            try? post(closeCommand)
            startWriting()
        } else {
            isClosing = true
        }
        await waitForEnd(within: closeTimeout)
        if end == nil {
            finish(.closed, closingChannel: false)
        }
        try? await channel.close(timeout: closeTimeout)
    }

    /// Resumes once the client has ended, or once `timeout` has passed.
    private func waitForEnd(within timeout: Duration) async {
        if end != nil { return }
        let timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.resumeCloseWaiters()
        }
        defer { timeoutTask.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.end != nil {
                continuation.resume()
            } else {
                self.closeWaiters.append(continuation)
            }
        }
    }

    private func resumeCloseWaiters() {
        let waiting = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
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
            case .dropped: break
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
        resumeCloseWaiters()
        waiters = []
        let waiting = runs
        runs = [:]
        for continuation in waiting.values { continuation.resume(throwing: Ended(end: end)) }
        lineSink.finish()
        eventSink.yield(.ended(end))
        eventSink.finish()
        if closingChannel {
            let timeout = closeTimeout
            Task { [channel] in try? await channel.close(timeout: timeout) }
        }
    }

    private static func transportError(_ error: any Error) -> TransportError {
        error as? TransportError ?? .channelFailed(detail: String(describing: error))
    }
}
