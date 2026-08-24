import Foundation

/// How to reach one Host, authenticate against it, and find its herdr socket.
struct SSHTransportSettings: Sendable {
    static let defaultSessionListCommand = "herdr session list --json"
    static let defaultStageDirectoryCommand =
        "/bin/sh -c 'umask 077; "
        + "directory=$(mktemp -d \"${TMPDIR:-/tmp}/heeler.XXXXXXXX\") || exit 1; "
        + "printf \"__HEELER_STAGE_DIR__=%s\\n\" \"$directory\"'"
    static let defaultWakeCommand = "herdr remote-client-bridge"
    static let defaultAttachCommand = "herdr agent attach"
    static let defaultTerminalAttachCommand = "herdr terminal attach"
    static let defaultHomeCommand = "printf '__HEELER_HOME__=%s\\n' \"$HOME\""
    static let defaultPluginListCommand = "herdr plugin list --json"
    static let agentAvailabilityMarker = "__HEELER_AGENT_KIND__="

    /// The Heeler plugin (ADR 0007/0008) whose config dir holds the
    /// Notification Registration file.
    static let notificationPluginID = "heeler"
    /// Ids the plugin shipped under before, newest first. A Host still running
    /// one keeps accepting Notification Registration: the matched id decides
    /// which config dir the registration file lands in, so it is the directory
    /// that Host's plugin actually reads. Only these fixed literals are ever
    /// substituted into the probe command; ids reported by the Host are not.
    /// (`heeler.pairing` existed only inside one unreleased cycle — no Host
    /// ever installed it, so it is deliberately absent.)
    static let legacyNotificationPluginIDs = ["herdr-mobile.pairing"]
    /// Replaced with the matched plugin id before the config-dir probe runs.
    /// A command injected without the token is used verbatim.
    static let notificationPluginIDToken = "__HEELER_PLUGIN_ID__"

    static let defaultNotificationConfigDirCommand =
        "/bin/sh -c '\(HerdrHostPath.pathExport); "
        + "printf \"__HEELER_PLUGIN_CONFIG_DIR__=%s\\n\" "
        + "\"$(herdr plugin config-dir \(notificationPluginIDToken))\"'"

    /// The default of ``requestTimeout``, named so budgets derived from it
    /// cannot drift out of step with it.
    static let defaultRequestTimeout: Duration = .seconds(15)

    static var defaultAgentDiscoveryCommand: String {
        let checks = SupportedAgentKind.allCases.map { kind in
            "command -v \(kind.executable) >/dev/null 2>&1"
                + " && printf \"\(agentAvailabilityMarker)%s\\n\" \"\(kind.rawValue)\""
        }
        return "/bin/sh -c '\(checks.joined(separator: "; ")); exit 0'"
    }

    /// Kinds reported by a Host `command -v` probe. Only marker-prefixed lines
    /// count, unknown labels are dropped, and the result is `allCases` order
    /// so the Start Agent picker stays stable across duplicate or noisy stdout.
    static func discoveredAgentKinds(from output: String) -> [SupportedAgentKind] {
        let discovered = Set(
            output.split(whereSeparator: \.isNewline)
                .compactMap { line -> SupportedAgentKind? in
                    guard line.hasPrefix(agentAvailabilityMarker) else {
                        return nil
                    }
                    return SupportedAgentKind(
                        rawValue: String(line.dropFirst(agentAvailabilityMarker.count)))
                })
        return SupportedAgentKind.allCases.filter(discovered.contains)
    }

    var host: String
    var port: Int
    var username: String
    var credentials: SSHCredentials
    /// TOFU host key policy (#2): the trusted-fingerprint store plus the
    /// first-connect confirmation the UI implements.
    var hostKeyPolicy: HostKeyPolicy
    /// Which herdr socket to reach on the Host.
    var socket: HerdrSocketLocation
    /// Optional Jump Host. When set, the Transport authenticates against the
    /// jump host first and opens the Host connection through it, so the Host
    /// needs no inbound reachability of its own. nil is a direct connection.
    var jump: SSHJumpSettings? = nil
    /// Command that wakes a stopped herdr server, run over a no-PTY exec
    /// channel when a request hits connection-refused (#6). The default is
    /// the strategy from spec #16: `herdr remote-client-bridge` ensures the
    /// server is running (spawn + wait for socket) before bridging, then
    /// exits on stdin EOF. Injectable so tests can substitute a script at
    /// the environment boundary. The exec wrapper already appends the
    /// well-known install prefixes to PATH; a per-Host override is for a
    /// binary that lives somewhere else, or for a test fixture.
    var wakeCommand: String = Self.defaultWakeCommand
    /// Official Host-local CLI command for discovering default and named
    /// sessions. It does not depend on a running API socket.
    var sessionListCommand: String = Self.defaultSessionListCommand
    /// Host-local availability probe for the protocol's canonical interactive
    /// Agent executables. It emits marker-delimited canonical kinds so login
    /// shell noise cannot become a false positive. Injectable only at the
    /// environment boundary for real-SSH tests.
    var agentDiscoveryCommand: String = Self.defaultAgentDiscoveryCommand
    /// Command that attaches interactively to a Pane, sent as the exec request
    /// on the Host's dedicated PTY channel (#11); the attach target and
    /// takeover flag are appended. Injectable so tests can substitute a script
    /// at the environment boundary. The exec wrapper already appends the
    /// well-known install prefixes to PATH; a per-Host override is for a
    /// binary that lives somewhere else, or for a test fixture.
    var attachCommand: String = Self.defaultAttachCommand
    /// Ordinary shell counterpart to ``attachCommand``. It is separate so
    /// fixtures can exercise command selection without teaching UI code how
    /// herdr spells either attach command.
    var terminalAttachCommand: String = Self.defaultTerminalAttachCommand
    /// Command used to print a marker-delimited remote home directory. It is
    /// injectable only at the environment boundary for real-SSH tests.
    var homeCommand: String = Self.defaultHomeCommand
    /// Creates one private directory beneath the Host operating system's
    /// selected temporary root. The marker makes login-shell noise harmless;
    /// callers never interpolate image names or paths into this command.
    var stageDirectoryCommand: String = Self.defaultStageDirectoryCommand
    /// Official Host-local CLI for listing installed plugins (offline, like
    /// session discovery). Notification Registration gates on the
    /// Heeler plugin being installed and enabled before touching its
    /// config dir — `herdr plugin config-dir` happily prints (and creates) a
    /// directory for any id, so it cannot carry the "is it installed" check.
    var pluginListCommand: String = Self.defaultPluginListCommand
    /// Prints the marker-delimited config dir of the Heeler plugin;
    /// herdr creates the directory if missing. Runs under POSIX sh because
    /// login shells do not share substitution syntax; the marker makes
    /// login-shell noise harmless. Any ``notificationPluginIDToken`` in the
    /// command is replaced with the plugin id matched from the Host's plugin
    /// list before the probe runs.
    var notificationConfigDirCommand: String = Self.defaultNotificationConfigDirCommand
    /// Per-request deadline covering the queue wait and the channel exchange;
    /// on expiry the request fails with `.timedOut` and its channel is
    /// closed. Short in tests, generous by default: a hung host should
    /// degrade gracefully, a slow one should still answer.
    ///
    /// It also bounds each individual PTY write and window-change on a live
    /// attach channel (`HeelerSSHTransport.runAttachChannel`).
    var requestTimeout: Duration = Self.defaultRequestTimeout
}

/// The Jump Host in front of a Host: its own coordinates and credentials. Its
/// host key is verified under the same TOFU policy as the Host's, keyed by
/// its own endpoint, so both hops must be confirmed before either is trusted.
///
/// The Host's `address`/`port` are resolved from the Jump Host, which is
/// normally a loopback port held open by a reverse tunnel. Two Hosts behind
/// one Jump Host therefore need distinct tunnel ports: known-hosts entries are
/// keyed by endpoint, so a shared `127.0.0.1:12222` would collide.
struct SSHJumpSettings: Sendable {
    var host: String
    var port: Int
    var username: String
    var credentials: SSHCredentials

    init(host: String, port: Int = 22, username: String, credentials: SSHCredentials) {
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
    }
}
