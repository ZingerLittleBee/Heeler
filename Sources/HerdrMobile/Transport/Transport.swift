import Foundation

/// The app-side abstraction that executes herdr API requests over SSH.
/// UI code talks to Transport, never to SSH primitives (ADR 0002).
protocol Transport: Sendable {
    /// Verifies the server speaks a protocol version we support and returns
    /// its identity. Must be the first call on every new connection path.
    func ping() async throws -> ServerInfo

    /// Lists the Agents herdr has detected across all workspaces.
    func listAgents() async throws -> [Agent]

    /// The full session tree in one call: agents plus the workspace context
    /// (labels, worktrees) that `listAgents()` lacks. The Console's snapshot
    /// source (#8) — re-fetched on every events-session `.connected`.
    func sessionSnapshot() async throws -> SessionSnapshot

    /// Reads a Pane's terminal output; the Console's last-output snippet
    /// source (`source: .recent`, ANSI stripped) and the Observe backfill.
    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult

    /// Delivers a typed message to an Agent (`agent.send`): the detail
    /// screen's message box (#10, User Story 6 — answering a Blocked agent
    /// without Attach). herdr's agent-aware send, targeted by the Agent's
    /// pane id. Returns once the server acknowledges; the effect shows up on
    /// the Observe stream.
    func sendToAgent(_ params: AgentSendParams) async throws

    /// Sends control keys to a Pane (`pane.send_keys`): the detail screen's
    /// quick-key bar (Enter/Esc/Ctrl-C/arrows/y-n, #10). Key names are
    /// herdr's own spellings — verified empirically against herdr 0.7.4:
    /// `enter`, `esc`, `ctrl+c`, `up`/`down`/`left`/`right`, `y`, `n` (herdr
    /// rejects e.g. `ctrl-c` with `invalid_key`).
    func sendKeys(_ params: PaneSendKeysParams) async throws

    /// Opens this Host's dedicated long-lived events channel and subscribes.
    /// Returns once the server acknowledges the subscription; the stream then
    /// carries events in canonical naming until `end()` closes the channel
    /// explicitly. One events channel per Host: a second call while one is
    /// live throws `.eventsChannelAlreadyOpen`.
    ///
    /// Subscribing does not replay existing state (verified against herdr
    /// 0.7.4): sync initial state with `listAgents()` alongside subscribing.
    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream

    /// Opens this Host's dedicated terminal channel and starts the read-only
    /// Observe live-follow (#9): NDJSON frame lines from `herdr terminal
    /// session observe`, decoded and base64-unwrapped, until `end()` closes
    /// the channel explicitly. One terminal channel per Host — the session
    /// slot budgeted for the terminal surface — so a second call while one
    /// is live throws `.terminalChannelAlreadyOpen`.
    func observeTerminal(_ request: TerminalObserveRequest) async throws -> TerminalFrameStream

    /// Whether the underlying connection to the Host is still alive. The
    /// reconnect machinery (#18) decides "re-subscribe on this connection or
    /// re-establish it" from this flag.
    var isConnected: Bool { get async }

    /// Tears the connection down explicitly, ending every channel it
    /// carries. Terminal: a closed Transport is not reusable.
    func close() async throws
}

/// herdr server identity as reported by `ping`.
struct ServerInfo: Sendable, Equatable {
    let version: String
    let protocolVersion: Int

    init(version: String, protocolVersion: Int) {
        self.version = version
        self.protocolVersion = protocolVersion
    }
}

/// A coding agent process running inside a herdr Pane.
///
/// The domain view of the generated wire type `AgentInfo`: only the fields
/// the app consumes, with wire-level optionality resolved. `AgentStatus` is
/// the generated raw-string wrapper; Blocked drives sort order and (later)
/// notifications.
struct Agent: Sendable, Equatable {
    let terminalID: String
    /// The agent program herdr detected: "claude", "codex", ...
    let kind: String
    /// Terminal title with spinner/status glyphs stripped.
    let title: String
    /// Mutable: the Console applies `pane.agent_status_changed` deltas in
    /// place between snapshots.
    var status: AgentStatus
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

    /// Maps the generated wire type onto the domain view. Wire-optional
    /// fields degrade instead of failing: herdr's API has no stability
    /// guarantee, and a missing title must not drop the Agent from the list.
    init(_ info: AgentInfo) {
        self.init(
            terminalID: info.terminalID,
            kind: info.agent ?? "unknown",
            title: info.terminalTitleStripped ?? info.terminalTitle ?? "",
            status: info.agentStatus,
            workspaceID: info.workspaceID,
            tabID: info.tabID,
            paneID: info.paneID,
            cwd: info.cwd ?? "",
            revision: info.revision
        )
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
/// user guidance consistently instead of string-matching.
enum TransportError: Error, Sendable, Equatable {
    /// The SSH server could not be reached: connection refused, no route,
    /// or the connection died before authentication.
    case sshUnreachable(detail: String)
    /// The Host rejected our credentials (key not authorized, wrong
    /// password, or the offered auth method is unavailable).
    case authenticationFailed
    /// First connect to an unknown Host and the user declined its key
    /// fingerprint; nothing was stored.
    case hostKeyRejected(presented: HostKeyFingerprint)
    /// The Host presented a key that differs from the trusted fingerprint —
    /// possibly a man-in-the-middle. Hard failure; the stored fingerprint is
    /// left untouched.
    case hostKeyMismatch(known: HostKeyFingerprint, presented: HostKeyFingerprint)
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
    /// A second events channel was requested while one is live; each Host
    /// keeps exactly one dedicated events channel (ADR 0002 headroom).
    case eventsChannelAlreadyOpen
    /// A second terminal channel was requested while one is live; each Host
    /// keeps exactly one (Observe now, Attach in #11 — the UI enforces one
    /// terminal surface at a time, this backstops the slot budget).
    case terminalChannelAlreadyOpen
    /// The request exceeded its per-request deadline; its exec channel was
    /// closed.
    case timedOut
    /// The request's task was cancelled before completing; any exec channel
    /// it held was closed.
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
