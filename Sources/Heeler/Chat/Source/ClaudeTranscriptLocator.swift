import Foundation

/// Where a Claude Code session's transcript lives on the Host.
struct ClaudeTranscriptLocation: Hashable, Sendable {
    /// `<config>/projects/<key>`, which also holds the session's subagent
    /// transcripts under `<session>/subagents/`.
    let projectDirectory: String
    let transcriptPath: String
    let sessionID: String

    /// A subagent's own transcript, by the `agentId` its launch reported.
    func subagentTranscriptPath(agentID: String) -> String? {
        guard Self.isSafeComponent(agentID) else { return nil }
        return RemoteFilePath.join(
            projectDirectory, sessionID, "subagents", "agent-\(agentID).jsonl")
    }

    /// Agent ids are short hex strings; anything that could leave the
    /// directory is refused.
    static func isSafeComponent(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 128
            && text.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
    }
}

enum ClaudeTranscriptUnavailable: Error, Hashable, Sendable {
    /// No searched directory holds the session's file. `searchedAll` is false
    /// when a listing was cut short or the stat budget ran out, so the file
    /// may still exist. Claude also writes nothing before the first prompt.
    case notFound(searchedAll: Bool)
    /// A file with the session's name holds a different session or a
    /// subagent's transcript.
    case mismatched
}

/// Finds a Claude Code session transcript under `~/.claude/projects`.
///
/// Claude files a session under the key of the directory it started in, so
/// the Agent's current and launch directories are tried first, both
/// NFC-normalized and as reported. A key over 200 characters ends in a hash
/// the CLI may compute differently, so directories sharing its prefix are
/// listed. Last, every project directory is tried, closest name first,
/// within a stat budget: `/cd` moves a session to another directory.
struct ClaudeTranscriptLocator: Sendable {
    let files: ChatHostFiles
    var statBudget = 200
    var projectListingLimit = 1_000

    init(files: ChatHostFiles) {
        self.files = files
    }

    func locate(
        sessionID: String, directories: [String]
    ) async throws -> Result<ClaudeTranscriptLocation, ClaudeTranscriptUnavailable> {
        let home = try await files.home()
        let projects = RemoteFilePath.join(home, ".claude", "projects")
        let fileName = "\(sessionID).jsonl"
        let plan = Self.plan(directories: directories)
        var tried = Set<String>()
        var stats = 0
        var sawMismatch = false

        func attempt(_ key: String) async throws -> ClaudeTranscriptLocation? {
            guard tried.insert(key).inserted else { return nil }
            let directory = RemoteFilePath.join(projects, key)
            let path = RemoteFilePath.join(directory, fileName)
            stats += 1
            guard let status = try await files.status(path), Self.isUsable(status) else { return nil }
            switch try await verify(path: path, sessionID: sessionID) {
            case true:
                return ClaudeTranscriptLocation(
                    projectDirectory: directory, transcriptPath: path, sessionID: sessionID)
            case false:
                sawMismatch = true
                return nil
            }
        }

        for key in plan.exactKeys {
            if let found = try await attempt(key) { return .success(found) }
        }
        for prefix in plan.longKeyPrefixes {
            let listing = try await files.list(
                RemoteFileListingRequest(
                    directory: projects, kinds: [.directory, .symlink], namePrefix: prefix,
                    maximumEntries: 100))
            for entry in listing?.entries ?? [] {
                if let found = try await attempt(entry.name) { return .success(found) }
            }
        }
        guard
            let listing = try await files.list(
                RemoteFileListingRequest(
                    directory: projects, kinds: [.directory, .symlink],
                    maximumEntries: projectListingLimit, maximumScanned: 20_000))
        else {
            return .failure(sawMismatch ? .mismatched : .notFound(searchedAll: true))
        }
        let ordered = Self.byClosestName(listing.entries.map(\.name), to: plan.exactKeys.first ?? "")
        var searchedAll = !listing.truncated && !listing.scanIncomplete
        for name in ordered where !tried.contains(name) {
            guard stats < statBudget else {
                searchedAll = false
                break
            }
            if let found = try await attempt(name) { return .success(found) }
        }
        return .failure(sawMismatch ? .mismatched : .notFound(searchedAll: searchedAll))
    }

    struct Plan: Equatable, Sendable {
        /// Directory names to stat directly, most likely first.
        let exactKeys: [String]
        /// Prefixes of over-long keys whose hash may differ.
        let longKeyPrefixes: [String]
    }

    static func plan(directories: [String]) -> Plan {
        var keys: [String] = []
        var prefixes: [String] = []
        for directory in directories where directory.hasPrefix("/") {
            for key in [
                ClaudeProjectKey.key(forDirectory: directory),
                ClaudeProjectKey.unnormalizedKey(forDirectory: directory),
            ] where !keys.contains(key) {
                keys.append(key)
            }
            if let prefix = ClaudeProjectKey.longKeyPrefix(forDirectory: directory),
                !prefixes.contains(prefix)
            {
                prefixes.append(prefix)
            }
        }
        return Plan(exactKeys: keys, longKeyPrefixes: prefixes)
    }

    /// Names sharing the longest prefix with `key` first, then by name.
    static func byClosestName(_ names: [String], to key: String) -> [String] {
        let key = Array(key.utf8)
        func shared(_ name: String) -> Int {
            zip(name.utf8, key).prefix { $0 == $1 }.count
        }
        return names
            .map { (name: $0, shared: shared($0)) }
            .sorted { $0.shared != $1.shared ? $0.shared > $1.shared : $0.name < $1.name }
            .map(\.name)
    }

    /// The SDK treats an empty file as "not here": Claude creates the file
    /// before writing its first record.
    static func isUsable(_ status: RemoteFileStatus) -> Bool {
        (status.kind == nil || status.kind == .regular) && (status.size ?? 0) > 0
    }

    /// Checks the head: the first record naming a session must name this
    /// one, and the first conversation record must not be a subagent's
    /// (subagent transcripts carry their parent's session id). A head with
    /// no complete line to check is accepted on its name.
    private func verify(path: String, sessionID: String) async throws -> Bool {
        var length = 4 << 10
        while true {
            guard let head = try await files.read(path: path, from: 0, to: UInt64(length), chunk: 64 << 10)
            else { return false }
            let verdict = Self.headVerdict(head, sessionID: sessionID)
            if let verdict { return verdict }
            if head.count < length || length >= 64 << 10 { return true }
            length = 64 << 10
        }
    }

    /// True or false once the head decides; nil when it needs more bytes.
    static func headVerdict(_ head: Data, sessionID: String) -> Bool? {
        var sawSession = false
        var sawChainRecord = false
        for line in JSONLLineFramer.lines(in: head) {
            guard let record = try? JSONDecoder().decode(HeadRecord.self, from: line.data) else {
                continue
            }
            if !sawSession, let id = record.sessionId {
                guard id.lowercased() == sessionID else { return false }
                sawSession = true
            }
            if !sawChainRecord, record.uuid != nil {
                guard record.isSidechain != true, record.agentId == nil else { return false }
                sawChainRecord = true
            }
            if sawSession, sawChainRecord { return true }
        }
        return nil
    }

    private struct HeadRecord: Decodable {
        let sessionId: String?
        let uuid: String?
        let isSidechain: Bool?
        let agentId: String?
    }
}
