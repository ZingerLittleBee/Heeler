import Foundation

/// What a launch on a herdr-core Host asks of `terminal.run` (ADR 0032, ADR 0034).
/// Pure: it builds the request and reads discovery's answer. `keep` is on, as the
/// desktop app adopts a Terminal, and no PATH is ever added: the user's shell
/// supplies it.
enum HerdrCoreLaunch {
    /// Where a launch lands: its directory, and the desktop app's labels when it
    /// belongs in one of its spaces.
    struct Placement: Equatable, Sendable {
        let cwd: String
        var labels: [String: String] = [:]

        /// A Tab the desktop app's document does not list yet, which the app
        /// adopts. Its ids read the same way.
        static func desktopSpace(_ space: String, cwd: String) -> Placement {
            Placement(cwd: cwd, labels: ["herdr.space": space, "herdr.tab": newDesktopTab()])
        }

        /// A space no document lists yet, which the app adopts under this id.
        static func newDesktopSpaceID() -> String {
            "sp" + newID()
        }

        private static func newDesktopTab() -> String {
            "tb" + newID()
        }

        private static func newID() -> String {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    }

    /// One discovery's answer: `kinds` in the picker's order.
    struct InstalledAgents: Equatable, Sendable {
        let kinds: [SupportedAgentKind]
        /// OpenCode's own words for its version; nil when it gave none.
        let openCodeVersion: String?
    }

    /// The label holding the session id Heeler generated. The hint is apart from
    /// the extensions' `heeler.session`, whose value says which process wrote it:
    /// the core has no pid for a program it has not started yet.
    static let sessionHintLabel = "heeler.launch-session"

    // MARK: Requests

    /// A New Terminal: with no argv the core runs its own shell.
    static func terminalRequest(placement: Placement) -> JSONValue {
        request(argv: nil, name: nil, environment: [:], placement: placement)
    }

    static func agentRequest(
        kind: SupportedAgentKind, name: String?, arguments: [String], shell: String,
        openCodeVersion: String?, placement: Placement
    ) -> JSONValue {
        let session = sessionStart(kind: kind, arguments: arguments, openCodeVersion: openCodeVersion)
        var labeled = placement
        if let hint = session.hint { labeled.labels[sessionHintLabel] = hint }
        return request(
            argv: HerdrCoreShellLaunch.argv(
                shell: shell, program: [kind.executable] + session.flags + arguments),
            name: name, environment: blankedVariables(kind), placement: labeled)
    }

    /// A Template by its name, as the core runs it: no shell, session flags or
    /// hint label (ADR 0032, ADR 0034).
    static func templateRequest(
        template: String, name: String?, placement: Placement
    ) -> JSONValue {
        request(argv: [template], name: name, environment: [:], placement: placement)
    }

    private static func request(
        argv: [String]?, name: String?, environment: [String: String], placement: Placement
    ) -> JSONValue {
        var fields: [String: JSONValue] = ["cwd": .string(placement.cwd), "keep": .bool(true)]
        if let argv { fields["argv"] = .array(argv.map(JSONValue.string)) }
        if let name { fields["name"] = .string(name) }
        if !environment.isEmpty { fields["env"] = .object(environment.mapValues(JSONValue.string)) }
        if !placement.labels.isEmpty {
            fields["labels"] = .object(placement.labels.mapValues(JSONValue.string))
        }
        return .object(fields)
    }

    /// A launch request can only set a variable empty, never unset it, so only
    /// those a test showed the program reads blank as unset are here (ADR 0034).
    private static func blankedVariables(_ kind: SupportedAgentKind) -> [String: String] {
        switch kind {
        case .claude: ["CLAUDE_CODE_CHILD_SESSION": "", "CLAUDE_CODE_SKIP_PROMPT_HISTORY": ""]
        case .grok: ["TMUX": "", "STY": "", "ZELLIJ": ""]
        default: [:]
        }
    }

    // MARK: The session from the start

    private struct SessionStart {
        var flags: [String] = []
        var hint: String?
    }

    /// Arguments that already pick a conversation or the mode. A second flag
    /// beside one makes these programs refuse to start.
    private static func flagsPickingASession(_ kind: SupportedAgentKind) -> Set<String> {
        switch kind {
        case .claude: ["--session-id", "--resume", "-r", "--continue", "-c", "--from-pr"]
        case .pi: ["--session-id", "--session", "--continue", "-c", "--resume", "-r", "--fork", "--no-session"]
        case .grok: ["--session-id", "-s", "--resume", "-r", "--continue", "-c"]
        case .opencode: ["--session", "-s", "--continue", "-c", "--fork"]
        case .codex: ["--no-daemon"]
        default: []
        }
    }

    private static func picksASession(_ arguments: [String], kind: SupportedAgentKind) -> Bool {
        let flags = flagsPickingASession(kind)
        return arguments.prefix { $0 != "--" }.contains { argument in
            flags.contains(argument)
                || argument.split(separator: "=", maxSplits: 1).first.map { flags.contains(String($0)) } == true
        }
    }

    private static func sessionStart(
        kind: SupportedAgentKind, arguments: [String], openCodeVersion: String?
    ) -> SessionStart {
        guard !picksASession(arguments, kind: kind) else { return SessionStart() }
        switch kind {
        case .claude, .pi:
            let id = newSessionUUID()
            return SessionStart(flags: ["--session-id", id], hint: id)
        case .grok:
            let id = newSessionUUID()
            return SessionStart(flags: ["-s", id], hint: id)
        case .opencode:
            guard openCodeNamesNewSessions(version: openCodeVersion) else { return SessionStart() }
            let id = newOpenCodeSessionID()
            return SessionStart(flags: ["-s", id], hint: id)
        case .codex:
            return SessionStart(flags: ["--no-daemon"])
        default:
            return SessionStart()
        }
    }

    private static func newSessionUUID() -> String {
        UUID().uuidString.lowercased()
    }

    /// `-s` names a new session from 2.1, the oldest release observed doing so;
    /// on 1.x it only continues one that exists. Anything unreadable is the safe
    /// side, which starts without it.
    static func openCodeNamesNewSessions(version: String?) -> Bool {
        guard let (major, minor) = openCodeRelease(version: version) else { return false }
        return major > 2 || (major == 2 && minor >= 1)
    }

    /// From OpenCode's own words, `opencode v2.0.32` or `1.19.5`.
    static func openCodeRelease(version: String?) -> (major: Int, minor: Int)? {
        guard let version else { return nil }
        for word in version.split(whereSeparator: \.isWhitespace) {
            let number = word.drop { $0 == "v" || $0 == "V" }
            let parts = number.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, let major = Int(parts[0]),
                let minor = Int(parts[1].prefix(while: \.isNumber))
            else { continue }
            return (major, minor)
        }
        return nil
    }

    /// OpenCode's own form, `ses_` with an inverted time so newer sorts first.
    static func newOpenCodeSessionID(now: Date = Date()) -> String {
        let milliseconds = UInt64(max(0, now.timeIntervalSince1970) * 1000)
        let inverted = ~(milliseconds &* 0x1000 &+ 1) & 0xFFFF_FFFF_FFFF
        let time = String(format: "%012llx", inverted)
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let random = (0..<14).compactMap { _ in alphabet.randomElement() }
        return "ses_\(time)\(String(random))"
    }

    // MARK: Templates

    /// What `templates.list` answers, without the files the core says it cannot use.
    static func templates(result: JSONValue) -> [AgentTemplate] {
        guard case .array(let entries)? = result["templates"] else { return [] }
        return entries.compactMap { entry in
            guard entry["error"]?.stringValue == nil,
                let name = entry["name"]?.stringValue, !name.isEmpty
            else { return nil }
            return AgentTemplate(name: name, description: entry["description"]?.stringValue ?? "")
        }
    }

    // MARK: Discovery

    static func discoveryScript(shell: String, nonce: String) -> Data {
        HerdrCoreShellLaunch.discoveryScript(
            shell: shell, executables: SupportedAgentKind.allCases.map(\.executable),
            versionOf: SupportedAgentKind.opencode.executable, nonce: nonce)
    }

    static func installedAgents(stdout: Data, nonce: String) throws -> InstalledAgents {
        let found = try HerdrCoreShellLaunch.parseDiscovery(stdout: stdout, nonce: nonce)
        return InstalledAgents(
            kinds: SupportedAgentKind.allCases.filter { found.executables.contains($0.executable) },
            openCodeVersion: found.version)
    }
}
