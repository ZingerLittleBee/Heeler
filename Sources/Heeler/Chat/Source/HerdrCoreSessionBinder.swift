import Foundation

/// What a check of a herdr-core Agent's process found (ADR 0034).
enum ChatSessionEvidence: Equatable, Sendable {
    /// `transcriptRoot` is the Agent's own config dir, which its Transcript and
    /// session folders are under. `directory` is where the program says it
    /// started the session, when it says.
    case bound(sessionID: String, transcriptRoot: String, directory: String?)
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
/// process, never from a guess (ADR 0034). A check is at most one exec and one
/// SFTP read, and the app makes it only when something says the answer may have
/// changed.
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
    /// Facts for each process the request reaches: one exec. An empty answer
    /// is an exec that failed on the Host, which tells nothing.
    var processes: @Sendable (HostProcessReader.Request) async throws -> [String: HostProcessReader.Facts]
    var files: ChatHostFiles
    /// Removes labels from the Terminal, each with the value that was found stale.
    var clearLabels: @Sendable ([String: String]) async throws -> Void
    /// The Terminal's labels as they stand now, nil when nothing newer than the
    /// record is known.
    var currentLabels: @Sendable () async -> [String: String]? = { nil }
    /// Whose evidence this looks for, which is the Agent's own program.
    var program: ChatProgram = .claude

    static let scopeVariable = "HC_SCOPE"
    static let homeVariable = "HOME"
    private static let configVariable = "CLAUDE_CONFIG_DIR"
    /// Past this no registry entry was ever this long, so it is not one.
    private static let entryLimit = 64 * 1024

    /// `coreCarries` is what the core's own environment holds, from the Host's
    /// leak check, so a reason can point at the Host notice.
    func check(_ record: HerdrCoreTerminalRecord, coreCarries: Set<String> = []) async throws -> ChatSessionEvidence {
        if program == .pi || program == .omp { return try await checkPiFamily(record) }
        let cannotTell = ChatSessionEvidence.unavailable(.cannotTellSession(.claude))
        guard let terminalPid = record.pid, let foreground = record.foreground?.pid else { return cannotTell }
        let root = String(foreground)
        let request = HostProcessReader.Request(
            pids: Array(Set([String(terminalPid), root])).sorted(),
            readsStart: true,
            valuesOf: [Self.scopeVariable, Self.homeVariable, Self.configVariable],
            namesOf: ChatTranscriptOffVariable.allCases.map(\.rawValue),
            descendantsOf: root)
        let facts = try await processes(request)
        guard case .value(let scope)? = facts[String(terminalPid)]?.variables[Self.scopeVariable], !scope.isEmpty,
            let pid = Self.agentProcess(from: root, in: facts, scope: scope), let process = facts[pid],
            case .value(let start) = process.start
        else { return cannotTell }

        let hints = await readHints(in: record, pid: pid, start: start)

        if case .value(let names) = process.nonEmptyNames {
            for variable in ChatTranscriptOffVariable.allCases where names.contains(variable.rawValue) {
                return .unavailable(
                    .transcriptOff(variable, coreCarriesIt: coreCarries.contains(variable.rawValue)))
            }
        }
        guard let configRoot = Self.configRoot(of: process) else { return cannotTell }
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

    /// Which process is the Agent: the nearest one to the foreground that calls
    /// itself Claude Code, past a launcher of the same name, or the foreground
    /// itself when nothing under it could be. Nil when two are equally near.
    private static func agentProcess(
        from root: String, in facts: [String: HostProcessReader.Facts], scope: String
    ) -> String? {
        func sharesScope(_ pid: String) -> Bool {
            facts[pid]?.variables[scopeVariable] == .value(scope)
        }
        guard sharesScope(root) else { return nil }
        var children: [String: [String]] = [:]
        if case .value(let descendants)? = facts[root]?.descendants {
            for pid in descendants where sharesScope(pid) {
                if let parent = facts[pid]?.parent { children[parent, default: []].append(pid) }
            }
        }
        var level = [root]
        while !level.isEmpty {
            let named = level.filter { isClaudeCode(facts[$0]) }
            if named.count > 1 { return nil }
            if let found = named.first { return realProcess(from: found, in: facts, children: children) }
            level = level.flatMap { children[$0] ?? [] }
        }
        return (children[root] ?? []).isEmpty ? root : nil
    }

    /// Follows a launcher into the process it started under the same name. A
    /// Claude Code that Claude Code started carries `CLAUDE_CODE_CHILD_SESSION`
    /// where its parent does not, so it is that one's tool and not the Agent.
    private static func realProcess(
        from start: String, in facts: [String: HostProcessReader.Facts], children: [String: [String]]
    ) -> String {
        var current = start
        while true {
            let next = (children[current] ?? []).filter { child in
                isClaudeCode(facts[child]) && (isToolOfClaudeCode(facts[child]) == isToolOfClaudeCode(facts[current]))
            }
            guard next.count == 1 else { return current }
            current = next[0]
        }
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

    private static func configRoot(of process: HostProcessReader.Facts) -> String? {
        switch process.variables[configVariable] {
        case .value(let directory)?:
            guard RemoteFilePath.isAcceptable(directory) else { return nil }
            return directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        case .unset?:
            guard case .value(let home)? = process.variables[homeVariable], RemoteFilePath.isAcceptable(home) else {
                return nil
            }
            return RemoteFilePath.join(home, ".claude")
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
