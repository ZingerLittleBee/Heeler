import Foundation
import HeelerSSH

private struct HeelerSSHSessionListResponse: Decodable {
    let sessions: [HerdrSession]
}

/// The libssh2-backed app Transport. Ordinary herdr RPCs use fresh
/// direct-streamlocal channels, while Events owns one reserved long-lived
/// forwarding channel per Host (ADR 0011).
actor HeelerSSHTransport: Transport {
    static let supportedProtocolVersion = 17
    static let maximumResponseBytes = 1_048_576
    static let maxConcurrentForwardingChannels = 8
    static let maxConcurrentExecChannels = 8

    private let connection: SSHConnection
    private let socketLocation: HerdrSocketLocation
    private let requestTimeout: Duration
    private let wakeCommand: String
    private let sessionListCommand: String
    private let agentDiscoveryCommand: String
    private let homeCommand: String
    private let forwardingChannelBudget: SSHChannelBudget
    private let execChannelBudget: SSHChannelBudget
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
        homeCommand = "printf '__HEELER_HOME__=%s\\n' \"$HOME\""
        forwardingChannelBudget = SSHChannelBudget(
            capacity: Self.maxConcurrentForwardingChannels)
        execChannelBudget = SSHChannelBudget(capacity: Self.maxConcurrentExecChannels)
    }

    private init(connection: SSHConnection, settings: SSHTransportSettings) {
        self.connection = connection
        socketLocation = settings.socket
        requestTimeout = settings.requestTimeout
        wakeCommand = settings.wakeCommand
        sessionListCommand = settings.sessionListCommand
        agentDiscoveryCommand = settings.agentDiscoveryCommand
        homeCommand = settings.homeCommand
        forwardingChannelBudget = SSHChannelBudget(
            capacity: Self.maxConcurrentForwardingChannels)
        execChannelBudget = SSHChannelBudget(capacity: Self.maxConcurrentExecChannels)
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
            .responseTooLarge:
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

    var isConnected: Bool {
        get async {
            guard connected else { return false }
            return await connection.isConnected
        }
    }

    func close() async throws {
        guard connected else { return }
        connected = false
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
            return try await self.forwardingChannelBudget.withChannel {
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
        try await execChannelBudget.withChannel {
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
            .channelFailed, .forwardingDenied, .targetUnreachable:
            return .channelFailed(detail: String(describing: error))
        }
    }

    private static let homeOutputPrefix = "__HEELER_HOME__="

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

    private func unsupported<Value>(_ operation: String) throws -> Value {
        throw TransportError.channelFailed(
            detail: "HeelerSSH \(operation) is implemented by a later migration ticket.")
    }

    func subscribeToEvents(
        _ subscriptions: [EventSubscription]
    ) async throws -> HerdrEventStream {
        guard eventsChannelState == .idle else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        eventsChannelState = .opening
        do {
            let (stream, readerID) = try await withColdStartWake {
                try await self.openEventsChannel(subscriptions)
            }
            if endedEventsReaders.remove(readerID) != nil {
                eventsChannelState = .idle
            } else {
                eventsChannelState = .streaming(readerID: readerID)
            }
            return stream
        } catch {
            eventsChannelState = .idle
            throw error
        }
    }

    private func openEventsChannel(
        _ subscriptions: [EventSubscription]
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
        try unsupported("attachTerminal")
    }
}
