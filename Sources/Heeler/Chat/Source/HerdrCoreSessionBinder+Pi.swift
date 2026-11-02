import Foundation

/// Pi and Oh My Pi's evidence (ADR 0034). Neither keeps a record of its running
/// session, so what names it is a `heeler.*` label the Agent's own extension wrote,
/// the launch hint for a Pi Heeler started with `--session-id`, or, for Oh My Pi
/// with no extension, its terminal breadcrumb once the process holds that file open.
extension HerdrCoreSessionBinder {
    private static let breadcrumbLimit = 16 * 1024

    func checkPiFamily(
        _ record: HerdrCoreTerminalRecord, tree: HerdrCoreTerminalProcesses
    ) async throws -> ChatSessionEvidence {
        guard let pid = piFamilyAgent(in: tree), let process = tree.facts[pid],
            case .value(let start) = process.start
        else { return cannotTell }

        let hints = await readHints(in: record, tree: tree, pid: pid, start: start)
        let places = PiSessionLayout(program: program).places(in: process.variables)
        for hint in hints {
            guard let session = hint.piSession(onWindows: isOnWindows) else { continue }
            // A file reads with no root, which an id cannot: it would look under the
            // Host's default, and only the Agent's own environment says where (ADR 0034).
            if places != nil || session.hasPrefix("/") {
                return .bound(sessionID: session, transcriptRoot: places?.sessions, directory: nil)
            }
        }
        guard let places else { return cannotTell }
        func bound(_ session: String) -> ChatSessionEvidence {
            .bound(sessionID: session, transcriptRoot: places.sessions, directory: nil)
        }
        // On Windows only the extension's label counts: Heeler's launch runs under
        // PowerShell, and open files are not read there.
        guard !isOnWindows else { return cannotTell }
        if program == .pi, pid == record.pid.map(String.init), let id = record.piLaunchSession {
            return bound(id)
        }
        if program == .omp, let file = try await confirmedBreadcrumbFile(of: process, agentDirectory: places.agent) {
            return bound(file)
        }
        return cannotTell
    }

    var piFamilyProcessAsk: ProcessAsk {
        ProcessAsk(
            values: [Self.homeVariable] + PiSessionLayout(program: program).variables,
            readsOpenFiles: program == .omp)
    }

    /// Where this process keeps its sessions, from its own environment.
    func piFamilySessions(of process: HostProcessReader.Facts) -> String? {
        PiSessionLayout(program: program).places(in: process.variables)?.sessions
    }

    /// The nearest process to the foreground that calls itself the program, since
    /// both take their name as their title (herdr compatibility). Nil when two are
    /// equally near. Oh My Pi's own broker and worker sit further from the foreground
    /// than it, and a worker takes the same name.
    func piFamilyAgent(in tree: HerdrCoreTerminalProcesses) -> String? {
        if isOnWindows {
            return tree.agentOnWindows(isAgent: { $0?.name == program.rawValue }, runtimes: Self.windowsRuntimes)
        }
        guard tree.sharesScope(tree.root) else { return nil }
        var children: [String: [String]] = [:]
        for pid in tree.descendants where tree.sharesScope(pid) {
            if let parent = tree.facts[pid]?.parent { children[parent, default: []].append(pid) }
        }
        var level = [tree.root]
        while !level.isEmpty {
            let named = level.filter { tree.facts[$0]?.name == program.rawValue }
            if named.count > 1 { return nil }
            if let found = named.first { return found }
            level = level.flatMap { children[$0] ?? [] }
        }
        return nil
    }

    /// The session file `<agent dir>/terminal-sessions/<tty>` names, when this
    /// process holds it open. A breadcrumb alone says nothing: it names a file before
    /// the file exists, and it outlives its process on a reused terminal name. The
    /// process's session lock would answer sooner, but no read-only check of it
    /// exists, since the hash in its name is unknown. So this binds only once the
    /// first message opens the file.
    private func confirmedBreadcrumbFile(
        of process: HostProcessReader.Facts, agentDirectory: String
    ) async throws -> String? {
        guard case .value(let openFiles) = process.openFiles, let terminal = terminalName(in: openFiles)
        else { return nil }
        let path = RemoteFilePath.join(agentDirectory, "terminal-sessions", terminal)
        let slice = try await files.read(RemoteFileRange(path: path, offset: 0, maxBytes: Self.breadcrumbLimit))
        guard slice.length != nil, slice.data.count < Self.breadcrumbLimit else { return nil }
        let lines = String(decoding: slice.data, as: UTF8.self).components(separatedBy: "\n")
        guard lines.count >= 2, !lines.dropFirst(2).contains("fresh") else { return nil }
        let file = lines[1]
        guard RemoteFilePath.isAcceptable(file), file.hasSuffix(".jsonl"), openFiles.contains(file) else { return nil }
        return file
    }

    /// The name Oh My Pi files a breadcrumb under: `/dev/pts/3` is `pts-3`, and on macOS
    /// `/dev/ttys006` is `ttys006`. Its stdin is the Terminal, but the read does not say
    /// which descriptor is which, so more than one terminal names none. On Linux a
    /// `/dev/ttyS0` is a serial port, so macOS's form counts only there.
    private func terminalName(in openFiles: [String]) -> String? {
        let terminals = Set(
            openFiles.filter { path in
                isOnMacOS
                    ? path.wholeMatch(of: /\/dev\/ttys[0-9]+/) != nil
                    : path.wholeMatch(of: /\/dev\/pts\/[0-9]+/) != nil
            })
        guard terminals.count == 1, let terminal = terminals.first else { return nil }
        return String(terminal.dropFirst("/dev/".count)).replacingOccurrences(of: "/", with: "-")
    }
}

extension HerdrCoreSessionHint {
    /// What an extension's label names: its file when the label gives one, which
    /// must be under the session's own name, else its id. A label whose file holds
    /// another session's name names nothing. On Windows the file reads as SFTP opens it.
    func piSession(onWindows: Bool) -> String? {
        guard let file = file.map({ onWindows ? RemoteFilePath.windowsForSFTP($0) : $0 }) else {
            return ConversationReference.canonicalUUID(session)
        }
        guard RemoteFilePath.isAcceptable(file), ConversationReference.file(file, isNamedFor: session) else {
            return nil
        }
        return file
    }
}

extension HerdrCoreTerminalRecord {
    /// The id Heeler started a Pi with: the launch label, while the Terminal's
    /// launch arguments still carry it after `--session-id`. `hc run` and a Template
    /// write no such label, and `restarted` replaces the arguments.
    fileprivate var piLaunchSession: String? {
        guard let hint = labels[HerdrCoreLaunch.sessionHintLabel],
            let id = ConversationReference.canonicalUUID(hint)
        else { return nil }
        let carries = zip(argv, argv.dropFirst()).contains { flag, value in
            flag == "--session-id" && value == hint
        }
        return carries ? id : nil
    }
}

/// Where Pi or Oh My Pi keeps its sessions, from the Agent's own environment and
/// never the core's, read by name. Each program's own rules, which come from its
/// source (herdr compatibility).
private struct PiSessionLayout {
    /// `agent` holds Oh My Pi's breadcrumbs, and `sessions` is where a session id is
    /// looked for.
    struct Places {
        let agent: String
        let sessions: String
    }

    let program: ChatProgram

    private static let home = "HOME"
    private static let agentDir = "PI_CODING_AGENT_DIR"
    private static let sessionDir = "PI_CODING_AGENT_SESSION_DIR"
    private static let configDir = "PI_CONFIG_DIR"
    private static let profile = "OMP_PROFILE"
    private static let legacyProfile = "PI_PROFILE"

    var variables: [String] {
        program == .pi
            ? [Self.agentDir, Self.sessionDir]
            : [Self.agentDir, Self.configDir, Self.profile, Self.legacyProfile]
    }

    func places(in variables: [String: HostProcessReader.Variable]) -> Places? {
        for name in self.variables where variables[name] == nil || variables[name] == .unavailable {
            return nil
        }
        guard case .value(let home)? = variables[Self.home], RemoteFilePath.isAcceptable(home) else { return nil }
        let reader = VariableReader(values: variables, home: home)
        return program == .pi ? pi(reader) : omp(reader)
    }

    /// `PI_CODING_AGENT_SESSION_DIR` holds files directly, unlike the folders per
    /// project under `sessions`. Pi expands a leading `~` in both variables.
    private func pi(_ reader: VariableReader) -> Places? {
        let agent: String
        if let value = reader.nonEmpty(Self.agentDir) {
            guard let directory = reader.directory(value, expandingTilde: true) else { return nil }
            agent = directory
        } else {
            agent = RemoteFilePath.join(reader.home, ".pi", "agent")
        }
        if let value = reader.nonEmpty(Self.sessionDir) {
            guard let sessions = reader.directory(value, expandingTilde: true) else { return nil }
            return Places(agent: agent, sessions: sessions)
        }
        return Places(agent: agent, sessions: RemoteFilePath.join(agent, "sessions"))
    }

    /// `OMP_PROFILE` when set at all, even blank, else `PI_PROFILE`, and a named
    /// profile ignores `PI_CODING_AGENT_DIR`. After `omp config init-xdg` its files
    /// move under the XDG folders, which the environment alone cannot show. There
    /// the breadcrumb reads as missing, which binds nothing.
    private func omp(_ reader: VariableReader) -> Places? {
        let configName = reader.nonEmpty(Self.configDir) ?? ".omp"
        let config = RemoteFilePath.join(reader.home, configName)
        guard RemoteFilePath.isAcceptable(config) else { return nil }
        let agent: String
        let profile = reader.value(Self.profile) ?? reader.value(Self.legacyProfile)
        switch profile?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case let name? where !name.isEmpty && name != "default":
            guard Self.isProfileName(name) else { return nil }
            agent = RemoteFilePath.join(config, "profiles", name, "agent")
        default:
            if let value = reader.nonEmpty(Self.agentDir) {
                guard let directory = reader.directory(value, expandingTilde: false) else { return nil }
                agent = directory
            } else {
                agent = RemoteFilePath.join(config, "agent")
            }
        }
        return Places(agent: agent, sessions: RemoteFilePath.join(agent, "sessions"))
    }

    private static func isProfileName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9._-]{0,63}/) != nil && !name.hasSuffix(".")
    }

    private struct VariableReader {
        let values: [String: HostProcessReader.Variable]
        let home: String

        func value(_ name: String) -> String? {
            if case .value(let value)? = values[name] { value } else { nil }
        }

        func nonEmpty(_ name: String) -> String? {
            value(name).flatMap { $0.isEmpty ? nil : $0 }
        }

        func directory(_ value: String, expandingTilde: Bool) -> String? {
            var path = value
            if expandingTilde {
                if path == "~" { path = home }
                if path.hasPrefix("~/") { path = RemoteFilePath.join(home, String(path.dropFirst(2))) }
            }
            guard RemoteFilePath.isAcceptable(path) else { return nil }
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
    }
}
