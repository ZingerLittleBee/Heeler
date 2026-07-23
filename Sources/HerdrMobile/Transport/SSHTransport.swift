// @preconcurrency: Citadel predates strict concurrency and SSHClient is not
// marked Sendable; its async methods hop off the actor executor, which would
// otherwise be an error. The actor still serializes all access to the client.
@preconcurrency import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// How to reach one Host, authenticate against it, and find its herdr socket.
struct SSHTransportSettings: Sendable {
    static let defaultSessionListCommand = "herdr session list --json"

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
    /// Official Host-local CLI command for discovering default and named
    /// sessions. It does not depend on a running API socket.
    var sessionListCommand: String = Self.defaultSessionListCommand
    /// Command that attaches interactively to a Pane, run on the Host's
    /// dedicated terminal channel with a PTY (#11); the attach target and
    /// takeover flag are appended (see `attachBootstrapLine`). Injectable so
    /// tests can substitute a script at the environment boundary; per-Host
    /// override also covers hosts where herdr is not on the login shell's
    /// PATH.
    var attachCommand: String = "herdr agent attach"
    /// Command used to print a marker-delimited remote home directory. It is
    /// injectable only at the environment boundary for real-SSH tests.
    var homeCommand: String = "printf '__HERDR_MOBILE_HOME__=%s\\n' \"$HOME\""
    /// Creates one private directory beneath the Host operating system's
    /// selected temporary root. The marker makes login-shell noise harmless;
    /// callers never interpolate image names or paths into this command.
    var stageDirectoryCommand: String =
        "/bin/sh -c 'umask 077; "
        + "directory=$(mktemp -d \"${TMPDIR:-/tmp}/herdr-mobile.XXXXXXXX\") || exit 1; "
        + "printf \"__HERDR_MOBILE_STAGE_DIR__=%s\\n\" \"$directory\"'"
    /// Per-request deadline covering the queue wait and the exec exchange;
    /// on expiry the request fails with `.timedOut` and its channel is
    /// closed. Short in tests, generous by default: a hung host should
    /// degrade gracefully, a slow one should still answer.
    var requestTimeout: Duration = .seconds(15)
}

private struct HerdrSessionListResponse: Decodable {
    let sessions: [HerdrSession]
}

/// Transport over SSH exec channels running `socat - UNIX-CONNECT:<sock>`,
/// one channel per request because herdr serves one request per connection
/// (ADR 0002). An actor because Citadel's SSHClient is not Sendable.
actor SSHTransport: Transport {
    /// The herdr wire protocol version this build speaks (herdr 0.7.5).
    static let supportedProtocolVersion = 17

    /// Exec channels are SSH session channels, capped by sshd's MaxSessions
    /// (default 10) per connection. Bound at 8 to leave headroom for the
    /// events channel and the interactive terminal.
    static let maxConcurrentExecChannels = 8

    private let client: SSHClient
    private let socketLocation: HerdrSocketLocation
    private let socatPath: String
    private let wakeCommand: String
    private let sessionListCommand: String
    private let attachCommand: String
    private let homeCommand: String
    private let stageDirectoryCommand: String
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
    /// Active SFTP channels keyed by staging operation. Cancellation closes
    /// the exact channel so a blocked Citadel request cannot continue after
    /// the app reports an interrupted upload.
    private var imageStageClients: [UUID: SFTPClient] = [:]

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
        wakeCommand: String, sessionListCommand: String, attachCommand: String,
        homeCommand: String, stageDirectoryCommand: String,
        requestTimeout: Duration
    ) {
        self.client = client
        self.socketLocation = socketLocation
        self.socatPath = socatPath
        self.wakeCommand = wakeCommand
        self.sessionListCommand = sessionListCommand
        self.attachCommand = attachCommand
        self.homeCommand = homeCommand
        self.stageDirectoryCommand = stageDirectoryCommand
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
            wakeCommand: settings.wakeCommand, sessionListCommand: settings.sessionListCommand,
            attachCommand: settings.attachCommand, homeCommand: settings.homeCommand,
            stageDirectoryCommand: settings.stageDirectoryCommand,
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

    func listSessions() async throws -> [HerdrSession] {
        let output = try await Self.withRequestDeadline(requestTimeout) {
            try await self.runSessionListCommand()
        }
        do {
            let sessions = try JSONDecoder().decode(HerdrSessionListResponse.self, from: output).sessions
            guard sessions.allSatisfy({ HerdrSessionName.isValid($0.name) }) else {
                throw TransportError.malformedResponse(
                    "herdr session list returned an invalid session name")
            }
            return sessions
        } catch {
            throw TransportError.malformedResponse(
                "herdr session list returned invalid JSON: \(Self.preview(output))")
        }
    }

    private func runSessionListCommand() async throws -> Data {
        try await acquireExecChannelSlot()
        defer { releaseExecChannelSlot() }
        do {
            let output = try await client.executeCommand(Self.cLocaleCommand(sessionListCommand))
            return Data(output.readableBytesView)
        } catch is CancellationError {
            throw TransportError.cancelled
        } catch {
            throw TransportError.channelFailed(detail: String(describing: error))
        }
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

    func startAgent(_ launch: AgentLaunchRequest) async throws -> Agent {
        let created = try await request(
            method: "tab.create",
            params: TabCreateParams(focus: false, workspaceID: launch.workspaceID),
            decoding: TabCreatedResponse.self)
        do {
            let response = try await request(
                method: "agent.start",
                params: AgentStartParams(
                    kind: launch.kind,
                    name: launch.name,
                    paneID: created.rootPane.paneID,
                    args: launch.arguments.isEmpty ? nil : launch.arguments),
                decoding: AgentStartedResponse.self)
            return Agent(response.agent)
        } catch let error as HerdrAPIError {
            // A definitive rejection must not leave the fresh empty tab behind.
            // Transport failures are ambiguous: the agent may have started even
            // if its reply was lost, so preserving the pane is safer there.
            try? await closePane(PaneTarget(paneID: created.rootPane.paneID))
            throw error
        }
    }

    func closePane(_ params: PaneTarget) async throws {
        _ = try await request(method: "pane.close", params: params, decoding: OkResponse.self)
    }

    // MARK: Image staging

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws -> StagedImage {
        guard
            image.byteCount > 0,
            image.byteCount <= Int64(ImagePreparer.maximumEncodedByteCount),
            let localSize = try? FileManager.default.attributesOfItem(
                atPath: image.fileURL.path)[.size] as? NSNumber,
            localSize.int64Value == image.byteCount
        else {
            throw ImageStagingError.invalidPreparedImage
        }

        do {
            try await acquireExecChannelSlot()
        } catch {
            throw ImageStagingError.cancelled
        }
        defer { releaseExecChannelSlot() }

        try Task.checkCancellation()
        let remoteDirectory = try await createStageDirectory()
        let operationID = UUID()
        await progress(
            ImageStageProgress(transferredBytes: 0, totalBytes: image.byteCount))

        do {
            return try await withTaskCancellationHandler {
                try await performImageStage(
                    image,
                    remoteDirectory: remoteDirectory,
                    operationID: operationID,
                    progress: progress)
            } onCancel: {
                Task { await self.cancelImageStage(operationID) }
            }
        } catch let error as ImageStagingError {
            throw error
        } catch is CancellationError {
            throw ImageStagingError.cancelled
        } catch {
            throw Task.isCancelled
                ? ImageStagingError.cancelled : ImageStagingError.transferFailed
        }
    }

    private func createStageDirectory() async throws -> String {
        let output: ByteBuffer
        do {
            output = try await client.executeCommand(
                Self.cLocaleCommand(stageDirectoryCommand))
        } catch {
            throw Task.isCancelled
                ? ImageStagingError.cancelled
                : ImageStagingError.remoteTemporaryDirectoryFailed
        }
        return try Self.parseStageDirectory(output)
    }

    private func performImageStage(
        _ image: PreparedImage,
        remoteDirectory: String,
        operationID: UUID,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws -> StagedImage {
        let sftp: SFTPClient
        do {
            sftp = try await client.openSFTP()
        } catch {
            throw Task.isCancelled
                ? ImageStagingError.cancelled : ImageStagingError.sftpUnavailable
        }
        imageStageClients[operationID] = sftp

        let randomName = UUID().uuidString.lowercased()
        let finalPath = "\(remoteDirectory)/\(randomName).\(image.format.fileExtension)"
        var partPath: String? = "\(finalPath).part"

        do {
            let directoryAttributes = try await sftp.getAttributes(at: remoteDirectory)
            guard Self.permissionBits(directoryAttributes.permissions) == 0o700 else {
                throw ImageStagingError.permissionEnforcementFailed
            }
            guard let currentPartPath = partPath else {
                throw ImageStagingError.transferFailed
            }
            try await streamImage(
                image,
                to: currentPartPath,
                over: sftp,
                progress: progress)
            try Task.checkCancellation()

            let uploadedAttributes = try await sftp.getAttributes(at: currentPartPath)
            guard
                uploadedAttributes.size == UInt64(image.byteCount),
                Self.permissionBits(uploadedAttributes.permissions) == 0o600
            else {
                throw ImageStagingError.byteCountMismatch
            }
            try await sftp.rename(at: currentPartPath, to: finalPath)
            partPath = nil

            let finalAttributes = try await sftp.getAttributes(at: finalPath)
            guard
                finalAttributes.size == UInt64(image.byteCount),
                Self.permissionBits(finalAttributes.permissions) == 0o600
            else {
                // Rename completed, so ADR 0005 forbids deleting this final
                // Host file even when the final verification response is bad.
                throw ImageStagingError.byteCountMismatch
            }
            let staged = try StagedImage(path: finalPath)
            imageStageClients[operationID] = nil
            try await sftp.close()
            return staged
        } catch {
            imageStageClients[operationID] = nil
            try? await sftp.close()
            if let partPath {
                await bestEffortRemovePart(at: partPath)
            }
            if Task.isCancelled {
                throw ImageStagingError.cancelled
            }
            if let stagingError = error as? ImageStagingError {
                throw stagingError
            }
            throw ImageStagingError.transferFailed
        }
    }

    private func streamImage(
        _ image: PreparedImage,
        to remotePath: String,
        over sftp: SFTPClient,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws {
        let localFile: FileHandle
        do {
            localFile = try FileHandle(forReadingFrom: image.fileURL)
        } catch {
            throw ImageStagingError.localReadFailed
        }
        defer { try? localFile.close() }

        var creationAttributes = SFTPFileAttributes()
        creationAttributes.permissions = 0o600
        let remoteFile = try await sftp.openFile(
            filePath: remotePath,
            flags: [.write, .create, .forceCreate],
            attributes: creationAttributes)
        do {
            let attributes = try await remoteFile.readAttributes()
            guard Self.permissionBits(attributes.permissions) == 0o600 else {
                throw ImageStagingError.permissionEnforcementFailed
            }

            let chunkSize = 64 * 1_024
            var transferred: Int64 = 0
            while transferred < image.byteCount {
                try Task.checkCancellation()
                let remaining = image.byteCount - transferred
                let requested = min(chunkSize, Int(remaining))
                guard
                    let data = try localFile.read(upToCount: requested),
                    !data.isEmpty
                else {
                    throw ImageStagingError.byteCountMismatch
                }
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await remoteFile.write(buffer, at: UInt64(transferred))
                transferred += Int64(data.count)
                await progress(
                    ImageStageProgress(
                        transferredBytes: transferred,
                        totalBytes: image.byteCount))
            }
            guard try localFile.read(upToCount: 1)?.isEmpty != false else {
                throw ImageStagingError.byteCountMismatch
            }
            try await remoteFile.close()
        } catch {
            try? await remoteFile.close()
            throw error
        }
    }

    private func cancelImageStage(_ operationID: UUID) async {
        guard let sftp = imageStageClients[operationID] else { return }
        try? await sftp.close()
    }

    private func bestEffortRemovePart(at path: String) async {
        guard let sftp = try? await client.openSFTP() else { return }
        try? await sftp.remove(at: path)
        try? await sftp.close()
    }

    private static func permissionBits(_ permissions: UInt32?) -> UInt32? {
        permissions.map { $0 & 0o777 }
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
        // Bounded event-path buffering (#22): under overflow the oldest
        // event is shed and the loss surfaces as a drop marker (see the
        // yield in runEventsChannel); the events session forwards it and
        // the Console resyncs from a snapshot. Sizing rationale lives on
        // HerdrEventStream.bufferLimit.
        let (events, eventContinuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(HerdrEventStream.bufferLimit))
        // Carries exactly one ack line and is finished right after it; one
        // slot is all it can ever hold.
        let (ackLines, ackContinuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
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
            let command = try Self.socatCommand(socatPath: socatPath, socketPath: socketPath)
            try await client.withExec(command) {
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
                                if case .dropped = eventContinuation.yield(event) {
                                    // The bounded buffer shed its oldest
                                    // event; one marker covers everything
                                    // shed before it, and a marker the
                                    // flood later sheds lands right back
                                    // here and is re-armed (see
                                    // HerdrEvent.eventsDropped).
                                    _ = eventContinuation.yield(.eventsDropped)
                                }
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

    // MARK: Terminal channel
    //
    // One dedicated interactive terminal channel is exempt from the exec-slot
    // queue. The session budget is 8 RPC slots + events + terminal = sshd's
    // default MaxSessions 10.

    private enum TerminalChannelState: Equatable {
        case idle
        case streaming(readerID: UInt64)
    }

    private var terminalChannelState: TerminalChannelState = .idle
    private var nextTerminalReaderID: UInt64 = 0

    // MARK: Attach
    //
    // Citadel 0.12.1's public API has no PTY + exec-request combination —
    // `withPTY` sends a PTY request followed by a *shell* request — so the
    // attach command rides in as the shell's first input line, `exec`'d to
    // replace the shell outright: when attach exits, nothing is left on the
    // channel and it closes. Closing a PTY channel HUPs the remote process
    // group, which ends attach promptly (verified against localhost sshd in
    // the #11 e2e).

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        let socketPath = try await resolvedSocketPath()
        guard terminalChannelState == .idle else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        let bootstrapLine = try Self.attachBootstrapLine(
            attachCommand: attachCommand, request: request, socketPath: socketPath)
        // Deliberately unbounded (#22): raw PTY bytes have no framing, no
        // seq, and no snapshot to resync from, so a shed chunk would corrupt
        // the escape stream for the rest of the session. Volume is
        // interactive TUI output bounded by SSH channel flow control, and
        // the consumer is a synchronous terminal feed.
        let (output, outputContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        // Deliberately unbounded (#22): keystrokes and resizes arrive at
        // human rate, and silently shedding input would type the wrong
        // thing; the writer task drains it for the channel's whole life.
        let (input, inputContinuation) = AsyncStream<TerminalAttachInput>.makeStream()
        nextTerminalReaderID += 1
        let readerID = nextTerminalReaderID
        let readerTask = Task {
            await self.runAttachChannel(
                readerID: readerID, request: request, bootstrapLine: bootstrapLine,
                input: input, output: outputContinuation)
        }
        // No suspension between the idle guard and here (attachBootstrapLine
        // is synchronous), so the reader cannot have observed — let alone
        // ended — a state it is only now being recorded into.
        terminalChannelState = .streaming(readerID: readerID)
        return TerminalAttachSession(output: output, input: inputContinuation) {
            readerTask.cancel()
            await readerTask.value
        }
    }

    /// The line typed into the attach channel's login shell to become the
    /// attach process (see the MARK above for why a shell is involved at
    /// all). `exec` replaces the shell so the attach process's exit is the
    /// channel's end. The line must parse identically in POSIX shells and
    /// fish — both treat single-quoted text literally as long as it contains
    /// no quote, backslash, or control characters, so targets are restricted
    /// to exactly that (a Pane id that violates it could only come from a
    /// hostile server, and refusing beats handing it a shell).
    ///
    /// The attach process runs under `/bin/sh` so `HERDR_SOCKET_PATH` can pin
    /// the herdr CLI to this Host's configured socket (fish parses prefix
    /// assignments differently, so the login shell cannot set it portably);
    /// without it the CLI resolves the default session and a named-session
    /// target is "not found" there.
    static func attachBootstrapLine(
        attachCommand: String, request: TerminalAttachRequest, socketPath: String
    ) throws -> String {
        let unquotable: (Character) -> Bool = { character in
            character == "'" || character == "\\"
                || character.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
        guard !request.target.isEmpty, !request.target.contains(where: unquotable) else {
            throw TransportError.channelFailed(
                detail: "attach target cannot be quoted for the remote shell")
        }
        guard let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            throw TransportError.channelFailed(
                detail: "The remote socket path cannot be quoted safely.")
        }
        let takeover = request.takeover ? " --takeover" : ""
        return "exec /bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
            + "exec \(attachCommand) \"$1\"\(takeover)' attach "
            + "'\(request.target)' \(quotedSocketPath)\n"
    }

    /// The attach channel's lifetime: opens the PTY, types the bootstrap
    /// line, then pumps bytes both ways until the channel ends. Ending is by
    /// explicit close or the remote attach exiting: cancelling the reader
    /// task only ends the *local* inbound stream, the PTY body then returns,
    /// and Citadel closes the channel on the way out. Takes no exec slot
    /// (see MARK).
    private func runAttachChannel(
        readerID: UInt64,
        request: TerminalAttachRequest,
        bootstrapLine: String,
        input: AsyncStream<TerminalAttachInput>,
        output continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) async {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: request.cols,
            terminalRowHeight: request.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        /// nil means the stream ends gracefully: explicit `end()`, or the
        /// remote attach exiting cleanly (the user detached inside the TUI).
        var failure: TransportError?
        /// The read loop draining to a clean end (exit status 0). The remote
        /// exiting closes the channel before `withPTY` gets to close it on
        /// the way out, and that close's "already closed" error must not
        /// repaint a clean detach as a failure (found by the #11 e2e).
        var sawCleanEnd = false
        do {
            try await client.withPTY(pty) { inbound, outbound in
                try await outbound.write(ByteBuffer(string: bootstrapLine))
                // The writer rides alongside the read loop; the one input
                // stream keeps keystrokes and resizes ordered. Write
                // failures are swallowed: the channel death they signal
                // surfaces through the read loop.
                let writer = Task {
                    for await item in input {
                        do {
                            switch item {
                            case .keystrokes(let data):
                                try await outbound.write(ByteBuffer(bytes: data))
                            case .resize(let cols, let rows):
                                try await outbound.changeSize(
                                    cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                            }
                        } catch {
                            return
                        }
                    }
                }
                defer { writer.cancel() }
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer):
                        // A PTY merges everything into one byte stream;
                        // stderr chunks should not occur, but any that do
                        // belong on the terminal too.
                        continuation.yield(Data(buffer.readableBytesView))
                    }
                }
                sawCleanEnd = true
            }
            failure = nil
        } catch is CancellationError {
            failure = nil
        } catch {
            failure =
                Task.isCancelled || sawCleanEnd
                ? nil  // Explicit end() or a clean remote exit.
                : TransportError.channelFailed(detail: "attach channel: \(error)")
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
        let stagingClients = Array(imageStageClients.values)
        imageStageClients.removeAll()
        for sftp in stagingClients {
            try? await sftp.close()
        }
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
                try await wakeServer(socketPath: path)
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
    private func wakeServer(socketPath: String) async throws {
        try await Self.withRequestDeadline(requestTimeout) {
            try await self.wake.value {
                try await self.runWakeCommand(socketPath: socketPath)
            }
        }
    }

    /// Runs the wake command over a slot-gated no-PTY exec channel with
    /// stdin at EOF from the start (`< /dev/null`). `HERDR_SOCKET_PATH` pins
    /// the bridge and the server it spawns to this Host's configured socket;
    /// named locations also set `HERDR_SESSION` so the spawned server uses
    /// that session's state directory instead of the default session's state.
    /// The path rides as a positional argument so only the outer shell ever
    /// quotes it. The bridge's entry point ensures the server is running
    /// (spawn + wait for socket) before it starts bridging; the bridge then
    /// reads EOF and exits — so the command completing implies a live socket,
    /// and its own lifetime bounds the channel without writing or closing
    /// anything mid-flight.
    private func runWakeCommand(socketPath: String) async throws {
        let command = try Self.wakeExecCommand(
            wakeCommand: wakeCommand, socketPath: socketPath, socketLocation: socketLocation)
        try await acquireExecChannelSlot()
        defer { releaseExecChannelSlot() }
        _ = try await client.executeCommand(command)
    }

    /// The full remote command for waking this Host's configured herdr
    /// server. It runs under POSIX sh because login shells such as fish do
    /// not share assignment syntax, and passes the socket and optional named
    /// session as arguments so the wrapper script never interpolates their
    /// bytes.
    static func wakeExecCommand(
        wakeCommand: String, socketPath: String, socketLocation: HerdrSocketLocation
    ) throws -> String {
        guard let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            throw TransportError.channelFailed(
                detail: "The remote socket path cannot be quoted safely.")
        }
        let command: String
        switch socketLocation {
        case .namedSession(let sessionName):
            guard HerdrSessionName.isValid(sessionName) else {
                throw TransportError.channelFailed(
                    detail: "The herdr session name is invalid.")
            }
            command = "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$1\"; "
                + "export HERDR_SESSION=\"$2\"; \(wakeCommand) < /dev/null' wake "
                + "\(quotedSocketPath) \(sessionName)"
        case .defaultSession, .absolutePath:
            command = "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$1\"; "
                + "\(wakeCommand) < /dev/null' wake \(quotedSocketPath)"
        }
        return cLocaleCommand(command)
    }

    /// One no-PTY exec channel per request, raced against the per-request
    /// deadline. The channel is ended by returning from the `withExec` body
    /// as soon as a full response line has arrived (Citadel closes the
    /// channel on return) — never by task cancellation, which a live exec
    /// channel does not respond to.
    private func performRequest<P: Encodable, R: Decodable>(
        method: String, params: P, decoding type: R.Type
    ) async throws -> R {
        let requestID = UUID().uuidString
        let line = try HerdrWire.requestLine(id: requestID, method: method, params: params)
        let responseLine = try await Self.withRequestDeadline(requestTimeout) {
            let socketPath = try await self.resolvedSocketPath()
            return try await self.performExchange(
                line: line, socketPath: socketPath, method: method)
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
            let command = try Self.socatCommand(socatPath: socatPath, socketPath: socketPath)
            try await client.withExec(command) {
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
            output = try await client.executeCommand(Self.cLocaleCommand(homeCommand))
        } catch {
            throw TransportError.homeDirectoryUnresolvable(detail: String(describing: error))
        }
        return try Self.parseRemoteHome(output)
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

    private static let homeOutputPrefix = "__HERDR_MOBILE_HOME__="
    private static let stageDirectoryOutputPrefix = "__HERDR_MOBILE_STAGE_DIR__="

    private static func parseRemoteHome(_ output: ByteBuffer) throws -> String {
        let text = String(buffer: output)
        let home = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .first { $0.hasPrefix(homeOutputPrefix) }
            .map { line in
                var value = String(line.dropFirst(homeOutputPrefix.count))
                if value.last == "\r" { value.removeLast() }
                return value
            }
        guard let home, RemoteShellPath.isQuotableAbsolute(home) else {
            throw TransportError.homeDirectoryUnresolvable(
                detail: "home command printed: \(text.prefix(200))")
        }
        return home
    }

    private static func parseStageDirectory(_ output: ByteBuffer) throws -> String {
        let text = String(buffer: output)
        let directory = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .first { $0.hasPrefix(stageDirectoryOutputPrefix) }
            .map { line in
                var value = String(line.dropFirst(stageDirectoryOutputPrefix.count))
                if value.last == "\r" { value.removeLast() }
                return value
            }
        guard let directory else {
            throw ImageStagingError.remoteTemporaryDirectoryFailed
        }
        return try StagedImage(path: "\(directory)/placeholder").fileURL
            .deletingLastPathComponent().path
    }

    private static func socatCommand(socatPath: String, socketPath: String) throws -> String {
        guard
            let quotedSocatPath = RemoteShellPath.quotedAbsolute(socatPath),
            let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath)
        else {
            throw TransportError.channelFailed(
                detail: "The remote socat or socket path cannot be quoted safely.")
        }
        return cLocaleCommand("\(quotedSocatPath) - UNIX-CONNECT:\(quotedSocketPath)")
    }

    /// Stabilizes every parsed remote exec surface. Error classification and
    /// JSON diagnostics must not change with the Host account's locale.
    private static func cLocaleCommand(_ command: String) -> String {
        "LC_ALL=C \(command)"
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
