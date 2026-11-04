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
    static let defaultHomeCommand =
        "/bin/sh -c 'printf \"__HEELER_HOME__=%s\\n\" \"$HOME\"'"
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
    /// Changes reads have a separate, shorter budget. Calibrate this value
    /// against large repositories and weak networks without changing RPCs.
    static let defaultGitExecTimeout: Duration = .seconds(10)
    /// Chat's store queries (ADR 0025) have their own budget, so calibrating
    /// one feature leaves the other alone.
    static let defaultChatQueryTimeout: Duration = .seconds(10)
    /// A plugin install fetches the plugin branch and runs its `npm ci`, and
    /// herdr bounds neither, so a slow network still gets minutes.
    static let defaultPluginInstallTimeout: Duration = .seconds(180)

    static var defaultAgentDiscoveryCommand: String {
        let checks = SupportedAgentKind.allCases.map { kind in
            "command -v \(kind.executable) >/dev/null 2>&1"
                + " && printf \"\(agentAvailabilityMarker)%s\\n\" \"\(kind.rawValue)\""
        }
        return "/bin/sh -c '\(HerdrHostPath.pathExport); "
            + "\(checks.joined(separator: "; ")); exit 0'"
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

    /// The ways to reach the Host, in the user's order; never empty. With
    /// more than one, `HeelerSSHTransport.connect` races them and keeps the
    /// first that reaches the Host (ADR 0022).
    var routes: [SSHRoute]
    var username: String
    var credentials: SSHCredentials
    /// TOFU host key policy (#2): the trusted-fingerprint store plus the
    /// first-connect confirmation the UI implements.
    var hostKeyPolicy: HostKeyPolicy
    /// Where the Host's own key is trusted: by endpoint, or by the catalog
    /// Host every route reaches. Jump Hosts are always trusted by endpoint.
    var hostKeyTrust: HostKeyTrust = .endpoint
    /// Which herdr socket to reach on the Host.
    var socket: HerdrSocketLocation
    /// The launcher of the Host's herdr endpoint (Pairing Code v2, ADR 0023).
    /// When set, the session list, plugin list, and plugin config-dir
    /// commands are its builders, and the wake and attach execs run it in
    /// place of ``wakeCommand``, ``attachCommand``, and
    /// ``terminalAttachCommand``. nil runs the `herdr` on the SSH PATH.
    var herdrLauncher: HerdrLauncher? = nil
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
    /// Command used to print a marker-delimited remote home directory. Runs
    /// under POSIX sh because login shells do not share substitution syntax
    /// (#275: nushell never expands `$HOME` inside double quotes); the marker
    /// makes login-shell noise harmless. Injectable only at the environment
    /// boundary for real-SSH tests.
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
    /// Bounds the caller's wait for ordinary-session admission and script
    /// execution. A remote watchdog also derives its bound from this value;
    /// dispatched execs retain their lease until SSH observes their exit.
    /// Expiry reports `.gitTimedOut`, which does not trigger link recovery.
    var gitExecTimeout: Duration = Self.defaultGitExecTimeout
    /// Bounds Chat's wait for one store query (ADR 0025) the way
    /// ``gitExecTimeout`` bounds a Changes read. The query's remote watchdog
    /// stops two seconds earlier, so the Host normally ends a slow query
    /// first. Expiry reports `.hostFileTimedOut`, which never redials.
    var chatQueryTimeout: Duration = Self.defaultChatQueryTimeout
    /// Bounds one `herdr plugin install` or `uninstall` exec run for the
    /// user. Expiry reports `.timedOut`; the Host may still finish the step.
    var pluginInstallTimeout: Duration = Self.defaultPluginInstallTimeout

    init(
        routes: [SSHRoute],
        username: String,
        credentials: SSHCredentials,
        hostKeyPolicy: HostKeyPolicy,
        hostKeyTrust: HostKeyTrust = .endpoint,
        socket: HerdrSocketLocation
    ) {
        precondition(!routes.isEmpty, "SSH settings need at least one route")
        self.routes = routes
        self.username = username
        self.credentials = credentials
        self.hostKeyPolicy = hostKeyPolicy
        self.hostKeyTrust = hostKeyTrust
        self.socket = socket
    }

    /// Settings for a single route.
    init(
        host: String,
        port: Int,
        username: String,
        credentials: SSHCredentials,
        hostKeyPolicy: HostKeyPolicy,
        socket: HerdrSocketLocation,
        jump: SSHJumpSettings? = nil,
        overlay: OverlayRoute? = nil
    ) {
        self.init(
            routes: [SSHRoute(host: host, port: port, jump: jump, overlay: overlay)],
            username: username,
            credentials: credentials,
            hostKeyPolicy: hostKeyPolicy,
            socket: socket)
    }

    /// The first route's Host address.
    var host: String { routes.first?.host ?? "" }

    /// The first route's Host port.
    var port: Int { routes.first?.port ?? 22 }
}

/// One way to reach the Host (ADR 0022): its address and port, optionally
/// resolved from a Jump Host, with the first hop optionally carried by an
/// Overlay Network.
struct SSHRoute: Sendable {
    var host: String
    var port: Int
    /// Optional Jump Host. When set, the Transport authenticates against the
    /// jump host first and opens the Host connection through it, so the Host
    /// needs no inbound reachability of its own. nil is a direct connection.
    var jump: SSHJumpSettings? = nil
    /// Optional Overlay Network carrying the first hop — the Host itself, or
    /// the Jump Host when one is set (ADR 0021). nil dials over this device's
    /// own network. The Jump Host's onward hop to the Host never uses it.
    var overlay: OverlayRoute? = nil
    /// The catalog route this is (`HostRoute.id`), reported back as the
    /// route a connection reached; nil outside the catalog.
    var id: UUID? = nil

    /// Whether the device dials the Host itself over its own network. Such
    /// routes start a race at once; the others wait a moment, so a reachable
    /// LAN address wins without starting an overlay node or a Jump Host.
    var isDirect: Bool {
        jump == nil && overlay == nil
    }

    /// Whether the address may name another machine once the device is on
    /// another network: a direct route to a loopback, private, link-local or
    /// unique-local address, or to a name only a local network resolves. A
    /// changed host key there can be that other machine, not an attack
    /// (ADR 0022). Overlay, CGNAT, public addresses and DNS names name the
    /// same machine wherever the device is.
    var mayNameAnotherMachine: Bool {
        isDirect && Self.isLocallyScoped(host)
    }

    private static let localNameSuffixes = [
        ".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain",
    ]

    static func isLocallyScoped(_ address: String) -> Bool {
        var host = address.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let first = value >> 24
            let second = (value >> 16) & 0xff
            return first == 10 || first == 127
                || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168)
                || (first == 169 && second == 254)
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isUniqueLocal = bytes[0] & 0xfe == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            return isLoopback || isUniqueLocal || isLinkLocal
        }
        // A single label resolves through the local search domain or mDNS.
        guard host.contains(".") else { return true }
        return localNameSuffixes.contains { host.hasSuffix($0) }
    }

    /// How a failure names this route: `10.0.0.5`, `100.64.0.5 over
    /// Tailscale`, `127.0.0.1:2222 via vps.example`, `127.0.0.1:2222 via
    /// vps.example:2022`.
    var label: String {
        var label = port == 22 ? host : "\(host):\(port)"
        if let jump {
            label += " via \(jump.port == 22 ? jump.host : "\(jump.host):\(jump.port)")"
        }
        if let overlay {
            label += " over \(overlay.networkName)"
        }
        return label
    }
}

/// The Jump Host in front of a Host: its own coordinates and credentials. Its
/// host key is verified under the same TOFU policy as the Host's, keyed by
/// its own endpoint, so both hops must be confirmed before either is trusted.
///
/// The Host's `address`/`port` are resolved from the Jump Host, which is
/// normally a loopback port held open by a reverse tunnel. A catalog Host's
/// key is trusted by Host rather than by that endpoint (ADR 0022), so two
/// Hosts behind different Jump Hosts may share a tunnel port such as
/// `127.0.0.1:12222`.
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
