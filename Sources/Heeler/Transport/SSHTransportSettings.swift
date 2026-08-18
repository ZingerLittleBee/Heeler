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
        "/bin/sh -c 'printf \"__HEELER_PLUGIN_CONFIG_DIR__=%s\\n\" "
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
    /// at the environment boundary; per-Host override also covers hosts where
    /// herdr is not on PATH.
    var attachCommand: String = Self.defaultAttachCommand
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

/// Where `herdr` actually lives on Hosts that install it via Homebrew,
/// linuxbrew, cargo, or a user-local prefix.
///
/// SSH exec is not a login shell: sshd's default `PATH` is typically
/// `/usr/bin:/bin`, so a Host that can run `herdr` interactively still
/// answers `exec: herdr: not found` (exit 127) on Attach. The API socket
/// path does not need the binary — that is why the Console can list Agents
/// while the PTY Attach dies (#206).
enum HerdrHostPath: Sendable {
    static let outputPrefix = "__HEELER_HERDR_BIN__="

    /// Directories prepended to `PATH` on every herdr CLI exec. `$HOME`
    /// is expanded by the remote `/bin/sh`, not by Swift.
    static let extraPATH =
        "$HOME/.local/bin:$HOME/.linuxbrew/bin:$HOME/.cargo/bin:"
        + "/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin"

    static var pathExport: String {
        "export PATH=\"\(extraPATH):$PATH\""
    }

    /// Marker-delimited probe: `command -v` under the extra PATH, then the
    /// same locations as absolute files. Login-shell noise is ignored the
    /// same way as the home-directory probe.
    static var discoveryCommand: String {
        "/bin/sh -c '\(pathExport); "
            + "bin=$(command -v herdr 2>/dev/null) || true; "
            + "if [ -n \"$bin\" ] && [ -x \"$bin\" ]; then "
            + "printf \"\(outputPrefix)%s\\n\" \"$bin\"; exit 0; fi; "
            + "for p in \"$HOME/.local/bin/herdr\" \"$HOME/.linuxbrew/bin/herdr\" "
            + "\"$HOME/.cargo/bin/herdr\" /opt/homebrew/bin/herdr "
            + "/usr/local/bin/herdr /home/linuxbrew/.linuxbrew/bin/herdr; do "
            + "if [ -x \"$p\" ]; then printf \"\(outputPrefix)%s\\n\" \"$p\"; "
            + "exit 0; fi; done; exit 1'"
    }

    /// True when `command` still invokes an unpathed `herdr` word.
    static func containsBareHerdr(_ command: String) -> Bool {
        bareHerdrRange(in: command) != nil
    }

    /// Replaces each unpathed `herdr` command word with the absolute binary.
    /// The path is left unquoted so it can sit inside the existing
    /// single-quoted `/bin/sh -c` wrappers; whitespace is refused because
    /// that would split the exec word. Leaves `/opt/herdr-wake` alone.
    static func substituting(_ command: String, herdrPath: String) -> String? {
        guard RemoteShellPath.isQuotableAbsolute(herdrPath),
            !herdrPath.contains(where: \.isWhitespace)
        else { return nil }
        var result = command
        while let range = bareHerdrRange(in: result) {
            result.replaceSubrange(range, with: herdrPath)
        }
        return result
    }

    /// Wraps a quote-free command so the extra PATH is visible to a bare
    /// `herdr`. Used when discovery did not produce a path.
    static func prefixed(_ command: String) -> String {
        guard !command.contains("'") else { return command }
        return "/bin/sh -c '\(pathExport); \(command)'"
    }

    static func path(from output: Data) -> String? {
        String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .first { $0.hasPrefix(outputPrefix) }
            .map { line in
                var value = String(line.dropFirst(outputPrefix.count))
                if value.last == "\r" { value.removeLast() }
                return value
            }
            .flatMap { path in
                RemoteShellPath.isQuotableAbsolute(path)
                    && !path.contains(where: \.isWhitespace) ? path : nil
            }
    }

    private static func bareHerdrRange(in command: String) -> Range<String.Index>? {
        var search = command.startIndex
        while let found = command[search...].range(of: "herdr") {
            let start = found.lowerBound
            let end = found.upperBound
            let precededByPath = start > command.startIndex
                && isCommandWordChar(command[command.index(before: start)])
            let followedByWord = end < command.endIndex && isCommandWordChar(command[end])
            if !precededByPath && !followedByWord {
                return found
            }
            search = end
        }
        return nil
    }

    private static func isCommandWordChar(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "_"
            || character == "-" || character == "/"
    }
}
