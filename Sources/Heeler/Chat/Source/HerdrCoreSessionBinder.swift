import Foundation

/// What a check of a herdr-core Agent's process found (ADR 0034).
enum ChatSessionEvidence: Equatable, Sendable {
    /// `transcriptRoot` is the Agent's own config dir, which its Transcript and
    /// session folders are under. `directory` is where the program says it
    /// started the session, when it says. A program that keeps no Transcript
    /// file has no root.
    case bound(sessionID: String, transcriptRoot: String?, directory: String?)
    /// The user confirmed this conversation from candidates, with nothing on the
    /// Host showing it, so a send guard watches it. A Pi Heeler started with
    /// `--session-id` reads the same: its launch hint keeps that id after `/new`
    /// moves Pi on in the same process, which nothing on the Host shows either.
    case picked(sessionID: String, transcriptRoot: String?)
    /// A pick's label or a Pi's launch hint stands, and this check could not see
    /// the process to hold it against. Nothing says the pick is wrong, so a Chat
    /// following it keeps the conversation and sends nothing until a check can say.
    case pickUnconfirmed(ChatUnavailableReason)
    /// A Chat following a pick takes this as the pick's end.
    case unavailable(ChatUnavailableReason)
    /// Heeler's own launch has not shown the core its program yet, so there is
    /// nothing to bind or to say about it. Chat keeps looking, and the core's sample
    /// of the program, a foreground event, brings the next check.
    case launching

    var leavesItToAPick: Bool {
        if case .unavailable(let reason) = self { reason.leavesItToAPick } else { false }
    }
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

/// Which machine a core Host is, where its binder and Chat read differently: from the
/// kernel its locator printed, nil or any other reading as neither.
enum HerdrCoreHostSystem: Equatable, Sendable {
    case windows
    case macOS
    case other

    init(kernel: String?) {
        switch kernel {
        case HerdrCoreLocator.windowsKernel: self = .windows
        case HerdrCoreLocator.macOSKernel: self = .macOS
        default: self = .other
        }
    }

    /// What Chat says when nothing names the session, in this Host's form.
    func cannotTellSession(_ program: ChatProgram) -> ChatUnavailableReason {
        self == .windows ? .cannotTellSessionOnWindows(program) : .cannotTellSession(program)
    }

    /// What Chat says when the process holds more than one conversation, in this Host's form.
    func multipleSessions(_ program: ChatProgram) -> ChatUnavailableReason {
        .multipleSessions(program, offersPick: self != .windows)
    }
}

/// Binds a herdr-core Agent's Chat from what the Host shows about the Agent's own
/// process, never from a guess (ADR 0034). A check is one exec and at most one
/// SFTP read, past a Codex holding several rollouts and an Oh My Pi whose
/// breadcrumb names nothing yet, which also looks for Heeler's extension, and the
/// app makes it only when something says the answer may have changed.
///
/// It starts from the Terminal's foreground process, and goes through descendants
/// that share the Terminal's `HC_SCOPE` to reach the process behind a launcher.
/// The scope is the Terminal's own process's, since the core keeps it out of the
/// Terminal's record. On a Mac that withholds that process's environment the
/// foreground's stands in, or there is none (`readTerminalProcesses`). Only the
/// variables named here are read, on the Host, and `HERDR_*` is never among them.
/// A tmux Pane's and a Rex terminal's processes are followed the same way, by
/// their own scopes (`ProcessScope`).
///
/// Claude Code's `<config dir>/sessions/<pid>.json` is read by name, so the
/// `<pid>.<hash>.key` beside it before the prompt is never read or listed.
struct HerdrCoreSessionBinder: Sendable {
    enum ProcessScope: Equatable, Sendable {
        case herdrCore
        case tmux(paneID: String, socketPath: String, serverPID: Int)
        /// A Rex terminal: the session and block every process typed into it
        /// carries as `REX_SESSION` and `REX_BLOCK`, and the names Rex gave its
        /// foreground, its name and its first argument's last path part, one
        /// of which the process read must find on the pid Rex named.
        case rex(sessionID: String, blockID: String, foregroundNames: Set<String>)
    }

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
    var hostSystem = HerdrCoreHostSystem.other
    /// The programs a macOS Host binds exactly. Any other reads as cannot tell there,
    /// which leaves it to the candidate list and one confirmation.
    var macOSExactPrograms = HostCapabilities.macOSExactCoreChatPrograms
    /// How a Terminal's processes identify their Pane and server instance.
    var processScope = ProcessScope.herdrCore

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
        let bindsExactly = !isOnMacOS || macOSExactPrograms.contains(program)
        // A Terminal's record starts with no foreground, and Heeler's launch of agy
        // runs as the Terminal's own process until the core samples it.
        let isUnsampledLaunch = bindsExactly && record.foreground == nil && antigravityLaunch(in: record) != nil
        guard
            let tree = try await readTerminalProcesses(
                of: record, ask: processAsk, from: isUnsampledLaunch ? record.pid : nil)
        else {
            return await evidenceWithoutProcesses(in: record)
        }
        let evidence: ChatSessionEvidence
        if !bindsExactly {
            evidence = try await evidenceOfAnUnconfirmedProgram(record, tree: tree)
        } else {
            evidence =
                switch program {
                case .claude: try await checkClaudeCode(record, tree: tree, coreCarries: coreCarries)
                case .codex: try await checkCodex(record, tree: tree)
                case .grok: try await checkGrokBuild(tree)
                case .amp: .unavailable(.amp(.unidentified))
                case .opencode: try await checkOpenCode(record, tree: tree)
                case .pi, .omp: try await checkPiFamily(record, tree: tree)
                case .agy: checkAntigravity(record, tree: tree)
                }
        }
        // No process of the program runs yet that a pick could be held against.
        if evidence == .launching { return evidence }
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
        .unavailable(cannotTellReason)
    }

    var multipleSessions: ChatSessionEvidence {
        .unavailable(hostSystem.multipleSessions(program))
    }

    /// A Pi or Oh My Pi in a Rex terminal has its own reason, since what names
    /// its session there is offered in Chat and by no Host Helper (ADR 0056).
    var cannotTellReason: ChatUnavailableReason {
        if case .rex = processScope, program.namesItsSessionThroughHeelersExtension {
            return .cannotTellSessionOnRex(program, extensionInPlace: false)
        }
        return hostSystem.cannotTellSession(program)
    }

    /// A native Windows Host, whose foreground is the Terminal's first process, usually
    /// PowerShell, and whose processes go by their image's name (herdr compatibility,
    /// one machine's observation). Only the programs in
    /// `HostCapabilities.windowsCoreChatCandidates` are checked there.
    var isOnWindows: Bool { hostSystem == .windows }

    /// A macOS Host, where Grok Build's start, Oh My Pi's terminal name and a Terminal
    /// that runs one of Apple's own binaries each read differently (herdr compatibility).
    var isOnMacOS: Bool { hostSystem == .macOS }

    /// Where a program says its session started, in the form the Host writes paths.
    func startDirectory(_ directory: String?) -> String? {
        directory.flatMap { RemoteHostPath.isStartDirectory($0, allowingWindows: isOnWindows) ? $0 : nil }
    }

    /// What one exec asks of a Terminal's processes, for this program's agent and
    /// its evidence.
    struct ProcessAsk {
        var values: [String] = []
        var namesOf: [String] = []
        var arguments: [String] = []
        var preservesArgumentOrder = false
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
        case .opencode, .amp: ProcessAsk()
        case .pi, .omp: piFamilyProcessAsk
        case .agy: antigravityProcessAsk
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
                : (tree.agent(
                    isAgent: Self.isClaudeCode, followsLauncher: true, isTool: Self.isToolOfClaudeCode)
                    ?? (tree.rootIsForeground ? nil : tree.leafRuntimeAgent(runtimes: Self.windowsRuntimes)))
        case .codex: codexAgent(in: tree)
        case .grok:
            isOnWindows
                ? tree.agentOnWindows(isAgent: { $0?.name == "grok" }) : tree.agent(isAgent: { $0?.name == "grok" })
        case .amp: nil
        case .opencode: tree.agent(isAgent: { $0?.name == "opencode" })
        case .pi, .omp: piFamilyAgent(in: tree)
        // A native binary that calls itself `agy`, with nothing of its own under
        // it at the prompt (agy 1.5.3, `host-evidence/agy`). Windows never asks:
        // its reads hold no open files, so `check` answers before any exec there.
        case .agy: tree.agent(isAgent: { $0?.name == "agy" })
        }
    }

    /// Where the Agent's own process says its Transcripts are, which a program with
    /// no files lacks (ADR 0034). Nil also when the process cannot say.
    func transcriptRoot(of process: HostProcessReader.Facts) -> String? {
        switch program {
        case .claude: Self.configRoot(of: process, variable: Self.configVariable, underHome: ".claude")
        case .codex: codexHome(of: process)
        case .grok: grokHome(of: process)
        case .opencode, .amp: nil
        case .pi, .omp: piFamilySessions(of: process)
        case .agy: antigravityRoot(of: process)
        }
    }

    private func checkClaudeCode(
        _ record: HerdrCoreTerminalRecord, tree: HerdrCoreTerminalProcesses, coreCarries: Set<String>
    ) async throws -> ChatSessionEvidence {
        guard let pid = agentProcess(in: tree), let process = tree.facts[pid], case .value(let start) = process.start
        else { return cannotTell }

        let hints = await readHints(in: record, tree: tree, pid: pid, start: start)

        var transcriptOff: ChatSessionEvidence?
        if case .value(let names) = process.nonEmptyNames,
            let variable = ChatTranscriptOffVariable.allCases.first(where: { names.contains($0.rawValue) })
        {
            transcriptOff = .unavailable(
                .transcriptOff(variable, coreCarriesIt: coreCarries.contains(variable.rawValue)))
            // Claude Code saves no Transcript whatever this one holds, and still
            // keeps a registry entry, so an entry proves nothing.
            if names.contains(ChatTranscriptOffVariable.skipPromptHistory.rawValue), let transcriptOff {
                return transcriptOff
            }
        }
        guard let configRoot = transcriptRoot(of: process) else { return transcriptOff ?? cannotTell }
        // Claude Code honors `CLAUDE_CODE_CHILD_SESSION` only for some values and
        // surroundings: 2.1.316 ignored `made-up` and kept both an entry and a
        // Transcript (#579). Its own entry says which happened.
        if let entry = try await readEntry(under: configRoot, pid: pid, start: start) {
            return .bound(sessionID: entry.sessionID, transcriptRoot: configRoot, directory: entry.directory)
        }
        if let transcriptOff { return transcriptOff }
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
    /// Agent (herdr compatibility). `root` stands in for a foreground the core has not
    /// sampled yet.
    func readTerminalProcesses(
        of record: HerdrCoreTerminalRecord, ask: ProcessAsk, from root: Int? = nil
    ) async throws -> HerdrCoreTerminalProcesses? {
        switch processScope {
        case .herdrCore:
            guard let terminalPid = record.pid, let foreground = record.foreground?.pid ?? root else { return nil }
            let root = String(foreground)
            let scopeVariable = HerdrCoreTerminalProcesses.scopeVariable
            let request = HostProcessReader.Request(
                pids: Array(Set([String(terminalPid), root])).sorted(),
                readsStart: true,
                valuesOf: [scopeVariable] + ask.values,
                namesOf: ask.namesOf,
                readsOpenFiles: ask.readsOpenFiles,
                argumentsAmong: ask.arguments,
                preservesArgumentOrder: ask.preservesArgumentOrder,
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
        case .tmux(let paneID, let socketPath, let serverPID):
            let foregroundPID = record.foreground?.pid
            guard let rootPID = foregroundPID ?? root ?? record.pid else { return nil }
            let root = String(rootPID)
            let terminal = record.pid.map(String.init)
            let pids = terminal.map { Array(Set([$0, root])).sorted() } ?? [root]
            let request = HostProcessReader.Request(
                pids: pids,
                readsStart: true,
                valuesOf: [
                    HerdrCoreTerminalProcesses.tmuxVariable,
                    HerdrCoreTerminalProcesses.tmuxPaneVariable,
                ] + ask.values,
                namesOf: ask.namesOf,
                readsOpenFiles: ask.readsOpenFiles,
                argumentsAmong: ask.arguments,
                preservesArgumentOrder: ask.preservesArgumentOrder,
                descendantsOf: root)
            let facts = try await processes(request)
            let expected = HerdrCoreTerminalProcesses.Scope.tmux(
                paneID: paneID, socketPath: socketPath, serverPID: serverPID)
            let tree = HerdrCoreTerminalProcesses(
                facts: facts, root: root, scope: expected, rootIsForeground: foregroundPID != nil)
            if tree.sharesScope(root) || terminal.map(tree.sharesScope) == true {
                return tree
            }
            let withheld = terminal.map(tree.scopeIsUnavailable) ?? tree.scopeIsUnavailable(root)
            guard isOnMacOS, withheld, tree.walkAnswered else { return nil }
            return tree
        case .rex(let sessionID, let blockID, let foregroundNames):
            return try await readRexTerminalProcesses(
                of: record, ask: ask, from: root,
                sessionID: sessionID, blockID: blockID, foregroundNames: foregroundNames)
        }
    }

    /// A Rex terminal's processes, from the foreground Rex names, the group
    /// leader holding its terminal. Rex gives no process of the terminal's
    /// own, so the foreground's scope is the one to follow. That pid is the
    /// foreground only while the read finds it under a name Rex gave it: one
    /// reused since says nothing. A multiplexer run inside the terminal sets
    /// its own variables for its panes, which keep the terminal's `REX_*`,
    /// so a process whose tmux or herdr-core variables differ from the
    /// foreground's is in another terminal. On a Mac that withholds the
    /// foreground's environment, a walk that answered still says which
    /// processes are there, and only one carrying none of those variables
    /// is in scope (rex-compatibility.md).
    ///
    /// The walk names processes, the foreground included, only when it answers:
    /// past its cap it names none. The foreground then counts only by carrying
    /// the terminal's own variables, and nothing under it is in sight, as on the
    /// other kinds.
    private func readRexTerminalProcesses(
        of record: HerdrCoreTerminalRecord, ask: ProcessAsk, from root: Int?,
        sessionID: String, blockID: String, foregroundNames: Set<String>
    ) async throws -> HerdrCoreTerminalProcesses? {
        guard let rootPID = record.foreground?.pid ?? root else { return nil }
        let root = String(rootPID)
        let nested = HerdrCoreTerminalProcesses.nestedMultiplexerVariables(onWindows: isOnWindows)
        let request = HostProcessReader.Request(
            pids: [root],
            readsStart: true,
            valuesOf: [HerdrCoreTerminalProcesses.rexSessionVariable, HerdrCoreTerminalProcesses.rexBlockVariable]
                + nested + ask.values,
            namesOf: ask.namesOf,
            readsOpenFiles: ask.readsOpenFiles,
            argumentsAmong: ask.arguments,
            preservesArgumentOrder: ask.preservesArgumentOrder,
            descendantsOf: root)
        let facts = try await processes(request)
        guard let rootFacts = facts[root] else { return nil }
        if let name = rootFacts.name {
            guard HerdrCoreTerminalProcesses.isNamed(name, oneOf: foregroundNames) else { return nil }
        } else if case .value = rootFacts.descendants {
            // A walk that answered without it: the process is gone.
            return nil
        }
        var outer: [String: HostProcessReader.Variable] = [:]
        for variable in nested {
            if case .value(let value)? = facts[root]?.variables[variable] {
                outer[variable] = .value(value)
            } else {
                outer[variable] = .unset
            }
        }
        let tree = HerdrCoreTerminalProcesses(
            facts: facts, root: root, scope: .rex(sessionID: sessionID, blockID: blockID, outer: outer))
        if tree.sharesScope(root) { return tree }
        guard isOnMacOS, tree.scopeIsUnavailable(root), tree.walkAnswered else { return nil }
        return tree
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

    /// On Windows Claude Code 2.1.286 and 2.1.316 wrote the creation FILETIME as
    /// decimal digits in `procStart`, with no `procStartFt` (one machine, herdr-core
    /// 0.1.16, 2026-11-03), though 2.1.316's source text names `procStartFt` there.
    /// A Windows read takes `procStartFt` and falls back to `procStart` (herdr
    /// compatibility).
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
    /// exec runs. A failure to clear leaves it for the next check. For that reason a
    /// label from a process of the Agent's own name still running below the foreground
    /// stays and binds nothing: under a wrapper of that name it may be the real Agent,
    /// or a subagent, and the real one would not write the label again (ADR 0034).
    func readHints(
        in record: HerdrCoreTerminalRecord, tree: HerdrCoreTerminalProcesses, pid: String, start: String
    ) async -> [HerdrCoreSessionHint] {
        let labels = await currentLabels() ?? record.labels
        guard let value = labels[HerdrCoreSessionHint.sessionLabel] else { return [] }
        if let hint = HerdrCoreSessionHint(label: value) {
            if String(hint.pid) == pid, hint.start == start { return [hint] }
            if tree.isRunning(String(hint.pid), from: hint.start, underTheNameOf: pid) { return [] }
        }
        try? await clearLabels([HerdrCoreSessionHint.sessionLabel: value])
        return []
    }
}

/// What one exec shows of a Terminal's processes, and which of them is the Agent.
struct HerdrCoreTerminalProcesses: Sendable {
    static let scopeVariable = "HC_SCOPE"
    static let tmuxVariable = "TMUX"
    static let tmuxPaneVariable = "TMUX_PANE"
    /// What Rex sets for every program in a terminal: its block id, and up
    /// to 0.1.0-preview.14 its session id. Rex 0.1.0-preview.23 sets
    /// `REX_BLOCK` and no `REX_SESSION`, on macOS and Windows alike, and a
    /// block id names one block on the server (rex-compatibility.md).
    static let rexSessionVariable = "REX_SESSION"
    static let rexBlockVariable = "REX_BLOCK"
    /// What a multiplexer Heeler knows sets for the programs in its own
    /// panes, so a process run in one inside a Rex terminal shows it.
    static let nestedMultiplexerVariables = [tmuxVariable, tmuxPaneVariable, scopeVariable]

    /// Those a read asks for. Native Windows runs no tmux, and its process
    /// read goes in one command line `cmd.exe` caps, so it asks for
    /// herdr-core's alone.
    static func nestedMultiplexerVariables(onWindows: Bool) -> [String] {
        onWindows ? [scopeVariable] : nestedMultiplexerVariables
    }

    struct TmuxEnvironment: Equatable, Sendable {
        let socketPath: String
        let serverPID: Int
    }

    enum Scope: Equatable, Sendable {
        case herdrCore(String)
        case tmux(paneID: String, socketPath: String, serverPID: Int)
        /// `outer` is what the terminal's foreground carries of each of
        /// `nestedMultiplexerVariables` the read asked for, a value or unset,
        /// which a process in the terminal carries too.
        case rex(sessionID: String, blockID: String, outer: [String: HostProcessReader.Variable])
    }

    let facts: [String: HostProcessReader.Facts]
    let root: String
    /// Nil when macOS withheld every process that could say it, so none is the Agent.
    let scope: Scope?
    /// True when `root` is `record.foreground.pid`; false when `root` is a tmux Pane's
    /// `pane_pid` (often an interactive shell rather than the foreground job).
    let rootIsForeground: Bool

    init(
        facts: [String: HostProcessReader.Facts], root: String, scope: Scope?,
        rootIsForeground: Bool = true
    ) {
        self.facts = facts
        self.root = root
        self.scope = scope
        self.rootIsForeground = rootIsForeground
    }

    init(facts: [String: HostProcessReader.Facts], root: String, scope: String?) {
        self.init(facts: facts, root: root, scope: scope.map(Scope.herdrCore), rootIsForeground: true)
    }

    /// Parses `<socket>,<server pid>,<session>` from `TMUX`, allowing commas inside
    /// `<socket>`.
    static func parseTmuxEnvironment(_ value: String) -> TmuxEnvironment? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let session = parts[parts.count - 1]
        let pidPart = parts[parts.count - 2]
        let socketPath = parts.dropLast(2).joined(separator: ",")
        guard socketPath.hasPrefix("/"),
            !session.isEmpty, session.allSatisfy({ $0.isASCII && $0.isNumber }),
            !pidPart.isEmpty, pidPart.allSatisfy({ $0.isASCII && $0.isNumber }),
            let serverPID = Int(pidPart), serverPID > 0
        else { return nil }
        return TmuxEnvironment(socketPath: socketPath, serverPID: serverPID)
    }

    /// Whether this process is in the Terminal, as far as its environment says.
    func sharesScope(_ pid: String) -> Bool {
        guard let scope, let variables = facts[pid]?.variables else { return false }
        switch scope {
        case .herdrCore(let expected):
            return variables[Self.scopeVariable] == .value(expected)
        case .tmux(let paneID, let socketPath, let serverPID):
            guard variables[Self.tmuxPaneVariable] == .value(paneID),
                case .value(let rawTmux)? = variables[Self.tmuxVariable],
                let parsed = Self.parseTmuxEnvironment(rawTmux)
            else { return false }
            return parsed == TmuxEnvironment(socketPath: socketPath, serverPID: serverPID)
        case .rex(let sessionID, let blockID, let outer):
            // A server that sets no session id leaves the block's to say it.
            guard variables[Self.rexBlockVariable] == .value(blockID),
                variables[Self.rexSessionVariable] == .value(sessionID)
                    || variables[Self.rexSessionVariable] == .unset
            else { return false }
            return outer.allSatisfy { name, value in variables[name] == value }
        }
    }

    func scopeIsUnavailable(_ pid: String) -> Bool {
        guard let variables = facts[pid]?.variables else { return false }
        switch scope {
        case .herdrCore, nil:
            return variables[Self.scopeVariable] == .unavailable
        case .tmux:
            return variables[Self.tmuxVariable] == .unavailable || variables[Self.tmuxPaneVariable] == .unavailable
        case .rex:
            return variables[Self.rexBlockVariable] == .unavailable
        }
    }

    /// Whether a process read's `name` is one of `names`: Linux gives the
    /// kernel's name, cut to 15 bytes.
    static func isNamed(_ name: String, oneOf names: Set<String>) -> Bool {
        names.contains { candidate in
            candidate == name
                || (candidate.utf8.count > 15 && String(decoding: candidate.utf8.prefix(15), as: UTF8.self) == name)
        }
    }

    /// Whether this process, from this start, runs below the foreground under the
    /// name `agent` goes by.
    func isRunning(_ pid: String, from start: String, underTheNameOf agent: String) -> Bool {
        descendants.contains(pid) && sharesScope(pid) && facts[pid]?.start == .value(start)
            && facts[pid]?.name == facts[agent]?.name
    }

    /// On Windows the foreground is the Terminal's first process for its whole life,
    /// usually a PowerShell that is never the Agent, and a program under npm goes by
    /// its runtime's image. So: the nearest process named for the program, the
    /// foreground included, else the nearest runtime under the foreground,
    /// with no following past it, since its children go by the same name whatever they
    /// are. What then proves it the Agent is its pid and start matching what the
    /// program recorded (ADR 0034).
    func agentOnWindows(
        isAgent: (HostProcessReader.Facts?) -> Bool, followsLauncher: Bool = false,
        isTool: (HostProcessReader.Facts?) -> Bool = { _ in false }, runtimes: Set<String> = []
    ) -> String? {
        if let found = nearestAgent(isAgent: isAgent, followsLauncher: followsLauncher, isTool: isTool) {
            return found
        }
        return nearestAgent(isAgent: { $0?.name.map(runtimes.contains) ?? false })
    }

    /// As ``agent(isAgent:followsLauncher:isTool:skips:)``, without its fallback to the
    /// foreground: only a process `isAgent` itself says is one.
    func nearestAgent(
        isAgent: (HostProcessReader.Facts?) -> Bool, followsLauncher: Bool = false,
        isTool: (HostProcessReader.Facts?) -> Bool = { _ in false }
    ) -> String? {
        agent(isAgent: isAgent, followsLauncher: followsLauncher, isTool: isTool).flatMap {
            isAgent(facts[$0]) ? $0 : nil
        }
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
        let rootInScope = sharesScope(root)
        let allowsWithheldRoot: Bool =
            switch scope {
            case .tmux, .rex: scopeIsUnavailable(root)
            case .herdrCore, nil: false
            }
        guard rootInScope || allowsWithheldRoot else { return nil }
        var children: [String: [String]] = [:]
        for pid in descendants where sharesScope(pid) && !skips(facts[pid]) {
            if let parent = facts[pid]?.parent { children[parent, default: []].append(pid) }
        }
        var level = rootInScope ? [root] : (children[root] ?? [])
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
        let isOutOfSight = descendants.contains { scopeIsUnavailable($0) }
        return rootInScope && rootIsForeground && (children[root] ?? []).isEmpty && !isOutOfSight ? root : nil
    }

    /// On tmux `root` is `pane_pid` (often the Pane's shell), so when nothing is named
    /// for the program, only a leaf runtime (`node`, `bun`, `deno`) with no withheld
    /// descendant can stand in for a script-launched Agent.
    func leafRuntimeAgent(runtimes: Set<String>) -> String? {
        guard !descendants.contains(where: { scopeIsUnavailable($0) }) else { return nil }
        var children: [String: [String]] = [:]
        for pid in descendants where sharesScope(pid) {
            if let parent = facts[pid]?.parent { children[parent, default: []].append(pid) }
        }
        guard let found = nearestAgent(isAgent: { $0?.name.map(runtimes.contains) ?? false }),
            (children[found] ?? []).isEmpty
        else { return nil }
        return found
    }
}
