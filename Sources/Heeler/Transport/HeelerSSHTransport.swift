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

    init(
        connection: SSHConnection,
        socketPath: String,
        requestTimeout: Duration = .seconds(15)
    ) {
        self.connection = connection
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
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
            .channelFailed, .connectionInvalidated:
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
