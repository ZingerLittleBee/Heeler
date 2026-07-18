import Foundation

/// The app-side abstraction that executes herdr API requests over SSH.
/// UI code talks to Transport, never to SSH primitives (ADR 0002).
protocol Transport: Sendable {
    /// Verifies the server speaks a protocol version we support and returns
    /// its identity. Must be the first call on every new connection path.
    func ping() async throws -> ServerInfo

    /// Lists the Agents herdr has detected across all workspaces.
    func listAgents() async throws -> [Agent]
}

/// herdr server identity as reported by `ping`.
struct ServerInfo: Sendable, Equatable, Decodable {
    let version: String
    let protocolVersion: Int

    init(version: String, protocolVersion: Int) {
        self.version = version
        self.protocolVersion = protocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
    }
}

/// herdr's detected state of an Agent. Blocked means the agent is waiting on
/// human input and drives sort order and (later) notifications.
enum AgentStatus: String, Sendable, Equatable, Decodable {
    case idle, working, blocked, done, unknown

    /// Lenient: herdr's API has no stability guarantee, so a status value we
    /// do not know degrades to `.unknown` instead of failing the decode.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

/// A coding agent process running inside a herdr Pane.
struct Agent: Sendable, Equatable, Decodable {
    let terminalID: String
    /// The agent program herdr detected: "claude", "codex", ...
    let kind: String
    /// Terminal title with spinner/status glyphs stripped.
    let title: String
    let status: AgentStatus
    let workspaceID: String
    let tabID: String
    /// The Pane address used for per-pane subscriptions and attach.
    let paneID: String
    let cwd: String
    let revision: Int

    init(
        terminalID: String, kind: String, title: String, status: AgentStatus,
        workspaceID: String, tabID: String, paneID: String, cwd: String, revision: Int
    ) {
        self.terminalID = terminalID
        self.kind = kind
        self.title = title
        self.status = status
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.cwd = cwd
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case kind = "agent"
        case title = "terminal_title_stripped"
        case status = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case cwd
        case revision
    }
}

/// Where the herdr API socket lives on a Host. Home-relative locations are
/// resolved against the remote home directory, which the Transport resolves
/// over exec once per Host and caches.
enum HerdrSocketLocation: Sendable, Equatable {
    /// The default herdr session: `~/.config/herdr/herdr.sock`.
    case defaultSession
    /// A named session: `~/.config/herdr/sessions/<name>/herdr.sock`.
    case namedSession(String)
    /// An absolute path known in advance; needs no remote resolution.
    case absolutePath(String)

    /// The absolute socket path, given the Host's home directory.
    func path(homeDirectory: String) -> String {
        let home =
            homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        switch self {
        case .defaultSession:
            return "\(home)/.config/herdr/herdr.sock"
        case .namedSession(let name):
            return "\(home)/.config/herdr/sessions/\(name)/herdr.sock"
        case .absolutePath(let path):
            return path
        }
    }
}

/// Transport-level failures: a closed taxonomy so every screen maps errors to
/// user guidance consistently instead of string-matching. `timedOut` and
/// `cancelled` exist as cases now; their enforcement machinery (request
/// queue, per-request deadline) is #5.
enum TransportError: Error, Sendable, Equatable {
    /// The herdr API socket path does not exist on the Host: herdr is not
    /// installed there, or the socket path is wrong.
    case socketNotFound(path: String)
    /// The socket file exists but nothing accepts connections: the herdr
    /// server is not running (cold-start wake is #6).
    case serverNotRunning(path: String)
    /// socat is not at its configured absolute path on the Host.
    case socatMissing(path: String)
    /// The server speaks a herdr protocol version this build does not support.
    case protocolVersionMismatch(server: Int, supported: Int)
    /// The remote home directory could not be resolved, so a home-relative
    /// socket location has no path.
    case homeDirectoryUnresolvable(detail: String)
    /// The request exceeded its deadline.
    case timedOut
    /// The request was cancelled before completing.
    case cancelled
    /// The channel produced bytes that do not decode as a herdr response.
    case malformedResponse(String)
    /// The exec channel failed outside the known failure shapes; carries the
    /// underlying description for diagnostics.
    case channelFailed(detail: String)
}

/// An error returned by the herdr server inside a response envelope.
struct HerdrAPIError: Error, Sendable, Equatable {
    /// Normalized to a string; the wire schema promises `{"code","message"}`
    /// without pinning the code's JSON type.
    let code: String
    let message: String
}
