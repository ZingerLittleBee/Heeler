import Foundation

/// The program that writes the transcript a Chat reads. Each one gets its own
/// adapter: the files share nothing beyond being JSON Lines, and herdr, not
/// the file, says which program an Agent runs.
enum ChatProgram: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

/// What herdr last reported the Agent doing. Adapters need it only to tell a
/// tool that is still running from one that never got a result; everything
/// else they read from the file.
enum ChatAgentActivity: Sendable, Equatable {
    case idle
    case working
    case blocked
    case unknown
}

/// A stable identity for one item in a conversation. Adapters derive it from
/// the program's own ids (a record uuid, a tool call id, a turn item id), or
/// from a byte offset when the program has none, so the same item keeps its
/// id across reloads, older-history pages and the cache.
struct ChatEntryID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One rendered item of a conversation: a message, a tool, a notice. Entries
/// are normalized and program-neutral so the list, the cache and the Blocked
/// cards never parse a transcript format themselves.
struct ChatEntry: Identifiable, Equatable, Codable, Sendable {
    let id: ChatEntryID
    /// Where the line that places this entry starts in its file. It orders
    /// entries within one file and tells pending-echo matching which entries
    /// arrived after a send.
    var sourceOffset: UInt64
    var content: Content

    init(id: ChatEntryID, sourceOffset: UInt64, content: Content) {
        self.id = id
        self.sourceOffset = sourceOffset
        self.content = content
    }

    enum Content: Equatable, Codable, Sendable {
        case user(ChatUserMessage)
        case assistant(ChatAssistantMessage)
        case reasoning(ChatReasoning)
        case tool(ChatToolActivity)
        case plan(ChatPlan)
        case questions(ChatQuestionSet)
        case notice(ChatNotice)
        case divider(ChatDivider)
    }
}

/// A prompt the user sent. The text is shown verbatim, never as Markdown,
/// because it is what the person typed.
struct ChatUserMessage: Equatable, Codable, Sendable {
    var text: String
    /// Images the prompt carried. Chat shows placeholders and never loads
    /// image data from a transcript.
    var imageCount: Int
    /// Short labels for other attachments the program recorded (a mention, a
    /// file reference), shown as chips.
    var attachmentLabels: [String]
    /// Set when the prompt invoked a command or skill. Both programs display
    /// as `/name arguments`, whatever the program itself records.
    var command: ChatCommandInvocation?
    /// True when the program took the prompt while a turn was running.
    var wasQueued: Bool

    init(
        text: String, imageCount: Int = 0, attachmentLabels: [String] = [],
        command: ChatCommandInvocation? = nil, wasQueued: Bool = false
    ) {
        self.text = text
        self.imageCount = imageCount
        self.attachmentLabels = attachmentLabels
        self.command = command
        self.wasQueued = wasQueued
    }

    /// What the bubble shows: a command reads as `/name arguments`.
    var displayText: String {
        guard let command else { return text }
        return command.displayText
    }
}

/// A command or skill invocation, normalized to the slash form Chat uses for
/// both programs (Codex records skills as `$name`).
struct ChatCommandInvocation: Equatable, Codable, Sendable {
    /// The name without its sigil.
    var name: String
    var arguments: String

    init(name: String, arguments: String = "") {
        self.name = name
        self.arguments = arguments
    }

    var displayText: String {
        arguments.isEmpty ? "/\(name)" : "/\(name) \(arguments)"
    }
}

/// Text the model wrote, rendered as Markdown.
struct ChatAssistantMessage: Equatable, Codable, Sendable {
    var text: String

    init(text: String) {
        self.text = text
    }
}

/// A reasoning block, folded by default. Claude often records only a
/// signature, so the text may be empty while the duration is known.
struct ChatReasoning: Equatable, Codable, Sendable {
    var text: String
    var durationMilliseconds: Int?

    init(text: String, durationMilliseconds: Int? = nil) {
        self.text = text
        self.durationMilliseconds = durationMilliseconds
    }
}

/// One tool call, shown as a single row that expands to its output.
struct ChatToolActivity: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case command
        case fileEdit
        case fileWrite
        case fileRead
        case search
        case web
        case agent
        case question
        case todo
        case mcp
        case image
        case other
    }

    enum Status: String, Codable, Sendable {
        /// No result yet and the turn is still open.
        case running
        /// No result yet and herdr reports the Agent Blocked on it.
        case awaitingApproval
        case succeeded
        case failed
        /// The user (or a permission rule) declined it.
        case declined
        /// The user interrupted it.
        case interrupted
        /// It ended without completing (an expired approval, an aborted turn).
        case notCompleted
        /// No result was ever recorded and the turn has moved on.
        case noResult
    }

    /// How the user answered the call's Blocked card in Chat.
    enum CardAnswer: Sendable {
        /// An option that allows the call.
        case allowed
        /// Stop: Esc, which declines and ends the turn.
        case stopped
    }

    /// Where reading the output again for an expanded row stands.
    enum OutputRead: Equatable, Sendable {
        case loading
        /// `preview` holds what the read found, or the earlier preview when
        /// it found none.
        case read
        /// Why the output could not be read, as the row says it. Reading
        /// again may succeed.
        case failed(String)
        /// Why the output can't be shown, as the row says it. Reading again
        /// would find the same.
        case unavailable(String)
    }

    var kind: Kind
    /// The program's own tool name: `Bash`, `Edit`, `exec_command`.
    var name: String
    /// The row's primary text: a command, a path, a description.
    var title: String
    /// Secondary text, such as the command under a Bash description.
    var subtitle: String?
    var status: Status
    /// The user's note: feedback with a decline, or a note added to an
    /// approval.
    var note: String?
    var diff: ChatDiffStats?
    /// The files the call changed, as the program recorded them.
    var fileChanges: ChatFileChanges?
    var exitCode: Int?
    /// Questions a question tool asked, with the answers once given.
    var questions: [ChatQuestion]
    /// The tool's id in the transcript (`toolu_…`, `call_…`), used to match a
    /// Blocked card's request and the program's later records.
    var callID: String?
    /// The start of the output: what `ChatToolPreview.rowLimits` keeps, or
    /// more once an expanded row read it again. Held in memory only: the
    /// cache stores entries without tool output.
    var preview: ChatToolPreview?
    /// Where the full output can be re-read on demand.
    var output: ChatOutputReference?
    /// What the transcript can't tell: an approval given in Chat reads there
    /// like an automatic one, and Stop like a decline. Held in memory only.
    var cardAnswer: CardAnswer?
    /// Reading the output again for an expanded row. Held in memory only.
    var outputRead: OutputRead?

    init(
        kind: Kind, name: String, title: String, subtitle: String? = nil,
        status: Status, note: String? = nil, diff: ChatDiffStats? = nil,
        fileChanges: ChatFileChanges? = nil, exitCode: Int? = nil, questions: [ChatQuestion] = [],
        callID: String? = nil, preview: ChatToolPreview? = nil, output: ChatOutputReference? = nil
    ) {
        self.kind = kind
        self.name = name
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.note = note
        self.diff = diff
        self.fileChanges = fileChanges
        self.exitCode = exitCode
        self.questions = questions
        self.callID = callID
        self.preview = preview
        self.output = output
    }

    /// Whether the row's output is its file's diff: an edit or a write whose
    /// patch was recorded.
    var showsDiffAsOutput: Bool {
        (kind == .fileEdit || kind == .fileWrite) && fileChanges != nil
    }

    /// Whether an expanded row has more output text to read: none was kept,
    /// or only its start. A row whose output is a diff reads for the diff.
    var previewIsIncomplete: Bool {
        showsDiffAsOutput ? false : preview?.isTruncated ?? true
    }

    // `preview`, `cardAnswer` and `outputRead` are deliberately absent:
    // decoding leaves them nil.
    private enum CodingKeys: String, CodingKey {
        case kind, name, title, subtitle, status, note, diff, fileChanges, exitCode, questions, callID, output
    }
}

/// Added and removed line counts for a file change.
struct ChatDiffStats: Equatable, Codable, Sendable {
    var added: Int
    var removed: Int
    var files: Int

    init(added: Int, removed: Int, files: Int = 1) {
        self.added = added
        self.removed = removed
        self.files = files
    }
}

/// The files a tool call changed, as the program recorded them: Claude
/// Code's diff of what a Bash command changed in its repository, or an
/// edit's patch. Chat lists them under the call, as Claude Code's terminal
/// does.
struct ChatFileChanges: Equatable, Codable, Sendable {
    var files: [ChatFileChange]
    /// Changed files recorded without a diff: binary or mode-only changes,
    /// diffs too large to record, and files past the program's limit.
    var moreFiles = 0
    /// The directory the call ran in. Paths inside it read relative to it.
    var directory: String?
    /// Another command ran in the same repository at the same time, so a
    /// change made by either may show under either.
    var isShared = false
    /// Part of the diff, or all of it, could not be taken.
    var isUnavailable = false
    /// The command was a single git command that moves the working tree,
    /// which Claude Code takes no diff of.
    var isSkipped = false
    /// The command runs a git step that can move the working tree, so the
    /// changes may be that step's rather than edits.
    var movesWorkingTree = false

    /// What every decoded row keeps of each file's hunks: as much as a file
    /// shows when it opens in its row.
    static let rowLimits = ChatToolPreview.Limits(lines: 40, bytes: 32 * 1_024)
    /// What each file keeps when an expanded row reads its record again.
    static let expandedLimits = ChatToolPreview.Limits(lines: 2_000, bytes: 512 * 1_024)
    /// The most files a row lists; the rest count in `moreFiles`.
    static let maximumFiles = 20

    /// The limits `ChatFileChange.init(path:kind:recorded:)` applies:
    /// `rowLimits`, except while an expanded row's record is decoded again.
    @TaskLocal static var limits = rowLimits

    /// How a file's path reads under its call: relative to the directory
    /// the call ran in when inside it, otherwise as recorded.
    func displayPath(of file: ChatFileChange) -> String {
        guard let directory, !directory.isEmpty else { return file.path }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard file.path.hasPrefix(prefix), file.path.count > prefix.count else { return file.path }
        return String(file.path.dropFirst(prefix.count))
    }

    /// The changes as Copy and Select Text take them: each file's line, then
    /// the hunks the row holds.
    var copyText: String {
        files.map { file in
            var lines = ["\(file.kind.label) \(displayPath(of: file)) (+\(file.added) -\(file.removed))"]
            for hunk in file.hunks {
                lines.append("@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@")
                lines.append(contentsOf: hunk.lines)
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// One file a tool call changed.
struct ChatFileChange: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case updated
        case created
        case deleted

        /// The word Claude Code's terminal puts before the path.
        var label: String {
            switch self {
            case .updated: "Updated"
            case .created: "Created"
            case .deleted: "Deleted"
            }
        }
    }

    /// The path as recorded: absolute for Claude Code.
    var path: String
    var kind: Kind
    var added: Int
    var removed: Int
    /// The diff lines of the recorded hunks, kept or not.
    var lineCount: Int
    /// The recorded hunks, up to `ChatFileChanges.limits` of their lines.
    /// Held in memory only: the cache stores entries without tool output.
    var hunks: [ChatDiffHunk] = []
    /// The last kept line was cut short. Held in memory only.
    var isLineCut = false

    /// Whether `hunks` holds every recorded line in full.
    var isComplete: Bool {
        !isLineCut && hunks.reduce(0) { $0 + $1.diffLineCount } >= lineCount
    }

    init(path: String, kind: Kind, added: Int, removed: Int, lineCount: Int, hunks: [ChatDiffHunk] = []) {
        self.path = path
        self.kind = kind
        self.added = added
        self.removed = removed
        self.lineCount = lineCount
        self.hunks = hunks
    }

    /// A change from its recorded hunks: every line counts, and `hunks`
    /// keeps them up to `ChatFileChanges.limits`.
    init(path: String, kind: Kind, recorded: [ChatDiffHunk]) {
        var added = 0
        var removed = 0
        var lineCount = 0
        for line in recorded.lazy.flatMap(\.lines) where !ChatDiffHunk.isNewlineMarker(line) {
            lineCount += 1
            if line.hasPrefix("+") { added += 1 }
            if line.hasPrefix("-") { removed += 1 }
        }
        self.init(path: path, kind: kind, added: added, removed: removed, lineCount: lineCount)
        let kept = Self.keeping(recorded, within: ChatFileChanges.limits)
        hunks = kept.hunks
        isLineCut = kept.isLineCut
    }

    /// The change with no more of its hunks than `limits` allow, as a row
    /// shows it.
    func keeping(_ limits: ChatToolPreview.Limits) -> ChatFileChange {
        let kept = Self.keeping(hunks, within: limits)
        guard !kept.isAll else { return self }
        var change = self
        change.hunks = kept.hunks
        change.isLineCut = kept.isLineCut
        return change
    }

    /// The start of `hunks` within `limits`, never splitting a character:
    /// whether that is all of them, and whether its last line was cut
    /// short. A first line longer than the limit keeps its start.
    private static func keeping(
        _ hunks: [ChatDiffHunk], within limits: ChatToolPreview.Limits
    ) -> (hunks: [ChatDiffHunk], isAll: Bool, isLineCut: Bool) {
        var result: [ChatDiffHunk] = []
        var isLineCut = false
        var keptLines = 0
        var keptBytes = 0
        for hunk in hunks {
            var kept = hunk
            kept.lines = []
            var isFull = false
            for line in hunk.lines {
                let isMarker = ChatDiffHunk.isNewlineMarker(line)
                if !isMarker, keptLines == limits.lines {
                    isFull = true
                    break
                }
                let size = line.utf8.count
                if keptBytes + size > limits.bytes {
                    if keptLines == 0, !isMarker {
                        kept.lines.append(Self.prefix(of: line, bytes: limits.bytes))
                        keptLines += 1
                        isLineCut = true
                    }
                    isFull = true
                    break
                }
                kept.lines.append(line)
                keptBytes += size
                if !isMarker { keptLines += 1 }
            }
            if !kept.lines.isEmpty { result.append(kept) }
            if isFull { return (result, false, isLineCut) }
        }
        return (result, true, false)
    }

    private static func prefix(of line: String, bytes: Int) -> String {
        var end = line.startIndex
        var size = 0
        for index in line.indices {
            let next = size + line[index].utf8.count
            guard next <= bytes else { break }
            size = next
            end = line.index(after: index)
        }
        return String(line[..<end])
    }

    // `hunks` and `isLineCut` are deliberately absent: decoding leaves the
    // change without its lines, which an expanded row reads again.
    private enum CodingKeys: String, CodingKey {
        case path, kind, added, removed, lineCount
    }
}

/// A hunk as the program recorded it.
struct ChatDiffHunk: Equatable, Sendable {
    var oldStart: Int
    var oldLines: Int
    var newStart: Int
    var newLines: Int
    /// Each line starts with ` `, `-` or `+`; a line starting with `\` says
    /// the line before it has no final newline.
    var lines: [String]

    /// The lines that are lines of the file, without newline markers.
    var diffLineCount: Int {
        lines.reduce(0) { Self.isNewlineMarker($1) ? $0 : $0 + 1 }
    }

    /// `\ No newline at end of file`, which belongs to the line before.
    static func isNewlineMarker(_ line: String) -> Bool {
        line.hasPrefix("\\")
    }
}

/// The capped start of a tool's output.
struct ChatToolPreview: Equatable, Sendable {
    /// At most the lines and UTF-8 bytes `limits` allowed when it was
    /// capped.
    var text: String
    /// True when the output continued past the cap.
    var isTruncated: Bool
    /// Images in the output, shown as placeholders.
    var imageCount: Int

    /// How much of an output a preview keeps.
    struct Limits: Equatable, Sendable {
        var lines: Int
        var bytes: Int
    }

    /// What every decoded row keeps.
    static let rowLimits = Limits(lines: 40, bytes: 8 * 1_024)
    /// What an expanded row keeps when it reads the output again.
    static let expandedLimits = Limits(lines: 1_000, bytes: 64 * 1_024)
    /// The longest line an expanded row reads again.
    static let maximumFetchBytes = 1_024 * 1_024

    /// The limits `init(capping:)` applies: `rowLimits`, except while an
    /// expanded row's output is decoded again.
    @TaskLocal static var limits = rowLimits

    init(text: String, isTruncated: Bool, imageCount: Int = 0) {
        self.text = text
        self.isTruncated = isTruncated
        self.imageCount = imageCount
    }

    /// Caps `output` at `limits`, never splitting a character.
    init(capping output: String, imageCount: Int = 0) {
        let limits = Self.limits
        var lines = 0
        var bytes = 0
        var end = output.startIndex
        var truncated = false
        for index in output.indices {
            let character = output[index]
            let size = character.utf8.count
            if bytes + size > limits.bytes {
                truncated = true
                break
            }
            if character == "\n" || character == "\r\n" {
                lines += 1
                if lines == limits.lines {
                    truncated = output.index(after: index) < output.endIndex
                    break
                }
            }
            bytes += size
            end = output.index(after: index)
        }
        self.init(text: String(output[..<end]), isTruncated: truncated, imageCount: imageCount)
    }
}

/// Where a tool's full output lives: one line of a transcript file.
struct ChatOutputReference: Equatable, Codable, Sendable {
    /// The file, or nil for the conversation's own transcript.
    var path: String?
    var offset: UInt64
    var length: Int

    init(path: String? = nil, offset: UInt64, length: Int) {
        self.path = path
        self.offset = offset
        self.length = length
    }
}

/// A tool's output decoded again from the line its row references. Either
/// form carries the files the call changed, kept up to
/// `ChatFileChanges.limits`, when the line records any.
enum ChatToolOutput: Equatable, Sendable {
    /// The output as `ChatToolPreview.limits` caps it; nil when the call
    /// recorded none.
    case preview(ChatToolPreview?, fileChanges: ChatFileChanges? = nil)
    /// The program moved the output to this file. `fallback` is what the
    /// line itself keeps.
    case file(String, fallback: ChatToolPreview?, fileChanges: ChatFileChanges? = nil)
}

/// What reading a tool's line again for an expanded row found.
struct ChatExpandedOutput: Equatable, Sendable {
    /// The output up to `ChatToolPreview.expandedLimits`; nil when it has
    /// nothing to show.
    var preview: ChatToolPreview?
    /// The files the call changed, each up to
    /// `ChatFileChanges.expandedLimits`; nil when the line records none.
    var fileChanges: ChatFileChanges?

    init(preview: ChatToolPreview? = nil, fileChanges: ChatFileChanges? = nil) {
        self.preview = preview
        self.fileChanges = fileChanges
    }
}

/// A plan the Agent proposed, rendered as Markdown.
struct ChatPlan: Equatable, Codable, Sendable {
    var text: String
    /// The plan file the program wrote, when it names one.
    var filePath: String?
    var status: ChatToolActivity.Status
    /// Feedback with a rejection, or a note added to an approval.
    var note: String?
    var callID: String?

    init(
        text: String, filePath: String? = nil, status: ChatToolActivity.Status,
        note: String? = nil, callID: String? = nil
    ) {
        self.text = text
        self.filePath = filePath
        self.status = status
        self.note = note
        self.callID = callID
    }
}

/// One question the Agent asked, with the answer once there is one.
struct ChatQuestion: Equatable, Codable, Sendable {
    /// An option as the call lists it. A string literal is an option
    /// without a description.
    struct Option: Equatable, Codable, Sendable, ExpressibleByStringLiteral {
        var label: String
        /// The call's `description`, shown under the label.
        var detail: String?

        init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }

        init(stringLiteral label: String) {
            self.init(label: label)
        }
    }

    /// The program's id for the question, when it has one.
    var id: String?
    var header: String?
    var text: String
    var options: [Option]
    /// Claude's `multiSelect`: the answer may be several options.
    var isMultiSelect: Bool
    var answer: String?
    /// An answer given in Chat that the program holds back: Codex records
    /// an asynchronous answer only once it sends it, after its next tool
    /// call. Held in memory only.
    var queuedAnswer: String?

    init(
        id: String? = nil, header: String? = nil, text: String, options: [Option] = [],
        isMultiSelect: Bool = false, answer: String? = nil
    ) {
        self.id = id
        self.header = header
        self.text = text
        self.options = options
        self.isMultiSelect = isMultiSelect
        self.answer = answer
    }

    // `queuedAnswer` is deliberately absent: decoding leaves it nil.
    private enum CodingKeys: String, CodingKey {
        case id, header, text, options, isMultiSelect, answer
    }
}

/// Questions the Agent asked outside a tool call (Codex's asynchronous
/// questions). Unanswered ones feed the question card.
struct ChatQuestionSet: Equatable, Codable, Sendable {
    var questions: [ChatQuestion]

    init(questions: [ChatQuestion]) {
        self.questions = questions
    }
}

/// A system row: something that happened in the conversation that is
/// neither a message nor a tool.
struct ChatNotice: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A command the program ran itself (`/compact`, `/model`).
        case command
        /// A shell command the user ran in the program's shell mode.
        case shellCommand
        /// A background task finished.
        case taskNotification
        /// The user interrupted the turn.
        case interrupted
        /// The turn stopped (Codex aborts, budget limits).
        case stopped
        /// The model provider returned an error.
        case error
        /// The program switched models.
        case modelChange
        /// The Agent entered plan mode.
        case planMode
        /// A hook's prompt or output.
        case hook
        /// Code review mode started or ended.
        case review
        /// Answers to questions asked outside a tool.
        case answered
        /// Anything else worth a line.
        case system
    }

    var kind: Kind
    var title: String
    var detail: String?
    var questions: [ChatQuestion]

    init(kind: Kind, title: String, detail: String? = nil, questions: [ChatQuestion] = []) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.questions = questions
    }
}

/// A full-width separator.
struct ChatDivider: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The program compacted its context. History above stays visible.
        case compaction
        /// History before this point could not be read.
        case historyUnavailable
    }

    var kind: Kind
    var detail: String?

    init(kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

/// A request the transcript shows as unresolved: a tool call without a
/// result, or a question without an answer. A Blocked card matches the
/// dialog on screen against these to show the full content; the screen
/// always decides the options.
struct ChatPendingRequest: Equatable, Sendable {
    var entryID: ChatEntryID
    var callID: String?
    var kind: ChatToolActivity.Kind
    /// The program's tool name.
    var toolName: String
    /// What a screen parse matches on: the command, path, URL or question.
    var summary: String
    var detail: String?
    var questions: [ChatQuestion]
    var planFilePath: String?
    /// Set when a subagent made the request: its description.
    var origin: String?

    init(
        entryID: ChatEntryID, callID: String?, kind: ChatToolActivity.Kind, toolName: String,
        summary: String, detail: String? = nil, questions: [ChatQuestion] = [],
        planFilePath: String? = nil, origin: String? = nil
    ) {
        self.entryID = entryID
        self.callID = callID
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.questions = questions
        self.planFilePath = planFilePath
        self.origin = origin
    }
}

/// A prompt as the program recorded it, offered to pending-echo matching.
/// Some records never become a bubble (Claude's queue operations), so this
/// is separate from the entries.
struct ChatRecordedPrompt: Equatable, Sendable {
    var offset: UInt64
    var text: String
    /// The bubble the prompt produced, when one shows.
    var entryID: ChatEntryID?

    init(offset: UInt64, text: String, entryID: ChatEntryID? = nil) {
        self.offset = offset
        self.text = text
        self.entryID = entryID
    }
}

/// One piece of Background Work: a Subagent or Workflow the program started
/// beside the conversation, as the transcript records its launch and its
/// end. Saved with the conversation only to carry a launch above a later
/// read's window into it, where that read's records can still end it.
struct ChatBackgroundWorkItem: Identifiable, Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        case subagent
        case workflow
    }

    enum State: Equatable, Codable, Sendable {
        case running
        case completed
        case failed
        case stopped
    }

    /// The counts the program reports when the work ends.
    struct Usage: Equatable, Codable, Sendable {
        var tokens: Int?
        var toolUses: Int?
        var durationMilliseconds: Int?
        /// A Workflow's agents: how many it ran, finished and failed.
        var agents: Int?
        var agentsDone: Int?
        var agentsFailed: Int?

        init(
            tokens: Int? = nil, toolUses: Int? = nil, durationMilliseconds: Int? = nil, agents: Int? = nil,
            agentsDone: Int? = nil, agentsFailed: Int? = nil
        ) {
            self.tokens = tokens
            self.toolUses = toolUses
            self.durationMilliseconds = durationMilliseconds
            self.agents = agents
            self.agentsDone = agentsDone
            self.agentsFailed = agentsFailed
        }
    }

    /// The launching call's id, which its row's entry id holds.
    let id: String
    var kind: Kind
    var title: String
    /// A Subagent's type, or what a Workflow says it does.
    var subtitle: String?
    var state: State
    /// Where a Workflow records its agents, on the Host; nil when it is
    /// not where Chat may read.
    var journalPath: String?
    var launchOffset: UInt64
    /// Where the record that says it ended starts.
    var endOffset: UInt64?
    /// On the Host's clock, from the records' timestamps.
    var launchedAt: Date?
    var endedAt: Date?
    var usage: Usage?

    init(
        id: String, kind: Kind, title: String, subtitle: String? = nil, state: State = .running,
        journalPath: String? = nil, launchOffset: UInt64, endOffset: UInt64? = nil, launchedAt: Date? = nil,
        endedAt: Date? = nil, usage: Usage? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.journalPath = journalPath
        self.launchOffset = launchOffset
        self.endOffset = endOffset
        self.launchedAt = launchedAt
        self.endedAt = endedAt
        self.usage = usage
    }
}

/// One turn of the conversation, as the program records it: the entries
/// from its first up to the next turn's first, in display order, and when
/// it started and ended on the Host's clock.
struct ChatTurn: Equatable, Codable, Sendable {
    enum Ending: String, Equatable, Codable, Sendable {
        case completed
        case interrupted
        case failed
    }

    /// The first entry the turn placed: the prompt, command or notice that
    /// opened it, or the first thing it wrote after an opener that shows
    /// nothing.
    var firstEntryID: ChatEntryID
    var startedAt: Date?
    var endedAt: Date?
    /// How the loaded records say it ended; nil while none does.
    var ending: Ending?

    init(firstEntryID: ChatEntryID, startedAt: Date? = nil, endedAt: Date? = nil, ending: Ending? = nil) {
        self.firstEntryID = firstEntryID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.ending = ending
    }
}

/// How a turn ended, as the records that close it say.
struct ChatTurnEnd: Equatable, Codable, Sendable {
    var ending: ChatTurn.Ending
    var endedAt: Date?
}

/// How a piece of Background Work ended, as one record says.
struct ChatBackgroundWorkEnd: Equatable, Sendable {
    var state: ChatBackgroundWorkItem.State
    /// Where the record starts.
    var offset: UInt64
    var endedAt: Date?
    var usage: ChatBackgroundWorkItem.Usage?

    init(
        state: ChatBackgroundWorkItem.State, offset: UInt64, endedAt: Date? = nil,
        usage: ChatBackgroundWorkItem.Usage? = nil
    ) {
        self.state = state
        self.offset = offset
        self.endedAt = endedAt
        self.usage = usage
    }
}

extension ChatBackgroundWorkItem {
    mutating func apply(_ end: ChatBackgroundWorkEnd) {
        state = end.state
        endOffset = end.offset
        endedAt = end.endedAt
        usage = end.usage
    }
}

/// Explicit links the transcript records to somewhere else.
struct ChatTranscriptLinks: Equatable, Sendable {
    /// Claude moved the session to a new working directory (`relocated`).
    var relocatedCwd: String?
    /// Claude continued the conversation in another session (`continued-in`).
    var continuedInSessionID: String?

    init(relocatedCwd: String? = nil, continuedInSessionID: String? = nil) {
        self.relocatedCwd = relocatedCwd
        self.continuedInSessionID = continuedInSessionID
    }
}

/// Lines the adapter could not use. Never fatal; counted for diagnostics.
struct ChatTranscriptDiagnostics: Equatable, Sendable {
    var invalidLines = 0
    var oversizedLines = 0
    var unknownRecordTypes: Set<String> = []

    init(invalidLines: Int = 0, oversizedLines: Int = 0, unknownRecordTypes: Set<String> = []) {
        self.invalidLines = invalidLines
        self.oversizedLines = oversizedLines
        self.unknownRecordTypes = unknownRecordTypes
    }
}

/// What an adapter produces from the lines it has been fed.
struct ChatTranscript: Equatable, Sendable {
    /// Display order, oldest first.
    var entries: [ChatEntry]
    /// The conversation's title, when the program records one.
    var title: String?
    /// True when the loaded lines need older history to be complete: the
    /// window does not start at the file's head, or the current branch's
    /// chain continues above it.
    var needsOlderHistory: Bool
    var pendingRequests: [ChatPendingRequest]
    var recordedPrompts: [ChatRecordedPrompt]
    var links: ChatTranscriptLinks
    var diagnostics: ChatTranscriptDiagnostics
    /// Background Work launched on the current branch of the loaded lines,
    /// in launch order.
    var backgroundWork: [ChatBackgroundWorkItem]
    /// Where the newest message the user sent starts, among the loaded
    /// lines.
    var latestPromptOffset: UInt64?
    /// Every end the loaded lines record, by the launching call's id,
    /// including ends of work launched above them.
    var backgroundWorkEnds: [String: ChatBackgroundWorkEnd]
    /// The first record among the loaded lines that stopped all Background
    /// Work, which ends work launched above them with no end of its own.
    var backgroundWorkStop: ChatBackgroundWorkEnd?
    /// The turns the loaded lines open, oldest first. Entries above the
    /// first belong to a turn opened above the loaded lines.
    var turns: [ChatTurn]
    /// How the turn opened above the loaded lines ended, when they close
    /// it before opening one of their own.
    var precedingTurnEnd: ChatTurnEnd?

    init(
        entries: [ChatEntry] = [], title: String? = nil, needsOlderHistory: Bool = false,
        pendingRequests: [ChatPendingRequest] = [], recordedPrompts: [ChatRecordedPrompt] = [],
        links: ChatTranscriptLinks = ChatTranscriptLinks(),
        diagnostics: ChatTranscriptDiagnostics = ChatTranscriptDiagnostics(),
        backgroundWork: [ChatBackgroundWorkItem] = [], latestPromptOffset: UInt64? = nil,
        backgroundWorkEnds: [String: ChatBackgroundWorkEnd] = [:], backgroundWorkStop: ChatBackgroundWorkEnd? = nil,
        turns: [ChatTurn] = [], precedingTurnEnd: ChatTurnEnd? = nil
    ) {
        self.entries = entries
        self.title = title
        self.needsOlderHistory = needsOlderHistory
        self.pendingRequests = pendingRequests
        self.recordedPrompts = recordedPrompts
        self.links = links
        self.diagnostics = diagnostics
        self.backgroundWork = backgroundWork
        self.latestPromptOffset = latestPromptOffset
        self.backgroundWorkEnds = backgroundWorkEnds
        self.backgroundWorkStop = backgroundWorkStop
        self.turns = turns
        self.precedingTurnEnd = precedingTurnEnd
    }

    /// The Background Work Chat lists: everything still running, and what
    /// ended after the user's latest message. Without a message among the
    /// loaded lines, everything they hold came after it.
    var listedBackgroundWork: [ChatBackgroundWorkItem] {
        let prompt = latestPromptOffset ?? 0
        return backgroundWork.filter { $0.state == .running || ($0.endOffset ?? 0) > prompt }
    }

    /// Puts work an earlier read listed, launched above `windowStart`, ahead
    /// of the work launched in the loaded lines, ending what they end. The
    /// earlier read's latest message stands when none is loaded.
    mutating func carryBackgroundWork(
        _ earlier: [ChatBackgroundWorkItem], launchedBefore windowStart: UInt64, latestPromptOffset earlierPrompt: UInt64?
    ) {
        let loaded = Set(backgroundWork.map(\.id))
        let carried = earlier.filter { $0.launchOffset < windowStart && !loaded.contains($0.id) }.map { item in
            var item = item
            if let end = backgroundWorkEnds[item.id], end.offset > (item.endOffset ?? item.launchOffset) {
                item.apply(end)
            } else if item.state == .running, let stop = backgroundWorkStop {
                item.apply(stop)
            }
            return item
        }
        backgroundWork = carried + backgroundWork
        if latestPromptOffset == nil { latestPromptOffset = earlierPrompt }
    }
}

/// What an adapter needs to know beyond the lines.
struct ChatProjectionContext: Equatable, Sendable {
    /// Where the loaded window starts; 0 means the file's head is loaded.
    var windowStart: UInt64
    var activity: ChatAgentActivity
    /// Skill names the Host offers, so a Codex `$name` prompt can display as
    /// `/name` even when the file did not record a skill part.
    var skillNames: Set<String>

    init(windowStart: UInt64 = 0, activity: ChatAgentActivity = .unknown, skillNames: Set<String> = []) {
        self.windowStart = windowStart
        self.activity = activity
        self.skillNames = skillNames
    }
}

/// Turns one program's transcript lines into Chat entries.
///
/// The follower feeds complete lines only. A reducer keeps whatever it needs
/// to rebuild the projection; `transcript(_:)` is pure over that state, so a
/// caller may project as often as the Agent's activity changes.
protocol ChatTranscriptReducer: Sendable {
    /// Lines that follow everything fed so far, in file order.
    mutating func append(_ lines: [ChatLine])
    /// Lines that precede everything fed so far, in file order: an older
    /// history page.
    mutating func prepend(_ lines: [ChatLine])
    func transcript(_ context: ChatProjectionContext) -> ChatTranscript
    /// Names the transcript's format when the lines show one this reducer
    /// does not read, such as a Codex rollout from before the envelope
    /// format. Chat then explains instead of showing a partial conversation.
    var unsupportedFormat: String? { get }
    /// The output `line` holds for `tool`, decoded again for an expanded
    /// row. Nil when the line no longer holds that call, as after the file
    /// was rewritten.
    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput?
}

extension ChatTranscriptReducer {
    var unsupportedFormat: String? { nil }

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? { nil }
}
