import Foundation

/// One Attach on a tmux Pane (ADR 0043): a control client in a session of
/// Heeler's own, whose events `TmuxPaneFeed` turns into the bytes of a
/// terminal that shows only that Pane.
///
/// The client's first reply to a command it wrote answers the barrier, and
/// says whether the session came out as `TmuxAttachScript` meant it, on the
/// server the request's `coreID` names. What came before it belongs to the
/// session's start and is dropped. A session that started wrong is ended: on
/// another server with `TransportError.tmuxServerGone`.
///
/// The output ends with `TransportError.tmuxPaneGone` once the Pane is gone or
/// Heeler's session no longer holds it, and with the client's own failure when
/// its exec failed. Ending the session closes the exec: tmux reads the end of
/// its input, detaches the client, and the session ends with it.
///
/// What the user types goes through the same client, in order (`type(_:)`).
/// The view's resizes are not sent.
actor TmuxPaneAttach {
    private let client: TmuxControlClient
    private let session: String
    private let pane: String
    private let viewRows: Int
    private let includingHistory: Bool
    private let instance: String?
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
        instance = request.coreID
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
            // A write fails only once the client has ended, which `output`
            // reports: there is nothing else for this task to say.
            try? await input.pump(write: { try await attach.type($0) }, resize: { _, _ in })
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
            switch TmuxAttachScript.started(reply, pane: pane, instance: instance) {
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
                if let session { await end(session) }
                await failStart(failure)
            case .otherServer(let session):
                await end(session)
                await failStart(TransportError.tmuxServerGone)
            }
        case .ended(let end):
            finishStart(.failure(Self.startFailure(end)))
        default:
            break
        }
    }

    private func end(_ session: String) async {
        _ = try? await client.run(TmuxControlCommand(["kill-session", "-t", session]), timeout: .seconds(5))
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

    // MARK: Input

    /// How long a read of `#{pane_key_mode}` may take before its key is dropped.
    private static let keyModeTimeout = Duration.seconds(5)

    /// Types the terminal view's bytes into the Pane through the client, in
    /// order (ADR 0043): text with `send-keys -l`, each key by its tmux name,
    /// and a paste through a buffer named for this Attach, so it arrives
    /// exactly and bracketed only if the program asked for that. Throws once
    /// the client has ended.
    func type(_ bytes: Data) async throws {
        for input in TmuxKeyReader.read(bytes) {
            switch input {
            case .text(let text):
                try await client.post(TmuxControlCommand(["send-keys", "-l", "-t", pane, "--", text]))
            case .key(let key):
                guard try await tmuxEncodes(key) else { continue }
                try await client.post(TmuxControlCommand(["send-keys", "-t", pane, key.name]))
            case .paste(let text):
                guard !text.isEmpty else { continue }
                try await client.post(TmuxControlCommand(["set-buffer", "-b", session, "--", text]))
                try await client.post(TmuxControlCommand(["paste-buffer", "-p", "-r", "-d", "-b", session, "-t", pane]))
            }
        }
    }

    /// Whether tmux can encode `key` for the Pane's program now: a key with no
    /// legacy encoding only in an extended mode, which tmux shows from 3.5.
    /// Anything typed after it waits for the answer.
    private func tmuxEncodes(_ key: TmuxKey) async throws -> Bool {
        guard key.isExtended else { return true }
        let reply: TmuxControlReply
        do {
            reply = try await client.run(
                TmuxControlCommand(["display-message", "-p", "-t", pane, TmuxKey.paneKeyModeFormat]),
                timeout: Self.keyModeTimeout)
        } catch TransportError.timedOut {
            return false
        }
        guard reply.succeeded else { return false }
        let mode = reply.lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        return key.isSent(whilePaneKeyModeReads: mode)
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
