import Foundation
import Synchronization
import HeelerSSH

private struct HeelerSSHSessionListResponse: Decodable {
    let sessions: [HerdrSession]
}

private enum HeelerSSHAttachPumpError: Error, Sendable {
    case input(String)
    case output(String)
    /// Remote process exited nonzero. Distinct from a channel I/O failure so
    /// Attach can map a bare-`herdr` exit 127 onto the PATH problem (#206).
    case remoteExit(Int32)
}

/// The live PTY operations used by the Attach pumps. `SSHPTYChannel` is the
/// production implementation; tests replace it at this boundary.
protocol HeelerSSHAttachChannel: Sendable {
    func write(_ data: Data, timeout: Duration) async throws
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data?
    func resize(columns: Int, rows: Int, timeout: Duration) async throws
    func exitStatus(timeout: Duration) async throws -> Int32
}

extension SSHPTYChannel: HeelerSSHAttachChannel {}

private final class HeelerSSHAttachPumpCancellation: Sendable {
    private let flushWithheld = Mutex(false)

    func requestDiagnosticFlush() {
        flushWithheld.withLock { $0 = true }
    }

    var shouldFlushDiagnostic: Bool {
        flushWithheld.withLock { $0 }
    }
}

private enum HeelerSSHNotificationFileError: Error, Sendable {
    case permissionVerificationFailed
}

#if DEBUG
struct HeelerSSHNotificationFileStateForTesting: Sendable, Equatable {
    let activeClientCount: Int
    let temporaryPaths: [String]
    let ordinarySessionCount: Int
    let connectionChannelCount: Int
    let writeIsDelayed: Bool
}
#endif

private actor HeelerSSHNotificationFileCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters { waiter.resume() }
    }
}

/// Linearizes explicit Attach shutdown with terminal output delivery.
///
/// `AsyncThrowingStream.Continuation.finish()` preserves buffered elements,
/// so a finished stream alone cannot guarantee that `end()` makes later
/// iterator reads return nil. This gate owns the buffer so explicit end can
/// discard it, while clean remote exit still drains every accepted byte.
///
/// The stream has exactly one consumer task. The first task to read claims
/// the stream; reads from another task are refused with
/// `TransportError.terminalChannelAlreadyOpen` and leave the claimant running,
/// whether output is parked or buffered; see `next()`.
final class HeelerSSHAttachOutputGate: Sendable {
    private enum Completion {
        case finished
        case failed(any Error)
    }

    private struct State: ~Copyable {
        var buffered: [Data] = []
        var bufferedIndex = 0
        var waiter: CheckedContinuation<Data?, any Error>?
        var completion: Completion?
        var isExplicitlyEnding = false
        var isConsumerCancelled = false
        var consumer: TaskIdentity?
    }

    /// A stable scalar derived from the task performing a read. The unfolding
    /// stream does not expose iterator identity, and `UnsafeCurrentTask` is
    /// explicitly non-Sendable, so the gate retains only its hash value.
    private struct TaskIdentity: Equatable {
        private let value: Int

        static var current: TaskIdentity {
            withUnsafeCurrentTask { task in
                TaskIdentity(value: task?.hashValue ?? 0)
            }
        }
    }

    private let state = Mutex(State())

    #if DEBUG
        /// Whether a consumer is parked waiting for the next chunk. Lets
        /// tests enter the double-consumer window deterministically instead
        /// of guessing at it with a sleep.
        var hasParkedConsumerForTesting: Bool {
            state.withLock { $0.waiter != nil }
        }
    #endif

    static func makeStream() -> (
        output: AsyncThrowingStream<Data, any Error>,
        gate: HeelerSSHAttachOutputGate
    ) {
        let gate = HeelerSSHAttachOutputGate()
        return (gate.makeOutput(), gate)
    }

    /// One stream view over this gate. The gate owns all buffering and the
    /// consumer claim, so views are stateless and interchangeable for the
    /// claimant — but they are not shareable across readers: an unfolding
    /// stream instance keeps one produce storage for all its iterators, and
    /// the standard library clears it from a cancellation handler that runs
    /// before `next()` is ever invoked when the reading task is already
    /// cancelled. Hand each potential reader its own view (#164).
    func makeOutput() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { try await self.next() }
    }

    func beginExplicitEnd() {
        state.withLock { state in
            guard !state.isExplicitlyEnding else { return }
            state.isExplicitlyEnding = true
            state.buffered.removeAll(keepingCapacity: false)
            state.bufferedIndex = 0
            state.waiter?.resume(returning: nil)
            state.waiter = nil
        }
    }

    func yield(_ bytes: Data) {
        state.withLock { state in
            guard
                !state.isExplicitlyEnding,
                !state.isConsumerCancelled,
                state.completion == nil
            else { return }
            if let waiting = state.waiter {
                state.waiter = nil
                waiting.resume(returning: bytes)
            } else {
                state.buffered.append(bytes)
            }
        }
    }

    func finish(throwing failure: (any Error)? = nil) {
        state.withLock { state in
            guard state.completion == nil else { return }
            state.completion = failure.map(Completion.failed) ?? .finished
            guard
                state.bufferedIndex == state.buffered.count,
                let waiter = state.waiter
            else { return }
            state.waiter = nil
            if let failure {
                waiter.resume(throwing: failure)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }

    private func next() async throws -> Data? {
        let reader = TaskIdentity.current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    // A parked waiter only identifies overlapping reads. A
                    // buffered read completes synchronously, so the claim
                    // must persist across calls and be checked before every
                    // branch. The first task to read owns the stream (#153).
                    guard state.consumer == nil || state.consumer == reader else {
                        continuation.resume(
                            throwing: TransportError.terminalChannelAlreadyOpen)
                        return
                    }
                    state.consumer = reader
                    if state.isExplicitlyEnding || state.isConsumerCancelled {
                        continuation.resume(returning: nil)
                        return
                    }
                    if state.bufferedIndex < state.buffered.count {
                        let bytes = state.buffered[state.bufferedIndex]
                        state.bufferedIndex += 1
                        if state.bufferedIndex == state.buffered.count {
                            state.buffered.removeAll(keepingCapacity: true)
                            state.bufferedIndex = 0
                        }
                        continuation.resume(returning: bytes)
                        return
                    }
                    if let completion = state.completion {
                        switch completion {
                        case .finished:
                            continuation.resume(returning: nil)
                        case .failed(let failure):
                            continuation.resume(throwing: failure)
                        }
                        return
                    }
                    // Throwing at the extra consumer is load-bearing: an
                    // unfolding stream shares storage across iterators, and
                    // returning nil here would end the legitimate consumer's
                    // stream too (#137).
                    state.waiter = continuation
                }
            }
        } onCancel: {
            cancelConsumer(reader)
        }
    }

    /// Ends delivery because a consumer's task was cancelled.
    ///
    /// The cancellation handler is installed by every reader before the
    /// claim check in `next()` can refuse it, and it can fire at any point
    /// after installation. Without the ownership guard, a refused second
    /// consumer whose task is cancelled around its read would clear the
    /// buffer and resume the claimant's waiter with nil — silently ending a
    /// terminal it never owned (#164). Only the claimant, or a first reader
    /// still racing its own claim, may cancel delivery.
    private func cancelConsumer(_ reader: TaskIdentity) {
        state.withLock { state in
            guard state.consumer == nil || state.consumer == reader else { return }
            guard !state.isConsumerCancelled else { return }
            state.isConsumerCancelled = true
            state.buffered.removeAll(keepingCapacity: false)
            state.bufferedIndex = 0
            state.waiter?.resume(returning: nil)
            state.waiter = nil
        }
    }
}

/// The libssh2-backed app Transport. Ordinary herdr RPCs use fresh
/// direct-streamlocal channels, Events owns one reserved forwarding channel,
/// and Attach owns one reserved PTY exec channel per Host (ADR 0011).
actor HeelerSSHTransport: Transport {
    /// Lowest herdr protocol this build can drive. Below it, methods this app
    /// calls may genuinely be absent, so the Host is refused.
    static let minimumProtocolVersion = 17
    /// Highest protocol the committed schema snapshot
    /// (`scripts/herdr-schema.json`) was generated against. A Host above this
    /// is accepted and fully usable; it is merely newer than this build knows.
    ///
    /// The version check is a floor rather than an equality on purpose. herdr
    /// states no stability guarantee, and CLAUDE.md's contract is to parse
    /// leniently and *surface* mismatches — surfacing and refusing are not the
    /// same thing. Equality turned protocol 19, which is additively compatible
    /// with 17 in every one of its 164 shared definitions, into an unusable
    /// Host (#140); bumping the constant would have rebuilt the same outage at
    /// protocol 20.
    static let generatedProtocolVersion = 19
    static let maximumResponseBytes = 1_048_576
    static let maxConcurrentForwardingChannels =
        SSHChannelAdmission.Limits.production.ordinaryForwarding
    static let maxConcurrentExecChannels =
        SSHChannelAdmission.Limits.production.ordinarySession
    static let maxConnectionChannels = SSHChannelAdmission.Limits.production.connection

    private let connection: SSHConnection
    private let socketLocation: HerdrSocketLocation
    private let requestTimeout: Duration
    private let wakeCommand: String
    private let sessionListCommand: String
    private let agentDiscoveryCommand: String
    private let attachCommand: String
    private let homeCommand: String
    private let stageDirectoryCommand: String
    private let pluginListCommand: String
    private let notificationConfigDirCommand: String
    private let channelAdmission: SSHChannelAdmission
    private let homeDirectory = SharedAsyncOperation<String>(cachesSuccess: true)
    private let notificationConfigDirectory = SharedAsyncOperation<String>(cachesSuccess: true)
    private let wake = SharedAsyncOperation<Void>(cachesSuccess: false)
    private var connected = true

    private enum EventsChannelState: Equatable {
        case idle
        case opening
        case streaming(readerID: UInt64)
    }

    private var eventsChannelState: EventsChannelState = .idle
    private var nextEventsReaderID: UInt64 = 0
    private var endedEventsReaders: Set<UInt64> = []

    private enum TerminalChannelState: Equatable {
        case idle
        case opening
        case streaming(readerID: UInt64)
    }

    private var terminalChannelState: TerminalChannelState = .idle
    private var nextTerminalReaderID: UInt64 = 0
    private var imageStageClients: [UUID: SSHSFTPClient] = [:]
    private var notificationFileClients: [UUID: SSHSFTPClient] = [:]
    private var notificationTemporaryPaths: [UUID: String] = [:]

    /// Establishes the libssh2 Transport through the same app-owned
    /// credentials and TOFU policy as the production connection path.
    static func connect(settings: SSHTransportSettings) async throws -> HeelerSSHTransport {
        let targetEndpoint = try endpoint(host: settings.host, port: settings.port)
        guard let jump = settings.jump else {
            let connection: SSHConnection
            do {
                connection = try await connectDirect(
                    endpoint: targetEndpoint,
                    username: settings.username,
                    credentials: settings.credentials,
                    policy: settings.hostKeyPolicy,
                    timeout: settings.requestTimeout)
            } catch {
                // Every other hop maps before it throws; the direct hop must
                // too, or a raw SSHError escapes the TransportError taxonomy
                // the app and preflight classify against.
                throw mapConnect(error)
            }
            return HeelerSSHTransport(
                connection: connection,
                settings: settings)
        }

        let jumpEndpoint = try endpoint(host: jump.host, port: jump.port)
        let jumpConnection: SSHConnection
        do {
            jumpConnection = try await connectDirect(
                endpoint: jumpEndpoint,
                username: jump.username,
                credentials: jump.credentials,
                policy: settings.hostKeyPolicy,
                timeout: settings.requestTimeout)
        } catch {
            throw TransportError.jumpHostFailed(mapConnect(error))
        }

        let targetConnection: SSHConnection
        do {
            targetConnection = try await jumpConnection.connectThrough(
                to: targetEndpoint,
                timeout: settings.requestTimeout)
        } catch SSHError.forwardingDenied {
            throw TransportError.jumpHostFailed(.tcpForwardingUnavailable)
        } catch SSHError.targetUnreachable {
            throw TransportError.sshUnreachable(detail: "The Host is unreachable from the Jump Host.")
        } catch {
            throw mapConnect(error)
        }

        do {
            try await HeelerSSHHostKeyVerifier(
                host: settings.host,
                port: settings.port,
                policy: settings.hostKeyPolicy)
                .verify(targetConnection.hostKey)
            try await authenticate(
                targetConnection,
                username: settings.username,
                credentials: settings.credentials,
                timeout: settings.requestTimeout)
            return HeelerSSHTransport(
                connection: targetConnection,
                settings: settings)
        } catch {
            try? await targetConnection.close(timeout: .seconds(2))
            throw mapConnect(error)
        }
    }

    /// Test and fixture entry that already holds an authenticated connection.
    /// Command defaults come from `SSHTransportSettings` statics so they cannot
    /// drift from the production `init(connection:settings:)` path (#133).
    init(
        connection: SSHConnection,
        socketPath: String,
        requestTimeout: Duration = SSHTransportSettings.defaultRequestTimeout
    ) {
        self.connection = connection
        socketLocation = .absolutePath(socketPath)
        self.requestTimeout = requestTimeout
        wakeCommand = SSHTransportSettings.defaultWakeCommand
        sessionListCommand = SSHTransportSettings.defaultSessionListCommand
        agentDiscoveryCommand = SSHTransportSettings.defaultAgentDiscoveryCommand
        attachCommand = SSHTransportSettings.defaultAttachCommand
        homeCommand = SSHTransportSettings.defaultHomeCommand
        stageDirectoryCommand = SSHTransportSettings.defaultStageDirectoryCommand
        pluginListCommand = SSHTransportSettings.defaultPluginListCommand
        notificationConfigDirCommand =
            SSHTransportSettings.defaultNotificationConfigDirCommand
        channelAdmission = SSHChannelAdmission()
    }

    private init(connection: SSHConnection, settings: SSHTransportSettings) {
        self.connection = connection
        socketLocation = settings.socket
        requestTimeout = settings.requestTimeout
        wakeCommand = settings.wakeCommand
        sessionListCommand = settings.sessionListCommand
        agentDiscoveryCommand = settings.agentDiscoveryCommand
        attachCommand = settings.attachCommand
        homeCommand = settings.homeCommand
        stageDirectoryCommand = settings.stageDirectoryCommand
        pluginListCommand = settings.pluginListCommand
        notificationConfigDirCommand = settings.notificationConfigDirCommand
        channelAdmission = SSHChannelAdmission()
    }

    private static func connectDirect(
        endpoint: SSHEndpoint,
        username: String,
        credentials: SSHCredentials,
        policy: HostKeyPolicy,
        timeout: Duration
    ) async throws -> SSHConnection {
        let connection = try await SSHConnection.connect(to: endpoint, timeout: timeout)
        do {
            try await HeelerSSHHostKeyVerifier(
                host: endpoint.host,
                port: Int(endpoint.port),
                policy: policy)
                .verify(connection.hostKey)
            try await authenticate(
                connection,
                username: username,
                credentials: credentials,
                timeout: timeout)
            return connection
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    private static func authenticate(
        _ connection: SSHConnection,
        username: String,
        credentials: SSHCredentials,
        timeout: Duration
    ) async throws {
        switch credentials {
        case .password(let password):
            try await connection.authenticate(
                username: username,
                password: password,
                timeout: timeout)
        case .ed25519(let privateKey):
            let deviceKey = DeviceKey(privateKey: privateKey)
            try await connection.authenticate(
                username: username,
                publicKey: deviceKey.publicKeyBlob,
                signer: { data in try deviceKey.privateKey.signature(for: data) },
                timeout: timeout)
        }
    }

    private static func endpoint(host: String, port: Int) throws -> SSHEndpoint {
        guard let port = UInt16(exactly: port), !host.isEmpty else {
            throw TransportError.sshUnreachable(detail: "Invalid SSH endpoint.")
        }
        return SSHEndpoint(host: host, port: port)
    }

    private static func mapConnect(_ error: any Error) -> TransportError {
        if let error = error as? TransportError { return error }
        guard let error = error as? SSHError else {
            return .sshUnreachable(detail: String(describing: error))
        }
        // Shared cases resolve here before any connect-only arm, so a later
        // generic `.channelFailed` list cannot reclassify them (#133).
        if let shared = sharedClassification(for: error) {
            return shared
        }
        switch error {
        case .targetUnreachable, .connectionFailed, .invalidEndpoint,
            .algorithmNegotiationFailed, .connectionInvalidated:
            return .sshUnreachable(detail: String(describing: error))
        case .channelFailed, .streamLocalOpenFailed, .unexpectedEOF,
            .responseTooLarge, .sftpUnavailable, .sftpFailure:
            return .channelFailed(detail: String(describing: error))
        case .authenticationFailed, .timedOut, .cancelled, .forwardingDenied:
            // Exhaustiveness only: `sharedClassification` is total over these.
            return .channelFailed(detail: String(describing: error))
        }
    }

    func ping() async throws -> ServerInfo {
        let pong = try await request(method: "ping", decoding: PongResponse.self)
        return try Self.serverInfo(from: pong)
    }

    static func serverInfo(from pong: PongResponse) throws -> ServerInfo {
        guard pong.protocolVersion >= Self.minimumProtocolVersion else {
            throw TransportError.protocolVersionMismatch(
                server: pong.protocolVersion,
                supported: Self.minimumProtocolVersion)
        }
        return ServerInfo(
            version: pong.version,
            protocolVersion: pong.protocolVersion,
            exceedsGeneratedProtocol: pong.protocolVersion > Self.generatedProtocolVersion)
    }

    func listSessions() async throws -> [HerdrSession] {
        let output = try await runHostCommand(sessionListCommand)
        let sessions: [HerdrSession]
        do {
            sessions = try JSONDecoder().decode(
                HeelerSSHSessionListResponse.self,
                from: output).sessions
        } catch {
            throw TransportError.malformedResponse(
                "herdr session list returned invalid JSON: \(Self.preview(output))")
        }
        guard sessions.allSatisfy({ HerdrSessionName.isValid($0.name) }) else {
            throw TransportError.malformedResponse(
                "herdr session list returned an invalid session name")
        }
        return sessions
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        let output = try await runHostCommand(agentDiscoveryCommand)
        let discovered = Set(
            String(decoding: output, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> SupportedAgentKind? in
                    guard line.hasPrefix(SSHTransportSettings.agentAvailabilityMarker) else {
                        return nil
                    }
                    return SupportedAgentKind(
                        rawValue: String(
                            line.dropFirst(
                                SSHTransportSettings.agentAvailabilityMarker.count)))
                })
        return SupportedAgentKind.allCases.filter(discovered.contains)
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        let sources = SkillSourceCatalog.sources(for: query.kind)
        guard !sources.isEmpty else { return [] }
        let home = try await remoteHomeDirectory()
        let resolved = sources.compactMap { source -> SkillProbe.ResolvedSource? in
            let root: String?
            switch source.root {
            case .home: root = home
            case .project: root = query.projectRoot
            }
            guard let root, !root.isEmpty else { return nil }
            let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
            guard
                let quoted = RemoteShellPath.quotedAbsolute(
                    "\(trimmed)/\(source.relativePath)")
            else { return nil }
            return SkillProbe.ResolvedSource(
                scope: source.scope,
                quotedDirectory: quoted,
                layout: source.layout,
                commandPrefix: source.commandPrefix)
        }
        guard !resolved.isEmpty else { return [] }
        let output = try await runHostCommand(SkillProbe.command(for: resolved))
        return SkillProbe.skills(fromProbeOutput: output, sources: resolved)
    }

    func readSkillFile(atPath path: String) async throws -> String {
        guard let quoted = RemoteShellPath.quotedAbsolute(path) else {
            throw TransportError.channelFailed(detail: "skill path is not quotable")
        }
        let output = try await runHostCommand(
            SkillProbe.readFileCommand(quotedPath: quoted))
        guard let content = SkillProbe.documentContent(in: output) else {
            throw TransportError.malformedResponse(
                "The skill file is gone or unreadable on the Host.")
        }
        return content
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

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        try await request(method: "agent.read", params: params, decoding: PaneReadResponse.self)
            .read
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        let response = try await request(
            method: "agent.prompt", params: params, decoding: AgentPromptedResponse.self)
        return Agent(response.agent)
    }

    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        _ = try await request(
            method: "agent.send_keys",
            params: params,
            decoding: OkResponse.self)
    }

    func startAgent(_ launch: AgentLaunchRequest) async throws -> Agent {
        let created = try await request(
            method: "tab.create",
            params: TabCreateParams(
                cwd: launch.cwd,
                focus: false,
                workspaceID: launch.workspaceID),
            decoding: TabCreatedResponse.self)
        do {
            let response = try await startAgentAwaitingShell(
                launch,
                paneID: created.rootPane.paneID)
            return Agent(response.agent)
        } catch let error as HerdrAPIError {
            try? await closePane(PaneTarget(paneID: created.rootPane.paneID))
            throw error
        }
    }

    func startAgentInNewWorktree(
        _ launch: AgentLaunchRequest,
        worktree: WorktreeSpec
    ) async throws -> Agent {
        let created = try await request(
            method: "worktree.create",
            params: WorktreeCreateParams(
                base: worktree.base,
                branch: worktree.branch,
                focus: false,
                workspaceID: launch.workspaceID),
            decoding: WorktreeCreatedResponse.self)
        do {
            let response = try await startAgentAwaitingShell(
                launch,
                paneID: created.rootPane.paneID)
            return Agent(response.agent)
        } catch let error as HerdrAPIError {
            try? await removeWorktree(workspaceID: created.workspace.workspaceID)
            throw error
        }
    }

    private func removeWorktree(workspaceID: String) async throws {
        _ = try await request(
            method: "worktree.remove",
            params: WorktreeRemoveParams(workspaceID: workspaceID),
            decoding: WorktreeRemovedResponse.self)
    }

    private func startAgentAwaitingShell(
        _ launch: AgentLaunchRequest,
        paneID: String
    ) async throws -> AgentStartedResponse {
        let params = AgentStartParams(
            kind: launch.kind,
            name: launch.name,
            paneID: paneID,
            args: launch.arguments.isEmpty ? nil : launch.arguments)
        let deadline = ContinuousClock.now + Self.shellReadinessBudget
        while true {
            do {
                return try await request(
                    method: "agent.start",
                    params: params,
                    decoding: AgentStartedResponse.self)
            } catch let error as HerdrAPIError where error.code == "agent_pane_busy" {
                guard ContinuousClock.now + Self.shellReadinessRetryDelay < deadline else {
                    throw error
                }
                try await Task.sleep(for: Self.shellReadinessRetryDelay)
            }
        }
    }

    private static let shellReadinessBudget: Duration = .seconds(10)
    private static let shellReadinessRetryDelay: Duration = .milliseconds(500)

    func closePane(_ params: PaneTarget) async throws {
        _ = try await request(
            method: "pane.close",
            params: params,
            decoding: OkResponse.self)
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        _ = try await request(
            method: "agent.rename",
            params: params,
            decoding: AgentInfoResponse.self)
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        _ = try await request(
            method: "workspace.rename",
            params: params,
            decoding: WorkspaceInfoResponse.self)
    }

    // MARK: Notification plugin files

    static let notificationRegistrationFileName = "notifications.json"
    static let notificationConfigFileName = "notify.json"

    func readNotificationRegistration() async throws -> Data? {
        try await readPluginConfigFile(named: Self.notificationRegistrationFileName)
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        try await replacePluginConfigFile(
            named: Self.notificationRegistrationFileName,
            contents: contents)
    }

    func readNotificationConfig() async throws -> Data? {
        try await readPluginConfigFile(named: Self.notificationConfigFileName)
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        try await replacePluginConfigFile(
            named: Self.notificationConfigFileName,
            contents: contents)
    }

    private func readPluginConfigFile(named name: String) async throws -> Data? {
        try await withNotificationFileRequestDeadline {
            guard await self.notificationConnectionIsAvailable() else {
                throw NotificationRegistrationError.readFailed(
                    detail: "The SSH connection is unavailable.")
            }
            let directory = try await self.notificationPluginConfigDirectory()
            let path = "\(directory)/\(name)"
            let operationID = UUID()
            return try await self.channelAdmission.withChannel(.ordinarySession) {
                try await self.performNotificationFileRead(
                    at: path,
                    configDirectory: directory,
                    operationID: operationID)
            }
        }
    }

    private func replacePluginConfigFile(named name: String, contents: Data) async throws {
        try await withNotificationFileRequestDeadline {
            guard await self.notificationConnectionIsAvailable() else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The SSH connection is unavailable.")
            }
            let directory = try await self.notificationPluginConfigDirectory()
            let path = "\(directory)/\(name)"
            let operationID = UUID()
            try await self.channelAdmission.withChannel(.ordinarySession) {
                try await self.performNotificationFileReplace(
                    contents,
                    at: path,
                    configDirectory: directory,
                    operationID: operationID)
            }
        }
    }

    private func notificationConnectionIsAvailable() async -> Bool {
        guard connected else { return false }
        return await connection.isConnected
    }

    private func performNotificationFileRead(
        at path: String,
        configDirectory: String,
        operationID: UUID
    ) async throws -> Data? {
        let sftp: SSHSFTPClient
        do {
            sftp = try await connection.openSFTP(timeout: requestTimeout)
        } catch {
            try Self.notificationReadError(error)
        }
        notificationFileClients[operationID] = sftp

        do {
            try Task.checkCancellation()
            try await enforceNotificationPermissions(
                0o700,
                at: configDirectory,
                over: sftp)
            let contents = try await sftp.readFileIfPresent(
                at: path,
                timeout: requestTimeout)
            if contents != nil {
                try await enforceNotificationPermissions(0o600, at: path, over: sftp)
            }
            notificationFileClients[operationID] = nil
            try await sftp.close(timeout: requestTimeout)
            return contents
        } catch {
            notificationFileClients[operationID] = nil
            try? await sftp.close(timeout: .seconds(2))
            try Self.notificationReadError(error)
        }
    }

    private func performNotificationFileReplace(
        _ contents: Data,
        at path: String,
        configDirectory: String,
        operationID: UUID
    ) async throws {
        let sftp: SSHSFTPClient
        do {
            sftp = try await connection.openSFTP(timeout: requestTimeout)
        } catch {
            try Self.notificationWriteError(error)
        }
        notificationFileClients[operationID] = sftp
        var temporaryPath: String? = "\(path).tmp-\(UUID().uuidString.lowercased())"
        notificationTemporaryPaths[operationID] = temporaryPath

        do {
            try Task.checkCancellation()
            try await enforceNotificationPermissions(
                0o700,
                at: configDirectory,
                over: sftp)
            guard let currentTemporaryPath = temporaryPath else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The private temporary file is unavailable.")
            }
            let file = try await sftp.openFileForWriting(
                at: currentTemporaryPath,
                permissions: 0o600,
                timeout: requestTimeout)
            do {
                try await enforceNotificationPermissions(
                    0o600,
                    at: currentTemporaryPath,
                    over: sftp)
                if !contents.isEmpty {
                    try await file.write(contents, timeout: requestTimeout)
                }
                try await file.close(timeout: requestTimeout)
            } catch {
                try? await file.close(timeout: .seconds(2))
                throw error
            }

            let temporaryAttributes = try await sftp.attributes(
                at: currentTemporaryPath,
                timeout: requestTimeout)
            guard
                temporaryAttributes.size == UInt64(contents.count),
                temporaryAttributes.permissions == 0o600
            else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The private temporary file failed verification.")
            }
            try Task.checkCancellation()
            try await sftp.renameFileAtomically(
                from: currentTemporaryPath,
                to: path,
                timeout: requestTimeout)
            temporaryPath = nil
            notificationTemporaryPaths[operationID] = nil
            try await sftp.close(timeout: .seconds(2))
            notificationFileClients[operationID] = nil
        } catch {
            let operationError = error
            var compensationFailed = false
            if let temporaryPath {
                do {
                    try await removeNotificationTemporaryFile(
                        at: temporaryPath,
                        over: sftp)
                } catch {
                    compensationFailed = true
                }
            }
            notificationTemporaryPaths[operationID] = nil
            try? await sftp.close(timeout: .seconds(2))
            notificationFileClients[operationID] = nil
            if !(await connection.isConnected) { connected = false }
            if compensationFailed {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The incomplete temporary file could not be removed safely.")
            }
            try Self.notificationWriteError(operationError)
        }
    }

    private func enforceNotificationPermissions(
        _ permissions: UInt32,
        at path: String,
        over sftp: SSHSFTPClient
    ) async throws {
        try await sftp.setPermissions(permissions, at: path, timeout: requestTimeout)
        let attributes = try await sftp.attributes(at: path, timeout: requestTimeout)
        guard attributes.permissions == permissions else {
            throw HeelerSSHNotificationFileError.permissionVerificationFailed
        }
    }

    private func removeNotificationTemporaryFile(
        at path: String,
        over currentSFTP: SSHSFTPClient
    ) async throws {
        try await currentSFTP.removeFileForCompensation(
            at: path,
            timeout: .seconds(2))
    }

    private func withNotificationFileRequestDeadline<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let completion = HeelerSSHNotificationFileCompletion()
        do {
            return try await withRequestDeadline {
                do {
                    let value = try await operation()
                    await completion.finish()
                    return value
                } catch {
                    await completion.finish()
                    throw error
                }
            }
        } catch {
            await completion.wait()
            throw error
        }
    }

#if DEBUG
    func delayNextNotificationSFTPWriteForTesting(_ delay: Duration) async {
        await connection.delayNextSFTPWriteForTesting(delay)
    }

    func notificationFileStateForTesting() async -> HeelerSSHNotificationFileStateForTesting {
        let admission = await channelAdmission.snapshot()
        return HeelerSSHNotificationFileStateForTesting(
            activeClientCount: notificationFileClients.count,
            temporaryPaths: notificationTemporaryPaths.values.sorted(),
            ordinarySessionCount: admission.ordinarySession,
            connectionChannelCount: admission.connection,
            writeIsDelayed: await connection.isSFTPWriteDelayedForTesting)
    }

    func readRemoteFileForTesting(at path: String) async throws -> Data? {
        try await channelAdmission.withChannel(.ordinarySession) {
            let sftp = try await self.connection.openSFTP(timeout: self.requestTimeout)
            do {
                let contents = try await sftp.readFileIfPresent(
                    at: path,
                    timeout: self.requestTimeout)
                try await sftp.close(timeout: .seconds(2))
                return contents
            } catch {
                try? await sftp.close(timeout: .seconds(2))
                throw error
            }
        }
    }
#endif

    private func notificationPluginConfigDirectory() async throws -> String {
        try await notificationConfigDirectory.value {
            try await self.resolveNotificationConfigDirectory()
        }
    }

    private func resolveNotificationConfigDirectory() async throws -> String {
        let listOutput = try await runNotificationPluginProbe(command: pluginListCommand)
        let pluginID = try installedNotificationPluginID(in: listOutput)
        let configDirCommand = notificationConfigDirCommand.replacingOccurrences(
            of: SSHTransportSettings.notificationPluginIDToken,
            with: pluginID)
        let output = try await runNotificationPluginProbe(command: configDirCommand)
        guard
            let directory = Self.markerValue(
                in: output,
                prefix: Self.pluginConfigDirOutputPrefix),
            RemoteShellPath.isQuotableAbsolute(directory)
        else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The plugin config directory response was invalid.")
        }
        return directory
    }

    /// The id the Host's Heeler plugin is enabled under: the current id when
    /// present, else the newest legacy id. Registration targets that plugin's
    /// own config dir, so a Host still on an old plugin build keeps working.
    private func installedNotificationPluginID(in listOutput: Data) throws -> String {
        let list: NotificationPluginListEnvelope
        do {
            list = try JSONDecoder().decode(NotificationPluginListEnvelope.self, from: listOutput)
        } catch {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The plugin list response was invalid.")
        }
        let enabledIDs = list.result.plugins.compactMap { plugin in
            plugin.enabled != false ? plugin.pluginID : nil
        }
        let knownIDs = [SSHTransportSettings.notificationPluginID]
            + SSHTransportSettings.legacyNotificationPluginIDs
        guard let pluginID = knownIDs.first(where: enabledIDs.contains) else {
            throw NotificationRegistrationError.pluginNotInstalled
        }
        return pluginID
    }

    private func runNotificationPluginProbe(command: String) async throws -> Data {
        do {
            let result = try await runExec(
                Self.cLocaleCommand(HerdrHostPath.wrappingBareHerdr(command)))
            if let missing = HerdrHostPath.missingBinaryError(
                exitStatus: result.exitStatus, command: command)
            {
                throw missing
            }
            guard result.exitStatus == 0, result.reachedEOF else {
                throw NotificationRegistrationError.pluginProbeFailed(
                    detail: "The Host plugin probe failed.")
            }
            return result.stdout
        } catch TransportError.cancelled {
            throw TransportError.cancelled
        } catch TransportError.timedOut {
            throw TransportError.timedOut
        } catch TransportError.herdrBinaryNotFound {
            throw TransportError.herdrBinaryNotFound
        } catch let error as NotificationRegistrationError {
            throw error
        } catch {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The Host plugin probe failed.")
        }
    }

    private struct NotificationPluginListEnvelope: Decodable {
        struct ResultBody: Decodable {
            let plugins: [Entry]
        }

        struct Entry: Decodable {
            let pluginID: String?
            let enabled: Bool?

            private enum CodingKeys: String, CodingKey {
                case pluginID = "plugin_id"
                case enabled
            }
        }

        let result: ResultBody
    }

    private static func notificationReadError(_ error: any Error) throws -> Never {
        if isNotificationCancellation(error) { throw TransportError.cancelled }
        if isNotificationTimeout(error) { throw TransportError.timedOut }
        if let error = error as? NotificationRegistrationError { throw error }
        throw NotificationRegistrationError.readFailed(
            detail: notificationFailureDetail(error))
    }

    private static func notificationWriteError(_ error: any Error) throws -> Never {
        if isNotificationCancellation(error) { throw TransportError.cancelled }
        if isNotificationTimeout(error) { throw TransportError.timedOut }
        if let error = error as? NotificationRegistrationError { throw error }
        throw NotificationRegistrationError.writeFailed(
            detail: notificationFailureDetail(error))
    }

    private static func isNotificationCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if error as? SSHError == .cancelled { return true }
        if error as? TransportError == .cancelled { return true }
        return false
    }

    private static func isNotificationTimeout(_ error: any Error) -> Bool {
        if error as? SSHError == .timedOut { return true }
        if error as? TransportError == .timedOut { return true }
        return false
    }

    private static func notificationFailureDetail(_ error: any Error) -> String {
        if let error = error as? SSHError,
            case .sftpFailure(let status) = error
        {
            return "SFTP failed with status \(status)."
        }
        if error as? SSHError == .sftpUnavailable {
            return "SFTP is unavailable."
        }
        return "The SSH file operation failed."
    }

    // MARK: Attachment staging

    private struct StagingSource {
        let fileURL: URL
        let byteCount: Int64
        let remoteFilename: String
    }

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        guard
            image.byteCount > 0,
            image.byteCount <= Int64(ImagePreparer.maximumEncodedByteCount),
            let localSize = try? FileManager.default.attributesOfItem(
                atPath: image.fileURL.path)[.size] as? NSNumber,
            localSize.int64Value == image.byteCount
        else {
            throw AttachmentStagingError.invalidPreparedSource
        }
        let path = try await stage(
            StagingSource(
                fileURL: image.fileURL,
                byteCount: image.byteCount,
                remoteFilename: "image.\(image.format.fileExtension)"),
            progress: progress)
        return try StagedImage(path: path)
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        guard
            file.byteCount > 0,
            file.byteCount <= Int64(FilePreparer.maximumByteCount),
            let localSize = try? FileManager.default.attributesOfItem(
                atPath: file.fileURL.path)[.size] as? NSNumber,
            localSize.int64Value == file.byteCount
        else {
            throw AttachmentStagingError.invalidPreparedSource
        }
        let path = try await stage(
            StagingSource(
                fileURL: file.fileURL,
                byteCount: file.byteCount,
                remoteFilename: file.remoteFilename),
            progress: progress)
        return try StagedFile(path: path)
    }

    private func stage(
        _ source: StagingSource,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> String {
        guard connected, await connection.isConnected else {
            throw AttachmentStagingError.transferFailed
        }

        await progress(
            AttachmentStageProgress(transferredBytes: 0, totalBytes: source.byteCount))
        let parentDirectory = try await createStageParentDirectory()
        let operationID = UUID()

        do {
            // No cancellation handler. One used to race the staging task from
            // `onCancel:`, closing the SFTP client out from under it so the
            // compensation had to open a fresh one to unlink the `.part` — and
            // that fresh open is what killed the connection on a slow link
            // (#136). Cancellation reaches the blocked write on its own:
            // `checkProgress` and the socket wait the driver parks in are both
            // cancellable, so the write unwinds and the structured compensation
            // below runs with the client it already owns.
            return try await channelAdmission.withChannel(.ordinarySession) {
                try await self.performStage(
                    source,
                    parentDirectory: parentDirectory,
                    operationID: operationID,
                    progress: progress)
            }
        } catch let error as AttachmentStagingError {
            throw error
        } catch is CancellationError {
            throw AttachmentStagingError.cancelled
        } catch {
            throw Task.isCancelled
                ? AttachmentStagingError.cancelled : AttachmentStagingError.transferFailed
        }
    }

    private func createStageParentDirectory() async throws -> String {
        do {
            let result = try await runExec(Self.cLocaleCommand(stageDirectoryCommand))
            guard
                result.exitStatus == 0,
                result.reachedEOF,
                let directory = Self.markerValue(
                    in: result.stdout,
                    prefix: Self.stageDirectoryOutputPrefix)
            else {
                throw AttachmentStagingError.remoteTemporaryDirectoryFailed
            }
            return try StagedImage(path: "\(directory)/placeholder").fileURL
                .deletingLastPathComponent().path
        } catch let error as AttachmentStagingError {
            throw error
        } catch TransportError.cancelled {
            throw AttachmentStagingError.cancelled
        } catch {
            let connectionIsConnected = await connection.isConnected
            if !connected || !connectionIsConnected {
                throw AttachmentStagingError.transferFailed
            }
            throw AttachmentStagingError.remoteTemporaryDirectoryFailed
        }
    }

    private func performStage(
        _ source: StagingSource,
        parentDirectory: String,
        operationID: UUID,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> String {
        let sftp: SSHSFTPClient
        do {
            sftp = try await connection.openSFTP(timeout: requestTimeout)
        } catch SSHError.sftpUnavailable {
            throw AttachmentStagingError.sftpUnavailable
        } catch {
            if Task.isCancelled { throw AttachmentStagingError.cancelled }
            throw AttachmentStagingError.transferFailed
        }
        imageStageClients[operationID] = sftp

        let stageID = UUID().uuidString.lowercased()
        let remoteDirectory = "\(parentDirectory)/stage-\(stageID)"
        let finalPath = "\(remoteDirectory)/\(source.remoteFilename)"
        var partPath: String? = "\(finalPath).part"

        do {
            try await enforcePermissions(0o700, at: parentDirectory, over: sftp)
            try await sftp.createDirectory(
                at: remoteDirectory,
                permissions: 0o700,
                timeout: requestTimeout)
            try await enforcePermissions(0o700, at: remoteDirectory, over: sftp)

            guard let currentPartPath = partPath else {
                throw AttachmentStagingError.transferFailed
            }
            try await streamFile(
                at: source.fileURL,
                byteCount: source.byteCount,
                to: currentPartPath,
                over: sftp,
                progress: progress)
            try Task.checkCancellation()

            let uploadedAttributes = try await sftp.attributes(
                at: currentPartPath,
                timeout: requestTimeout)
            guard uploadedAttributes.size == UInt64(source.byteCount) else {
                throw AttachmentStagingError.byteCountMismatch
            }
            guard uploadedAttributes.permissions == 0o600 else {
                throw AttachmentStagingError.permissionEnforcementFailed
            }
            try await sftp.renameFileAtomically(
                from: currentPartPath,
                to: finalPath,
                timeout: requestTimeout)
            partPath = nil

            let finalAttributes = try await sftp.attributes(
                at: finalPath,
                timeout: requestTimeout)
            guard finalAttributes.size == UInt64(source.byteCount) else {
                throw AttachmentStagingError.byteCountMismatch
            }
            guard finalAttributes.permissions == 0o600 else {
                throw AttachmentStagingError.permissionEnforcementFailed
            }
            imageStageClients[operationID] = nil
            try await sftp.close(timeout: requestTimeout)
            return finalPath
        } catch {
            imageStageClients[operationID] = nil
            if let partPath {
                await bestEffortRemoveRemoteFile(at: partPath, over: sftp)
            }
            try? await sftp.close(timeout: .seconds(2))
            if Task.isCancelled { throw AttachmentStagingError.cancelled }
            if let stagingError = error as? AttachmentStagingError {
                throw stagingError
            }
            if error as? SSHError == .sftpUnavailable {
                throw AttachmentStagingError.sftpUnavailable
            }
            throw AttachmentStagingError.transferFailed
        }
    }

    private func enforcePermissions(
        _ permissions: UInt32,
        at path: String,
        over sftp: SSHSFTPClient
    ) async throws {
        try await sftp.setPermissions(permissions, at: path, timeout: requestTimeout)
        let attributes = try await sftp.attributes(at: path, timeout: requestTimeout)
        guard attributes.permissions == permissions else {
            throw AttachmentStagingError.permissionEnforcementFailed
        }
    }

    private func streamFile(
        at localURL: URL,
        byteCount: Int64,
        to remotePath: String,
        over sftp: SSHSFTPClient,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws {
        let localFile: FileHandle
        do {
            localFile = try FileHandle(forReadingFrom: localURL)
        } catch {
            throw AttachmentStagingError.localReadFailed
        }
        defer { try? localFile.close() }

        let remoteFile = try await sftp.openFileForWriting(
            at: remotePath,
            permissions: 0o600,
            timeout: requestTimeout)
        do {
            try await enforcePermissions(0o600, at: remotePath, over: sftp)
            let chunkSize = 64 * 1_024
            var transferred: Int64 = 0
            while transferred < byteCount {
                try Task.checkCancellation()
                let remaining = byteCount - transferred
                let requested = min(chunkSize, Int(remaining))
                guard
                    let data = try localFile.read(upToCount: requested),
                    !data.isEmpty
                else {
                    throw AttachmentStagingError.byteCountMismatch
                }
                try await remoteFile.write(data, timeout: requestTimeout)
                transferred += Int64(data.count)
                await progress(AttachmentStageProgress(
                    transferredBytes: transferred,
                    totalBytes: byteCount))
            }
            guard try localFile.read(upToCount: 1)?.isEmpty != false else {
                throw AttachmentStagingError.byteCountMismatch
            }
            try await remoteFile.close(timeout: requestTimeout)
        } catch {
            try? await remoteFile.close(timeout: .seconds(2))
            throw error
        }
    }

    /// Unlinks one abandoned `.part` so the user's attachment bytes do not outlive
    /// the failed operation, on the SFTP client that operation already owns.
    ///
    /// Detached, because the caller is usually a cancelled task and the unlink
    /// would inherit that cancellation and skip. Never on a *fresh* client:
    /// `SessionDriver.openSFTP` invalidates the whole session when its own
    /// budget expires, deliberately — an abandoned `libssh2_sftp_init` leaves
    /// session state no later call can clean up — and a cleanup that can kill
    /// the connection is not best-effort. Opening one here on a two-second
    /// budget is what made cancelling an upload over a slow link report
    /// `.sshUnreachable` on the user's next request (#136).
    private func bestEffortRemoveRemoteFile(
        at path: String,
        over sftp: SSHSFTPClient
    ) async {
        let cleanup = Task {
            try? await sftp.removeFile(at: path, timeout: .seconds(2))
        }
        await cleanup.value
    }

    var isConnected: Bool {
        get async {
            guard connected else { return false }
            return await connection.isConnected
        }
    }

    func close() async throws {
        guard connected else { return }
        connected = false
        let stagingClients = Array(imageStageClients.values)
        imageStageClients.removeAll()
        let notificationClients = Array(notificationFileClients.values)
        notificationFileClients.removeAll()
        for sftp in stagingClients {
            try? await sftp.close(timeout: .seconds(2))
        }
        for sftp in notificationClients {
            try? await sftp.close(timeout: .seconds(2))
        }
        do {
            try await connection.close(timeout: .seconds(2))
        } catch {
            throw await mapOperationError(error)
        }
    }

    private func request<R: Decodable & Sendable>(
        method: String,
        decoding type: R.Type
    ) async throws -> R {
        try await request(
            method: method,
            params: HerdrWire.EmptyParams(),
            decoding: type)
    }

    private func request<P: Encodable & Sendable, R: Decodable & Sendable>(
        method: String,
        params: P,
        decoding type: R.Type
    ) async throws -> R {
        try await withColdStartWake {
            try await self.performRequest(
                method: method,
                params: params,
                decoding: type)
        }
    }

    private func performRequest<P: Encodable & Sendable, R: Decodable & Sendable>(
        method: String,
        params: P,
        decoding type: R.Type
    ) async throws -> R {
        guard connected else {
            throw TransportError.sshUnreachable(
                detail: "The SSH connection is closed.")
        }
        let requestID = UUID().uuidString
        let line = try HerdrWire.requestLine(
            id: requestID,
            method: method,
            params: params)
        let responseLine = try await withRequestDeadline {
            let socketPath = try await self.resolvedSocketPath()
            return try await self.channelAdmission.withChannel(.ordinaryForwarding) {
                do {
                    return try await self.connection.exchangeStreamLocal(
                        socketPath: socketPath,
                        request: Data(line.utf8),
                        maximumResponseBytes: Self.maximumResponseBytes,
                        timeout: self.requestTimeout)
                } catch SSHError.streamLocalOpenFailed {
                    throw try await self.classifyStreamLocalOpenFailure(
                        socketPath: socketPath)
                } catch {
                    throw await self.mapOperationError(error)
                }
            }
        }
        return try HerdrWire.decodeResult(
            type,
            fromResponseLine: responseLine,
            requestID: requestID)
    }

    private func withColdStartWake<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch TransportError.streamLocalOpenFailed(let path) {
            do {
                try await wakeServer(socketPath: path)
            } catch TransportError.cancelled {
                throw TransportError.cancelled
            } catch TransportError.timedOut {
                throw TransportError.timedOut
            } catch {
                // The wake is a recovery attempt, not a diagnostic: its exit
                // status is evidence about the wake command, not about the
                // socket. A Host can run herdr from a login shell while `herdr`
                // is absent from the non-interactive PATH, so a failed wake
                // says nothing new — the original classification stands.
                throw TransportError.streamLocalOpenFailed(path: path)
            }
            return try await operation()
        }
    }

    private func wakeServer(socketPath: String) async throws {
        try await withRequestDeadline {
            try await self.wake.value {
                let command = try Self.wakeExecCommand(
                    wakeCommand: self.wakeCommand,
                    socketPath: socketPath,
                    socketLocation: self.socketLocation)
                let result = try await self.runExec(command)
                guard result.exitStatus == 0, result.reachedEOF else {
                    throw TransportError.channelFailed(
                        detail: "herdr wake command failed: \(Self.preview(result.stderr))")
                }
            }
        }
    }

    private func classifyStreamLocalOpenFailure(
        socketPath: String
    ) async throws -> TransportError {
        guard let quotedPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            return .socketNotFound(path: socketPath)
        }
        do {
            let result = try await runExec(
                "/bin/sh -c 'test -S \"$1\"' heeler \(quotedPath)")
            if result.exitStatus == 1 {
                return .socketNotFound(path: socketPath)
            }
            return .streamLocalOpenFailed(path: socketPath)
        } catch TransportError.cancelled {
            throw TransportError.cancelled
        } catch TransportError.timedOut {
            throw TransportError.timedOut
        } catch {
            return .streamLocalOpenFailed(path: socketPath)
        }
    }

    private func resolvedSocketPath() async throws -> String {
        if case .absolutePath(let path) = socketLocation { return path }
        return socketLocation.path(homeDirectory: try await remoteHomeDirectory())
    }

    private func remoteHomeDirectory() async throws -> String {
        try await withRequestDeadline {
            try await self.homeDirectory.value {
                let result = try await self.runExec(Self.cLocaleCommand(self.homeCommand))
                guard
                    result.exitStatus == 0,
                    let home = Self.markerValue(
                        in: result.stdout,
                        prefix: Self.homeOutputPrefix),
                    RemoteShellPath.isQuotableAbsolute(home)
                else {
                    throw TransportError.homeDirectoryUnresolvable(
                        detail: "home command printed: \(Self.preview(result.stdout))")
                }
                return home
            }
        }
    }

    private func runHostCommand(_ command: String) async throws -> Data {
        try await withRequestDeadline {
            let result = try await self.runExec(
                Self.cLocaleCommand(HerdrHostPath.wrappingBareHerdr(command)))
            if let missing = HerdrHostPath.missingBinaryError(
                exitStatus: result.exitStatus, command: command)
            {
                throw missing
            }
            guard result.reachedEOF else {
                throw TransportError.channelFailed(
                    detail: "Host command closed before EOF")
            }
            return result.stdout
        }
    }

    private func runExec(_ command: String) async throws -> SSHExecResult {
        try await channelAdmission.withChannel(.ordinarySession) {
            do {
                return try await self.connection.execute(
                    command,
                    timeout: self.requestTimeout)
            } catch {
                throw await self.mapOperationError(error)
            }
        }
    }

    private func withRequestDeadline<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await AsyncDeadline.run(
                for: requestTimeout,
                operation: operation)
        } catch AsyncDeadlineError.timedOut {
            throw TransportError.timedOut
        } catch is CancellationError {
            throw TransportError.cancelled
        }
    }

    private func mapOperationError(_ error: any Error) async -> TransportError {
        if error as? SSHError == .connectionInvalidated {
            connected = false
        }
        return Self.map(error)
    }

    private static func map(_ error: any Error) -> TransportError {
        guard let error = error as? SSHError else {
            return .channelFailed(detail: String(describing: error))
        }
        // Shared cases resolve here before any operation-only arm, so a later
        // generic `.channelFailed` list cannot reclassify them (#133).
        if let shared = sharedClassification(for: error) {
            return shared
        }
        switch error {
        case .unexpectedEOF:
            return .malformedResponse("stream-local channel closed before a response line")
        case .responseTooLarge(let limit):
            return .malformedResponse("response line exceeds \(limit) bytes")
        case .connectionInvalidated:
            return .sshUnreachable(detail: "The SSH connection is no longer reusable.")
        // `.streamLocalOpenFailed` falls here on purpose. Only
        // `classifyStreamLocalOpenFailure` may produce the path-bearing
        // `TransportError` of the same name, because only it knows the socket
        // path and has run `test -S` against it. Both stream-local open sites
        // catch the SSH error before reaching this generic mapper; were one to
        // stop doing so, a diagnostic-free `.channelFailed` is honest where a
        // fabricated path would not be.
        case .invalidEndpoint, .connectionFailed, .algorithmNegotiationFailed,
            .channelFailed, .streamLocalOpenFailed,
            .targetUnreachable, .sftpUnavailable, .sftpFailure:
            return .channelFailed(detail: String(describing: error))
        case .authenticationFailed, .timedOut, .cancelled, .forwardingDenied:
            // Exhaustiveness only: `sharedClassification` is total over these.
            return .channelFailed(detail: String(describing: error))
        }
    }

    /// Classifications that both connect-time (`mapConnect`) and post-connect
    /// (`map`) apply first for the same `SSHError`. Path-specific arms never
    /// see these cases while this returns non-nil (#133).
    private static func sharedClassification(for error: SSHError) -> TransportError? {
        switch error {
        case .authenticationFailed:
            return .authenticationFailed
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .forwardingDenied:
            return .tcpForwardingUnavailable
        case .invalidEndpoint, .connectionFailed, .algorithmNegotiationFailed,
            .channelFailed, .streamLocalOpenFailed, .unexpectedEOF,
            .responseTooLarge, .connectionInvalidated, .targetUnreachable,
            .sftpUnavailable, .sftpFailure:
            return nil
        }
    }

    #if DEBUG
    /// Test surface for the real connect-time mapper; not a second taxonomy.
    static func mapConnectForTesting(_ error: any Error) -> TransportError {
        mapConnect(error)
    }

    /// Test surface for the real post-connect mapper; not a second taxonomy.
    static func mapOperationForTesting(_ error: any Error) -> TransportError {
        map(error)
    }
    #endif

    private static let homeOutputPrefix = "__HEELER_HOME__="
    private static let stageDirectoryOutputPrefix = "__HEELER_STAGE_DIR__="
    private static let pluginConfigDirOutputPrefix = "__HEELER_PLUGIN_CONFIG_DIR__="

    private static func markerValue(in output: Data, prefix: String) -> String? {
        String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .first { $0.hasPrefix(prefix) }
            .map { line in
                var value = String(line.dropFirst(prefix.count))
                if value.last == "\r" { value.removeLast() }
                return value
            }
    }

    private static func preview(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
    }

    private static func cLocaleCommand(_ command: String) -> String {
        "LC_ALL=C \(command)"
    }

    /// The exec command that wakes a stopped herdr server (#6). A named
    /// session scopes the wake to its own state directory, so the spawned
    /// server serves the socket the request is actually waiting on.
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
            command = "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$1\"; "
                + "export HERDR_SESSION=\"$2\"; \(wakeCommand) < /dev/null' wake "
                + "\(quotedSocketPath) \(sessionName)"
        case .defaultSession, .absolutePath:
            command = "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$1\"; "
                + "\(wakeCommand) < /dev/null' wake \(quotedSocketPath)"
        }
        return cLocaleCommand(command)
    }

    func subscribeToEvents(
        _ subscriptions: [EventSubscription]
    ) async throws -> HerdrEventStream {
        guard eventsChannelState == .idle else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        eventsChannelState = .opening
        var admissionLease: SSHChannelAdmissionLease?
        do {
            let lease = try await channelAdmission.acquire(.events)
            admissionLease = lease
            let (stream, readerID) = try await withColdStartWake {
                try await self.openEventsChannel(
                    subscriptions,
                    admissionLease: lease)
            }
            if endedEventsReaders.remove(readerID) != nil {
                eventsChannelState = .idle
            } else {
                eventsChannelState = .streaming(readerID: readerID)
            }
            return stream
        } catch {
            if let admissionLease { await admissionLease.release() }
            eventsChannelState = .idle
            throw error
        }
    }

    private func openEventsChannel(
        _ subscriptions: [EventSubscription],
        admissionLease: SSHChannelAdmissionLease
    ) async throws -> (HerdrEventStream, readerID: UInt64) {
        guard connected else {
            throw TransportError.sshUnreachable(detail: "The SSH connection is closed.")
        }
        let socketPath = try await resolvedSocketPath()
        let requestID = UUID().uuidString
        let requestLine = try HerdrWire.subscribeRequestLine(
            id: requestID,
            subscriptions: subscriptions)
        let channel: SSHStreamLocalChannel
        do {
            channel = try await connection.openStreamLocal(
                socketPath: socketPath,
                timeout: requestTimeout)
        } catch SSHError.streamLocalOpenFailed {
            throw try await classifyStreamLocalOpenFailure(socketPath: socketPath)
        } catch {
            throw await mapOperationError(error)
        }

        do {
            try await channel.write(Data(requestLine.utf8), timeout: requestTimeout)
        } catch {
            try? await channel.close(timeout: .seconds(2))
            throw await mapOperationError(error)
        }

        let (events, eventContinuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(HerdrEventStream.bufferLimit))
        let (ackLines, ackContinuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        nextEventsReaderID &+= 1
        let readerID = nextEventsReaderID
        let readerTask = Task {
            await self.runEventsChannel(
                readerID: readerID,
                channel: channel,
                admissionLease: admissionLease,
                ack: ackContinuation,
                events: eventContinuation)
        }

        do {
            let ackLine = try await withRequestDeadline {
                var iterator = ackLines.makeAsyncIterator()
                guard let line = try await iterator.next() else {
                    throw TransportError.channelFailed(
                        detail: "events channel ended before ack")
                }
                return line
            }
            _ = try HerdrWire.decodeResult(
                SubscriptionStartedResponse.self,
                fromResponseLine: ackLine,
                requestID: requestID)
        } catch {
            readerTask.cancel()
            await readerTask.value
            endedEventsReaders.remove(readerID)
            throw error
        }

        return (
            HerdrEventStream(events: events) {
                readerTask.cancel()
                await readerTask.value
            },
            readerID)
    }

    private func runEventsChannel(
        readerID: UInt64,
        channel: SSHStreamLocalChannel,
        admissionLease: SSHChannelAdmissionLease,
        ack ackContinuation: AsyncThrowingStream<Data, any Error>.Continuation,
        events eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation
    ) async {
        var pending = Data()
        var sawAck = false
        var streamFailure: TransportError?
        var ackFailure = TransportError.cancelled

        do {
            while !Task.isCancelled {
                let chunk: Data?
                do {
                    chunk = try await channel.read(
                        maximumBytes: 16 * 1024,
                        timeout: .seconds(1))
                } catch SSHError.timedOut {
                    continue
                }
                guard let chunk else {
                    if sawAck {
                        streamFailure = .channelFailed(
                            detail: "events channel closed by remote")
                    } else {
                        ackFailure = .channelFailed(
                            detail: "events channel ended before ack")
                        streamFailure = ackFailure
                    }
                    break
                }
                pending.append(chunk)
                guard pending.count <= Self.maximumResponseBytes else {
                    throw TransportError.malformedResponse(
                        "events line exceeds \(Self.maximumResponseBytes) bytes")
                }
                while let line = Self.takeLine(from: &pending) {
                    if !sawAck {
                        sawAck = true
                        ackContinuation.yield(line)
                        ackContinuation.finish()
                    } else if let event = HerdrWire.decodeEvent(fromLine: line) {
                        if case .dropped = eventContinuation.yield(event) {
                            _ = eventContinuation.yield(.eventsDropped)
                        }
                    }
                }
            }
        } catch SSHError.cancelled {
            streamFailure = nil
        } catch is CancellationError {
            streamFailure = nil
        } catch {
            let failure = await mapOperationError(error)
            ackFailure = failure
            streamFailure = failure
        }

        do {
            try await channel.close(timeout: .seconds(2))
        } catch {
            let failure = await mapOperationError(error)
            if !Task.isCancelled {
                ackFailure = failure
                streamFailure = failure
            }
        }
        await admissionLease.release()

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
            endedEventsReaders.insert(readerID)
        }
    }

    private static func takeLine(from pending: inout Data) -> Data? {
        guard let newline = pending.firstIndex(of: 0x0A) else { return nil }
        let line = Data(pending[...newline])
        pending.removeSubrange(...newline)
        return line
    }

    func attachTerminal(
        _ request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession {
        guard terminalChannelState == .idle else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        terminalChannelState = .opening
        var admissionLease: SSHChannelAdmissionLease?

        do {
            let lease = try await channelAdmission.acquire(.attach)
            admissionLease = lease
            let socketPath = try await resolvedSocketPath()
            let command = try Self.attachExecCommand(
                attachCommand: attachCommand,
                request: request,
                socketPath: socketPath)
            let channel: SSHPTYChannel
            do {
                channel = try await connection.openPTY(
                    command: command,
                    columns: request.cols,
                    rows: request.rows,
                    timeout: requestTimeout)
            } catch {
                throw await mapOperationError(error)
            }

            let outputGate = HeelerSSHAttachOutputGate()
            let input = TerminalAttachInputQueue()
            nextTerminalReaderID &+= 1
            let readerID = nextTerminalReaderID
            terminalChannelState = .streaming(readerID: readerID)
            let readerTask = Task {
                await self.runAttachChannel(
                    readerID: readerID,
                    channel: channel,
                    admissionLease: lease,
                    input: input,
                    output: outputGate,
                    attachCommand: attachCommand)
            }
            return TerminalAttachSession(
                output: outputGate.makeOutput,
                input: input,
                onEndStarted: outputGate.beginExplicitEnd
            ) {
                input.finish()
                readerTask.cancel()
                await readerTask.value
            }
        } catch {
            if let admissionLease { await admissionLease.release() }
            terminalChannelState = .idle
            throw error
        }
    }

    /// Builds the remote exec request used after the PTY has been accepted.
    /// `HERDR_SOCKET_PATH` is set by the command itself, not an SSH environment
    /// request that the Host may reject. OpenSSH still runs the request through
    /// the account shell as `shell -c …`, so generic shell or SSH rc chatter
    /// can still reach the PTY; the handshake marker is printed immediately
    /// before `exec` of attach so the bootstrap gate can drop everything earlier.
    /// See `AttachBootstrapHandshake`.
    static func attachExecCommand(
        attachCommand: String,
        request: TerminalAttachRequest,
        socketPath: String
    ) throws -> String {
        let unquotable: (Character) -> Bool = { character in
            character == "'" || character == "\\"
                || character.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
        guard
            !attachCommand.isEmpty,
            !request.target.isEmpty,
            !request.target.contains(where: unquotable)
        else {
            throw TransportError.channelFailed(
                detail: "attach target cannot be quoted for the remote command")
        }
        guard let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            throw TransportError.channelFailed(
                detail: "The remote socket path cannot be quoted safely.")
        }
        let takeover = request.takeover ? " --takeover" : ""
        // The marker goes out last thing before the exec, so earlier startup
        // chatter can be dropped.
        return "/bin/sh -c '\(HerdrHostPath.pathExport); "
            + "export HERDR_SOCKET_PATH=\"$2\"; "
            + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
            + "exec \(attachCommand) \"$1\"\(takeover)' attach "
            + "'\(request.target)' \(quotedSocketPath)"
    }

    /// Maps a remote attach exit onto the Transport taxonomy. Exit 127 is
    /// `herdrBinaryNotFound` only when the exec'd command is still a bare
    /// `herdr` word; injectable scripts keep the generic channel failure.
    static func attachChannelFailure(
        exitStatus: Int32, attachCommand: String
    ) -> TransportError {
        HerdrHostPath.missingBinaryError(exitStatus: exitStatus, command: attachCommand)
            ?? .channelFailed(detail: "attach channel: remote exit status \(exitStatus)")
    }

    private func runAttachChannel(
        readerID: UInt64,
        channel: SSHPTYChannel,
        admissionLease: SSHChannelAdmissionLease,
        input: TerminalAttachInputQueue,
        output: HeelerSSHAttachOutputGate,
        attachCommand: String
    ) async {
        var failure: TransportError?
        var sawCleanEnd = false
        var pumpFailure: HeelerSSHAttachPumpError?

        do {
            do {
                sawCleanEnd = try await Self.runAttachPumps(
                    channel: channel,
                    input: input,
                    output: output,
                    requestTimeout: requestTimeout)
            } catch let error as HeelerSSHAttachPumpError {
                pumpFailure = error
                throw error
            }
            failure = nil
        } catch is CancellationError {
            failure = nil
        } catch {
            if Task.isCancelled || sawCleanEnd {
                failure = nil
            } else {
                switch pumpFailure {
                case .input(let detail):
                    failure = .channelFailed(detail: "attach input: \(detail)")
                case .output(let detail):
                    failure = .channelFailed(detail: "attach channel: \(detail)")
                case .remoteExit(let status):
                    failure = Self.attachChannelFailure(
                        exitStatus: status, attachCommand: attachCommand)
                case nil:
                    failure = .channelFailed(detail: "attach channel: \(error)")
                }
            }
        }

        do {
            try await channel.close(timeout: .seconds(2))
        } catch {
            let cleanupFailure = await mapOperationError(error)
            if failure == nil, !Task.isCancelled, !sawCleanEnd {
                failure = cleanupFailure
            }
        }
        await admissionLease.release()

        input.finish()
        if terminalChannelState == .streaming(readerID: readerID) {
            terminalChannelState = .idle
        }
        if let failure {
            output.finish(throwing: failure)
        } else {
            output.finish()
        }
    }

    /// Runs the same input and output pumps used by `runAttachChannel`, while
    /// leaving connection teardown and actor state to its caller.
    static func runAttachPumps(
        channel: any HeelerSSHAttachChannel,
        input: TerminalAttachInputQueue,
        output: HeelerSSHAttachOutputGate,
        requestTimeout: Duration
    ) async throws -> Bool {
        let cancellation = HeelerSSHAttachPumpCancellation()
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await input.pump(
                        write: { data in
                            try await channel.write(data, timeout: requestTimeout)
                        },
                        resize: { columns, rows in
                            try await channel.resize(
                                columns: columns,
                                rows: rows,
                                timeout: requestTimeout)
                        })
                    return false
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard !Task.isCancelled else { throw CancellationError() }
                    cancellation.requestDiagnosticFlush()
                    throw HeelerSSHAttachPumpError.input(String(describing: error))
                }
            }
            group.addTask {
                // Remote startup chatter stays off the terminal until the
                // attach exec prints the bootstrap marker.
                var gate = AttachBootstrapGate()
                func yieldAdmitted(_ bytes: Data) {
                    guard !bytes.isEmpty else { return }
                    output.yield(bytes)
                }
                do {
                    while !Task.isCancelled {
                        let bytes: Data?
                        do {
                            bytes = try await channel.read(
                                maximumBytes: 16 * 1024,
                                timeout: .seconds(1))
                        } catch SSHError.timedOut {
                            continue
                        }
                        guard let bytes else {
                            let status = try await channel.exitStatus(timeout: requestTimeout)
                            guard status == 0 else {
                                yieldAdmitted(gate.flush())
                                throw HeelerSSHAttachPumpError.remoteExit(status)
                            }
                            yieldAdmitted(gate.flush())
                            return true
                        }
                        yieldAdmitted(gate.admit(bytes))
                    }
                    throw CancellationError()
                } catch is CancellationError {
                    // A sibling input failure requests one diagnostic flush;
                    // explicit cancellation leaves the request false.
                    if cancellation.shouldFlushDiagnostic {
                        yieldAdmitted(gate.flush())
                    }
                    throw CancellationError()
                } catch let error as HeelerSSHAttachPumpError {
                    throw error
                } catch {
                    yieldAdmitted(gate.flush())
                    throw HeelerSSHAttachPumpError.output(String(describing: error))
                }
            }
            defer {
                input.finish()
                group.cancelAll()
            }
            return try await group.next() ?? true
        }
    }
}
