import Foundation

/// What a check of a herdr-core Agent's process found (ADR 0034).
enum ChatSessionEvidence: Equatable, Sendable {
    /// `transcriptRoot` is the Agent's own config dir, which its Transcript and
    /// session folders are under. `directory` is where the program says it
    /// started the session, when it says. A program that keeps no Transcript
    /// file has no root.
    case bound(sessionID: String, transcriptRoot: String?, directory: String?)
    /// The user confirmed this conversation from candidates, with nothing on the
    /// Host showing it, so a send guard watches it.
    case picked(sessionID: String, transcriptRoot: String?)
    /// A pick's label stands, and this check could not see the process to hold it
    /// against. Nothing says the pick is wrong, so a Chat following it keeps the
    /// conversation and sends nothing until a check can say.
    case pickUnconfirmed(ChatUnavailableReason)
    /// A Chat following a pick takes this as the pick's end.
    case unavailable(ChatUnavailableReason)
}

/// A `heeler.*` label naming a session (ADR 0034). It is a hint: anything may
/// write a label, and one outlives the process that wrote it, so it counts only
/// for the process it names, by pid and process start.
struct HerdrCoreSessionHint: Equatable, Sendable {
    /// What a program's own extension or plugin writes. The labels hold this JSON.
    /// `heeler.launch-session` is none of them: it holds the id alone, written
    /// before any process exists (ADR 0034).
    static let sessionLabel = "heeler.session"
    /// A conversation the user confirmed from candidates.
    static let pickLabel = "heeler.chat"

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
/// The scope is the Terminal's own process's, since the core keeps it out of the
/// Terminal's record. On a Mac that withholds that process's environment the
/// foreground's stands in, or there is none (`readTerminalProcesses`). Only the
/// variables named here are read, on the Host, and `HERDR_*` is never among them.
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
    /// Whether this value of the pick label is one a send guard already dropped,
    /// whose removal may not have reached the core.
    var isDroppedPick: @Sendable (String) async -> Bool = { _ in false }
    var now: @Sendable () -> Date = { Date() }
    /// A native Windows Host, whose foreground is the Terminal's PowerShell and whose
    /// processes go by their image's name (herdr compatibility). Only the programs in
    /// `HostCapabilities.windowsCoreChatCandidates` are checked there.
    var isOnWindows = false
    /// A macOS Host, where Grok Build's start, Oh My Pi's terminal name and a Terminal
    /// that runs one of Apple's own binaries each read differently (herdr compatibility).
    var isOnMacOS = false
    /// The programs a macOS Host binds exactly. Any other reads as cannot tell there,
    /// which leaves it to the candidate list and one confirmation.
    var macOSExactPrograms = HostCapabilities.macOSExactCoreChatPrograms

    /// What an npm install runs as on Windows, where a program cannot retitle itself.
    static let windowsRuntimes: Set<String> = ["node", "bun"]
    static let homeVariable = "HOME"
    private static let configVariable = "CLAUDE_CONFIG_DIR"
    /// Past this no registry entry was ever this long, so it is not one.
    private static let entryLimit = 64 * 1024

    /// `coreCarries` is what the core's own environment holds, from the Host's
    /// leak check, so a reason can point at the Host notice.
    func check(_ record: HerdrCoreTerminalRecord, coreCarries: Set<String> = []) async throws -> ChatSessionEvidence {
        if isOnWindows, !HostCapabilities.windowsCoreChatCandidates.contains(program) { return cannotTell }
        guard let tree = try await readTerminalProcesses(of: record, ask: processAsk) else {
            return await evidenceWithoutProcesses(in: record)
        }
        let evidence: ChatSessionEvidence
        if isOnMacOS, !macOSExactPrograms.contains(program) {
            evidence = try await evidenceOfAnUnconfirmedProgram(record, tree: tree)
        } else {
            evidence =
                switch program {
                case .claude: try await checkClaudeCode(record, tree: tree, coreCarries: coreCarries)
                case .codex: try await checkCodex(record, tree: tree)
                case .grok: try await checkGrokBuild(tree)
                case .opencode: try await checkOpenCode(record, tree: tree)
                case .pi, .omp: try await checkPiFamily(record, tree: tree)
                }
        }
        return await applyingPick(to: evidence, record: record, tree: tree)
    }

    /// Nothing binds exactly, and a Codex on the shared daemon still gets only its
    /// message, because a confirmation could not hold there either (ADR 0034).
    private func evidenceOfAnUnconfirmedProgram(
        _ record: HerdrCoreTerminalRecord, tree: HerdrCoreTerminalProcesses
    ) async throws -> ChatSessionEvidence {
        guard program == .codex, let pid = codexAgent(in: tree), let process = tree.facts[pid],
            try await isCodexOnSharedDaemon(record, tree: tree, process: process)
        else { return cannotTell }
        return .unavailable(.codexSharedDaemon)
    }

    var cannotTell: ChatSessionEvidence {
        .unavailable(isOnWindows ? .cannotTellSessionOnWindows(program) : .cannotTellSession(program))
    }

    /// Where a program says its session started, in the form the Host writes paths.
    func startDirectory(_ directory: String?) -> String? {
        directory.flatMap { path in
            path.hasPrefix("/") || (isOnWindows && RemoteHostPath.isWindowsAbsolute(path)) ? path : nil
        }
    }

    /// What one exec asks of a Terminal's processes, for this program's agent and
    /// its evidence.
    struct ProcessAsk {
        var values: [String] = []
        var namesOf: [String] = []
        var arguments: [String] = []
        var readsOpenFiles = false
    }

    var processAsk: ProcessAsk {
        switch program {
        case .claude:
            ProcessAsk(
                values: [Self.homeVariable, Self.configVariable],
                namesOf: ChatTranscriptOffVariable.allCases.map(\.rawValue))
        case .codex: codexProcessAsk
        case .grok: grokProcessAsk
        case .opencode: ProcessAsk()
        case .pi, .omp: piFamilyProcessAsk
        }
    }

    /// The process that is this program's Agent, by ADR 0034's rule for it. Nil when
    /// two are equally near, or, for Pi and Oh My Pi, when no process is named for it.
    func agentProcess(in tree: HerdrCoreTerminalProcesses) -> String? {
        switch program {
        case .claude:
            isOnWindows
                ? tree.agentOnWindows(
                    isAgent: Self.isClaudeCode, followsLauncher: true, isTool: Self.isToolOfClaudeCode,
                    runtimes: Self.windowsRuntimes)
                : tree.agent(isAgent: Self.isClaudeCode, followsLauncher: true, isTool: Self.isToolOfClaudeCode)
        case .codex: codexAgent(in: tree)
        case .grok:
            isOnWindows
                ? tree.agentOnWindows(isAgent: { $0?.name == "grok" }) : tree.agent(isAgent: { $0?.name == "grok" })
        case .opencode: tree.agent(isAgent: { $0?.name == "opencode" })
        case .pi, .omp: piFamilyAgent(in: tree)
        }
    }

    /// Where the Agent's own process says its Transcripts are, which a program with
    /// no files lacks (ADR 0034). Nil also when the process cannot say.
    func transcriptRoot(of process: HostProcessReader.Facts) -> String? {
        switch program {
        case .claude: Self.configRoot(of: process, variable: Self.configVariable, underHome: ".claude")
        case .codex: codexHome(of: process)
        case .grok: grokHome(of: process)
        case .opencode: nil
        case .pi, .omp: piFamilySessions(of: process)
        }
    }

    private func checkClaudeCode(
        _ record: HerdrCoreTerminalRecord, tree: HerdrCoreTerminalProcesses, coreCarries: Set<String>
    ) async throws -> ChatSessionEvidence {
        guard let pid = agentProcess(in: tree), let process = tree.facts[pid], case .value(let start) = process.start
        else { return cannotTell }

        let hints = await readHints(in: record, pid: pid, start: start)

        if case .value(let names) = process.nonEmptyNames {
            for variable in ChatTranscriptOffVariable.allCases where names.contains(variable.rawValue) {
                return .unavailable(
                    .transcriptOff(variable, coreCarriesIt: coreCarries.contains(variable.rawValue)))
            }
        }
        guard let configRoot = transcriptRoot(of: process) else { return cannotTell }
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
    /// descendants. Nil when it shows no scope to follow, which on macOS takes more:
    /// the Terminal's own process is usually `/bin/zsh`, whose environment a Mac with
    /// SIP on withholds, so the foreground's scope stands in for it. With both withheld, a
    /// walk that answered still says which processes are there, and no process is the
    /// Agent (herdr compatibility).
    func readTerminalProcesses(
        of record: HerdrCoreTerminalRecord, ask: ProcessAsk
    ) async throws -> HerdrCoreTerminalProcesses? {
        guard let terminalPid = record.pid, let foreground = record.foreground?.pid else { return nil }
        let root = String(foreground)
        let scopeVariable = HerdrCoreTerminalProcesses.scopeVariable
        let request = HostProcessReader.Request(
            pids: Array(Set([String(terminalPid), root])).sorted(),
            readsStart: true,
            valuesOf: [scopeVariable] + ask.values,
            namesOf: ask.namesOf,
            readsOpenFiles: ask.readsOpenFiles,
            argumentsAmong: ask.arguments,
            descendantsOf: root)
        let facts = try await processes(request)
        func scope(of pid: String) -> String? {
            guard case .value(let scope)? = facts[pid]?.variables[scopeVariable], !scope.isEmpty else { return nil }
            return scope
        }
        if let scope = scope(of: String(terminalPid)) {
            return HerdrCoreTerminalProcesses(facts: facts, root: root, scope: scope)
        }
        guard isOnMacOS, facts[String(terminalPid)]?.variables[scopeVariable] == .unavailable else { return nil }
        let tree = HerdrCoreTerminalProcesses(facts: facts, root: root, scope: scope(of: root))
        return tree.scope != nil || tree.walkAnswered ? tree : nil
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

    /// On Windows Claude Code keeps the creation FILETIME in `procStartFt`, as
    /// decimal digits (2.1.316 source, herdr compatibility).
    private struct RegistryEntry: Decodable {
        let pid: Int?
        let sessionId: String
        let procStart: String?
        let procStartFt: String?
        let cwd: String?
    }

    private func readEntry(
        under configRoot: String, pid: String, start: String
    ) async throws -> (sessionID: String, directory: String?)? {
        let path = RemoteFilePath.join(configRoot, "sessions", "\(pid).json")
        let slice = try await files.read(RemoteFileRange(path: path, offset: 0, maxBytes: Self.entryLimit))
        guard slice.length != nil, slice.data.count < Self.entryLimit,
            let entry = try? JSONDecoder().decode(RegistryEntry.self, from: slice.data),
            (isOnWindows ? entry.procStartFt ?? entry.procStart : entry.procStart) == start,
            entry.pid.map(String.init) == pid,
            let sessionID = ConversationReference.canonicalUUID(entry.sessionId)
        else { return nil }
        return (sessionID, startDirectory(entry.cwd))
    }

    // MARK: Hints

    /// The session hint for this process, after clearing one for another. The labels
    /// are read after the exec, not taken from the record the check began on: a
    /// process writes its label once, as its session starts, which may be while the
    /// exec runs. A failure to clear leaves it for the next check.
    func readHints(
        in record: HerdrCoreTerminalRecord, pid: String, start: String
    ) async -> [HerdrCoreSessionHint] {
        let labels = await currentLabels() ?? record.labels
        guard let value = labels[HerdrCoreSessionHint.sessionLabel] else { return [] }
        if let hint = HerdrCoreSessionHint(label: value), String(hint.pid) == pid, hint.start == start {
            return [hint]
        }
        try? await clearLabels([HerdrCoreSessionHint.sessionLabel: value])
        return []
    }
}

/// What one exec shows of a Terminal's processes, and which of them is the Agent.
struct HerdrCoreTerminalProcesses: Sendable {
    static let scopeVariable = "HC_SCOPE"

    let facts: [String: HostProcessReader.Facts]
    let root: String
    /// Nil when macOS withheld every process that could say it, so none is the Agent.
    let scope: String?

    /// Whether this process is in the Terminal, as far as its environment says.
    func sharesScope(_ pid: String) -> Bool {
        guard let scope else { return false }
        return facts[pid]?.variables[Self.scopeVariable] == .value(scope)
    }

    /// On Windows the foreground is the Terminal's PowerShell, which is never the
    /// Agent, and a program under npm goes by its runtime's image. So: the nearest
    /// process named for the program, else the nearest runtime under the foreground,
    /// with no following past it, since its children go by the same name whatever they
    /// are. What then proves it the Agent is its pid and start matching what the
    /// program recorded (ADR 0034).
    func agentOnWindows(
        isAgent: (HostProcessReader.Facts?) -> Bool, followsLauncher: Bool = false,
        isTool: (HostProcessReader.Facts?) -> Bool = { _ in false }, runtimes: Set<String> = []
    ) -> String? {
        if let found = agent(isAgent: isAgent, followsLauncher: followsLauncher, isTool: isTool),
            isAgent(facts[found])
        {
            return found
        }
        func isRuntime(_ process: HostProcessReader.Facts?) -> Bool {
            process?.name.map(runtimes.contains) ?? false
        }
        return agent(isAgent: isRuntime).flatMap { isRuntime(facts[$0]) ? $0 : nil }
    }

    /// The foreground's descendants, whatever scope they carry.
    var descendants: [String] {
        guard case .value(let descendants)? = facts[root]?.descendants else { return [] }
        return descendants
    }

    /// Whether ``descendants`` is the whole tree, so a process it leaves out is not there.
    var walkAnswered: Bool {
        if case .value? = facts[root]?.descendants { true } else { false }
    }

    /// The nearest process to the foreground that calls itself the program, or
    /// the foreground itself when nothing under it could be, which a process whose
    /// environment cannot be read could. Nil when two are equally near. A process
    /// `skips` names counts for nothing, and neither do those of another scope.
    /// `followsLauncher` goes on past a launcher into the process it started under
    /// the same name, unless `isTool` says that one is the program's own tool and its
    /// parent is not.
    func agent(
        isAgent: (HostProcessReader.Facts?) -> Bool, followsLauncher: Bool = false,
        isTool: (HostProcessReader.Facts?) -> Bool = { _ in false },
        skips: (HostProcessReader.Facts?) -> Bool = { _ in false }
    ) -> String? {
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
        let isOutOfSight = descendants.contains { facts[$0]?.variables[Self.scopeVariable] == .unavailable }
        return (children[root] ?? []).isEmpty && !isOutOfSight ? root : nil
    }
}
