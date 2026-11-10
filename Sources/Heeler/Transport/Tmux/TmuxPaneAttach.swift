import Foundation

/// One Attach on a tmux Pane (ADR 0043): a control client in a session of
/// Heeler's own, whose events `TmuxPaneFeed` turns into the bytes of a
/// terminal that shows only that Pane.
///
/// The client's first reply to a command it wrote answers the barrier, and
/// says whether the session came out as `TmuxAttachScript` meant it. What came
/// before it belongs to the session's start and is dropped. A session that
/// started wrong is ended.
///
/// The output ends with `TransportError.tmuxPaneGone` once the Pane is gone or
/// Heeler's session no longer holds it, and with the client's own failure when
/// its exec failed. Ending the session closes the exec: tmux reads the end of
/// its input, detaches the client, and the session ends with it.
///
/// Keys are not sent yet: they are dropped.
actor TmuxPaneAttach {
    private let client: TmuxControlClient
    private let session: String
    private let pane: String
    private let viewRows: Int
    private let includingHistory: Bool
    private var feed: TmuxPaneFeed?
    private var starting: CheckedContinuation<Void, any Error>?
    private var startResult: Result<Void, any Error>?
    private var pending = Data()
    private var reader: CheckedContinuation<Data?, any Error>?
    private var outcome: Result<Void, any Error>?

    /// The tag of the barrier. `TmuxPaneFeed` tags its commands from 1.
    private static let barrierTag: UInt64 = 0

    private init(client: TmuxControlClient, session: String, pane: String, request: TerminalAttachRequest) {
        self.client = client
        self.session = session
        self.pane = pane
        viewRows = request.rows
        includingHistory = !request.surfaceHasHistory
    }

    /// Opens the Attach on `channel`, an exec of `TmuxAttachScript.script`
    /// for `session` and `pane`, once its session started as meant and within
    /// `startLimit`.
    static func open(
        channel: any WindowsTerminalExecChannel, session: String, pane: String, request: TerminalAttachRequest,
        startLimit: Duration
    ) async throws -> TerminalAttachSession {
        let client = TmuxControlClient(channel: channel)
        let attach = TmuxPaneAttach(client: client, session: session, pane: pane, request: request)
        try await attach.start(within: startLimit)
        let input = TerminalAttachInputQueue()
        let pump = Task {
            try? await input.pump(write: { _ in }, resize: { _, _ in })
        }
        return TerminalAttachSession(
            output: { AsyncThrowingStream { try await attach.read() } },
            input: input
        ) {
            input.finish()
            pump.cancel()
            await attach.close()
        }
    }

    private func start(within limit: Duration) async throws {
        let events = client.events
        Task {
            for await event in events { await self.take(event) }
        }
        try await client.send(TmuxAttachScript.barrier(session: session), tag: Self.barrierTag)
        let timer = Task { [weak self] in
            try await Task.sleep(for: limit)
            await self?.failStart(TransportError.timedOut)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let startResult {
                    continuation.resume(with: startResult)
                } else {
                    starting = continuation
                }
            }
        } onCancel: {
            Task { await self.failStart(CancellationError()) }
        }
    }

    private func failStart(_ error: any Error) async {
        guard startResult == nil else { return }
        finishStart(.failure(error))
        await client.close()
    }

    private func finishStart(_ result: Result<Void, any Error>) {
        guard startResult == nil else { return }
        startResult = result
        starting?.resume(with: result)
        starting = nil
    }

    /// Ends the Attach: the client's exec closes, and the output ends.
    func close() async {
        await client.close()
        finishOutput(.success(()))
    }

    // MARK: Events

    private func take(_ event: TmuxControlClient.Event) async {
        guard var feed else {
            await starting(with: event)
            return
        }
        if case .ended(let end) = event {
            finishOutput(Self.outcome(of: end))
            return
        }
        let actions = feed.receive(event)
        self.feed = feed
        await perform(actions)
    }

    private func starting(with event: TmuxControlClient.Event) async {
        guard startResult == nil else { return }
        switch event {
        case .replied(Self.barrierTag, let reply):
            switch TmuxAttachScript.started(reply, pane: pane) {
            case .ready(let session, let window):
                var feed = TmuxPaneFeed(
                    pane: pane, window: window, session: session, viewRows: viewRows,
                    includingHistory: includingHistory)
                let actions = feed.start()
                self.feed = feed
                finishStart(.success(()))
                await perform(actions)
            case .failed(let session):
                let failure = await refusal()
                if let session {
                    _ = try? await client.run(TmuxControlCommand(["kill-session", "-t", session]), timeout: .seconds(5))
                }
                await failStart(failure)
            }
        case .ended(let end):
            finishStart(.failure(Self.startFailure(end)))
        default:
            break
        }
    }

    /// Why the session did not come out as meant: a Pane that is gone ends the
    /// Terminal, anything else is tmux's own word.
    private func refusal() async -> any Error {
        let said = await client.startReplies.filter { !$0.succeeded }.flatMap(\.lines)
            .map { String(decoding: $0, as: UTF8.self) }
        if said.isEmpty || said.contains(where: { $0.hasPrefix("can't find pane") }) {
            return TransportError.tmuxPaneGone
        }
        return TransportError.malformedResponse(said.joined(separator: " "))
    }

    private static func startFailure(_ end: TmuxControlClient.End) -> any Error {
        switch end {
        case .failed(let failure): failure
        case .closed: CancellationError()
        case .exited, .channelEnded:
            TransportError.malformedResponse(String(localized: "tmux: The control client ended before it attached."))
        }
    }

    private static func outcome(of end: TmuxControlClient.End) -> Result<Void, any Error> {
        switch end {
        case .closed: .success(())
        case .failed(let failure): .failure(failure)
        // The session went with its window, or the server with everything.
        case .exited, .channelEnded: .failure(TransportError.tmuxPaneGone)
        }
    }

    private func perform(_ actions: [TmuxPaneFeed.Action]) async {
        for action in actions {
            switch action {
            case .send(let command, let tag):
                try? await client.send(command, tag: tag)
            case .write(let bytes):
                deliver(bytes)
            case .end(.paneGone), .end(.sessionLeft):
                finishOutput(.failure(TransportError.tmuxPaneGone))
                await client.close()
            case .end(.paintFailed):
                finishOutput(
                    .failure(TransportError.malformedResponse(String(localized: "tmux: The Pane's screen could not be read."))))
                await client.close()
            }
        }
    }

    // MARK: Output

    private func deliver(_ bytes: Data) {
        guard outcome == nil, !bytes.isEmpty else { return }
        if let reader {
            self.reader = nil
            reader.resume(returning: bytes)
        } else {
            pending.append(bytes)
        }
    }

    private func finishOutput(_ result: Result<Void, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        guard let reader else { return }
        self.reader = nil
        if pending.isEmpty { reader.resume(with: result.map { nil }) }
    }

    /// The next bytes for the terminal; nil once the Attach ended cleanly.
    /// One reader at a time.
    func read() async throws -> Data? {
        if !pending.isEmpty {
            defer { pending = Data() }
            return pending
        }
        if let outcome { return try outcome.map { nil }.get() }
        guard reader == nil else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }
}
