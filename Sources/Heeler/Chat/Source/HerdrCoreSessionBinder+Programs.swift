import Foundation

/// The evidence ADR 0034 names for Codex, Grok Build, OpenCode and Antigravity
/// CLI. None of it
/// counts until the recorded shape in `ChatFixtures/host-evidence` matches, and a
/// shape it does not know binds nothing.
extension HerdrCoreSessionBinder {
    // MARK: Codex

    /// A bound check reads only the rollouts the process holds, and a process
    /// holding more than this reads as holding too many to say.
    static let heldRolloutLimit = 8
    /// `session_meta`, line 1, carries the base instructions, which reach tens of
    /// kilobytes.
    private static let rolloutHeadLimit = 256 * 1024
    static let codexHomeVariable = "CODEX_HOME"
    /// `app-server --managed-daemon`, and its `app-server daemon pid-update-loop`.
    private static let codexDaemonArguments = ["--managed-daemon", "app-server", "pid-update-loop"]

    /// Embedded Codex holds its own rollout from the first prompt. The shared
    /// daemon holds every window's and no window holds any, so a daemon under the
    /// Agent, or a launch on the shared server while its socket exists, gets no
    /// binding (ADR 0034).
    func checkCodex(
        _ record: HerdrCoreTerminalRecord, tree: HerdrCoreTerminalProcesses
    ) async throws -> ChatSessionEvidence {
        guard let pid = codexAgent(in: tree), let process = tree.facts[pid], let codexHome = codexHome(of: process)
        else { return cannotTell }
        if try await isCodexOnSharedDaemon(record, tree: tree, process: process) {
            return .unavailable(.codexSharedDaemon)
        }
        let rollouts = Self.rollouts(heldBy: process)
        guard !rollouts.isEmpty, rollouts.count <= Self.heldRolloutLimit,
            !Self.holdsALockWithoutItsRollout(process, rollouts: rollouts)
        else { return cannotTell }
        var roots: [RolloutHead] = []
        for rollout in rollouts {
            guard let head = try await readRolloutHead(rollout) else { return cannotTell }
            if head.isRoot { roots.append(head) }
        }
        guard roots.count == 1, let root = roots.first else { return cannotTell }
        return .bound(sessionID: root.threadID, transcriptRoot: codexHome, directory: root.directory)
    }

    /// A daemon under the Agent, or a launch on the shared server, holding no
    /// rollout of its own, while the server's socket exists. A thread-writer lock is
    /// a thread of its own, which a window on the daemon never holds (Codex CLI
    /// 0.165.0, `host-evidence/codex/no-daemon.json` and `default-daemon.json`), and
    /// which a script under Codex's name can hide `--no-daemon` from the arguments of.
    func isCodexOnSharedDaemon(
        _ record: HerdrCoreTerminalRecord, tree: HerdrCoreTerminalProcesses, process: HostProcessReader.Facts
    ) async throws -> Bool {
        if tree.descendants.contains(where: { Self.isManagedDaemon(tree.facts[$0]) }) { return true }
        guard Self.rollouts(heldBy: process).isEmpty, !Self.holdsAThreadLock(process),
            let codexHome = codexHome(of: process),
            CodexLaunch.launchesOnSharedServer(foreground: record.foreground) == true
        else { return false }
        return try await files.status(CodexLaunch.controlSocketPath(codexHome: codexHome)) != nil
    }

    var codexProcessAsk: ProcessAsk {
        ProcessAsk(
            values: [Self.homeVariable, Self.codexHomeVariable], arguments: Self.codexDaemonArguments,
            readsOpenFiles: true)
    }

    func codexAgent(in tree: HerdrCoreTerminalProcesses) -> String? {
        tree.agent(isAgent: { $0?.name == "codex" }, skips: Self.isCodexDaemon)
    }

    func codexHome(of process: HostProcessReader.Facts) -> String? {
        Self.configRoot(of: process, variable: Self.codexHomeVariable, underHome: ".codex")
    }

    private static func isManagedDaemon(_ process: HostProcessReader.Facts?) -> Bool {
        guard case .value(let arguments)? = process?.arguments else { return false }
        return arguments.contains("--managed-daemon")
    }

    private static func isCodexDaemon(_ process: HostProcessReader.Facts?) -> Bool {
        guard case .value(let arguments)? = process?.arguments else { return false }
        return arguments.contains("--managed-daemon")
            || (arguments.contains("app-server") && arguments.contains("pid-update-loop"))
    }

    private static func holdsAThreadLock(_ process: HostProcessReader.Facts) -> Bool {
        guard case .value(let files) = process.openFiles else { return false }
        return files.contains { $0.contains("/thread-writer-locks/") }
    }

    struct HeldRollout {
        let path: String
        let name: CodexRolloutFileName
    }

    /// A thread-writer lock with no held rollout of its thread is a thread with
    /// nothing to read yet, and the screen may be on it: the first prompt after
    /// `/new` leaves this while the old rollout stays held (Codex CLI 0.165.0,
    /// `host-evidence/codex/no-daemon-after-new.json`). A name no recording shows
    /// could be any thread's.
    private static func holdsALockWithoutItsRollout(
        _ process: HostProcessReader.Facts, rollouts: [HeldRollout]
    ) -> Bool {
        guard case .value(let files) = process.openFiles else { return false }
        let threads = Set(rollouts.compactMap { ConversationReference.canonicalUUID($0.name.threadID) })
        return files.contains { path in
            guard path.contains("/thread-writer-locks/"), let leaf = path.split(separator: "/").last else {
                return false
            }
            guard leaf.hasSuffix(".lock"),
                let thread = ConversationReference.canonicalUUID(String(leaf.dropLast(".lock".count)))
            else { return true }
            return !threads.contains(thread)
        }
    }

    /// The process's open files that are rollouts. Its thread-writer locks and
    /// anything else it holds are not.
    static func rollouts(heldBy process: HostProcessReader.Facts) -> [HeldRollout] {
        guard case .value(let files) = process.openFiles else { return [] }
        return files.compactMap { path in
            guard path.contains("/sessions/") || path.contains("/archived_sessions/"),
                let leaf = path.split(separator: "/").last,
                let name = CodexRolloutFileName(fileName: String(leaf)), !name.isCompressed
            else { return nil }
            return HeldRollout(path: path, name: name)
        }
    }

    struct RolloutHead {
        let threadID: String
        let isRoot: Bool
        let directory: String?
    }

    /// Line 1, when it is one `session_meta` naming the thread the file is named
    /// for. A head cut short or unreadable says nothing about whether this is the
    /// root, so the caller binds nothing.
    func readRolloutHead(_ rollout: HeldRollout) async throws -> RolloutHead? {
        let slice = try await files.read(
            RemoteFileRange(path: rollout.path, offset: 0, maxBytes: Self.rolloutHeadLimit))
        guard slice.length != nil, let newline = slice.data.firstIndex(of: UInt8(ascii: "\n")),
            let line = try? JSONDecoder().decode(
                RolloutSessionMeta.self, from: slice.data[slice.data.startIndex..<newline]),
            line.type == "session_meta", let threadID = ConversationReference.canonicalUUID(line.payload.id),
            threadID == ConversationReference.canonicalUUID(rollout.name.threadID)
        else { return nil }
        let payload = line.payload
        let isRoot = payload.parentThreadID == nil && payload.threadSource != "subagent" && payload.sourceIsPlain
        return RolloutHead(
            threadID: threadID, isRoot: isRoot, directory: payload.cwd.flatMap { $0.hasPrefix("/") ? $0 : nil })
    }

    /// `source` is a word for a root (`cli`, `vscode`) and an object naming the
    /// parent for a subagent (Codex CLI 0.165.0, `host-evidence/codex`).
    private struct RolloutSessionMeta: Decodable {
        struct Payload: Decodable {
            let id: String
            let parentThreadID: String?
            let threadSource: String?
            let sourceIsPlain: Bool
            let cwd: String?

            private enum CodingKeys: String, CodingKey {
                case id, cwd, source
                case parentThreadID = "parent_thread_id"
                case threadSource = "thread_source"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                parentThreadID = try? container.decodeIfPresent(String.self, forKey: .parentThreadID)
                threadSource = try? container.decodeIfPresent(String.self, forKey: .threadSource)
                cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
                sourceIsPlain =
                    !container.contains(.source) || (try? container.decode(String.self, forKey: .source)) != nil
            }
        }

        let type: String
        let payload: Payload
    }

    // MARK: Grok Build

    private static let grokHomeVariable = "GROK_HOME"
    /// Rows go when their process ends, so a Host never holds many.
    private static let activeSessionsLimit = 1024 * 1024

    /// The one row whose `pid` and `pid_start` match the Agent's process, or on
    /// Windows, where rows have no `pid_start`, its `pid` and an `opened_at` no
    /// earlier than the process's creation. `/new` adds a second row for the same
    /// process and keeps the first, and nothing says which the screen shows, so two
    /// bind nothing (ADR 0034).
    func checkGrokBuild(_ tree: HerdrCoreTerminalProcesses) async throws -> ChatSessionEvidence {
        guard let pid = agentProcess(in: tree), let process = tree.facts[pid],
            case .value(let start) = process.start, let grokHome = grokHome(of: process)
        else { return cannotTell }
        let path = RemoteFilePath.join(grokHome, "active_sessions.json")
        let slice = try await files.read(RemoteFileRange(path: path, offset: 0, maxBytes: Self.activeSessionsLimit))
        // Any row in another shape could be the one that matches.
        guard slice.length != nil, slice.data.count < Self.activeSessionsLimit,
            let rows = try? JSONDecoder().decode([ActiveSession].self, from: slice.data),
            rows.allSatisfy(hasGrokStart)
        else { return cannotTell }
        let matching = rows.filter { String($0.pid) == pid && matchesGrokStart($0, start: start) }
        guard matching.count == 1, let row = matching.first,
            let session = ConversationReference.lowercaseUUID(row.sessionID)
        else { return cannotTell }
        return .bound(sessionID: session, transcriptRoot: grokHome, directory: startDirectory(row.cwd))
    }

    /// Whether a row says when its process started, in a form this Host's read compares.
    private func hasGrokStart(_ row: ActiveSession) -> Bool {
        row.pidStart != nil || (isOnWindows && row.openedAt != nil)
    }

    /// macOS's read says the second, and the row its microseconds. Windows's says the
    /// creation FILETIME: a row with no `pid_start` matches when Grok Build opened it
    /// after its process was created, so a row an earlier process with a reused pid
    /// left behind cannot.
    private func matchesGrokStart(_ row: ActiveSession, start: String) -> Bool {
        guard let pidStart = row.pidStart else {
            guard isOnWindows, let created = Int64(start),
                let opened = row.openedAt.flatMap(Self.windowsFileTime(ofUTC:))
            else { return false }
            return opened >= created
        }
        guard isOnMacOS else { return String(pidStart) == start }
        return HostProcessReader.macOSStartSeconds(start) == pidStart / 1_000_000
    }

    /// `2026-11-03T07:56:52.816690400Z` as a FILETIME, 100-nanosecond ticks since
    /// 1601 in UTC, exact to its seventh decimal. Nil for any other form.
    static func windowsFileTime(ofUTC text: String) -> Int64? {
        let pattern = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$/
        guard let match = text.wholeMatch(of: pattern),
            let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
            let hour = Int(match.4), let minute = Int(match.5), let second = Int(match.6),
            (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == day else {
            return nil
        }
        let digits = String((match.7.map(String.init) ?? "").prefix(7))
        let ticks = Int64(digits.padding(toLength: 7, withPad: "0", startingAt: 0)) ?? 0
        let seconds = Int64(date.timeIntervalSince1970.rounded()) + Self.fileTimeEpochOffset
        return seconds * 10_000_000 + ticks
    }

    /// Seconds from 1601 to 1970.
    private static let fileTimeEpochOffset: Int64 = 11_644_473_600

    var grokProcessAsk: ProcessAsk {
        ProcessAsk(values: [Self.homeVariable, Self.grokHomeVariable])
    }

    func grokHome(of process: HostProcessReader.Facts) -> String? {
        Self.configRoot(of: process, variable: Self.grokHomeVariable, underHome: ".grok")
    }

    /// One row of `active_sessions.json`. `pid_start` is a JSON number, field 22
    /// of `/proc/<pid>/stat` (Grok Build 1.0.70, `host-evidence/grok/s-flag.json`), and
    /// microseconds since the epoch on macOS (the same, `host-evidence/macos`).
    /// On Windows Grok Build 1.0.70's rows had no `pid_start` at all, only
    /// `opened_at`, such as `2026-11-03T07:56:52.816690400Z`, 2 s after the process's
    /// creation (one machine, herdr-core 0.1.16, 2026-11-03). A row there that has a
    /// `pid_start` is taken to hold the creation FILETIME, and any other number binds
    /// nothing (herdr compatibility).
    private struct ActiveSession: Decodable {
        let sessionID: String
        let pid: Int
        let pidStart: Int64?
        let openedAt: String?
        let cwd: String?

        private enum CodingKeys: String, CodingKey {
            case pid, cwd
            case sessionID = "session_id"
            case pidStart = "pid_start"
            case openedAt = "opened_at"
        }
    }

    // MARK: OpenCode

    /// OpenCode says nothing of its session on the Host, so only an id Heeler gave
    /// it counts: a `heeler.*` hint for this very process, or the launch label,
    /// which a launch writes before any process exists. The foreground's own argv
    /// ties that one to this process, and a Terminal that runs anything else no
    /// longer has it there (ADR 0034).
    func checkOpenCode(
        _ record: HerdrCoreTerminalRecord, tree: HerdrCoreTerminalProcesses
    ) async throws -> ChatSessionEvidence {
        guard let pid = agentProcess(in: tree), let process = tree.facts[pid], process.name == "opencode",
            case .value(let start) = process.start
        else { return cannotTell }
        for hint in await readHints(in: record, tree: tree, pid: pid, start: start) {
            if let session = OpenCodeSessionID(hint.session) {
                return .bound(sessionID: session.rawValue, transcriptRoot: nil, directory: nil)
            }
        }
        guard let label = record.labels[HerdrCoreLaunch.sessionHintLabel],
            let session = OpenCodeSessionID(label), let argv = record.foreground?.argv,
            zip(argv, argv.dropFirst()).contains(where: { $0 == "-s" && $1 == label })
        else { return cannotTell }
        return .bound(sessionID: session.rawValue, transcriptRoot: nil, directory: nil)
    }

    // MARK: Antigravity CLI

    /// A conversation's presence lock, and the data root it is under.
    struct AntigravityLock: Hashable {
        let session: String
        let root: String
    }

    /// agy holds `<data root>/presence/<conversation id>.lock` under an exclusive
    /// lock for the conversation on its screen: from the first prompt of a new one,
    /// and from its start for one it resumes by id. `/clear` and `/fork` move it at
    /// once (agy 1.5.3 on macOS, `host-evidence/agy/presence-lock-1.5.3.json`). Lock
    /// files outlive their process, and a second agy on a conversation already open
    /// holds none, so only a lock the Agent holds open counts, and the brain folder
    /// and database of a conversation it left with `/clear` or `/fork` stay open
    /// and never bind. One lock is the whole proof, so a check reads no file.
    func checkAntigravity(_ tree: HerdrCoreTerminalProcesses) -> ChatSessionEvidence {
        guard let pid = agentProcess(in: tree), let process = tree.facts[pid],
            case .value(let files) = process.openFiles
        else { return cannotTell }
        // lsof lists a file once per descriptor, so the same lock twice is one.
        let held = Set(files.compactMap(Self.antigravityLock(held:)))
        // One process holds one: anything else is a release no recording shows.
        guard held.count == 1, let lock = held.first else { return cannotTell }
        // The root the process really writes under, whatever its `HOME` says.
        return .bound(sessionID: lock.session, transcriptRoot: lock.root, directory: nil)
    }

    /// `<root>/presence/<uuid>.lock`, with a root a read can take. The folder must be
    /// `presence` itself: agy also holds `config/projects/<uuid>.json` and
    /// `brain/<uuid>`, and neither says what the screen shows.
    static func antigravityLock(held path: String) -> AntigravityLock? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[parts.count - 2] == "presence", let leaf = parts.last, leaf.hasSuffix(".lock"),
            let session = ConversationReference.canonicalUUID(String(leaf.dropLast(".lock".count)))
        else { return nil }
        let root = parts.dropLast(2).joined(separator: "/")
        guard RemoteFilePath.isAcceptable(root) else { return nil }
        return AntigravityLock(session: session, root: root)
    }

    /// A conversation whose files an agy process holds: its lock, its brain folder
    /// or its database. A second agy on a conversation already open holds the last
    /// two alone on macOS, which only a confirmation can take (`host-evidence/agy`).
    /// On Linux it holds none, and only its command line names the conversation.
    static func antigravityConversation(held path: String) -> String? {
        if let lock = antigravityLock(held: path) { return lock.session }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, RemoteFilePath.isAcceptable(path), let leaf = parts.last else { return nil }
        switch parts[parts.count - 2] {
        case "brain": return ConversationReference.canonicalUUID(String(leaf))
        case "conversations" where leaf.hasSuffix(".db"):
            return ConversationReference.canonicalUUID(String(leaf.dropLast(".db".count)))
        default: return nil
        }
    }

    /// `HOME`, for the data root a pick and the candidate list read under.
    var antigravityProcessAsk: ProcessAsk {
        ProcessAsk(values: [Self.homeVariable], readsOpenFiles: true)
    }

    /// `~/.gemini/antigravity-cli` under the Agent's own `HOME`. No variable is known
    /// to move it: agy 1.5.3 kept it in place with `ANTIGRAVITY_APP_DATA_DIR` set, and
    /// the binary's other `ANTIGRAVITY_*` names were not tried. So nothing else is asked.
    func antigravityRoot(of process: HostProcessReader.Facts) -> String? {
        guard case .value(let home)? = process.variables[Self.homeVariable], RemoteFilePath.isAcceptable(home) else {
            return nil
        }
        return RemoteFilePath.join(home, AgyTranscriptLocator.defaultRoot)
    }
}
