// @preconcurrency: Citadel predates strict concurrency and SSHClient is not
// marked Sendable; its async methods hop off the actor executor, which would
// otherwise be an error. The actor still serializes all access to the client.
@preconcurrency import Citadel
import CryptoKit
import Foundation
import NIOCore

/// How to reach one Host and its herdr socket. Auth is the tracer-bullet
/// Ed25519 subset; richer auth and host key policy are the SSH core work (#2).
struct SSHTransportSettings: Sendable {
    var host: String
    var port: Int
    var username: String
    var privateKey: Curve25519.Signing.PrivateKey
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
}

/// Transport over SSH exec channels running `socat - UNIX-CONNECT:<sock>`,
/// one channel per request because herdr serves one request per connection
/// (ADR 0002). An actor because Citadel's SSHClient is not Sendable.
actor SSHTransport: Transport {
    /// The herdr wire protocol version this build speaks (herdr 0.7.4).
    static let supportedProtocolVersion = 16

    private let client: SSHClient
    private let socketLocation: HerdrSocketLocation
    private let socatPath: String
    private let wakeCommand: String
    /// In-flight or completed remote home directory resolution; see
    /// `remoteHomeDirectory()`.
    private var homeDirectoryTask: Task<String, Error>?
    /// In-flight cold-start wake; concurrent refused requests share one wake
    /// instead of racing exec channels. Cleared on completion so a later
    /// cold start can wake again.
    private var wakeTask: Task<Void, Error>?

    private init(
        client: SSHClient, socketLocation: HerdrSocketLocation, socatPath: String,
        wakeCommand: String
    ) {
        self.client = client
        self.socketLocation = socketLocation
        self.socatPath = socatPath
        self.wakeCommand = wakeCommand
    }

    /// Connects and authenticates, but sends nothing yet: callers must `ping`
    /// first to verify the protocol version.
    ///
    /// Host key verification is not implemented yet (TOFU with fingerprint
    /// confirmation ships with the SSH core work); until then the server's
    /// host key is accepted without verification.
    static func connect(settings: SSHTransportSettings) async throws -> SSHTransport {
        let client = try await SSHClient.connect(
            host: settings.host,
            port: settings.port,
            authenticationMethod: .ed25519(
                username: settings.username, privateKey: settings.privateKey),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        return SSHTransport(
            client: client, socketLocation: settings.socket, socatPath: settings.socatPath,
            wakeCommand: settings.wakeCommand)
    }

    func ping() async throws -> ServerInfo {
        let info = try await request(method: "ping", decoding: ServerInfo.self)
        guard info.protocolVersion == Self.supportedProtocolVersion else {
            throw TransportError.protocolVersionMismatch(
                server: info.protocolVersion, supported: Self.supportedProtocolVersion)
        }
        return info
    }

    func listAgents() async throws -> [Agent] {
        try await request(method: "agent.list", decoding: AgentListResult.self).agents
    }

    /// Closes the SSH connection. Explicit close is the only way to end
    /// Citadel channels — a live exec channel ignores task cancellation.
    func close() async throws {
        try await client.close()
    }

    /// Executes one request, with cold-start recovery (#6): connection
    /// refused means the socket exists but the server is stopped, so run the
    /// wake command and retry the socket. Strictly bounded — one wake, one
    /// retry — so a wake that does not help surfaces `.serverNotRunning` to
    /// the user instead of looping silently.
    private func request<R: Decodable>(method: String, decoding type: R.Type) async throws -> R {
        do {
            return try await performRequest(method: method, decoding: type)
        } catch TransportError.serverNotRunning(let path) {
            do {
                try await wakeServer()
            } catch TransportError.cancelled {
                throw TransportError.cancelled
            } catch {
                // The wake itself failed (herdr missing, command errored):
                // the actionable problem is still a server that is not
                // running on this Host.
                throw TransportError.serverNotRunning(path: path)
            }
            return try await performRequest(method: method, decoding: type)
        }
    }

    /// Wakes the herdr server via the Host's wake command; concurrent
    /// refused requests share one in-flight wake.
    private func wakeServer() async throws {
        if let task = wakeTask {
            return try await task.value
        }
        let task = Task { try await self.runWakeCommand() }
        wakeTask = task
        defer { wakeTask = nil }
        return try await task.value
    }

    /// Runs the wake command over a no-PTY exec channel with stdin at EOF
    /// from the start (`< /dev/null`). The bridge's entry point ensures the
    /// server is running (spawn + wait for socket) before it starts
    /// bridging; the bridge then reads EOF and exits — so the command
    /// completing implies a live socket, and its own lifetime bounds the
    /// channel without writing or closing anything mid-flight.
    private func runWakeCommand() async throws {
        do {
            _ = try await client.executeCommand("\(wakeCommand) < /dev/null")
        } catch is CancellationError {
            throw TransportError.cancelled
        }
    }

    /// One no-PTY exec channel per request. The channel is ended by returning
    /// from the `withExec` body as soon as a full response line has arrived
    /// (Citadel closes the channel on return) — never by task cancellation,
    /// which a live exec channel does not respond to.
    private func performRequest<R: Decodable>(method: String, decoding type: R.Type) async throws
        -> R
    {
        let socketPath = try await resolvedSocketPath()
        let requestID = UUID().uuidString
        let line = try HerdrWire.requestLine(id: requestID, method: method)
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
        if !stdout.contains(0x0A),
            let failure = classifyExecFailure(stderr: stderr, socketPath: socketPath)
        {
            throw failure
        }
        return try HerdrWire.decodeResult(type, fromResponseLine: stdout, requestID: requestID)
    }

    /// The absolute socket path on this Host, resolving the remote home
    /// directory for home-relative locations.
    private func resolvedSocketPath() async throws -> String {
        if case .absolutePath(let path) = socketLocation { return path }
        return socketLocation.path(homeDirectory: try await remoteHomeDirectory())
    }

    /// The remote home directory, resolved over exec once per Host:
    /// concurrent first requests share one in-flight resolution, and the
    /// result is cached for the lifetime of the connection. A failed
    /// resolution is not cached, so the next request retries.
    private func remoteHomeDirectory() async throws -> String {
        let task = homeDirectoryTask ?? Task { try await self.resolveHomeDirectoryOverExec() }
        homeDirectoryTask = task
        do {
            return try await task.value
        } catch {
            homeDirectoryTask = nil
            throw error
        }
    }

    private func resolveHomeDirectoryOverExec() async throws -> String {
        let output: ByteBuffer
        do {
            // $HOME expands in every mainstream login shell, fish included.
            output = try await client.executeCommand("echo $HOME")
        } catch is CancellationError {
            throw TransportError.cancelled
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
