import Foundation
import Synchronization
import HeelerSSH

private struct HeelerSSHSessionListResponse: Decodable {
    let sessions: [HerdrSession]
}

private enum HeelerSSHAttachPumpError: Error, Sendable {
    case input(String)
    case output(String)
}

/// Linearizes explicit Attach shutdown with terminal output delivery.
///
/// `AsyncThrowingStream.Continuation.finish()` preserves buffered elements,
/// so a finished stream alone cannot guarantee that `end()` makes later
/// iterator reads return nil. This gate owns the buffer so explicit end can
/// discard it, while clean remote exit still drains every accepted byte.
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
    }

    private let state = Mutex(State())

    static func makeStream() -> (
        output: AsyncThrowingStream<Data, any Error>,
        gate: HeelerSSHAttachOutputGate
    ) {
        let gate = HeelerSSHAttachOutputGate()
        let output = AsyncThrowingStream<Data, any Error> {
            try await gate.next()
        }
        return (output, gate)
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
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
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
                    precondition(state.waiter == nil, "Attach output has more than one consumer")
                    state.waiter = continuation
                }
            }
        } onCancel: {
            cancelConsumer()
        }
    }

    private func cancelConsumer() {
        state.withLock { state in
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
    static let supportedProtocolVersion = 17
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
    private let channelAdmission: SSHChannelAdmission
    private let homeDirectory = SharedAsyncOperation<String>(cachesSuccess: true)
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

    /// Establishes the libssh2 Transport through the same app-owned
    /// credentials and TOFU policy as the production connection path.
    static func connect(settings: SSHTransportSettings) async throws -> HeelerSSHTransport {
        let targetEndpoint = try endpoint(host: settings.host, port: settings.port)
        guard let jump = settings.jump else {
            let connection = try await connectDirect(
                endpoint: targetEndpoint,
                username: settings.username,
                credentials: settings.credentials,
                policy: settings.hostKeyPolicy,
                timeout: settings.requestTimeout)
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

    init(
        connection: SSHConnection,
        socketPath: String,
        requestTimeout: Duration = .seconds(15)
    ) {
        self.connection = connection
        socketLocation = .absolutePath(socketPath)
        self.requestTimeout = requestTimeout
        wakeCommand = "herdr remote-client-bridge"
        sessionListCommand = SSHTransportSettings.defaultSessionListCommand
        agentDiscoveryCommand = SSHTransportSettings.defaultAgentDiscoveryCommand
        attachCommand = "herdr agent attach"
        homeCommand = "printf '__HEELER_HOME__=%s\\n' \"$HOME\""
        stageDirectoryCommand = SSHTransportSettings.defaultStageDirectoryCommand
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
        switch error {
        case .authenticationFailed:
            return .authenticationFailed
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .forwardingDenied:
            return .tcpForwardingUnavailable
        case .targetUnreachable, .connectionFailed, .invalidEndpoint,
            .algorithmNegotiationFailed, .connectionInvalidated:
            return .sshUnreachable(detail: String(describing: error))
        case .channelFailed, .streamLocalOpenFailed, .unexpectedEOF,
            .responseTooLarge, .sftpUnavailable, .sftpFailure:
            return .channelFailed(detail: String(describing: error))
        }
    }

    func ping() async throws -> ServerInfo {
        let pong = try await request(method: "ping", decoding: PongResponse.self)
        return try Self.serverInfo(from: pong)
    }

    static func serverInfo(from pong: PongResponse) throws -> ServerInfo {
        guard pong.protocolVersion == Self.supportedProtocolVersion else {
            throw TransportError.protocolVersionMismatch(
                server: pong.protocolVersion,
                supported: Self.supportedProtocolVersion)
        }
        return ServerInfo(version: pong.version, protocolVersion: pong.protocolVersion)
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
        guard connected, await connection.isConnected else {
            throw ImageStagingError.transferFailed
        }

        await progress(ImageStageProgress(transferredBytes: 0, totalBytes: image.byteCount))
        let parentDirectory = try await createStageParentDirectory()
        let operationID = UUID()

        do {
            return try await channelAdmission.withChannel(.ordinarySession) {
                try await withTaskCancellationHandler {
                    try await self.performImageStage(
                        image,
                        parentDirectory: parentDirectory,
                        operationID: operationID,
                        progress: progress)
                } onCancel: {
                    Task { await self.cancelImageStage(operationID) }
                }
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
                throw ImageStagingError.remoteTemporaryDirectoryFailed
            }
            return try StagedImage(path: "\(directory)/placeholder").fileURL
                .deletingLastPathComponent().path
        } catch let error as ImageStagingError {
            throw error
        } catch TransportError.cancelled {
            throw ImageStagingError.cancelled
        } catch {
            let connectionIsConnected = await connection.isConnected
            if !connected || !connectionIsConnected {
                throw ImageStagingError.transferFailed
            }
            throw ImageStagingError.remoteTemporaryDirectoryFailed
        }
    }

    private func performImageStage(
        _ image: PreparedImage,
        parentDirectory: String,
        operationID: UUID,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws -> StagedImage {
        let sftp: SSHSFTPClient
        do {
            sftp = try await connection.openSFTP(timeout: requestTimeout)
        } catch SSHError.sftpUnavailable {
            throw ImageStagingError.sftpUnavailable
        } catch {
            if Task.isCancelled { throw ImageStagingError.cancelled }
            throw ImageStagingError.transferFailed
        }
        imageStageClients[operationID] = sftp

        let stageID = UUID().uuidString.lowercased()
        let remoteDirectory = "\(parentDirectory)/stage-\(stageID)"
        let finalPath = "\(remoteDirectory)/image.\(image.format.fileExtension)"
        var partPath: String? = "\(finalPath).part"

        do {
            try await enforcePermissions(0o700, at: parentDirectory, over: sftp)
            try await sftp.createDirectory(
                at: remoteDirectory,
                permissions: 0o700,
                timeout: requestTimeout)
            try await enforcePermissions(0o700, at: remoteDirectory, over: sftp)

            guard let currentPartPath = partPath else {
                throw ImageStagingError.transferFailed
            }
            try await streamImage(
                image,
                to: currentPartPath,
                over: sftp,
                progress: progress)
            try Task.checkCancellation()

            let uploadedAttributes = try await sftp.attributes(
                at: currentPartPath,
                timeout: requestTimeout)
            guard uploadedAttributes.size == UInt64(image.byteCount) else {
                throw ImageStagingError.byteCountMismatch
            }
            guard uploadedAttributes.permissions == 0o600 else {
                throw ImageStagingError.permissionEnforcementFailed
            }
            try await sftp.renameFileAtomically(
                from: currentPartPath,
                to: finalPath,
                timeout: requestTimeout)
            partPath = nil

            let finalAttributes = try await sftp.attributes(
                at: finalPath,
                timeout: requestTimeout)
            guard finalAttributes.size == UInt64(image.byteCount) else {
                throw ImageStagingError.byteCountMismatch
            }
            guard finalAttributes.permissions == 0o600 else {
                throw ImageStagingError.permissionEnforcementFailed
            }
            let staged = try StagedImage(path: finalPath)
            imageStageClients[operationID] = nil
            try await sftp.close(timeout: requestTimeout)
            return staged
        } catch {
            imageStageClients[operationID] = nil
            try? await sftp.close(timeout: .seconds(2))
            if let partPath {
                await bestEffortRemoveRemoteFile(at: partPath)
            }
            if Task.isCancelled { throw ImageStagingError.cancelled }
            if let stagingError = error as? ImageStagingError {
                throw stagingError
            }
            if error as? SSHError == .sftpUnavailable {
                throw ImageStagingError.sftpUnavailable
            }
            throw ImageStagingError.transferFailed
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
            throw ImageStagingError.permissionEnforcementFailed
        }
    }

    private func streamImage(
        _ image: PreparedImage,
        to remotePath: String,
        over sftp: SSHSFTPClient,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws {
        let localFile: FileHandle
        do {
            localFile = try FileHandle(forReadingFrom: image.fileURL)
        } catch {
            throw ImageStagingError.localReadFailed
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
                try await remoteFile.write(data, timeout: requestTimeout)
                transferred += Int64(data.count)
                await progress(ImageStageProgress(
                    transferredBytes: transferred,
                    totalBytes: image.byteCount))
            }
            guard try localFile.read(upToCount: 1)?.isEmpty != false else {
                throw ImageStagingError.byteCountMismatch
            }
            try await remoteFile.close(timeout: requestTimeout)
        } catch {
            try? await remoteFile.close(timeout: .seconds(2))
            throw error
        }
    }

    private func cancelImageStage(_ operationID: UUID) async {
        guard let sftp = imageStageClients[operationID] else { return }
        try? await sftp.close(timeout: .seconds(2))
    }

    private func bestEffortRemoveRemoteFile(at path: String) async {
        let cleanup = Task {
            guard let sftp = try? await self.connection.openSFTP(timeout: .seconds(2)) else {
                return
            }
            try? await sftp.removeFile(at: path, timeout: .seconds(2))
            try? await sftp.close(timeout: .seconds(2))
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
        for sftp in stagingClients {
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
                throw TransportError.serverNotRunning(path: path)
            }
            return try await operation()
        }
    }

    private func wakeServer(socketPath: String) async throws {
        try await withRequestDeadline {
            try await self.wake.value {
                let command = try SSHTransport.wakeExecCommand(
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
            let result = try await self.runExec(Self.cLocaleCommand(command))
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
        switch error {
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .unexpectedEOF:
            return .malformedResponse("stream-local channel closed before a response line")
        case .responseTooLarge(let limit):
            return .malformedResponse("response line exceeds \(limit) bytes")
        case .authenticationFailed:
            return .authenticationFailed
        case .streamLocalOpenFailed:
            return .streamLocalOpenFailed(path: "<unknown>")
        case .connectionInvalidated:
            return .sshUnreachable(detail: "The SSH connection is no longer reusable.")
        case .invalidEndpoint, .connectionFailed, .algorithmNegotiationFailed,
            .channelFailed, .forwardingDenied, .targetUnreachable,
            .sftpUnavailable, .sftpFailure:
            return .channelFailed(detail: String(describing: error))
        }
    }

    private static let homeOutputPrefix = "__HEELER_HOME__="
    private static let stageDirectoryOutputPrefix = "__HEELER_STAGE_DIR__="

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

            let outputSource = HeelerSSHAttachOutputGate.makeStream()
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
                    output: outputSource.gate)
            }
            return TerminalAttachSession(
                output: outputSource.output,
                input: input,
                onEndStarted: outputSource.gate.beginExplicitEnd
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
    /// request that the Host may reject. The SSH server invokes its command
    /// processor for every exec request, but no interactive login shell is
    /// started or exposed to the terminal stream.
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
        return "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
            + "exec \(attachCommand) \"$1\"\(takeover)' attach "
            + "'\(request.target)' \(quotedSocketPath)"
    }

    private func runAttachChannel(
        readerID: UInt64,
        channel: SSHPTYChannel,
        admissionLease: SSHChannelAdmissionLease,
        input: TerminalAttachInputQueue,
        output: HeelerSSHAttachOutputGate
    ) async {
        var failure: TransportError?
        var sawCleanEnd = false
        var pumpFailure: HeelerSSHAttachPumpError?

        do {
            do {
                sawCleanEnd = try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        do {
                            try await SSHTransport.writeTerminalAttachInput(
                                input,
                                write: { data in
                                    try await channel.write(data, timeout: self.requestTimeout)
                                },
                                resize: { columns, rows in
                                    try await channel.resize(
                                        columns: columns,
                                        rows: rows,
                                        timeout: self.requestTimeout)
                                })
                            return false
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw HeelerSSHAttachPumpError.input(String(describing: error))
                        }
                    }
                    group.addTask {
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
                                    let status = try await channel.exitStatus(
                                        timeout: self.requestTimeout)
                                    guard status == 0 else {
                                        throw HeelerSSHAttachPumpError.output(
                                            "remote exit status \(status)")
                                    }
                                    return true
                                }
                                if !bytes.isEmpty { output.yield(bytes) }
                            }
                            throw CancellationError()
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as HeelerSSHAttachPumpError {
                            throw error
                        } catch {
                            throw HeelerSSHAttachPumpError.output(String(describing: error))
                        }
                    }
                    defer {
                        input.finish()
                        group.cancelAll()
                    }
                    return try await group.next() ?? true
                }
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
}
