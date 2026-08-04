import Foundation

/// How to reach one Host, authenticate against it, and find its herdr socket.
struct SSHTransportSettings: Sendable {
    static let defaultSessionListCommand = "herdr session list --json"
    static let defaultStageDirectoryCommand =
        "/bin/sh -c 'umask 077; "
        + "directory=$(mktemp -d \"${TMPDIR:-/tmp}/heeler.XXXXXXXX\") || exit 1; "
        + "printf \"__HEELER_STAGE_DIR__=%s\\n\" \"$directory\"'"
    static let agentAvailabilityMarker = "__HEELER_AGENT_KIND__="

    /// The Heeler plugin (ADR 0007/0008) whose config dir holds the
    /// Notification Registration file.
    static let notificationPluginID = "heeler.pairing"

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
    /// the environment boundary; per-Host override also covers hosts where
    /// herdr is not on the login shell's PATH.
    var wakeCommand: String = "herdr remote-client-bridge"
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
    /// at the environment boundary; per-Host override also covers hosts where
    /// herdr is not on PATH.
    var attachCommand: String = "herdr agent attach"
    /// Command used to print a marker-delimited remote home directory. It is
    /// injectable only at the environment boundary for real-SSH tests.
    var homeCommand: String = "printf '__HEELER_HOME__=%s\\n' \"$HOME\""
    /// Creates one private directory beneath the Host operating system's
    /// selected temporary root. The marker makes login-shell noise harmless;
    /// callers never interpolate image names or paths into this command.
    var stageDirectoryCommand: String = Self.defaultStageDirectoryCommand
    /// Official Host-local CLI for listing installed plugins (offline, like
    /// session discovery). Notification Registration gates on the
    /// Heeler plugin being installed and enabled before touching its
    /// config dir — `herdr plugin config-dir` happily prints (and creates) a
    /// directory for any id, so it cannot carry the "is it installed" check.
    var pluginListCommand: String = "herdr plugin list --json"
    /// Prints the marker-delimited config dir of the Heeler plugin;
    /// herdr creates the directory if missing. Runs under POSIX sh because
    /// login shells do not share substitution syntax; the marker makes
    /// login-shell noise harmless.
    var notificationConfigDirCommand: String =
        "/bin/sh -c 'printf \"__HEELER_PLUGIN_CONFIG_DIR__=%s\\n\" "
        + "\"$(herdr plugin config-dir \(SSHTransportSettings.notificationPluginID))\"'"
    /// Per-request deadline covering the queue wait and the channel exchange;
    /// on expiry the request fails with `.timedOut` and its channel is
    /// closed. Short in tests, generous by default: a hung host should
    /// degrade gracefully, a slow one should still answer.
    var requestTimeout: Duration = .seconds(15)

    static var defaultAgentDiscoveryCommand: String {
        let checks = SupportedAgentKind.allCases.map { kind in
            "command -v \(kind.executable) >/dev/null 2>&1"
                + " && printf \"\(agentAvailabilityMarker)%s\\n\" \"\(kind.rawValue)\""
        }
        return "/bin/sh -c '\(checks.joined(separator: "; ")); exit 0'"
    }
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
