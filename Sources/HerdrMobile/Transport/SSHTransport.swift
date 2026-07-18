// @preconcurrency: Citadel predates strict concurrency and SSHClient is not
// marked Sendable; its async methods hop off the actor executor, which would
// otherwise be an error. The actor still serializes all access to the client.
@preconcurrency import Citadel
import CryptoKit
import Foundation
import NIOCore

/// How to reach one Host and its herdr socket. Tracer-bullet subset: Ed25519
/// key auth and an explicit socket path; remote socket path resolution and the
/// full error taxonomy are #17, richer auth is the SSH core work.
struct SSHTransportSettings: Sendable {
    var host: String
    var port: Int
    var username: String
    var privateKey: Curve25519.Signing.PrivateKey
    /// Absolute path of the herdr API socket on the Host.
    var socketPath: String
    /// Absolute path of socat on the Host. Remote commands run through the
    /// user's login shell, whose PATH cannot be trusted.
    var socatPath: String
}

/// Transport over SSH exec channels running `socat - UNIX-CONNECT:<sock>`,
/// one channel per request because herdr serves one request per connection
/// (ADR 0002). An actor because Citadel's SSHClient is not Sendable.
actor SSHTransport: Transport {
    /// The herdr wire protocol version this build speaks (herdr 0.7.4).
    static let supportedProtocolVersion = 16

    private let client: SSHClient
    private let socketPath: String
    private let socatPath: String

    private init(client: SSHClient, socketPath: String, socatPath: String) {
        self.client = client
        self.socketPath = socketPath
        self.socatPath = socatPath
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
            client: client, socketPath: settings.socketPath, socatPath: settings.socatPath)
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

    /// One no-PTY exec channel per request. The channel is ended by returning
    /// from the `withExec` body as soon as a full response line has arrived
    /// (Citadel closes the channel on return) — never by task cancellation,
    /// which a live exec channel does not respond to.
    private func request<R: Decodable>(method: String, decoding type: R.Type) async throws -> R {
        let requestID = UUID().uuidString
        let line = try HerdrWire.requestLine(id: requestID, method: method)
        var stdout = Data()
        try await client.withExec("\(socatPath) - UNIX-CONNECT:\(socketPath)") {
            inbound, outbound in
            try await outbound.write(ByteBuffer(string: line))
            for try await chunk in inbound {
                guard case .stdout(let buffer) = chunk else { continue }
                stdout.append(contentsOf: buffer.readableBytesView)
                if stdout.contains(0x0A) { return }
            }
        }
        return try HerdrWire.decodeResult(type, fromResponseLine: stdout, requestID: requestID)
    }
}
