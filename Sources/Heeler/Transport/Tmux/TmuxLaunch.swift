import Foundation

/// The tmux commands a user asks for on a tmux Host (ADR 0042, ADR 0043).
/// Pure: it builds one `/bin/sh` script and reads the ids tmux prints back.
///
/// A window opens detached in the session the user chose, so that session's
/// current window stays put. A new session on a running server takes the
/// server's environment (`-E`). With no server, only Linux New Workspace
/// starts one, through the user's login shell and without `-N`; macOS says to
/// start tmux on the Mac, and anything else starts nothing. An Agent is the
/// same program herdr-core runs: the user's shell replaces itself with it,
/// with ADR 0034's session flags, and a Claude Code under a configuration root
/// without Heeler's hooks gets them for that launch alone through `--settings`
/// (ADR 0044).
enum TmuxLaunch {
    struct Server: Equatable, Sendable {
        var paths: TmuxPaths
        var shell: String
        /// `uname -s` from the last probe. Nil has not been read.
        var kernel: String?
        var running: Bool
        var openCodeVersion: String?
    }

    struct Command: Equatable, Sendable {
        var script: Data
        /// The Linux start, whose script is the login shell's to run.
        var throughLoginShell: Bool
    }

    enum Refusal: Error, Equatable {
        /// macOS, and no server: New Workspace does not start one.
        case startTmuxOnMac
        /// No server, and this command is not the Linux start.
        case serverNotRunning
        /// A window with no session, or a launch with no directory.
        case missingTarget
    }

    /// What `new-window -P` or `new-session -P` printed.
    struct Created: Equatable, Sendable {
        var paneID: String
        var windowID: String
        var sessionID: String?
        var sessionName: String?
    }

    static let paneFormat = "#{pane_id} #{window_id}"
    static let sessionFormat = "#{pane_id} #{window_id} #{session_id} #{session_name}"

    /// `hookSettings` is the settings file a Claude Code launch passes. Any
    /// other program ignores it.
    static func agentWindow(
        _ request: AgentLaunchRequest, on server: Server, hookSettings: String? = nil
    ) throws -> Command {
        let session = try required(request.workspaceID)
        let directory = try required(request.cwd)
        let launch = try disposition(of: server, createsSession: false)
        let agent = program(of: request, on: server, hookSettings: hookSettings)
        return command(
            windowWords(session: session, directory: directory, environment: agent.environment, program: agent.argv),
            paths: server.paths, loginShell: launch.loginShell)
    }

    static func shellWindow(_ request: ShellTerminalCreationRequest, on server: Server) throws -> Command {
        let launch = try disposition(of: server, createsSession: false)
        return command(
            windowWords(
                session: try required(request.workspaceID), directory: try required(request.cwd),
                environment: [:], program: []),
            paths: server.paths, loginShell: launch.loginShell)
    }

    static func agentSession(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec, on server: Server, hookSettings: String? = nil
    ) throws -> Command {
        let launch = try disposition(of: server, createsSession: true)
        let agent = program(of: request, on: server, hookSettings: hookSettings)
        return command(
            sessionWords(
                name: workspace.label, directory: try required(workspace.directory),
                environment: agent.environment, program: agent.argv, inheritServerEnvironment: launch.inherit),
            paths: server.paths, loginShell: launch.loginShell)
    }

    static func shellSession(_ workspace: NewWorkspaceSpec, on server: Server) throws -> Command {
        let launch = try disposition(of: server, createsSession: true)
        return command(
            sessionWords(
                name: workspace.label, directory: try required(workspace.directory),
                environment: [:], program: [], inheritServerEnvironment: launch.inherit),
            paths: server.paths, loginShell: launch.loginShell)
    }

    static func renameSession(id: String, label: String, paths: TmuxPaths) -> Command {
        // The label is positional. `--` keeps a name like `-x` from being a flag.
        command(["rename-session", "-t", id, "--", label], paths: paths, loginShell: false)
    }

    static func killPane(_ id: String, paths: TmuxPaths) -> Command {
        command(["kill-pane", "-t", id], paths: paths, loginShell: false)
    }

    static func killWindow(_ id: String, paths: TmuxPaths) -> Command {
        command(["kill-window", "-t", id], paths: paths, loginShell: false)
    }

    /// The server's global environment, which a new session inherits.
    /// `show-environment -g` prints `NAME=value`; the caller keeps names only.
    static func showEnvironment(paths: TmuxPaths) -> Command {
        command(["show-environment", "-g"], paths: paths, loginShell: false)
    }

    /// One session's environment delta, addressed by its id (`$n`), never its name.
    static func showEnvironment(session: String, paths: TmuxPaths) -> Command {
        command(["show-environment", "-t", session], paths: paths, loginShell: false)
    }

    /// The last non-empty line. A login shell's startup files may print before it.
    static func created(from stdout: Data) -> Created? {
        let lines = String(decoding: stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let text = lines.last, let paneEnd = text.firstIndex(of: " ") else { return nil }
        let pane = String(text[..<paneEnd])
        guard isID(pane, prefix: "%") else { return nil }
        let rest = text[text.index(after: paneEnd)...]
        let window: String
        let afterWindow: Substring
        if let space = rest.firstIndex(of: " ") {
            window = String(rest[..<space])
            afterWindow = rest[rest.index(after: space)...]
        } else {
            window = String(rest)
            afterWindow = ""
        }
        guard isID(window, prefix: "@") else { return nil }
        guard !afterWindow.isEmpty else {
            return Created(paneID: pane, windowID: window, sessionID: nil, sessionName: nil)
        }
        guard let space = afterWindow.firstIndex(of: " ") else { return nil }
        let session = String(afterWindow[..<space])
        let name = String(afterWindow[afterWindow.index(after: space)...])
        guard isID(session, prefix: "$"), !name.isEmpty else { return nil }
        return Created(paneID: pane, windowID: window, sessionID: session, sessionName: name)
    }

    // MARK: The words tmux is given

    private struct Launch {
        var loginShell: Bool
        var inherit: Bool
    }

    /// A running server keeps `-N`. A new session on one also keeps `-E`.
    /// Linux with no server is the login-shell start, and the only command
    /// without `-N`.
    private static func disposition(of server: Server, createsSession: Bool) throws -> Launch {
        if server.running { return Launch(loginShell: false, inherit: createsSession) }
        guard createsSession else { throw Refusal.serverNotRunning }
        switch server.kernel {
        case HerdrCoreLocator.linuxKernel: return Launch(loginShell: true, inherit: false)
        case HerdrCoreLocator.macOSKernel: throw Refusal.startTmuxOnMac
        default: throw Refusal.serverNotRunning
        }
    }

    private static func required(_ value: String?) throws -> String {
        try required(value ?? "")
    }

    private static func required(_ value: String) throws -> String {
        guard !value.isEmpty else { throw Refusal.missingTarget }
        return value
    }

    private static func program(
        of request: AgentLaunchRequest, on server: Server, hookSettings: String?
    ) -> (argv: [String], environment: [String: String]) {
        guard let kind = SupportedAgentKind(rawValue: request.kind) else {
            let argv = HerdrCoreShellLaunch.argv(shell: server.shell, program: [request.kind] + request.arguments)
            return (argv, request.environment)
        }
        var arguments = request.arguments
        if kind == .claude, let hookSettings { arguments = ["--settings", hookSettings] + arguments }
        let start = HerdrCoreLaunch.agentStart(
            kind: kind, arguments: arguments, environment: request.environment,
            openCodeVersion: server.openCodeVersion)
        return (HerdrCoreShellLaunch.argv(shell: server.shell, program: start.program), start.environment)
    }

    private static func windowWords(
        session: String, directory: String, environment: [String: String], program: [String]
    ) -> [String] {
        ["new-window", "-d", "-t", session, "-c", directory]
            + environmentFlags(environment)
            + ["-P", "-F", paneFormat]
            + (program.isEmpty ? [] : ["--"] + program)
    }

    private static func sessionWords(
        name: String?, directory: String, environment: [String: String], program: [String],
        inheritServerEnvironment: Bool
    ) -> [String] {
        var words = ["new-session", "-d"]
        if inheritServerEnvironment { words.append("-E") }
        if let name, !name.isEmpty { words += ["-s", name] }
        return words + ["-c", directory] + environmentFlags(environment) + ["-P", "-F", sessionFormat]
            + (program.isEmpty ? [] : ["--"] + program)
    }

    /// Blanked names and the launch's own, in one order a test can write down.
    /// The launch's value already won where the names match.
    private static func environmentFlags(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().flatMap { key in ["-e", "\(key)=\(environment[key] ?? "")"] }
    }

    private static func command(_ words: [String], paths: TmuxPaths, loginShell: Bool) -> Command {
        let flags = loginShell ? ["-S"] : ["-N", "-S"]
        // tmux would take a word's trailing `;` as the end of the command.
        let arguments = words.map { shellWord(TmuxArgument.oneShot($0)) }
        let line = (["exec", "\"$t\""] + flags + ["\"$s\""] + arguments).joined(separator: " ")
        let body = """
            t=\(HerdrCoreLocator.quoted(paths.executable))
            s=\(HerdrCoreLocator.quoted(paths.socket))
            \(line)
            """
        let script =
            loginShell
            ? """
            __heeler_tmux_start=\(HerdrCoreLocator.quoted(body))
            export __heeler_tmux_start
            "$SHELL" -lic 'exec /bin/sh -c "$__heeler_tmux_start"'

            """
            : body + "\n"
        return Command(script: Data(script.utf8), throughLoginShell: loginShell)
    }

    /// A word `/bin/sh` will not split or expand. `@` stays bare so a window id
    /// reads as itself, and `_` so a session id does; everything else with a
    /// shell meaning is single-quoted.
    private static func shellWord(_ value: String) -> String {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@_-")
        return value.unicodeScalars.allSatisfy(plain.contains) ? value : HerdrCoreLocator.quoted(value)
    }

    private static func isID(_ value: String, prefix: Character) -> Bool {
        guard let first = value.first, first == prefix else { return false }
        let rest = value.dropFirst()
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
}
