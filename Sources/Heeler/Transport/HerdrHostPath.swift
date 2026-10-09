import Foundation

/// Where `herdr` actually lives on Hosts that install it via Homebrew,
/// linuxbrew, cargo, or a user-local prefix.
///
/// SSH exec is not a login shell: sshd's default `PATH` is typically
/// `/usr/bin:/bin`, so a Host that can run `herdr` interactively still
/// answers `exec: herdr: not found` (exit 127) on Attach. The API socket
/// path does not need the binary — that is why the Console can list Agents
/// while the PTY Attach dies (#206).
///
/// Extra prefixes are prepended before the session `PATH` so user-installed
/// or package-manager-updated binaries (such as `~/.local/bin/herdr`, Homebrew,
/// Cargo, or mise shims) take precedence over stale system binaries in
/// `/usr/bin` that would cause protocol mismatches against the running server.
/// There is no separate probe to discover the `herdr` path; the agent-availability
/// probe reuses this export in its shell body instead of adding another SSH round trip.
///
/// Two ways the prefixes get onto a command, pick by how `herdr` is spelled:
/// - ``wrappingBareHerdr(_:)`` at the exec site when the command *word* is
///   still an unpathed `herdr` (session list, plugin list, and those
///   overrides).
/// - Bake ``pathExport`` into an existing `/bin/sh -c` body when a bare
///   `herdr` or an agent probe lives inside that body. The default plugin
///   config-dir and agent-discovery commands use this form. Wrapping looks
///   only at the command word, so it cannot see an inner `herdr`.
///
/// A Host with a herdr endpoint uses neither for herdr: ``HerdrLauncher``
/// commands name the launcher by absolute path and carry no PATH.
enum HerdrHostPath: Sendable {
    /// Directories prepended to `PATH` on herdr CLI and Agent discovery
    /// execs. `$HOME` and the parameter expansions are evaluated by the
    /// remote `/bin/sh`, not by Swift.
    ///
    /// mise exposes its tools to non-interactive shells through its shims
    /// directory (#293); `mise activate` lives in interactive rc files the
    /// probe never reads. The expansion follows mise's own resolution order,
    /// `MISE_DATA_DIR`, then `XDG_DATA_HOME/mise`, then
    /// `~/.local/share/mise`, but only sees a value that reaches the
    /// non-interactive environment. One set solely in `.zshrc` or `.bashrc`
    /// still resolves to the default.
    static let extraPATH =
        "$HOME/.local/bin:\(miseShims):$HOME/.linuxbrew/bin:$HOME/.cargo/bin:$HOME/.bun/bin:"
        + "/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin"

    /// POSIX sh expansion of mise's shims directory.
    static let miseShims = "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"

    static var pathAssignment: String {
        "PATH=\"\(extraPATH):$PATH\""
    }

    static var pathExport: String {
        "export \(pathAssignment)"
    }

    /// True when `command` invokes an unpathed `herdr` as its command word.
    /// Leading `NAME=value` assignments are skipped, so `HERDR_X=1 herdr …`
    /// still counts. Quoted literals (`'herdr: not json'`), `ENV=herdr` in
    /// front of another command, and absolute injectables (`/opt/herdr-wake`,
    /// `/nonexistent/herdr`) stay false.
    static func isBareHerdrCommand(_ command: String) -> Bool {
        commandWord(in: command) == "herdr"
    }

    /// Wraps a still-bare `herdr …` in `/bin/sh` so the extra prefixes are
    /// visible even when the account shell is fish (`$PATH` is a list there).
    /// The wrap therefore runs under POSIX sh, not the login shell: a `herdr`
    /// that exists only as a shell function or alias is not visible.
    /// Injectable commands whose command word is not `herdr` are unchanged.
    /// Embedded single quotes are escaped with `'\''` so a per-Host override
    /// such as `herdr --config '/x/y' session list` still gets the PATH fix.
    static func wrappingBareHerdr(_ command: String) -> String {
        guard isBareHerdrCommand(command) else { return command }
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "/bin/sh -c '\(pathExport); exec \(escaped)'"
    }

    /// Exit 127 from a still-bare `herdr` is the PATH miss (#206). Any other
    /// status, or an injectable command, is left for the caller.
    ///
    /// With an endpoint `launcher` the command runs that launcher instead, so
    /// exit 126 or 127 means it is missing, not executable, or could not start
    /// herdr, whatever the command word.
    static func missingBinaryError(
        exitStatus: Int32, command: String, launcher: HerdrLauncher? = nil
    ) -> TransportError? {
        if let launcher {
            guard exitStatus == 126 || exitStatus == 127 else { return nil }
            return .herdrLauncherNotFound(path: launcher.executablePath)
        }
        guard exitStatus == 127, isBareHerdrCommand(command) else { return nil }
        return .herdrBinaryNotFound
    }

    private static func commandWord(in command: String) -> Substring? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: \.isWhitespace)
            .first { !isEnvironmentAssignment($0) }
    }

    /// POSIX `NAME=value` words a shell would consume before the command.
    private static func isEnvironmentAssignment(_ word: Substring) -> Bool {
        guard let separator = word.firstIndex(of: "="), separator > word.startIndex else {
            return false
        }
        let name = word[..<separator]
        guard let first = name.first, first.isASCII else { return false }
        guard first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "_")
        }
    }
}

/// The launcher of a Host's herdr endpoint (Pairing Code v2, ADR 0021): an
/// executable that behaves as `herdr` for the endpoint's socket. Every herdr
/// exec runs it as a positional argument of a POSIX `/bin/sh -c` body with
/// `HERDR_SOCKET_PATH` exported, so neither path is spliced into shell
/// syntax. There is no PATH export and no fallback to the `herdr` on PATH.
struct HerdrLauncher: Sendable, Equatable {
    /// The launcher's absolute path.
    let executablePath: String
    /// The endpoint's socket, exported to every launcher exec.
    let socketPath: String
    private let quotedExecutablePath: String
    private let quotedSocketPath: String

    /// nil unless both paths are absolute and quotable as one remote shell
    /// word (`RemoteShellPath`).
    init?(executablePath: String, socketPath: String) {
        guard let quotedExecutablePath = RemoteShellPath.quotedAbsolute(executablePath),
            let quotedSocketPath = RemoteShellPath.quotedAbsolute(socketPath)
        else { return nil }
        self.executablePath = executablePath
        self.socketPath = socketPath
        self.quotedExecutablePath = quotedExecutablePath
        self.quotedSocketPath = quotedSocketPath
    }

    /// The endpoint's `herdr session list --json`.
    var sessionListCommand: String {
        herdrCommand(arguments: "session list --json")
    }

    /// The endpoint's `herdr plugin list --json`.
    var pluginListCommand: String {
        herdrCommand(arguments: "plugin list --json")
    }

    /// The endpoint's counterpart to
    /// `SSHTransportSettings.defaultNotificationConfigDirCommand`: the same
    /// marker and plugin id token, with the launcher in place of `herdr`.
    var notificationConfigDirCommand: String {
        "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
            + "printf \"__HEELER_PLUGIN_CONFIG_DIR__=%s\\n\" "
            + "\"$(\"$1\" plugin config-dir \(SSHTransportSettings.notificationPluginIDToken))\"' "
            + "herdr \(quotedExecutablePath) \(quotedSocketPath)"
    }

    /// Starts or reaches the endpoint's server through
    /// `remote-client-bridge`. `socket` is the already quoted socket the
    /// request is waiting on (`$1`); the launcher is `$2`. A named-session
    /// socket also exports its session (`$3`), as the regular named-session
    /// wake does, so the spawned server uses that session's state.
    func wakeCommand(quotedSocketPath socket: String) -> String {
        // A non-empty name passed HerdrSessionName.isValid: one shell word.
        let session = HerdrEndpoint.session(fromSocketPath: socketPath) ?? ""
        let sessionExport = session.isEmpty ? "" : "export HERDR_SESSION=\"$3\"; "
        let sessionArgument = session.isEmpty ? "" : " \(session)"
        return "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$1\"; \(sessionExport)"
            + "\"$2\" remote-client-bridge < /dev/null' wake "
            + "\(socket) \(quotedExecutablePath)\(sessionArgument)"
    }

    /// Attaches the already validated `target` (`$1`) with `subcommand`,
    /// such as `agent attach`, over the already quoted `socket` (`$2`) with
    /// the launcher (`$3`). The handshake marker goes out last before exec.
    func attachCommand(
        subcommand: String, target: String, takeover: Bool, quotedSocketPath socket: String
    ) -> String {
        let takeoverFlag = takeover ? " --takeover" : ""
        return "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; "
            + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
            + "exec \"$3\" \(subcommand) \"$1\"\(takeoverFlag)' attach "
            + "'\(target)' \(socket) \(quotedExecutablePath)"
    }

    private func herdrCommand(arguments: String) -> String {
        "/bin/sh -c 'export HERDR_SOCKET_PATH=\"$2\"; exec \"$1\" \(arguments)' "
            + "herdr \(quotedExecutablePath) \(quotedSocketPath)"
    }
}
