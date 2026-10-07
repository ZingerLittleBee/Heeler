import Foundation

/// The Claude Code adapter: folds transcript lines into an index and projects
/// the conversation's current branch on demand.
///
/// Lines may arrive in any order (a tail window, then older pages, then
/// re-fed lines after a rewrite); the index converges on the same state
/// either way, so `append` and `prepend` differ only in what the follower
/// promises. Everything else happens in `transcript(_:)`, which is pure: the
/// branch is chosen again on every projection because a later line can
/// change it (a rewind, a second writer, a compaction).
struct ClaudeTranscriptReducer: ChatTranscriptReducer {
    enum Role: Sendable, Equatable {
        /// A session's own transcript, where sidechain and team records are
        /// someone else's.
        case main
        /// A subagent's file, where every record is a sidechain.
        case subagent
    }

    /// Bumped whenever the same lines start projecting to different entries,
    /// so a device cache written by an older build is dropped instead of
    /// mixed with new entries.
    static let revision = 4

    let role: Role
    /// The file being read, whose sidecar directory holds the outputs
    /// Claude Code spills; nil reads none of them.
    let transcriptPath: String?
    private(set) var index = ClaudeTranscriptIndex()

    init(role: Role = .main, transcriptPath: String? = nil) {
        self.role = role
        self.transcriptPath = transcriptPath
    }

    mutating func append(_ lines: [ChatLine]) {
        for line in lines {
            index.apply(line)
        }
    }

    mutating func prepend(_ lines: [ChatLine]) {
        for line in lines {
            index.apply(line)
        }
    }

    /// The current branch. With the file's head loaded, a missing parent is
    /// a line that could not be read, and the walk bridges it; in a tail
    /// window it is where an older page continues.
    func chain(_ context: ChatProjectionContext) -> ClaudeChain {
        ClaudeChainResolver.resolve(index, role: role, bridgesMissingParents: context.windowStart == 0)
    }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        ClaudeTranscriptProjection.transcript(
            index: index, chain: chain(context), role: role, context: context, transcriptPath: transcriptPath)
    }

    /// The result record's output for the call, built as its row's preview
    /// is. A call whose record is not indexed (an older page not loaded)
    /// builds it from the tool's name alone.
    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard let callID = tool.callID, case .record(let record) = ClaudeLine.decode(line) else { return nil }
        let use =
            index.records.values.lazy.flatMap(\.toolUses).first { $0.id == callID }
            ?? ClaudeToolUse(id: callID, name: tool.name, input: ClaudeToolInput())
        switch ClaudeTranscriptProjection.output(of: use, in: record) {
        case .file(let path, let fallback, let fileChanges)?:
            return isSpilledOutput(path)
                ? .file(path, fallback: fallback, fileChanges: fileChanges) : .preview(fallback, fileChanges: fileChanges)
        case let output:
            return output
        }
    }

    /// Claude Code spills a long output into `tool-results` beside the
    /// transcript (`<session>/tool-results/`); no other file is read.
    private func isSpilledOutput(_ path: String) -> Bool {
        guard let transcriptPath, transcriptPath.hasSuffix(".jsonl"), RemoteFilePath.isAcceptable(path) else {
            return false
        }
        return path.hasPrefix(String(transcriptPath.dropLast(".jsonl".count)) + "/tool-results/")
    }

    /// The form a sent prompt and a recorded one are compared in
    /// (docs/research/claude-code-transcript-format.md, "Prompt recording and
    /// echo matching"): NFC, LF line ends, `<pasted_content>` unwrapped,
    /// trimmed. Claude Code trims what it records, and Heeler appends a space
    /// when it sends.
    static func echoKey(_ text: String) -> String {
        let unified = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return ClaudeUserText.unwrappingPastedContent(unified).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
