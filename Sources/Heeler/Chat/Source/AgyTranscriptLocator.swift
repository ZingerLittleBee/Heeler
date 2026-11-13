import Foundation

/// Finds an Antigravity CLI conversation's transcript,
/// `brain/<id>/.system_generated/logs/transcript_full.jsonl` under
/// `~/.gemini/antigravity-cli`, then under each added Account's directory.
/// No environment variable is known to move that directory (agy 1.5.3 kept
/// it in place with `ANTIGRAVITY_APP_DATA_DIR` set; the binary's other
/// `ANTIGRAVITY_*` names were not tried), so on Herdr TUI another one is
/// searched only once it is an Account. On herdr-core `configRoot` is the
/// one directory searched.
///
/// The folder is named for the conversation's id, so the lookup is direct:
/// no directory is bucketed by project. Chat reads the full file, whose tool
/// arguments are JSON values; `transcript.jsonl` beside it cuts long fields
/// and encodes every argument as a string.
///
/// The folder can be there before the first message, which brings the file,
/// so a folder without it is a conversation still to start.
///
/// Subagents run in the same `agy` process and fire herdr's `PreInvocation`
/// hook with their own `conversationId` while the terminal stays in the
/// top-level conversation. A subagent's transcript begins with a
/// `SYSTEM_MESSAGE` naming its parent in `[Message] timestamp=… sender=<id>`,
/// optionally after a `SYSTEM_SDK` reminder, so locating walks `sender=<id>`
/// in the same root up to the top-level conversation's transcript.
struct AgyTranscriptLocator: Sendable {
    enum Failure: Error, Equatable, Sendable {
        /// No directory holds the conversation's folder.
        case notFound
        /// The conversation's folder is there without its transcript yet.
        case notWritten
    }

    /// The default directory, under the Host's home.
    static let defaultRoot = ".gemini/antigravity-cli"

    private static let headBytes: UInt64 = 4 << 10
    private static let maximumParentHops = 8

    let files: ChatHostFiles

    func locate(sessionID: String, configRoot: String? = nil) async throws -> Result<String, Failure> {
        // The folder's name is the id as agy writes it: a lowercase UUID.
        guard let id = ConversationReference.canonicalUUID(sessionID) else { return .failure(.notFound) }
        let roots: [String]
        if let configRoot {
            roots = [configRoot]
        } else {
            let home = try await files.home()
            roots = try await files.configRoots(
                for: .antigravity, defaultRoot: RemoteFilePath.join(home, Self.defaultRoot))
        }
        var sawUnwritten = false
        let found = try await ChatHostFiles.firstAnswer(across: roots) { root -> String? in
            let folder = Self.folder(in: root, id: id)
            guard RemoteFilePath.isAcceptable(folder),
                let status = try await files.status(folder), status.kind == nil || status.kind == .directory
            else { return nil }
            let path = Self.transcriptPath(inFolder: folder)
            guard let file = try await files.status(path), ClaudeTranscriptLocator.isUsable(file) else {
                sawUnwritten = true
                return nil
            }
            return try await rootTranscriptPath(from: path, id: id, in: root)
        }
        if let found { return .success(found) }
        return .failure(sawUnwritten ? .notWritten : .notFound)
    }

    /// Walks `sender=<id>` in subagent opening steps up to the top-level
    /// conversation's transcript in `root`.
    private func rootTranscriptPath(
        from initialPath: String, id initialID: String, in root: String
    ) async throws -> String? {
        var currentPath = initialPath
        var visited: Set<String> = [initialID]
        for _ in 0...Self.maximumParentHops {
            guard
                let head = try await files.read(
                    path: currentPath, from: 0, to: Self.headBytes, chunk: Int(Self.headBytes))
            else { return nil }
            guard let parentID = Self.parentSessionID(inHead: head) else { return currentPath }
            guard visited.count <= Self.maximumParentHops, visited.insert(parentID).inserted else { return nil }
            let parentFolder = Self.folder(in: root, id: parentID)
            guard RemoteFilePath.isAcceptable(parentFolder),
                let status = try await files.status(parentFolder), status.kind == nil || status.kind == .directory
            else { return nil }
            let parentPath = Self.transcriptPath(inFolder: parentFolder)
            guard let file = try await files.status(parentPath), ClaudeTranscriptLocator.isUsable(file) else {
                return nil
            }
            currentPath = parentPath
        }
        return nil
    }

    /// The parent conversation's id when a transcript's opening steps are a
    /// subagent's system message from that parent (`[Message] timestamp=…
    /// sender=<id> …`). A subagent may start with a `SYSTEM_SDK` reminder
    /// before that message; a top-level conversation starts with
    /// `USER_INPUT` or a `/fork` checkpoint, before any subagent replies to
    /// it.
    static func parentSessionID(inHead head: Data) -> String? {
        let text = String(decoding: head, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let header = line.range(of: #""content":"#).map { line[..<$0.lowerBound] } ?? line.prefix(256)
            guard header.contains(#""type":"SYSTEM_MESSAGE""#) || header.contains(#""type": "SYSTEM_MESSAGE""#) else {
                return nil
            }
            guard let marker = line.range(of: #"<SYSTEM_MESSAGE>\n[Message] "#) else { continue }
            let rest = line[marker.upperBound...]
            let envelope = rest.range(of: " content=").map { rest[..<$0.lowerBound] } ?? rest.prefix(128)
            guard let sender = envelope.range(of: "sender=") else { return nil }
            let raw = envelope[sender.upperBound...].prefix { $0 != " " }
            return ConversationReference.canonicalUUID(String(raw))
        }
        return nil
    }

    /// `<root>/brain/<id>`.
    static func folder(in root: String, id: String) -> String {
        RemoteFilePath.join(root, "brain", id)
    }

    /// The full transcript in a conversation's folder.
    static func transcriptPath(inFolder folder: String) -> String {
        RemoteFilePath.join(folder, ".system_generated", "logs", "transcript_full.jsonl")
    }

    /// The conversation id in a path from `transcriptPath(inFolder:)`.
    static func sessionID(ofTranscript path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[parts.count - 5] == "brain" else { return nil }
        return ConversationReference.canonicalUUID(String(parts[parts.count - 4]))
    }

    /// The directory a transcript at `transcriptPath(inFolder:)` is under,
    /// which also holds agy's prompt log.
    static func root(ofTranscript path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).dropLast(5).joined(separator: "/")
    }
}
