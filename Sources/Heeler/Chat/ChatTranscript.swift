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
        /// Why the output could not be read, as the row says it.
        case failed(String)
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
        exitCode: Int? = nil, questions: [ChatQuestion] = [], callID: String? = nil,
        preview: ChatToolPreview? = nil, output: ChatOutputReference? = nil
    ) {
        self.kind = kind
        self.name = name
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.note = note
        self.diff = diff
        self.exitCode = exitCode
        self.questions = questions
        self.callID = callID
        self.preview = preview
        self.output = output
    }

    // `preview`, `cardAnswer` and `outputRead` are deliberately absent:
    // decoding leaves them nil.
    private enum CodingKeys: String, CodingKey {
        case kind, name, title, subtitle, status, note, diff, exitCode, questions, callID, output
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

/// A tool's output decoded again from the line its row references.
enum ChatToolOutput: Equatable, Sendable {
    /// The output as `ChatToolPreview.limits` caps it; nil when the call
    /// recorded none.
    case preview(ChatToolPreview?)
    /// The program moved the output to this file. `fallback` is what the
    /// line itself keeps.
    case file(String, fallback: ChatToolPreview?)
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

    init(
        entries: [ChatEntry] = [], title: String? = nil, needsOlderHistory: Bool = false,
        pendingRequests: [ChatPendingRequest] = [], recordedPrompts: [ChatRecordedPrompt] = [],
        links: ChatTranscriptLinks = ChatTranscriptLinks(),
        diagnostics: ChatTranscriptDiagnostics = ChatTranscriptDiagnostics()
    ) {
        self.entries = entries
        self.title = title
        self.needsOlderHistory = needsOlderHistory
        self.pendingRequests = pendingRequests
        self.recordedPrompts = recordedPrompts
        self.links = links
        self.diagnostics = diagnostics
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
