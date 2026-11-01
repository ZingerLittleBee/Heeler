import Foundation

/// A conversation the user could confirm as the one an Agent is in (ADR 0034).
struct ChatSessionCandidate: Identifiable, Equatable, Sendable {
    /// Why it is listed. None of these says the Agent is in it.
    enum Origin: Hashable, Sendable {
        /// The Agent's process holds its file open.
        case heldOpen
        /// A Program Status record names it, which also happens for another
        /// Terminal's session (herdr compatibility).
        case programStatus
        /// One of the newest Transcripts in the Agent's directory.
        case recentTranscript
    }

    let sessionID: String
    /// Set where the program's reference is its file: Pi and Oh My Pi.
    let file: String?
    var title: String?
    var modified: Date?
    var origins: Set<Origin>

    var id: String { sessionID }
    /// How Chat reads this conversation.
    var conversationID: String { file ?? sessionID }
}

/// One listing for one Agent process: what a confirmation binds to.
struct ChatSessionCandidates: Equatable, Sendable {
    let pid: Int
    let start: String
    /// Where the Agent's own process says its Transcripts are.
    let transcriptRoot: String?
    /// Where the Agent runs and was started, most current first.
    let directories: [String]
    /// The core this listing's address means.
    var core: String?
    let candidates: [ChatSessionCandidate]
}

enum ChatCandidatesAnswer: Equatable, Sendable {
    case listed(ChatSessionCandidates)
    /// Every daemon window's sessions look alike, so it gets no list (ADR 0034).
    case sharedDaemon
    /// Nothing on the Host names the Agent's process, which a choice binds to.
    case noProcess
}

/// Lists what a user could confirm when a check finds no exact evidence. It runs
/// only when asked for, and nothing it finds binds: the user reads a conversation
/// before choosing it. One exec, as a check is, then the listings it takes.
extension HerdrCoreSessionBinder {
    /// The newest Transcripts offered per directory.
    static let recentCandidateLimit = 12
    /// A Codex rollout's directory takes reading its head, so a listing stops here.
    private static let rolloutHeadBudget = 24
    private static let rolloutDaysBack = 7

    func candidates(of record: HerdrCoreTerminalRecord) async throws -> ChatCandidatesAnswer {
        var ask = processAsk
        ask.readsOpenFiles = true
        guard let tree = try await readTerminalProcesses(of: record, ask: ask),
            let pid = agentProcess(in: tree), let process = tree.facts[pid], let number = Int(pid),
            case .value(let start) = process.start
        else { return .noProcess }
        if program == .codex, try await isCodexOnSharedDaemon(record, tree: tree, process: process) {
            return .sharedDaemon
        }
        let root = transcriptRoot(of: process)
        if root == nil, program != .opencode { return .noProcess }
        let directories = Self.directories(of: record)
        var found: [String: ChatSessionCandidate] = [:]
        func add(_ session: String, file: String? = nil, origin: ChatSessionCandidate.Origin, modified: UInt32? = nil) {
            var candidate =
                found[session]
                ?? ChatSessionCandidate(sessionID: session, file: file, origins: [])
            candidate.origins.insert(origin)
            if let modified { candidate.modified = Date(timeIntervalSince1970: TimeInterval(modified)) }
            found[session] = candidate
        }

        for held in try await heldConversations(of: process) { add(held.session, file: held.file, origin: .heldOpen) }
        for key in record.records.keys {
            if let session = statusChildConversation(key) { add(session, origin: .programStatus) }
        }
        for recent in try await recentConversations(root: root, process: process, directories: directories) {
            add(recent.session, file: recent.file, origin: .recentTranscript, modified: recent.modified)
            if let title = recent.title { found[recent.session]?.title = title }
        }

        let ordered = found.values.sorted { lhs, rhs in
            func rank(_ candidate: ChatSessionCandidate) -> Int {
                if candidate.origins.contains(.heldOpen) { return 0 }
                return candidate.origins.contains(.programStatus) ? 1 : 2
            }
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            let (left, right) = (lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
            return left != right ? left > right : lhs.sessionID < rhs.sessionID
        }
        return .listed(
            ChatSessionCandidates(
                pid: number, start: start, transcriptRoot: root, directories: directories, candidates: ordered))
    }

    private static func directories(of record: HerdrCoreTerminalRecord) -> [String] {
        var directories: [String] = []
        for directory in [record.foreground?.cwd, record.cwd].compactMap({ $0 })
        where RemoteFilePath.isAcceptable(directory) && !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }

    private struct Found {
        let session: String
        var file: String?
        var modified: UInt32?
        var title: String?
    }

    /// A Program Status record's key, when it reads as this program's session id.
    /// Grok Build's recorded keys are `s0`, `s1`, which name no conversation
    /// (`host-evidence/grok/s-flag-core-events.ndjson`).
    private func statusChildConversation(_ key: String) -> String? {
        switch program {
        case .claude, .codex, .pi, .omp: ConversationReference.canonicalUUID(key)
        case .grok: ConversationReference.lowercaseUUID(key)
        case .opencode: OpenCodeSessionID(key)?.rawValue
        }
    }

    // MARK: Held open

    private func heldConversations(of process: HostProcessReader.Facts) async throws -> [Found] {
        guard case .value(let paths) = process.openFiles else { return [] }
        if program == .codex { return try await heldCodexRoots(of: process) }
        var seen = Set<String>()
        return paths.compactMap { path -> Found? in
            guard let found = heldConversation(path), seen.insert(found.session).inserted else { return nil }
            return found
        }
    }

    private func heldConversation(_ path: String) -> Found? {
        let parts = path.split(separator: "/").map(String.init)
        guard let leaf = parts.last else { return nil }
        switch program {
        case .claude:
            guard path.contains("/projects/"), !path.contains("/subagents/"), leaf.hasSuffix(".jsonl"),
                let session = ConversationReference.canonicalUUID(String(leaf.dropLast(".jsonl".count)))
            else { return nil }
            return Found(session: session)
        case .grok:
            guard parts.count >= 4, parts[parts.count - 4] == "sessions",
                let session = ConversationReference.lowercaseUUID(parts[parts.count - 2])
            else { return nil }
            return Found(session: session)
        case .opencode:
            for part in parts.reversed() {
                let stem = part.split(separator: ".").first.map(String.init) ?? part
                if let session = OpenCodeSessionID(stem) { return Found(session: session.rawValue) }
            }
            return nil
        case .pi, .omp:
            guard let session = Self.piSession(inFileName: leaf), RemoteFilePath.isAcceptable(path) else { return nil }
            return Found(session: session, file: path)
        case .codex:
            return nil
        }
    }

    /// The UUID ending a Pi or Oh My Pi session file's name.
    private static func piSession(inFileName name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropLast(".jsonl".count)
        guard stem.count >= 36 else { return nil }
        return ConversationReference.canonicalUUID(String(stem.suffix(36)))
    }

    private func heldCodexRoots(of process: HostProcessReader.Facts) async throws -> [Found] {
        var found: [Found] = []
        for rollout in Self.rollouts(heldBy: process).prefix(Self.heldRolloutLimit) {
            guard let head = try await readRolloutHead(rollout), head.isRoot else { continue }
            found.append(Found(session: head.threadID))
        }
        return found
    }

    // MARK: Recent in the directory

    private func recentConversations(
        root: String?, process: HostProcessReader.Facts, directories: [String]
    ) async throws -> [Found] {
        switch program {
        case .claude: return try await recentClaudeCode(root: root, directories: directories)
        case .codex: return try await recentCodex(root: root, directories: directories)
        case .grok: return try await recentGrokBuild(root: root, directories: directories)
        case .opencode: return try await recentOpenCode(directories: directories)
        case .pi, .omp: return try await recentPiFamily(root: root, process: process, directories: directories)
        }
    }

    private static func newest(_ found: [Found]) -> [Found] {
        Array(found.sorted { ($0.modified ?? 0) > ($1.modified ?? 0) }.prefix(recentCandidateLimit))
    }

    private func recentClaudeCode(root: String?, directories: [String]) async throws -> [Found] {
        guard let root else { return [] }
        var found: [Found] = []
        for key in ClaudeTranscriptLocator.plan(directories: directories).exactKeys {
            let listing = try await files.list(
                RemoteFileListingRequest(
                    directory: RemoteFilePath.join(root, "projects", key), kinds: [.regular], nameSuffixes: [".jsonl"]))
            for entry in listing?.entries ?? [] where (entry.status.size ?? 0) > 0 {
                if let session = ConversationReference.canonicalUUID(String(entry.name.dropLast(".jsonl".count))) {
                    found.append(Found(session: session, modified: entry.status.modificationTime))
                }
            }
        }
        return Self.newest(found)
    }

    /// Codex files by day rather than by directory, so a rollout counts once its
    /// `session_meta` says it started here. The Host's clock names the folders, and
    /// a week back from this device's clock covers any zone.
    private func recentCodex(root: String?, directories: [String]) async throws -> [Found] {
        guard let root else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let today = now()
        var budget = Self.rolloutHeadBudget
        var found: [Found] = []
        for back in -1...Self.rolloutDaysBack where budget > 0 && found.count < Self.recentCandidateLimit {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
            let folder = RemoteFilePath.join(
                root, "sessions", String(format: "%04d", year), String(format: "%02d", month),
                String(format: "%02d", date))
            let listing = try await files.list(
                RemoteFileListingRequest(
                    directory: folder, kinds: [.regular], namePrefix: "rollout-", nameSuffixes: [".jsonl"]))
            for entry in (listing?.entries ?? []).sorted(by: { $0.name > $1.name })
            where budget > 0 && found.count < Self.recentCandidateLimit {
                guard let name = CodexRolloutFileName(fileName: entry.name) else { continue }
                budget -= 1
                guard
                    let head = try await readRolloutHead(
                        HeldRollout(path: RemoteFilePath.join(folder, entry.name), name: name)),
                    head.isRoot, let directory = head.directory, directories.contains(directory)
                else { continue }
                found.append(Found(session: head.threadID, modified: entry.status.modificationTime))
            }
        }
        return found
    }

    /// A directory past Grok's longest group name files under a slug and hash, whose
    /// `.cwd` a listing would have to read. Those offer what the process holds.
    private func recentGrokBuild(root: String?, directories: [String]) async throws -> [Found] {
        guard let root else { return [] }
        var found: [Found] = []
        for directory in directories {
            guard let group = GrokTranscriptLocator.groupName(forDirectory: directory) else { continue }
            let listing = try await files.list(
                RemoteFileListingRequest(directory: RemoteFilePath.join(root, "sessions", group), kinds: [.directory]))
            for entry in listing?.entries ?? [] {
                if let session = ConversationReference.lowercaseUUID(entry.name) {
                    found.append(Found(session: session, modified: entry.status.modificationTime))
                }
            }
        }
        return Self.newest(found)
    }

    private func recentOpenCode(directories: [String]) async throws -> [Found] {
        guard let query = files.queryOpenCode else { return [] }
        var found: [Found] = []
        for directory in directories {
            let request = OpenCodeQuery(session: nil, kind: .recentSessions(directory: directory, limit: Self.recentCandidateLimit))
            guard case .records(let records) = try await query(request) else { continue }
            for row in records.recentSessions {
                guard let session = OpenCodeSessionID(row.id) else { continue }
                found.append(
                    Found(
                        session: session.rawValue, modified: UInt32(clamping: row.updated / 1000),
                        title: row.title))
            }
        }
        return Self.newest(found)
    }

    private func recentPiFamily(
        root: String?, process: HostProcessReader.Facts, directories: [String]
    ) async throws -> [Found] {
        guard let root else { return [] }
        var folders = directories.map { RemoteFilePath.join(root, PiTranscriptLocator.projectKey($0)) }
        // A folder from `PI_CODING_AGENT_SESSION_DIR` holds its files directly.
        folders.append(root)
        // Oh My Pi also uses home-relative keys in recent releases.
        if program == .omp, case .value(let home)? = process.variables[Self.homeVariable] {
            for directory in directories where directory.hasPrefix(home + "/") {
                folders.append(
                    RemoteFilePath.join(root, PiTranscriptLocator.homeRelativeKey(String(directory.dropFirst(home.count + 1)))))
            }
        }
        var found: [Found] = []
        for folder in folders {
            let listing = try await files.list(
                RemoteFileListingRequest(directory: folder, kinds: [.regular], nameSuffixes: [".jsonl"]))
            for entry in listing?.entries ?? [] where (entry.status.size ?? 0) > 0 {
                let path = RemoteFilePath.join(folder, entry.name)
                if let session = Self.piSession(inFileName: entry.name), RemoteFilePath.isAcceptable(path) {
                    found.append(Found(session: session, file: path, modified: entry.status.modificationTime))
                }
            }
        }
        return Self.newest(found)
    }
}
