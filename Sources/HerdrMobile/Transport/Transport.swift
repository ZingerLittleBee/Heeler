import Foundation

/// The app-side abstraction that executes herdr API requests over SSH.
/// UI code talks to Transport, never to SSH primitives (ADR 0002).
protocol Transport: Sendable {
    /// Verifies the server speaks a protocol version we support and returns
    /// its identity. Must be the first herdr API call on every new connection
    /// path; Host-local session discovery may run before it.
    func ping() async throws -> ServerInfo

    /// Lists the local herdr sessions visible to this SSH account. This is a
    /// Host-level capability and does not depend on the currently selected
    /// API socket, so onboarding can recover from a stale manual selection.
    func listSessions() async throws -> [HerdrSession]

    /// Lists the Agents herdr has detected across all workspaces.
    func listAgents() async throws -> [Agent]

    /// The full session tree in one call: agents plus the workspace context
    /// (labels, worktrees) that `listAgents()` lacks. The Console's snapshot
    /// source (#8) — re-fetched on every events-session `.connected`.
    func sessionSnapshot() async throws -> SessionSnapshot

    /// Reads a Pane's recent terminal output for the Console card snippet.
    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult

    /// Starts a new Agent: the new-agent flow (#12, User Story 8 — dispatch
    /// work from the road). Creates a fresh herdr tab in the chosen workspace,
    /// starts the requested agent in its root pane, and returns the Agent once
    /// the server acknowledges. The new pane also surfaces in the
    /// Console through the normal snapshot/delta machinery (a membership
    /// event triggers a re-snapshot), so callers do not thread the return
    /// value into the list themselves.
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent

    /// Closes a Pane (`pane.close`): the Agent detail screen's destructive
    /// close action (#13, User Story 9 — a Done agent must not be destroyed
    /// by a stray swipe, so the UI gates this behind an explicit
    /// confirmation). herdr removes the pane and its agent everywhere; the
    /// removal surfaces in the Console through the normal snapshot/delta
    /// machinery (a `pane.closed` membership event triggers a re-snapshot),
    /// so callers do not prune the list themselves. Targeted by the Pane's
    /// id; returns once the server acknowledges.
    func closePane(_ params: PaneTarget) async throws

    /// Opens this Host's dedicated long-lived events channel and subscribes.
    /// Returns once the server acknowledges the subscription; the stream then
    /// carries events in canonical naming until `end()` closes the channel
    /// explicitly. One events channel per Host: a second call while one is
    /// live throws `.eventsChannelAlreadyOpen`.
    ///
    /// Subscribing does not replay existing state (verified against herdr
    /// 0.7.4): sync initial state with `listAgents()` alongside subscribing.
    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream

    /// Opens this Host's dedicated terminal channel as a full interactive
    /// Attach: a PTY running `herdr agent attach`, raw bytes both ways until
    /// `end()` closes the channel explicitly. One terminal channel is allowed
    /// per Host, so a second call while one is live throws
    /// `.terminalChannelAlreadyOpen`.
    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession

    /// Stages one normalized app-owned image in private Host temporary
    /// storage. Concrete transports own destination selection, restrictive
    /// permissions, partial-file handling, and atomic completion (ADR 0006).
    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws -> StagedImage

    /// Reads the Notification Registration file (v1, `plugin/README.md`)
    /// from the herdr-mobile plugin's config dir on this Host; nil when no
    /// device has registered yet. Throws
    /// `NotificationRegistrationError.pluginNotInstalled` when the plugin is
    /// absent, so the ceremony can tell "install the plugin" apart from a
    /// broken read (#72).
    func readNotificationRegistration() async throws -> Data?

    /// Atomically replaces the Notification Registration file with
    /// `contents` (temp file + rename per the v1 contract), creating it when
    /// absent. Same plugin gate as the read.
    func replaceNotificationRegistration(_ contents: Data) async throws

    /// Whether the underlying connection to the Host is still alive. The
    /// reconnect machinery (#18) decides "re-subscribe on this connection or
    /// re-establish it" from this flag.
    var isConnected: Bool { get async }

    /// Tears the connection down explicitly, ending every channel it
    /// carries. Terminal: a closed Transport is not reusable.
    func close() async throws
}

extension Transport {
    /// Test doubles and alternative transports that do not expose Host-level
    /// session discovery can opt out without inventing sessions.
    func listSessions() async throws -> [HerdrSession] { [] }

    /// Non-SSH test doubles and alternative transports can state that SFTP is
    /// unavailable without importing or emulating Citadel.
    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws -> StagedImage {
        throw ImageStagingError.sftpUnavailable
    }

    /// Test doubles and alternative transports without a Host-side plugin
    /// can report its absence without emulating the plugin CLI.
    func readNotificationRegistration() async throws -> Data? {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        throw NotificationRegistrationError.pluginNotInstalled
    }
}

/// App-domain request for launching a fresh coding agent.
///
/// herdr protocol 17 split the old topology-changing `agent.start` into
/// `tab.create` followed by a pane-targeted `agent.start`. Keeping that wire
/// choreography behind `Transport` prevents UI code from depending on the
/// server's transport-level request shapes.
struct AgentLaunchRequest: Sendable, Equatable {
    let kind: String
    let name: String
    let arguments: [String]
    let workspaceID: String?

    init(kind: String, name: String, arguments: [String] = [], workspaceID: String? = nil) {
        self.kind = kind
        self.name = name
        self.arguments = arguments
        self.workspaceID = workspaceID
    }
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

/// One entry from `herdr session list --json` on a Host.
struct HerdrSession: Sendable, Equatable, Decodable {
    let name: String
    let isDefault: Bool
    let isRunning: Bool

    init(name: String, isDefault: Bool, isRunning: Bool) {
        self.name = name
        self.isDefault = isDefault
        self.isRunning = isRunning
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "default"
        case isRunning = "running"
    }
}

/// The grammar enforced by herdr 0.7.4 for named sessions. Keeping it at the
/// transport boundary prevents malformed discovery output from becoming part
/// of a remote socket path; forms reuse it for immediate feedback.
enum HerdrSessionName {
    static let maximumUTF8Length = 64

    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard name.utf8.count <= maximumUTF8Length else { return false }
        return name.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }
}

/// Paths passed through the Host's login shell use the conservative quoting
/// subset shared by POSIX shells and fish. Spaces are safe inside single
/// quotes; quote, backslash, and control characters are refused because their
/// single-quote behavior differs across those shells.
enum RemoteShellPath {
    static func quotedAbsolute(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        guard path.unicodeScalars.allSatisfy(isQuotable) else { return nil }
        return "'\(path)'"
    }

    static func isQuotableAbsolute(_ path: String) -> Bool {
        quotedAbsolute(path) != nil
    }

    private static func isQuotable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F
            && scalar.value != 0x27 && scalar.value != 0x5C
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
    /// The agent program herdr detected: "claude", "codex", ... Behavior
    /// stays keyed off this; labels prefer `displayName`.
    let kind: String
    /// The server-reported agent name the herdr TUI shows (`display_agent`,
    /// falling back to `name`); nil when the server reports neither.
    let name: String?
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

    /// The card's primary label (#41): the server-reported name when present,
    /// otherwise the detected kind.
    var displayName: String { name ?? kind }

    init(
        terminalID: String, kind: String, title: String, status: AgentStatus,
        workspaceID: String, tabID: String, paneID: String, cwd: String, revision: Int,
        name: String? = nil
    ) {
        self.terminalID = terminalID
        self.kind = kind
        self.name = name
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
            revision: info.revision,
            name: Self.nonEmpty(info.displayAgent) ?? Self.nonEmpty(info.name)
        )
    }

    /// An empty wire string carries no name; treating it as missing keeps the
    /// fallback chain from rendering a blank card label.
    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
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
    /// The device's stored Ed25519 private key cannot be decoded. Reconnecting
    /// cannot repair it; the user must explicitly replace the Device Key.
    case deviceKeyCorrupt
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
    /// keeps exactly one interactive terminal surface at a time.
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

    /// Whether reconnecting without user intervention can plausibly recover.
    /// Configuration, trust, authentication, and protocol failures instead
    /// stop so the UI can explain the required action.
    var isRetryable: Bool {
        switch self {
        case .sshUnreachable, .serverNotRunning, .timedOut, .cancelled, .channelFailed:
            true
        case .authenticationFailed, .deviceKeyCorrupt, .hostKeyRejected, .hostKeyMismatch,
            .socketNotFound, .socatMissing, .protocolVersionMismatch,
            .homeDirectoryUnresolvable, .eventsChannelAlreadyOpen,
            .terminalChannelAlreadyOpen, .malformedResponse:
            false
        }
    }
}

/// An error returned by the herdr server inside a response envelope.
struct HerdrAPIError: Error, Sendable, Equatable {
    /// Normalized to a string; the wire schema promises `{"code","message"}`
    /// without pinning the code's JSON type.
    let code: String
    let message: String
}
