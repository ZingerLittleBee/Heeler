import Foundation

/// What a check of a herdr-core Agent's process found (ADR 0034).
enum ChatSessionEvidence: Equatable, Sendable {
    /// `transcriptRoot` is the Agent's own config dir, which its Transcript and
    /// session folders are under. `directory` is where the program says it
    /// started the session, when it says. A program that keeps no Transcript
    /// file has no root.
    case bound(sessionID: String, transcriptRoot: String?, directory: String?)
    case unavailable(ChatUnavailableReason)
}

/// A `heeler.*` label naming a session (ADR 0034). It is a hint: anything may
/// write a label, and one outlives the process that wrote it, so it counts only
/// for the process it names, by pid and process start.
struct HerdrCoreSessionHint: Equatable, Sendable {
    /// The labels hold this JSON. `heeler.launch-session` is none of them: it
    /// holds the id alone, written before any process exists (ADR 0034).
    static let labels = ["heeler.session", "heeler.chat"]

    let session: String
    /// The session's file, in the label the Pi and Oh My Pi extension writes.
    let file: String?
    let pid: Int
    let start: String

    init?(label: String) {
        guard let fields = try? JSONDecoder().decode(Fields.self, from: Data(label.utf8)), let start = fields.start
        else { return nil }
        session = fields.session
        file = fields.file
        pid = fields.pid
        self.start = start
    }

    private struct Fields: Decodable {
        let session: String
        let file: String?
        let pid: Int
        let start: String?
    }
}

/// Binds a herdr-core Agent's Chat from what the Host shows about the Agent's own
/// process, never from a guess (ADR 0034). A check is one exec and at most one
/// SFTP read, past a Codex holding several rollouts, and the app makes it only
/// when something says the answer may have changed.
///
/// It starts from the Terminal's foreground process, and goes through descendants
/// that share the Terminal's `HC_SCOPE` to reach the process behind a launcher.
/// The scope is the Terminal's own process's: the core keeps it out of the
/// Terminal's record. Only the variables named here are read, on the Host, and
/// `HERDR_*` is never among them.
///
/// Claude Code's `<config dir>/sessions/<pid>.json` is read by name, so the
/// `<pid>.<hash>.key` beside it before the prompt is never read or listed.
struct HerdrCoreSessionBinder: Sendable {
    let program: ChatProgram
    /// Facts for each process the request reaches: one exec. An empty answer
    /// is an exec that failed on the Host, which tells nothing.
    var processes: @Sendable (HostProcessReader.Request) async throws -> [String: HostProcessReader.Facts]
    var files: ChatHostFiles
    /// Removes labels from the Terminal, each with the value that was found stale.
    var clearLabels: @Sendable ([String: String]) async throws -> Void
    /// The Terminal's labels as they stand now, nil when nothing newer than the
    /// record is known.
    var currentLabels: @Sendable () async -> [String: String]? = { nil }

    static let scopeVariable = HerdrCoreTerminalProcesses.scopeVariable
    static let homeVariable = "HOME"
    private static let configVariable = "CLAUDE_CONFIG_DIR"
    /// Past this no registry entry was ever this long, so it is not one.
    private static let entryLimit = 64 * 1024

    /// `coreCarries` is what the core's own environment holds, from the Host's
    /// leak check, so a reason can point at the Host notice.
    func check(_ record: HerdrCoreTerminalRecord, coreCarries: Set<String> = []) async throws -> ChatSessionEvidence {
        switch program {
        case .claude: try await checkClaudeCode(record, coreCarries: coreCarries)
        case .codex: try await checkCodex(record)
        case .grok: try await checkGrokBuild(record)
        case .opencode: try await checkOpenCode(record)
        case .pi, .omp: try await checkPiFamily(record)
        }
    }

    var cannotTell: ChatSessionEvidence { .unavailable(.cannotTellSession(program)) }

    private func checkClaudeCode(
        _ record: HerdrCoreTerminalRecord, coreCarries: Set<String>
    ) async throws -> ChatSessionEvidence {
        guard
            let tree = try await readTerminalProcesses(
                of: record, values: [Self.homeVariable, Self.configVariable],
                namesOf: ChatTranscriptOffVariable.allCases.map(\.rawValue)),
            let pid = tree.agent(
                isAgent: Self.isClaudeCode, followsLauncher: true, isTool: Self.isToolOfClaudeCode),
            let process = tree.facts[pid], case .value(let start) = process.start
        else { return cannotTell }

        let hints = await readHints(in: record, pid: pid, start: start)

        if case .value(let names) = process.nonEmptyNames {
            for variable in ChatTranscriptOffVariable.allCases where names.contains(variable.rawValue) {
                return .unavailable(
                    .transcriptOff(variable, coreCarriesIt: coreCarries.contains(variable.rawValue)))
            }
        }
        guard let configRoot = Self.configRoot(of: process, variable: Self.configVariable, underHome: ".claude")
        else { return cannotTell }
        if let entry = try await readEntry(under: configRoot, pid: pid, start: start) {
            return .bound(sessionID: entry.sessionID, transcriptRoot: configRoot, directory: entry.directory)
        }
        for hint in hints {
            if let session = ConversationReference.canonicalUUID(hint.session) {
                return .bound(sessionID: session, transcriptRoot: configRoot, directory: nil)
            }
        }
        return cannotTell
    }

    // MARK: Process

    /// One exec's facts about a Terminal: its own process and the foreground's
    /// descendants. Nil when it shows no scope to follow.
    func readTerminalProcesses(
        of record: HerdrCoreTerminalRecord, values: [String] = [], namesOf: [String] = [],
        arguments: [String] = [], readsOpenFiles: Bool = false
    ) async throws -> HerdrCoreTerminalProcesses? {
        guard let terminalPid = record.pid, let foreground = record.foreground?.pid else { return nil }
        let root = String(foreground)
        let scopeVariable = HerdrCoreTerminalProcesses.scopeVariable
        let request = HostProcessReader.Request(
            pids: Array(Set([String(terminalPid), root])).sorted(),
            readsStart: true,
            valuesOf: [scopeVariable] + values,
            namesOf: namesOf,
            readsOpenFiles: readsOpenFiles,
            argumentsAmong: arguments,
            descendantsOf: root)
        let facts = try await processes(request)
        guard case .value(let scope)? = facts[String(terminalPid)]?.variables[scopeVariable], !scope.isEmpty
        else { return nil }
        return HerdrCoreTerminalProcesses(facts: facts, root: root, scope: scope)
    }

    private static func isToolOfClaudeCode(_ process: HostProcessReader.Facts?) -> Bool {
        guard case .value(let names)? = process?.nonEmptyNames else { return false }
        return names.contains(ChatTranscriptOffVariable.childSession.rawValue)
    }

    /// Node takes the title `claude`, and the native installer's binary is
    /// `claude`, or its version when run from `versions/` directly.
    private static func isClaudeCode(_ process: HostProcessReader.Facts?) -> Bool {
        guard let name = process?.name else { return false }
        return name == "claude" || name.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil
    }

    /// A program's config root: the Agent's own variable, or a folder under its
    /// `HOME`. The Host's Default Account follows the core's environment, which
    /// can differ (ADR 0034).
    static func configRoot(
        of process: HostProcessReader.Facts, variable: String, underHome folder: String
    ) -> String? {
        switch process.variables[variable] {
        case .value(let directory)?:
            guard RemoteFilePath.isAcceptable(directory) else { return nil }
            return directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        case .unset?:
            guard case .value(let home)? = process.variables[homeVariable], RemoteFilePath.isAcceptable(home) else {
                return nil
            }
            return RemoteFilePath.join(home, folder)
        case .unavailable?, nil:
            return nil
        }
    }

    // MARK: Registry

    private struct RegistryEntry: Decodable {
        let pid: Int?
        let sessionId: String
        let procStart: String
        let cwd: String?
    }

    private func readEntry(
        under configRoot: String, pid: String, start: String
    ) async throws -> (sessionID: String, directory: String?)? {
        let path = RemoteFilePath.join(configRoot, "sessions", "\(pid).json")
        let slice = try await files.read(RemoteFileRange(path: path, offset: 0, maxBytes: Self.entryLimit))
        guard slice.length != nil, slice.data.count < Self.entryLimit,
            let entry = try? JSONDecoder().decode(RegistryEntry.self, from: slice.data),
            entry.procStart == start, entry.pid.map(String.init) == pid,
            let sessionID = ConversationReference.canonicalUUID(entry.sessionId)
        else { return nil }
        return (sessionID, entry.cwd.flatMap { $0.hasPrefix("/") ? $0 : nil })
    }

    // MARK: Hints

    /// The hints for this process, after clearing those for another. The labels
    /// are read after the exec, not taken from the record the check began on: a
    /// process writes its label once, as its session starts, which may be while the
    /// exec runs. A failure to clear leaves it for the next check.
    func readHints(
        in record: HerdrCoreTerminalRecord, pid: String, start: String
    ) async -> [HerdrCoreSessionHint] {
        let labels = await currentLabels() ?? record.labels
        var matching: [HerdrCoreSessionHint] = []
        var stale: [String: String] = [:]
        for label in HerdrCoreSessionHint.labels {
            guard let value = labels[label] else { continue }
            if let hint = HerdrCoreSessionHint(label: value), String(hint.pid) == pid, hint.start == start {
                matching.append(hint)
            } else {
                stale[label] = value
            }
        }
        if !stale.isEmpty { try? await clearLabels(stale) }
        return matching
    }
}

/// What one exec shows of a Terminal's processes, and which of them is the Agent.
struct HerdrCoreTerminalProcesses: Sendable {
    static let scopeVariable = "HC_SCOPE"

    let facts: [String: HostProcessReader.Facts]
    let root: String
    let scope: String

    /// The foreground's descendants, whatever scope they carry.
    var descendants: [String] {
        guard case .value(let descendants)? = facts[root]?.descendants else { return [] }
        return descendants
    }

    /// The nearest process to the foreground that calls itself the program, or
    /// the foreground itself when nothing under it could be. Nil when two are
    /// equally near. A process `skips` names counts for nothing, and neither do
    /// those of another scope. `followsLauncher` goes on past a launcher into the
    /// process it started under the same name, unless `isTool` says that one is
    /// the program's own tool and its parent is not.
    func agent(
        isAgent: (HostProcessReader.Facts?) -> Bool, followsLauncher: Bool = false,
        isTool: (HostProcessReader.Facts?) -> Bool = { _ in false },
        skips: (HostProcessReader.Facts?) -> Bool = { _ in false }
    ) -> String? {
        func sharesScope(_ pid: String) -> Bool {
            facts[pid]?.variables[Self.scopeVariable] == .value(scope)
        }
        guard sharesScope(root) else { return nil }
        var children: [String: [String]] = [:]
        for pid in descendants where sharesScope(pid) && !skips(facts[pid]) {
            if let parent = facts[pid]?.parent { children[parent, default: []].append(pid) }
        }
        var level = [root]
        while !level.isEmpty {
            let named = level.filter { isAgent(facts[$0]) }
            if named.count > 1 { return nil }
            if let found = named.first {
                guard followsLauncher else { return found }
                var current = found
                while true {
                    let next = (children[current] ?? []).filter { child in
                        isAgent(facts[child]) && isTool(facts[child]) == isTool(facts[current])
                    }
                    guard next.count == 1 else { return current }
                    current = next[0]
                }
            }
            level = level.flatMap { children[$0] ?? [] }
        }
        return (children[root] ?? []).isEmpty ? root : nil
    }
}
