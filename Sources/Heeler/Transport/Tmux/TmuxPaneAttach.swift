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
/// While shown, the client asks for a per-window size scaled from the Pane's
/// share of its window and corrects it until the Pane fits inside the view's
/// grid; when hidden or retained it turns on `ignore-size` so tmux hands the
/// window back to any other client at once.
///
/// The output ends with `TransportError.tmuxPaneGone` once the Pane is gone or
/// Heeler's session no longer holds it, and with the client's own failure when
/// its exec failed. Ending the session closes the exec: tmux reads the end of
/// its input, detaches the client, and the session ends with it.
///
/// What the user types and the view's resizes go through the same client, in
/// order (`type(_:)`, `resize(columns:rows:)`).
actor TmuxPaneAttach {
    private let client: TmuxControlClient
    private let session: String
    private let pane: String
    private var viewColumns: Int
    private var viewRows: Int
    private let sizesWindow: Bool
    private var isViewed: Bool
    private let includingHistory: Bool
    private let instance: String?
    private var window: String?
    private var ignoringSize = false
    private var lastSizedWindow: (width: Int, height: Int)?
    private var settled: (geometry: TmuxPaneGeometry, columns: Int, rows: Int)?
    private var lastPainted: (paneWidth: Int, paneHeight: Int, viewColumns: Int, viewRows: Int)?
    private var syncingPlacement = false
    private var needsPlacementSync = false
    private var placementWaiters: [CheckedContinuation<Void, Never>] = []
    private var feed: TmuxPaneFeed?
    private var starting: CheckedContinuation<Void, any Error>?
    private var startResult: Result<Void, any Error>?
    private var pending = Data()
    private var reader: CheckedContinuation<Data?, any Error>?
    private var outcome: Result<Void, any Error>?
    private var typed = TmuxInputStream()

    /// The tag of the barrier. `TmuxPaneFeed` tags its commands from 1.
    private static let barrierTag: UInt64 = 0

    private init(client: TmuxControlClient, session: String, pane: String, request: TerminalAttachRequest) {
        self.client = client
        self.session = session
        self.pane = pane
        viewColumns = request.cols
        viewRows = request.rows
        sizesWindow = request.viewer != .observe
        isViewed = request.isViewed && request.viewer != .observe
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
            try? await input.pump(
                write: { try await attach.type($0, moreQueued: { input.hasQueuedKeystrokes }) },
                resize: { cols, rows in await attach.resize(columns: cols, rows: rows) })
        }
        let (presences, presence) = AsyncStream.makeStream(of: TerminalViewerPresence.self)
        let presencePump = Task {
            for await change in presences {
                await attach.applyPresence(change)
            }
        }
        return TerminalAttachSession(
            output: { AsyncThrowingStream { try await attach.read() } },
            input: input,
            onPresence: { presence.yield($0) }
        ) {
            input.finish()
            presence.finish()
            pump.cancel()
            presencePump.cancel()
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
        if case .notification(.layoutChanged(let changed)) = event,
            changed == window, isViewed, sizesWindow, outcome == nil
        {
            Task { await self.syncPlacement() }
        }
    }

    private func starting(with event: TmuxControlClient.Event) async {
        guard startResult == nil else { return }
        switch event {
        case .replied(Self.barrierTag, let reply):
            switch TmuxAttachScript.started(reply, pane: pane, instance: instance) {
            case .ready(let session, let window):
                self.window = window
                do {
                    try await applyInitialPlacement()
                } catch let ended as TmuxControlClient.Ended {
                    finishStart(.failure(Self.startFailure(ended.end)))
                    return
                } catch {
                    await failStart(error)
                    return
                }
                guard startResult == nil else { return }
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

    // MARK: Sizing and presence

    func resize(columns: Int, rows: Int) async {
        guard columns > 0, rows > 0, outcome == nil else { return }
        if columns != viewColumns || rows != viewRows {
            viewColumns = columns
            viewRows = rows
            settled = nil
            feed?.updateViewRows(rows)
        }
        guard isViewed, sizesWindow else { return }
        await syncPlacement()
    }

    func applyPresence(_ presence: TerminalViewerPresence) async {
        guard outcome == nil else { return }
        switch presence {
        case .viewed:
            guard sizesWindow else { return }
            if !isViewed {
                isViewed = true
                settled = nil
            } else if !ignoringSize, settled?.columns == viewColumns, settled?.rows == viewRows {
                return
            }
            await syncPlacement()
        case .hidden:
            guard isViewed || !ignoringSize else { return }
            isViewed = false
            settled = nil
            await syncPlacement()
        case .factsChanged:
            return
        }
    }

    private func applyInitialPlacement() async throws {
        if isViewed, sizesWindow, viewColumns > 0, viewRows > 0 {
            let targetColumns = viewColumns
            let targetRows = viewRows
            guard let initial = try await readGeometry(),
                let final = try await runSizer(from: initial, targetColumns: targetColumns, targetRows: targetRows)
            else { return }
            lastPainted = (
                paneWidth: final.paneWidth, paneHeight: final.paneHeight,
                viewColumns: targetColumns, viewRows: targetRows
            )
        } else {
            try await client.post(TmuxPaneSize.ignoreSizeCommand())
            ignoringSize = true
        }
    }

    private func syncPlacement() async {
        needsPlacementSync = true
        if syncingPlacement {
            await withCheckedContinuation { placementWaiters.append($0) }
            return
        }
        syncingPlacement = true
        defer {
            syncingPlacement = false
            let waiters = placementWaiters
            placementWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        while needsPlacementSync, outcome == nil {
            needsPlacementSync = false
            await applyPlacementOnce()
        }
    }

    private func applyPlacementOnce() async {
        guard let window, outcome == nil else { return }
        let wantsSize = isViewed && sizesWindow && viewColumns > 0 && viewRows > 0
        if !wantsSize {
            guard !ignoringSize else { return }
            let releasing = lastSizedWindow.map { (window: window, width: $0.width, height: $0.height) }
            guard (try? await client.post(TmuxPaneSize.ignoreSizeCommand(releasing: releasing))) != nil else { return }
            ignoringSize = true
            settled = nil
            return
        }
        let targetColumns = viewColumns
        let targetRows = viewRows
        do {
            guard let initial = try await readGeometry() else { return }
            if lastSizedWindow != nil {
                lastSizedWindow = (initial.windowWidth, initial.windowHeight)
            }
            guard isViewed, sizesWindow, viewColumns == targetColumns, viewRows == targetRows else { return }
            if !ignoringSize,
                let settled,
                settled.geometry == initial,
                settled.columns == targetColumns,
                settled.rows == targetRows
            {
                await repaintIfNeeded(
                    paneWidth: initial.paneWidth, paneHeight: initial.paneHeight,
                    viewColumns: targetColumns, viewRows: targetRows)
                return
            }
            guard let final = try await runSizer(from: initial, targetColumns: targetColumns, targetRows: targetRows) else {
                return
            }
            await repaintIfNeeded(
                paneWidth: final.paneWidth, paneHeight: final.paneHeight,
                viewColumns: targetColumns, viewRows: targetRows)
        } catch {
            return
        }
    }

    private func runSizer(
        from initial: TmuxPaneGeometry, targetColumns: Int, targetRows: Int
    ) async throws -> TmuxPaneGeometry? {
        var sizer = TmuxPaneSizer(targetColumns: targetColumns, targetRows: targetRows)
        let first = sizer.initialRequest(from: initial)
        try await client.post(
            TmuxPaneSize.sizeCommand(
                window: initial.windowID, columns: first.columns, rows: first.rows,
                clearingIgnoreSize: ignoringSize))
        guard var geometry = try await readGeometry() else { return nil }
        while let next = sizer.nextRequest(after: geometry) {
            guard isViewed, sizesWindow, viewColumns == targetColumns, viewRows == targetRows else {
                ignoringSize = false
                lastSizedWindow = (geometry.windowWidth, geometry.windowHeight)
                return nil
            }
            try await client.post(
                TmuxPaneSize.sizeCommand(window: geometry.windowID, columns: next.columns, rows: next.rows))
            guard let updated = try await readGeometry() else { return nil }
            geometry = updated
        }
        ignoringSize = false
        lastSizedWindow = (geometry.windowWidth, geometry.windowHeight)
        settled = (geometry, targetColumns, targetRows)
        return geometry
    }

    private func readGeometry() async throws -> TmuxPaneGeometry? {
        let reply: TmuxControlReply
        do {
            reply = try await client.run(TmuxPaneSize.readCommand(pane: pane), timeout: Self.answerTimeout)
        } catch TransportError.timedOut {
            return nil
        }
        guard reply.succeeded, let line = reply.lines.first else { return nil }
        return TmuxPaneGeometry(line)
    }

    private func repaintIfNeeded(paneWidth: Int, paneHeight: Int, viewColumns: Int, viewRows: Int) async {
        let current = (paneWidth: paneWidth, paneHeight: paneHeight, viewColumns: viewColumns, viewRows: viewRows)
        if let last = lastPainted,
            last.paneWidth == current.paneWidth,
            last.paneHeight == current.paneHeight,
            last.viewColumns == current.viewColumns,
            last.viewRows == current.viewRows
        {
            return
        }
        lastPainted = current
        guard var feed else { return }
        feed.updateViewRows(viewRows)
        let actions = feed.repaint()
        self.feed = feed
        await perform(actions)
    }

    // MARK: Input

    /// How long tmux may take to answer a read of `#{pane_key_mode}`, whose
    /// key is then dropped, or a paste, whose buffer is then deleted.
    private static let answerTimeout = Duration.seconds(5)

    /// Types the terminal view's bytes into the Pane through the client, in
    /// order (ADR 0043): text with `send-keys -l`, each key by its tmux name,
    /// and a paste through a buffer named for this Attach, so it arrives
    /// exactly and bracketed only if the program asked for that. A paste goes
    /// on across writes (`TmuxInputStream`); `moreQueued` says whether another
    /// write already waits. Throws once the client has ended.
    func type(_ bytes: Data, moreQueued: @Sendable () -> Bool = { false }) async throws {
        for input in typed.read(bytes, moreQueued: moreQueued()) {
            switch input {
            case .text(let text):
                try await client.post(TmuxControlCommand(["send-keys", "-l", "-t", pane, "--", text]))
            case .key(let key):
                guard try await tmuxEncodes(key) else { continue }
                try await client.post(TmuxControlCommand(["send-keys", "-t", pane, key.name]))
            case .paste(let text):
                try await paste(text)
            }
        }
    }

    /// Pastes `text` from the buffer named for this Attach, which `-d`
    /// deletes once pasted. A paste that failed, or that tmux did not answer
    /// in time, leaves the buffer to be deleted by that name.
    private func paste(_ text: String) async throws {
        guard !text.isEmpty else { return }
        try await client.post(TmuxControlCommand(["set-buffer", "-b", session, "--", text]))
        let pasted: Bool
        do {
            pasted = try await client.run(
                TmuxControlCommand(["paste-buffer", "-p", "-r", "-d", "-b", session, "-t", pane]),
                timeout: Self.answerTimeout
            ).succeeded
        } catch TransportError.timedOut {
            pasted = false
        }
        if !pasted { try await client.post(TmuxControlCommand(["delete-buffer", "-b", session])) }
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
                timeout: Self.answerTimeout)
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
