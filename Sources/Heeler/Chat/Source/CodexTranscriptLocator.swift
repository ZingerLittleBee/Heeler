import Foundation

/// One rollout file of a Codex thread.
struct CodexRolloutSegment: Hashable, Sendable {
    let path: String
    let name: CodexRolloutFileName
}

/// Where a Codex thread's rollout files live on the Host.
struct CodexTranscriptLocation: Hashable, Sendable {
    /// The thread's readable segments, oldest first. The last is the live
    /// segment Codex appends to; a revert's segment names its base segment
    /// in its `session_meta`, which may be any earlier one.
    let segments: [CodexRolloutSegment]

    var live: CodexRolloutSegment? { segments.last }
}

enum CodexTranscriptUnavailable: Error, Hashable, Sendable {
    /// No searched directory holds the thread's rollout. Codex writes the
    /// file only after the first prompt.
    case notFound
    /// The newest segment is compressed (`.jsonl.zst`).
    case compressed
    /// The newest file's `session_meta` names a different thread.
    case mismatched
}

/// Finds a Codex thread's rollout under `~/.codex`.
///
/// Rollouts live in `sessions/YYYY/MM/DD/` by the Host's local date when the
/// thread started, which the version 7 UUID's timestamp gives to within a
/// day of time zone. A revert writes its new segment under the date it
/// happened, so today's neighbourhood is searched too; archiving moves files
/// unchanged into the flat `archived_sessions/`. Directory listings are
/// filtered on the Host by the thread id, so a busy day costs only matches.
struct CodexTranscriptLocator: Sendable {
    let files: ChatHostFiles
    let now: @Sendable () -> Date

    init(files: ChatHostFiles, now: @escaping @Sendable () -> Date = { Date() }) {
        self.files = files
        self.now = now
    }

    func locate(threadID: String) async throws -> Result<CodexTranscriptLocation, CodexTranscriptUnavailable> {
        let home = try await files.home()
        let root = RemoteFilePath.join(home, ".codex")
        var segments: [CodexRolloutSegment] = []
        for date in Self.dateDirectories(threadID: threadID, now: now()) {
            segments += try await matches(
                in: RemoteFilePath.join(root, "sessions", date), threadID: threadID)
        }
        if segments.isEmpty {
            segments = try await matches(
                in: RemoteFilePath.join(root, "archived_sessions"), threadID: threadID)
        }
        let ordered = Set(segments).sorted { CodexRolloutFileName.isOrderedBefore($0.name, $1.name) }
        guard let newest = ordered.last else { return .failure(.notFound) }
        guard !newest.name.isCompressed else { return .failure(.compressed) }
        guard try await sessionMetaNames(threadID, in: newest.path) else {
            return .failure(.mismatched)
        }
        // A plain copy shadows a compressed one of the same segment.
        let readable = ordered.filter { segment in
            !segment.name.isCompressed
        }
        return .success(CodexTranscriptLocation(segments: readable))
    }

    private func matches(in directory: String, threadID: String) async throws -> [CodexRolloutSegment] {
        let listing = try await files.list(
            RemoteFileListingRequest(
                directory: directory, kinds: [.regular, .symlink], namePrefix: "rollout-",
                nameSuffixes: [".jsonl", ".jsonl.zst"], nameContains: threadID,
                maximumEntries: 200))
        return (listing?.entries ?? []).compactMap { entry in
            guard let name = CodexRolloutFileName(fileName: entry.name), name.threadID == threadID
            else { return nil }
            return CodexRolloutSegment(path: RemoteFilePath.join(directory, entry.name), name: name)
        }
    }

    /// `YYYY/MM/DD` for the day before, of and after the thread's creation
    /// and today, in UTC: a Host's local date is within a day of it.
    static func dateDirectories(threadID: String, now: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var days: [String] = []
        for anchor in [CodexThreadID.creationDate(of: threadID), now].compactMap(\.self) {
            for offset in -1...1 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: anchor) else {
                    continue
                }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day
                else { continue }
                let text = "\(padded(year, 4))/\(padded(month, 2))/\(padded(dayOfMonth, 2))"
                if !days.contains(text) { days.append(text) }
            }
        }
        return days
    }

    private static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// Line 1 of a rollout is its `session_meta`, whose `payload.id` is the
    /// thread id across reverts. The line carries the base instructions, so
    /// it can run to tens of kilobytes; a line longer than 1 MiB is accepted
    /// on its file name.
    private func sessionMetaNames(_ threadID: String, in path: String) async throws -> Bool {
        switch try await files.firstLine(of: path, initialBytes: 64 << 10, limit: 1 << 20) {
        case .line(let data):
            guard let meta = try? JSONDecoder().decode(SessionMetaLine.self, from: data),
                meta.type == "session_meta"
            else { return false }
            return meta.payload?.id?.lowercased() == threadID
        case .unterminated, .tooLong:
            return true
        case nil:
            return false
        }
    }

    private struct SessionMetaLine: Decodable {
        struct Payload: Decodable {
            let id: String?
        }
        let type: String?
        let payload: Payload?
    }
}
