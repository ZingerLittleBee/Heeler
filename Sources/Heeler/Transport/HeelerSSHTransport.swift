import Foundation
import HeelerSSH

/// The direct-streamlocal tracer for the libssh2 migration. It proves the
/// existing Transport seam and herdr wire behavior while the production app
/// remains on SSHTransport until the atomic cutover in ADR 0011.
actor HeelerSSHTransport: Transport {
    static let supportedProtocolVersion = 17
    static let maximumResponseBytes = 1_048_576

    private let connection: SSHConnection
    private let socketPath: String
    private let requestTimeout: Duration
    private var connected = true

    /// Establishes the libssh2 tracer through the same app-owned credentials
    /// and TOFU policy as the production Transport. This is the Jump Host gate
    /// from ADR 0011; broader capability migration remains in later tickets.
    static func connect(settings: SSHTransportSettings) async throws -> HeelerSSHTransport {
        guard case .absolutePath(let socketPath) = settings.socket else {
            throw TransportError.homeDirectoryUnresolvable(
                detail: "The Jump Host gate requires an absolute fixture socket path.")
        }
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
                socketPath: socketPath,
                requestTimeout: settings.requestTimeout)
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
                socketPath: socketPath,
                requestTimeout: settings.requestTimeout)
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
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
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
        guard connected else {
            throw TransportError.sshUnreachable(detail: "The SSH connection is closed.")
        }
        let requestID = UUID().uuidString
        let requestLine = try HerdrWire.requestLine(id: requestID, method: "ping")
        let responseLine: Data
        do {
            responseLine = try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: Data(requestLine.utf8),
                maximumResponseBytes: Self.maximumResponseBytes,
                timeout: requestTimeout)
        } catch SSHError.streamLocalOpenFailed {
            throw await classifyStreamLocalOpenFailure()
        } catch {
            throw Self.map(error)
        }

        let pong = try HerdrWire.decodeResult(
            PongResponse.self,
            fromResponseLine: responseLine,
            requestID: requestID)
        guard pong.protocolVersion == Self.supportedProtocolVersion else {
            throw TransportError.protocolVersionMismatch(
                server: pong.protocolVersion,
                supported: Self.supportedProtocolVersion)
        }
        return ServerInfo(version: pong.version, protocolVersion: pong.protocolVersion)
    }

    var isConnected: Bool { connected }

    func close() async throws {
        guard connected else { return }
        connected = false
        do {
            try await connection.close(timeout: .seconds(2))
        } catch {
            throw Self.map(error)
        }
    }

    private func classifyStreamLocalOpenFailure() async -> TransportError {
        guard let quotedPath = RemoteShellPath.quotedAbsolute(socketPath) else {
            return .socketNotFound(path: socketPath)
        }
        do {
            let result = try await connection.execute(
                "/bin/sh -c 'test -S \"$1\"' heeler \(quotedPath)",
                timeout: requestTimeout)
            if result.exitStatus == 1 {
                return .socketNotFound(path: socketPath)
            }
            return .streamLocalOpenFailed(path: socketPath)
        } catch {
            return .streamLocalOpenFailed(path: socketPath)
        }
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
        case .invalidEndpoint, .connectionFailed, .algorithmNegotiationFailed,
            .channelFailed, .forwardingDenied, .targetUnreachable,
            .connectionInvalidated:
            return .channelFailed(detail: String(describing: error))
        }
    }

    private func unsupported<Value>(_ operation: String) throws -> Value {
        throw TransportError.channelFailed(
            detail: "HeelerSSH \(operation) is implemented by a later migration ticket.")
    }

    func listAgents() async throws -> [Agent] { try unsupported("listAgents") }
    func sessionSnapshot() async throws -> SessionSnapshot { try unsupported("sessionSnapshot") }
    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        try unsupported("readPane")
    }
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        try unsupported("startAgent")
    }
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest,
        worktree: WorktreeSpec
    ) async throws -> Agent {
        try unsupported("startAgentInNewWorktree")
    }
    func closePane(_ params: PaneTarget) async throws { try unsupported("closePane") as Void }
    func renameAgent(_ params: AgentRenameParams) async throws {
        try unsupported("renameAgent") as Void
    }
    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        try unsupported("renameWorkspace") as Void
    }
    func subscribeToEvents(
        _ subscriptions: [EventSubscription]
    ) async throws -> HerdrEventStream {
        try unsupported("subscribeToEvents")
    }
    func attachTerminal(
        _ request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession {
        try unsupported("attachTerminal")
    }
}
