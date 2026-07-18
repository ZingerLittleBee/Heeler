// @preconcurrency: Citadel predates strict concurrency and SSHClient is not
// marked Sendable; its async methods hop off the actor executor, which would
// otherwise be an error. The actor still serializes all access to the client.
@preconcurrency import Citadel
import Foundation
import NIOCore

/// How to reach one Host, authenticate against it, and find its herdr socket.
struct SSHTransportSettings: Sendable {
    var host: String
    var port: Int
    var username: String
    var credentials: SSHCredentials
    /// TOFU host key policy (#2): the trusted-fingerprint store plus the
    /// first-connect confirmation the UI implements.
    var hostKeyPolicy: HostKeyPolicy
    /// Which herdr socket to reach on the Host.
    var socket: HerdrSocketLocation
    /// Absolute path of socat on the Host. Remote commands run through the
    /// user's login shell, whose PATH cannot be trusted.
    var socatPath: String
    /// Command that wakes a stopped herdr server, run over a no-PTY exec
    /// channel when a request hits connection-refused (#6). The default is
    /// the strategy from spec #16: `herdr remote-client-bridge` ensures the
    /// server is running (spawn + wait for socket) before bridging, then
    /// exits on stdin EOF. Injectable so tests can substitute a script at
    /// the environment boundary; per-Host override also covers hosts where
    /// herdr is not on the login shell's PATH.
    var wakeCommand: String = "herdr remote-client-bridge"
    /// Command that streams a Pane's terminal as NDJSON frame lines over a
    /// no-PTY exec channel (#9 probe: observe needs no PTY); the observe
    /// target and geometry are appended, and the whole thing runs inside a
    /// kill-on-stdin-EOF wrapper (see `observeChannelCommand`), so it must
    /// contain no single quotes. Injectable so tests can substitute a
    /// frame-emitting script at the environment boundary; per-Host override
    /// also covers hosts where herdr is not on the login shell's PATH.
    var observeCommand: String = "herdr terminal session observe"
    /// Per-request deadline covering the queue wait and the exec exchange;
    /// on expiry the request fails with `.timedOut` and its channel is
    /// closed. Short in tests, generous by default: a hung host should
    /// degrade gracefully, a slow one should still answer.
    var requestTimeout: Duration = .seconds(15)
}

/// Transport over SSH exec channels running `socat - UNIX-CONNECT:<sock>`,
/// one channel per request because herdr serves one request per connection
/// (ADR 0002). An actor because Citadel's SSHClient is not Sendable.
actor SSHTransport: Transport {
    /// The herdr wire protocol version this build speaks (herdr 0.7.4).
    static let supportedProtocolVersion = 16

    /// Exec channels are SSH session channels, capped by sshd's MaxSessions
    /// (default 10) per connection. Bound at 8 to leave headroom for the
    /// events channel and a future Attach terminal.
    static let maxConcurrentExecChannels = 8

    private let client: SSHClient
    private let socketLocation: HerdrSocketLocation
    private let socatPath: String
    private let wakeCommand: String
    private let observeCommand: String
    private let requestTimeout: Duration
    /// Remote home directory resolution, resolved over exec once per Host:
    /// concurrent first requests share one in-flight run, success is cached
    /// for the connection's lifetime, failure is not (the next request
    /// retries).
    private let homeDirectory = SharedAsyncOperation<String>(cachesSuccess: true)
    /// Cold-start wake; concurrent refused requests share one wake instead
    /// of racing exec channels, and a later cold start wakes again.
    private let wake = SharedAsyncOperation<Void>(cachesSuccess: false)

    // MARK: Exec channel slots
    //
    // The actor-based request queue (#5): every exec channel — RPC, home
    // resolution, wake — holds a slot for the channel's lifetime, bounding
    // concurrency at `maxConcurrentExecChannels`. Slots are never held
    // across another slot acquisition, so the queue cannot deadlock.

    private struct SlotWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var execSlotsInUse = 0
    private var slotWaiters: [SlotWaiter] = []
    /// Waiter ids whose cancellation raced ahead: the cancellation handler
    /// hops onto the actor via a Task, so it can run before the waiter's
    /// continuation is stored (marker consumed on arrival) or after the
    /// waiter was already resumed (marker swept by `acquireExecChannelSlot`'s
    /// defer, keyed on `pendingSlotRequests`).
    private var cancelledSlotRequests: Set<UInt64> = []
    private var pendingSlotRequests: Set<UInt64> = []
    private var nextSlotRequestID: UInt64 = 0

    /// Waits for a free exec channel slot. Throws `CancellationError` without
    /// consuming a slot if the task is cancelled while queued.
    private func acquireExecChannelSlot() async throws {
        try Task.checkCancellation()
        nextSlotRequestID += 1
        let id = nextSlotRequestID
        pendingSlotRequests.insert(id)
        defer {
            pendingSlotRequests.remove(id)
            cancelledSlotRequests.remove(id)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledSlotRequests.contains(id) {
                    continuation.resume(throwing: CancellationError())
                } else if execSlotsInUse < Self.maxConcurrentExecChannels {
                    execSlotsInUse += 1
                    continuation.resume()
                } else {
                    slotWaiters.append(SlotWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSlotWaiter(id: id) }
        }
    }

    /// Frees a slot, handing it to the oldest waiter if any.
    private func releaseExecChannelSlot() {
        if slotWaiters.isEmpty {
            execSlotsInUse -= 1
        } else {
            slotWaiters.removeFirst().continuation.resume()
        }
    }

    private func cancelSlotWaiter(id: UInt64) {
        guard pendingSlotRequests.contains(id) else { return }
        if let index = slotWaiters.firstIndex(where: { $0.id == id }) {
            slotWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelledSlotRequests.insert(id)
        }
    }

    private init(
        client: SSHClient, socketLocation: HerdrSocketLocation, socatPath: String,
        wakeCommand: String, observeCommand: String, requestTimeout: Duration
    ) {
        self.client = client
        self.socketLocation = socketLocation
        self.socatPath = socatPath
        self.wakeCommand = wakeCommand
        self.observeCommand = observeCommand
        self.requestTimeout = requestTimeout
    }

    /// Connects, verifies the host key per the TOFU policy, and
    /// authenticates — but sends nothing yet: callers must `ping` first to
    /// verify the protocol version.
    static func connect(settings: SSHTransportSettings) async throws -> SSHTransport {
        let validator = TOFUHostKeyValidator(
            host: settings.host, port: settings.port, policy: settings.hostKeyPolicy)
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: settings.host,
                port: settings.port,
                authenticationMethod: settings.credentials.citadelMethod(
                    username: settings.username),
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
        } catch {
            // NIOSSH may wrap the validator's error on its way out of the
            // handshake; the recorded verdict is the source of truth.
            if let hostKeyFailure = validator.failure {
                throw hostKeyFailure
            }
            throw Self.classifyConnectFailure(error)
        }
        return SSHTransport(
            client: client, socketLocation: settings.socket, socatPath: settings.socatPath,
            wakeCommand: settings.wakeCommand, observeCommand: settings.observeCommand,
            requestTimeout: settings.requestTimeout)
    }

    /// Maps connect-time failures onto the taxonomy: credential rejection is
    /// actionable ("fix your key/password"), everything else is a Host that
    /// could not be reached.
    private static func classifyConnectFailure(_ error: any Error) -> TransportError {
        switch error {
        case SSHClientError.allAuthenticationOptionsFailed,
            SSHClientError.unsupportedPasswordAuthentication,
            SSHClientError.unsupportedPrivateKeyAuthentication,
            SSHClientError.unsupportedHostBasedAuthentication:
            return .authenticationFailed
        default:
            return .sshUnreachable(detail: String(describing: error))
        }
    }

    func ping() async throws -> ServerInfo {
        let pong = try await request(method: "ping", decoding: PongResponse.self)
        guard pong.protocolVersion == Self.supportedProtocolVersion else {
            throw TransportError.protocolVersionMismatch(
                server: pong.protocolVersion, supported: Self.supportedProtocolVersion)
        }
        return ServerInfo(version: pong.version, protocolVersion: pong.protocolVersion)
    }

    func listAgents() async throws -> [Agent] {
        try await request(method: "agent.list", decoding: AgentListResponse.self)
            .agents.map(Agent.init)
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        try await request(method: "session.snapshot", decoding: SessionSnapshotResponse.self)
            .snapshot
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        try await request(method: "pane.read", params: params, decoding: PaneReadResponse.self)
            .read
    }

    func sendToAgent(_ params: AgentSendParams) async throws {
        _ = try await request(method: "agent.send", params: params, decoding: OkResponse.self)
    }

    func sendKeys(_ params: PaneSendKeysParams) async throws {
        _ = try await request(method: "pane.send_keys", params: params, decoding: OkResponse.self)
    }

    // MARK: Events channel (#4)
    //
    // One dedicated long-lived exec+socat channel per Host holds the
    // events.subscribe stream: one ack line, then event lines until the
    // channel is closed explicitly. It is exempt from the exec-slot queue —
    // the queue's bound of 8 exists precisely to leave MaxSessions headroom
    // for this channel (and a future Attach terminal) — and the state below
    // keeps it to exactly one channel per Host.

    private enum EventsChannelState: Equatable {
        case idle
        /// A subscribe call is setting the channel up (including a cold-start
        /// wake retry); further subscribes are refused meanwhile.
        case opening
        case streaming(readerID: UInt64)
    }

    private var eventsChannelState: EventsChannelState = .idle
    private var nextEventsReaderID: UInt64 = 0
    /// Readers that ended while the channel was still `.opening` (e.g. the
    /// remote closed right after the ack); the subscribe path reconciles so
    /// the state can never stick at `.streaming` for a dead reader.
    private var endedEventsReaders: Set<UInt64> = []

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        guard eventsChannelState == .idle else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        eventsChannelState = .opening
        do {
            let (stream, readerID) = try await withColdStartWake {
                try await self.openEventsChannel(subscriptions)
            }
            if endedEventsReaders.remove(readerID) != nil {
                // The reader already died (remote closed straight after the
                // ack); the stream the caller gets is finished, not live.
                eventsChannelState = .idle
            } else {
                eventsChannelState = .streaming(readerID: readerID)
            }
            return stream
        } catch {
            // openEventsChannel tears its reader down and awaits it before
            // throwing, so no live channel can outlast this reset.
            eventsChannelState = .idle
            throw error
        }
    }

    /// Opens the dedicated channel, sends the subscribe request, and waits
    /// for the ack line under the per-request deadline. On any failure the
    /// reader is torn down and awaited before the error propagates.
    private func openEventsChannel(_ subscriptions: [EventSubscription]) async throws
        -> (HerdrEventStream, readerID: UInt64)
    {
        let socketPath = try await resolvedSocketPath()
        let requestID = UUID().uuidString
        let requestLine = try HerdrWire.subscribeRequestLine(
            id: requestID, subscriptions: subscriptions)
        let (events, eventContinuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        let (ackLines, ackContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        nextEventsReaderID += 1
        let readerID = nextEventsReaderID
        let readerTask = Task {
            await self.runEventsChannel(
                readerID: readerID, requestLine: requestLine, socketPath: socketPath,
                ack: ackContinuation, events: eventContinuation)
        }
        do {
            let ackLine = try await Self.withRequestDeadline(requestTimeout) {
                var iterator = ackLines.makeAsyncIterator()
                guard let line = try await iterator.next() else {
                    throw TransportError.channelFailed(detail: "events channel ended before ack")
                }
                return line
            }
            _ = try HerdrWire.decodeResult(
                SubscriptionStartedResponse.self, fromResponseLine: ackLine, requestID: requestID)
        } catch {
            readerTask.cancel()
            await readerTask.value
            endedEventsReaders.remove(readerID)
            throw error
        }
        let stream = HerdrEventStream(events: events) {
            readerTask.cancel()
            await readerTask.value
        }
        return (stream, readerID)
    }

    /// The events channel's read loop: writes the subscribe request, hands
    /// the first stdout line to the ack stream, then yields every complete
    /// event line until the channel ends. Ending is always by explicit
    /// close: cancelling the reader task only ends the *local* inbound
    /// stream, the exec body then returns, Citadel closes the channel on the
    /// way out, and socat exits on stdin EOF. Takes no exec slot (see MARK).
    private func runEventsChannel(
        readerID: UInt64,
        requestLine: String,
        socketPath: String,
        ack ackContinuation: AsyncThrowingStream<Data, any Error>.Continuation,
        events eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation
    ) async {
        var stderr = Data()
        var pending = Data()
        var sawAck = false
        /// nil means the stream ends gracefully (explicit `end()`).
        var streamFailure: TransportError?
        /// Backstop for an ack that never arrived; a finish after finish is
        /// a no-op, so this is only observed when the ack line never came.
        var ackFailure = TransportError.cancelled
        do {
            try await client.withExec("\(socatPath) - UNIX-CONNECT:\(socketPath)") {
                inbound, outbound in
                try? await outbound.write(ByteBuffer(string: requestLine))
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer):
                        pending.append(contentsOf: buffer.readableBytesView)
                        while let lineData = Self.takeLine(from: &pending) {
                            if !sawAck {
                                sawAck = true
                                ackContinuation.yield(lineData)
                                ackContinuation.finish()
                            } else if let event = HerdrWire.decodeEvent(fromLine: lineData) {
                                eventContinuation.yield(event)
                            }
                            // Undecodable lines are dropped: junk on the
                            // stream must never kill it.
                        }
                    case .stderr(let buffer):
                        stderr.append(contentsOf: buffer.readableBytesView)
                    }
                }
            }
            if Task.isCancelled {
                // Explicit end(): the consumer closed the channel.
                streamFailure = nil
            } else if sawAck {
                streamFailure = TransportError.channelFailed(
                    detail: "events channel closed by remote")
            } else {
                ackFailure =
                    classifyExecFailure(stderr: stderr, socketPath: socketPath)
                    ?? TransportError.channelFailed(
                        detail:
                            "events channel closed before ack; stderr: \(Self.preview(stderr))")
                streamFailure = ackFailure
            }
        } catch is CancellationError {
            streamFailure = nil
        } catch {
            let failure =
                classifyExecFailure(stderr: stderr, socketPath: socketPath)
                ?? TransportError.channelFailed(
                    detail: "events channel: \(error); stderr: \(Self.preview(stderr))")
            ackFailure = failure
            streamFailure = failure
        }
        // State first, continuations second: a consumer resuming on the
        // stream's end must already see the channel as free.
        eventsChannelReaderDidEnd(readerID)
        ackContinuation.finish(throwing: ackFailure)
        if let streamFailure {
            eventContinuation.finish(throwing: streamFailure)
        } else {
            eventContinuation.finish()
        }
    }

    private func eventsChannelReaderDidEnd(_ readerID: UInt64) {
        if eventsChannelState == .streaming(readerID: readerID) {
            eventsChannelState = .idle
        } else {
            // Ended mid-open: the subscribe path reconciles (and cleans up
            // this marker on its failure path).
            endedEventsReaders.insert(readerID)
        }
    }

    // MARK: Terminal channel (#9)
    //
    // One dedicated exec channel carries the terminal surface: the Observe
    // live-follow runs `herdr terminal session observe <target>` (no PTY —
    // verified against herdr 0.7.4) and streams NDJSON frame lines until
    // the channel is closed explicitly. Like the events channel it is
    // exempt from the exec-slot queue: the session budget is 8 RPC slots +
    // events + this terminal channel = sshd's default MaxSessions 10.
    // Attach (#11) will reuse this single-channel budget; the state below
    // keeps it to exactly one terminal channel per Host.

    private enum TerminalChannelState: Equatable {
        case idle
        case streaming(readerID: UInt64)
    }

    private var terminalChannelState: TerminalChannelState = .idle
    private var nextTerminalReaderID: UInt64 = 0

    func observeTerminal(_ request: TerminalObserveRequest) async throws -> TerminalFrameStream {
        guard terminalChannelState == .idle else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        let command = Self.observeChannelCommand(
            observeCommand: observeCommand, request: request)
        let (frames, continuation) = AsyncThrowingStream<TerminalFrame, any Error>.makeStream()
        nextTerminalReaderID += 1
        let readerID = nextTerminalReaderID
        let readerTask = Task {
            await self.runTerminalChannel(
                readerID: readerID, command: command, frames: continuation)
        }
        // No suspension between the idle guard and here, and the reader is
        // actor-isolated too, so it cannot have observed — let alone ended —
        // a state it is only now being recorded into.
        terminalChannelState = .streaming(readerID: readerID)
        return TerminalFrameStream(frames: frames) {
            readerTask.cancel()
            await readerTask.value
        }
    }

    /// The full remote command for one observe channel. Everything this
    /// transport runs must die on stdin EOF — explicit close is the only way
    /// to end a Citadel channel, and the close only completes once the
    /// remote command exits (verified against localhost sshd: a command that
    /// ignores EOF pins the teardown for its whole lifetime). socat has that
    /// property natively; `herdr terminal session observe` does not (probed
    /// against herdr 0.7.4: it streams on regardless), so a POSIX wrapper
    /// adds it: a watcher waits for stdin EOF and kills observe.
    ///
    /// Runs under `/bin/sh` explicitly because the login shell owning the
    /// exec command line may not speak POSIX (fish). The target rides as a
    /// positional argument so only the outer shell ever quotes it.
    ///
    /// The stdin dance: POSIX hands `/dev/null` to backgrounded (`&`)
    /// commands, so the real stdin is saved to fd 3 first and the watcher
    /// reads that. Observe exiting on its own (pane closed, herdr died)
    /// takes the `wait` path: the watcher is killed and the wrapper exits,
    /// so the remote death still surfaces as the stream ending.
    static func observeChannelCommand(
        observeCommand: String, request: TerminalObserveRequest
    ) -> String {
        let quotedTarget =
            "'" + request.target.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let observe = "\(observeCommand) \"$1\" --cols \(request.cols) --rows \(request.rows)"
        let wrapper =
            "exec 3<&0 0</dev/null; \(observe) & p=$!; "
            + "(cat <&3 >/dev/null 2>&1 3<&-; kill $p 2>/dev/null) & w=$!; "
            + "wait $p; kill $w 2>/dev/null; exit 0"
        return "/bin/sh -c '\(wrapper)' observe \(quotedTarget)"
    }

    /// The terminal channel's read loop: yields every complete frame line
    /// until the channel ends. Ending is always by explicit close, exactly
    /// like the events channel: cancelling the reader task only ends the
    /// *local* inbound stream, the exec body then returns, and Citadel
    /// closes the channel on the way out. Takes no exec slot (see MARK).
    private func runTerminalChannel(
        readerID: UInt64,
        command: String,
        frames continuation: AsyncThrowingStream<TerminalFrame, any Error>.Continuation
    ) async {
        var stderr = Data()
        var pending = Data()
        /// nil means the stream ends gracefully (explicit `end()`).
        var failure: TransportError?
        do {
            try await client.withExec(command) { inbound, _ in
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer):
                        pending.append(contentsOf: buffer.readableBytesView)
                        while let lineData = Self.takeLine(from: &pending) {
                            if let frame = TerminalFrame.decode(fromLine: lineData) {
                                continuation.yield(frame)
                            }
                            // Undecodable lines are dropped: junk on the
                            // stream must never kill it.
                        }
                    case .stderr(let buffer):
                        stderr.append(contentsOf: buffer.readableBytesView)
                    }
                }
            }
            failure =
                Task.isCancelled
                ? nil  // Explicit end(): the consumer closed the channel.
                : TransportError.channelFailed(
                    detail:
                        "terminal channel closed by remote; stderr: \(Self.preview(stderr))")
        } catch is CancellationError {
            failure = nil
        } catch {
            failure = TransportError.channelFailed(
                detail: "terminal channel: \(error); stderr: \(Self.preview(stderr))")
        }
        // State first, continuation second: a consumer resuming on the
        // stream's end must already see the channel as free.
        if terminalChannelState == .streaming(readerID: readerID) {
            terminalChannelState = .idle
        }
        if let failure {
            continuation.finish(throwing: failure)
        } else {
            continuation.finish()
        }
    }

    /// Removes and returns the first complete line (newline stripped) from
    /// `buffer`, or nil if no full line has arrived yet.
    private static func takeLine(from buffer: inout Data) -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer = Data(buffer[buffer.index(after: newline)...])
        return line
    }

    /// Whether the SSH connection is still alive (Citadel tracks the
    /// underlying channel's liveness). False after `close()` or a remote
    /// death; this transport is then dead for good — Citadel's auto-reconnect
    /// is deliberately off (`.never`), re-establishing is the reconnect
    /// machinery's job (#18) so backoff stays bounded and observable.
    var isConnected: Bool {
        client.isConnected
    }

    /// Closes the SSH connection. Explicit close is the only way to end
    /// Citadel channels — a live exec channel ignores task cancellation.
    func close() async throws {
        try await client.close()
    }

    /// Executes one parameterless request with cold-start recovery.
    private func request<R: Decodable>(method: String, decoding type: R.Type) async throws -> R {
        try await request(method: method, params: HerdrWire.EmptyParams(), decoding: type)
    }

    /// Executes one request with cold-start recovery.
    private func request<P: Encodable, R: Decodable>(
        method: String, params: P, decoding type: R.Type
    ) async throws -> R {
        try await withColdStartWake {
            try await self.performRequest(method: method, params: params, decoding: type)
        }
    }

    /// Runs `operation` with cold-start recovery (#6): connection refused
    /// means the socket exists but the server is stopped, so run the wake
    /// command and retry. Strictly bounded — one wake, one retry — so a wake
    /// that does not help surfaces `.serverNotRunning` to the user instead
    /// of looping silently.
    private func withColdStartWake<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch TransportError.serverNotRunning(let path) {
            do {
                try await wakeServer()
            } catch TransportError.cancelled {
                throw TransportError.cancelled
            } catch TransportError.timedOut {
                throw TransportError.timedOut
            } catch {
                // The wake itself failed (herdr missing, command errored):
                // the actionable problem is still a server that is not
                // running on this Host.
                throw TransportError.serverNotRunning(path: path)
            }
            return try await operation()
        }
    }

    /// Wakes the herdr server via the Host's wake command; concurrent
    /// refused requests share one in-flight wake. The wait — not the wake —
    /// is deadline-bounded: a hung wake command cannot be ended client-side
    /// (sshd holds the channel until the command exits), so waiters abandon
    /// it with `.timedOut` while it keeps its slot until it really ends.
    private func wakeServer() async throws {
        try await Self.withRequestDeadline(requestTimeout) {
            try await self.wake.value {
                try await self.runWakeCommand()
            }
        }
    }

    /// Runs the wake command over a slot-gated no-PTY exec channel with
    /// stdin at EOF from the start (`< /dev/null`). The bridge's entry point
    /// ensures the server is running (spawn + wait for socket) before it
    /// starts bridging; the bridge then reads EOF and exits — so the command
    /// completing implies a live socket, and its own lifetime bounds the
    /// channel without writing or closing anything mid-flight.
    private func runWakeCommand() async throws {
        try await acquireExecChannelSlot()
        defer { releaseExecChannelSlot() }
        _ = try await client.executeCommand("\(wakeCommand) < /dev/null")
    }

    /// One no-PTY exec channel per request, raced against the per-request
    /// deadline. The channel is ended by returning from the `withExec` body
    /// as soon as a full response line has arrived (Citadel closes the
    /// channel on return) — never by task cancellation, which a live exec
    /// channel does not respond to.
    private func performRequest<P: Encodable, R: Decodable>(
        method: String, params: P, decoding type: R.Type
    ) async throws -> R {
        let socketPath = try await resolvedSocketPath()
        let requestID = UUID().uuidString
        let line = try HerdrWire.requestLine(id: requestID, method: method, params: params)
        let responseLine = try await Self.withRequestDeadline(requestTimeout) {
            try await self.performExchange(line: line, socketPath: socketPath, method: method)
        }
        return try HerdrWire.decodeResult(type, fromResponseLine: responseLine, requestID: requestID)
    }

    /// Takes a channel slot, runs one exec+socat exchange, and returns the
    /// raw response bytes (guaranteed to contain a full line).
    private func performExchange(line: String, socketPath: String, method: String) async throws
        -> Data
    {
        try await acquireExecChannelSlot()
        defer { releaseExecChannelSlot() }
        var stdout = Data()
        var stderr = Data()
        do {
            try await client.withExec("\(socatPath) - UNIX-CONNECT:\(socketPath)") {
                inbound, outbound in
                // A fast-failing command (socat missing, socket absent) can
                // close the channel before this write lands; the read loop
                // below still drains stderr and surfaces the real failure.
                try? await outbound.write(ByteBuffer(string: line))
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer):
                        stdout.append(contentsOf: buffer.readableBytesView)
                        if stdout.contains(0x0A) { return }
                    case .stderr(let buffer):
                        stderr.append(contentsOf: buffer.readableBytesView)
                    }
                }
            }
        } catch is CancellationError {
            throw TransportError.cancelled
        } catch {
            throw classifyExecFailure(stderr: stderr, socketPath: socketPath)
                ?? TransportError.channelFailed(
                    detail: "\(method): \(error); stderr: \(Self.preview(stderr))")
        }
        // A cancelled exchange ends its read through the local inbound
        // stream, after which withExec has already closed the channel;
        // surface that instead of misreading the truncated output as a
        // protocol error.
        try Task.checkCancellation()
        if !stdout.contains(0x0A),
            let failure = classifyExecFailure(stderr: stderr, socketPath: socketPath)
        {
            throw failure
        }
        return stdout
    }

    /// Races `operation` against the per-request deadline, mapping expiry to
    /// `.timedOut` and caller cancellation to `.cancelled`.
    ///
    /// A live exec channel ignores Swift task cancellation, so the losing
    /// operation is never cancel-and-awaited at the channel: cancelling it
    /// only ends the *local* inbound stream (an `AsyncThrowingStream`, whose
    /// iterator resumes on task cancellation), the exec body then returns,
    /// and Citadel closes the channel explicitly on the way out. A queued
    /// operation that has no channel yet leaves the slot queue the same way.
    private static func withRequestDeadline<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            do {
                guard let finished = try await group.next(), let value = finished else {
                    throw TransportError.timedOut
                }
                // The operation may have completed with junk after the
                // caller's task was cancelled mid-read; cancellation wins.
                try Task.checkCancellation()
                return value
            } catch is CancellationError {
                throw TransportError.cancelled
            }
        }
    }

    /// The absolute socket path on this Host, resolving the remote home
    /// directory for home-relative locations.
    private func resolvedSocketPath() async throws -> String {
        if case .absolutePath(let path) = socketLocation { return path }
        return socketLocation.path(homeDirectory: try await remoteHomeDirectory())
    }

    /// The shared home resolution, with the wait — not the resolution —
    /// deadline-bounded, exactly like `wakeServer()`.
    private func remoteHomeDirectory() async throws -> String {
        try await Self.withRequestDeadline(requestTimeout) {
            try await self.homeDirectory.value {
                try await self.resolveHomeDirectoryOverExec()
            }
        }
    }

    private func resolveHomeDirectoryOverExec() async throws -> String {
        try await acquireExecChannelSlot()
        defer { releaseExecChannelSlot() }
        let output: ByteBuffer
        do {
            // $HOME expands in every mainstream login shell, fish included.
            output = try await client.executeCommand("echo $HOME")
        } catch {
            throw TransportError.homeDirectoryUnresolvable(detail: String(describing: error))
        }
        let home = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else {
            throw TransportError.homeDirectoryUnresolvable(
                detail: "echo $HOME printed: \(home.prefix(200))")
        }
        return home
    }

    /// Maps the observable failure shapes (verified against herdr 0.7.4 in
    /// the #3 spike) onto taxonomy cases:
    /// - missing socket:  socat stderr `E connect(... "<sock>" ...): No such file or directory`
    /// - stale socket:    socat stderr `E connect(... "<sock>" ...): Connection refused`
    /// - socat missing:   login-shell stderr naming the socat path
    ///
    /// socat connect diagnostics are keyed on their `E connect` marker plus
    /// the quoted socket path: shells like fish echo the whole failing
    /// command line (which contains both paths), so path presence alone
    /// cannot distinguish the shapes.
    private func classifyExecFailure(stderr: Data, socketPath: String) -> TransportError? {
        let text = String(decoding: stderr, as: UTF8.self)
        if text.contains("E connect"), text.contains("\"\(socketPath)\"") {
            if text.contains("No such file or directory") {
                return .socketNotFound(path: socketPath)
            }
            if text.contains("Connection refused") {
                return .serverNotRunning(path: socketPath)
            }
        }
        if text.contains(socatPath) {
            return .socatMissing(path: socatPath)
        }
        return nil
    }

    private static func preview(_ stderr: Data) -> String {
        String(decoding: stderr.prefix(200), as: UTF8.self)
    }
}

extension SSHCredentials {
    /// The Citadel authentication method for these credentials. Lives here so
    /// the credentials type itself stays free of SSH library types.
    fileprivate func citadelMethod(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .ed25519(let privateKey):
            .ed25519(username: username, privateKey: privateKey)
        case .password(let password):
            .passwordBased(username: username, password: password)
        }
    }
}
