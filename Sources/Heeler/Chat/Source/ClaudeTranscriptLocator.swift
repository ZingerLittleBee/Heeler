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

    /// Where a Workflow run records its agents:
    /// `<session>/subagents/workflows/<runId>/journal.jsonl` beside the
    /// transcript at `transcriptPath`. Only the run id comes from the
    /// transcript, so it must stay one path component.
    static func workflowJournalPath(transcriptPath: String, runID: String) -> String? {
        guard transcriptPath.hasSuffix(".jsonl"), isWorkflowRunID(runID) else { return nil }
        let session = String(transcriptPath.dropLast(".jsonl".count))
        let path = RemoteFilePath.join(session, "subagents", "workflows", runID, "journal.jsonl")
        return RemoteFilePath.isAcceptable(path) ? path : nil
    }

    /// `wf_` and up to 61 ASCII letters, digits or hyphens. Claude Code
    /// writes twelve (`wf_2d6c7df2-dc3`); a longer id still reads.
    static func isWorkflowRunID(_ id: String) -> Bool {
        guard id.hasPrefix("wf_") else { return false }
        let rest = id.utf8.dropFirst(3)
        return (1...61).contains(rest.count)
            && rest.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || byte == UInt8(ascii: "-")
            }
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
    /// when a listing was cut short, the stat budget ran out, or the search
    /// kept to the Agent's directories, so the file may still exist.
    case notFound(searchedAll: Bool)
    /// No searched directory holds the file, but Claude started the session
    /// under this home: it writes the file with the first message.
    case notWritten
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
///
/// A session with no file anywhere may be new: Claude Code makes
/// `session-env/<id>` when it starts a session, before running the
/// SessionStart hooks that report it to herdr, keeps it after the session
/// ends, and writes the transcript only with the first message (2.1.312).
struct ClaudeTranscriptLocator: Sendable {
    let files: ChatHostFiles
    var statBudget = 200
    var projectListingLimit = 1_000

    init(files: ChatHostFiles) {
        self.files = files
    }

    /// `searchesEveryProject` false keeps to the Agent's directories, a
    /// few stats, for a new session whose file comes under one of them.
    func locate(
        sessionID: String, directories: [String], searchesEveryProject: Bool = true
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
        guard searchesEveryProject else {
            return .failure(sawMismatch ? .mismatched : .notFound(searchedAll: false))
        }
        func missing(searchedAll: Bool) async throws -> ClaudeTranscriptUnavailable {
            if sawMismatch { return .mismatched }
            return try await sessionStarted(home: home, sessionID: sessionID)
                ? .notWritten : .notFound(searchedAll: searchedAll)
        }
        guard
            let listing = try await files.list(
                RemoteFileListingRequest(
                    directory: projects, kinds: [.directory, .symlink],
                    maximumEntries: projectListingLimit, maximumScanned: 20_000))
        else {
            return .failure(try await missing(searchedAll: true))
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
        return .failure(try await missing(searchedAll: searchedAll))
    }

    /// Whether Claude Code started the session under `home`: its
    /// `session-env/<id>` is a directory. One the Host won't let Heeler
    /// see is no sign either way.
    private func sessionStarted(home: String, sessionID: String) async throws -> Bool {
        let path = RemoteFilePath.join(home, ".claude", "session-env", sessionID)
        do {
            guard let status = try await files.status(path) else { return false }
            return status.kind == nil || status.kind == .directory
        } catch TransportError.hostFileUnreadable {
            return false
        }
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
