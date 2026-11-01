import Foundation

/// The evidence ADR 0034 names for Codex, Grok Build and OpenCode. None of it
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
    private static let codexHomeVariable = "CODEX_HOME"
    /// `app-server --managed-daemon`, and its `app-server daemon pid-update-loop`.
    private static let codexDaemonArguments = ["--managed-daemon", "app-server", "pid-update-loop"]

    /// Embedded Codex holds its own rollout from the first prompt. The shared
    /// daemon holds every window's and no window holds any, so a daemon under the
    /// Agent, or a launch on the shared server while its socket exists, gets no
    /// binding (ADR 0034).
    func checkCodex(_ record: HerdrCoreTerminalRecord) async throws -> ChatSessionEvidence {
        guard
            let tree = try await readTerminalProcesses(
                of: record, values: ["HOME", Self.codexHomeVariable], arguments: Self.codexDaemonArguments,
                readsOpenFiles: true),
            let pid = tree.agent(isAgent: { $0?.name == "codex" }, skips: Self.isCodexDaemon),
            let process = tree.facts[pid],
            let codexHome = Self.configRoot(of: process, variable: Self.codexHomeVariable, underHome: ".codex")
        else { return cannotTell }
        if tree.descendants.contains(where: { Self.isManagedDaemon(tree.facts[$0]) }) {
            return .unavailable(.codexSharedDaemon)
        }
        let rollouts = Self.rollouts(heldBy: process)
        if rollouts.isEmpty {
            guard CodexLaunch.launchesOnSharedServer(foreground: record.foreground) == true,
                try await files.status(CodexLaunch.controlSocketPath(codexHome: codexHome)) != nil
            else { return cannotTell }
            return .unavailable(.codexSharedDaemon)
        }
        guard rollouts.count <= Self.heldRolloutLimit,
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

    private static func isManagedDaemon(_ process: HostProcessReader.Facts?) -> Bool {
        guard case .value(let arguments)? = process?.arguments else { return false }
        return arguments.contains("--managed-daemon")
    }

    private static func isCodexDaemon(_ process: HostProcessReader.Facts?) -> Bool {
        guard case .value(let arguments)? = process?.arguments else { return false }
        return arguments.contains("--managed-daemon")
            || (arguments.contains("app-server") && arguments.contains("pid-update-loop"))
    }

    private struct HeldRollout {
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
    private static func rollouts(heldBy process: HostProcessReader.Facts) -> [HeldRollout] {
        guard case .value(let files) = process.openFiles else { return [] }
        return files.compactMap { path in
            guard path.contains("/sessions/") || path.contains("/archived_sessions/"),
                let leaf = path.split(separator: "/").last,
                let name = CodexRolloutFileName(fileName: String(leaf)), !name.isCompressed
            else { return nil }
            return HeldRollout(path: path, name: name)
        }
    }

    private struct RolloutHead {
        let threadID: String
        let isRoot: Bool
        let directory: String?
    }

    /// Line 1, when it is one `session_meta` naming the thread the file is named
    /// for. A head cut short or unreadable says nothing about whether this is the
    /// root, so the caller binds nothing.
    private func readRolloutHead(_ rollout: HeldRollout) async throws -> RolloutHead? {
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

    /// The one row whose `pid` and `pid_start` match the Agent's process. `/new`
    /// adds a second row for the same process and keeps the first, and nothing
    /// says which the screen shows, so two bind nothing (ADR 0034).
    func checkGrokBuild(_ record: HerdrCoreTerminalRecord) async throws -> ChatSessionEvidence {
        guard
            let tree = try await readTerminalProcesses(of: record, values: ["HOME", Self.grokHomeVariable]),
            let pid =
                isOnWindows
                ? tree.agentOnWindows(isAgent: { $0?.name == "grok" }) : tree.agent(isAgent: { $0?.name == "grok" }),
            let process = tree.facts[pid], case .value(let start) = process.start,
            let grokHome = Self.configRoot(of: process, variable: Self.grokHomeVariable, underHome: ".grok")
        else { return cannotTell }
        let path = RemoteFilePath.join(grokHome, "active_sessions.json")
        let slice = try await files.read(RemoteFileRange(path: path, offset: 0, maxBytes: Self.activeSessionsLimit))
        // Any row in another shape could be the one that matches.
        guard slice.length != nil, slice.data.count < Self.activeSessionsLimit,
            let rows = try? JSONDecoder().decode([ActiveSession].self, from: slice.data)
        else { return cannotTell }
        let matching = rows.filter { String($0.pid) == pid && String($0.pidStart) == start }
        guard matching.count == 1, let row = matching.first,
            let session = ConversationReference.lowercaseUUID(row.sessionID)
        else { return cannotTell }
        return .bound(sessionID: session, transcriptRoot: grokHome, directory: startDirectory(row.cwd))
    }

    /// One row of `active_sessions.json`. `pid_start` is a JSON number, field 22
    /// of `/proc/<pid>/stat` (Grok Build 1.0.70, `host-evidence/grok/s-flag.json`).
    /// On Windows it is taken to be the creation FILETIME, which no row has shown yet
    /// (herdr compatibility): any other number binds nothing.
    private struct ActiveSession: Decodable {
        let sessionID: String
        let pid: Int
        let pidStart: Int64
        let cwd: String?

        private enum CodingKeys: String, CodingKey {
            case pid, cwd
            case sessionID = "session_id"
            case pidStart = "pid_start"
        }
    }

    // MARK: OpenCode

    /// OpenCode says nothing of its session on the Host, so only an id Heeler gave
    /// it counts: a `heeler.*` hint for this very process, or the launch label,
    /// which a launch writes before any process exists. The foreground's own argv
    /// ties that one to this process, and a Terminal that runs anything else no
    /// longer has it there (ADR 0034).
    func checkOpenCode(_ record: HerdrCoreTerminalRecord) async throws -> ChatSessionEvidence {
        guard
            let tree = try await readTerminalProcesses(of: record),
            let pid = tree.agent(isAgent: { $0?.name == "opencode" }),
            let process = tree.facts[pid], process.name == "opencode", case .value(let start) = process.start
        else { return cannotTell }
        for hint in await readHints(in: record, pid: pid, start: start) {
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
}
