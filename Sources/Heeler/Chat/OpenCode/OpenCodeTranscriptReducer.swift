import Foundation

/// OpenCode keeps a session as rows in its own database, which the record
/// source reads by query (ADR 0025). Rows order by `seq`, never by time.
/// OpenCode rewrites its newest step in place, so the reducer holds rows by
/// id and a newer read of a row replaces its entries. A committed `/undo`
/// deletes rows, after which the source starts a fresh reducer.
///
/// A turn runs from a prompt to the `idle` row OpenCode writes when the
/// session goes idle; prompts steered in while it runs stay in it. A
/// declined permission or a dismissed question ends a turn with no `idle`
/// row, so the reducer ends it at that step while the step is the turn's
/// last: OpenCode may resume the turn after a restart.
///
/// A session OpenCode 2 imported from 1.x keeps its 1.x version and has no
/// `idle` rows, and 1.x took no steers. Until an `idle` row shows the
/// session going on in OpenCode 2, each of its prompts opens a turn, and
/// the turn before ends with its last step.
struct OpenCodeTranscriptReducer: ChatTranscriptReducer {
    static let revision = 1

    private struct Held: Sendable {
        let row: OpenCodeRow
        /// The line's length, which an expanded tool row reads again.
        let length: Int
    }

    private var rows: [String: Held] = [:]
    private var session: OpenCodeSession?
    private var inbox: OpenCodeInbox?
    /// Lines that are none of the three kinds, by offset.
    private var malformed: Set<UInt64> = []
    /// Lines that arrived cut short, by offset.
    private var cut: Set<UInt64> = []

    mutating func append(_ lines: [ChatLine]) {
        read(lines, isNewer: true)
    }

    mutating func prepend(_ lines: [ChatLine]) {
        read(lines, isNewer: false)
    }

    /// An older page never replaces what a newer read gave.
    private mutating func read(_ lines: [ChatLine], isNewer: Bool) {
        for line in lines {
            guard !line.isTruncated else {
                cut.insert(line.offset)
                continue
            }
            switch OpenCodeLine(line.data) {
            case .session(let value):
                if isNewer || session == nil { session = value }
            case .inbox(let value):
                if isNewer || inbox == nil { inbox = value }
            case .row(let row):
                if isNewer || rows[row.id] == nil { rows[row.id] = Held(row: row, length: line.length) }
            case .malformed:
                malformed.insert(line.offset)
            }
        }
    }

    var unsupportedFormat: String? {
        guard let version = session?.version, let major = session?.majorVersion, major > 2 else { return nil }
        return "OpenCode session version \(version)"
    }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        var projection = Projection(context: context, isImported: session?.majorVersion.map { $0 < 2 } ?? false)
        projection.transcript.title = Self.title(session?.title)
        projection.transcript.diagnostics = diagnostics
        // A staged `/undo` hides its rows, as OpenCode's own screen does:
        // the next prompt deletes them.
        let boundary = session?.revertMessage.flatMap { session?.revertSeq ?? rows[$0]?.row.seq }
        let ordered = rows.values.sorted(by: { $0.row.seq < $1.row.seq })
        let directories = Self.directories(of: ordered.map(\.row), now: session?.directory)
        for (held, directory) in zip(ordered, directories) where held.row.seq < boundary ?? .max {
            projection.add(held.row, length: held.length, directory: directory)
        }
        projection.finish()
        if let boundary, let message = session?.revertMessage {
            projection.append(
                ChatEntry(
                    id: ChatEntryID("oc:revert:\(message)"), sourceOffset: Self.offset(boundary),
                    content: .notice(
                        ChatNotice(
                            kind: .system, title: "Undone in the terminal",
                            detail: "The next message removes these messages; /redo brings them back."))))
        }
        // Prompts OpenCode holds until the running step ends keep the id
        // their rows will carry.
        for item in inbox?.items ?? [] where item.type == "user" {
            guard let id = item.id, rows[id] == nil else { continue }
            projection.addQueued(item, id: ChatEntryID("oc:\(id)"))
        }
        return projection.transcript
    }

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard !line.isTruncated, let callID = tool.callID, case .row(let row) = OpenCodeLine(line.data),
            case .assistant(let step) = row.content,
            let call = step.tools.first(where: { $0.callID == callID })
        else { return nil }
        return OpenCodeToolSummary.output(of: call)
    }

    private var diagnostics: ChatTranscriptDiagnostics {
        var diagnostics = ChatTranscriptDiagnostics(invalidLines: malformed.count, oversizedLines: cut.count)
        for held in rows.values {
            switch held.row.content {
            case .invalid: diagnostics.invalidLines += 1
            case .oversized: diagnostics.oversizedLines += 1
            case .unknown: diagnostics.unknownRecordTypes.insert(held.row.type)
            default: break
            }
        }
        return diagnostics
    }

    /// The folder the session was in at each of `rows`, oldest first, which
    /// OpenCode 2 resolves a relative tool path against. The session's row
    /// names only where it is `now`, so each move, read from the newest
    /// back, gives where it was before; nil past a move that names none.
    private static func directories(of rows: [OpenCodeRow], now: String?) -> [String?] {
        var directory = now
        var result: [String?] = []
        result.reserveCapacity(rows.count)
        for row in rows.reversed() {
            result.append(directory)
            if case .locationSwitched(_, let previous) = row.content { directory = previous }
        }
        return result.reversed()
    }

    /// OpenCode's timestamped placeholder titles say nothing.
    private static func title(_ title: String?) -> String? {
        guard let title, !title.isEmpty,
            title.wholeMatch(of: /(New|Child) session - \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) == nil
        else { return nil }
        return title
    }

    fileprivate static func offset(_ seq: Int64) -> UInt64 {
        UInt64(max(seq, 0))
    }

    fileprivate static func date(_ milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }
}

// MARK: Projection

/// The entries, turns and prompts the rows make, built in `seq` order.
private struct Projection {
    /// The rows since the last turn boundary.
    struct Run {
        enum Place {
            /// The turn opened above the loaded rows; `seen` once a step
            /// shows it still running.
            case above(seen: Bool)
            /// A turn the loaded rows open, by index.
            case turn(Int)
            /// Rows after a turn ended that no prompt opened.
            case loose
        }

        /// A step OpenCode declined, while it is the run's last.
        struct Decline {
            var endedAt: Date?
        }

        var place: Place
        var isEnded = false
        var decline: Decline?
        /// The error the run's last failed step showed.
        var failure: String?
        /// How the run ends if it ends at its newest step.
        var lastStep: ChatTurnEnd?
        /// Tool entries still running, oldest first.
        var runningTools: [Int] = []

        /// Whether a prompt now steers this run rather than opening a turn.
        var takesSteers: Bool {
            guard !isEnded, decline == nil else { return false }
            switch place {
            case .above(let seen): return seen
            case .turn: return true
            case .loose: return false
            }
        }
    }

    var transcript = ChatTranscript()
    let context: ChatProjectionContext
    /// The session was imported from OpenCode 1.x.
    let isImported: Bool
    /// An `idle` row was read: an imported session went on in OpenCode 2.
    var sawIdle = false
    var run: Run

    init(context: ChatProjectionContext, isImported: Bool) {
        self.context = context
        self.isImported = isImported
        transcript.needsOlderHistory = context.windowStart > 0
        run = context.windowStart > 0 ? Run(place: .above(seen: false)) : Run(place: .loose, isEnded: true)
    }

    /// `directory` is the folder the session was in at `row`.
    mutating func add(_ row: OpenCodeRow, length: Int, directory: String?) {
        switch row.content {
        case .user(let message):
            addPrompt(row, message)
        case .assistant(let step):
            addStep(row, step, length: length, directory: directory)
        case .idle(let idle):
            sawIdle = true
            // A run its declined step ended is already over: this idle,
            // such as the one `/redo` writes, closes nothing.
            settleDecline()
            let ending: ChatTurn.Ending =
                switch idle.outcome {
                case "interrupted": .interrupted
                // An idle row too large to keep reads as a failure.
                case "failed", nil: .failed
                default: .completed
                }
            // A step that failed has already said why.
            let message = idle.error?.message ?? "The turn failed"
            let isSaid = !run.isEnded && run.failure == message
            end(ending, at: OpenCodeTranscriptReducer.date(row.created))
            if ending == .failed, !isSaid {
                add(row, .notice(ChatNotice(kind: .error, title: message)))
            } else if ending == .interrupted {
                // A stop says so, as OpenCode's own screen does.
                add(row, .notice(ChatNotice(kind: .interrupted, title: "Interrupted")))
            }
        case .compaction(let compaction):
            if compaction.reason == "manual" {
                let id = entryID(row)
                open(row, id: id)
                add(row, .notice(ChatNotice(kind: .command, title: "/compact")))
                transcript.recordedPrompts.append(
                    ChatRecordedPrompt(offset: OpenCodeTranscriptReducer.offset(row.seq), text: "/compact", entryID: id))
            } else {
                resume()
            }
            switch compaction.status {
            case "completed": add(row, .divider(.compaction(summary: compaction.summary)), ":divider")
            case "failed": addFailedCompaction(row, compaction.error)
            default: break
            }
        case .note(let note):
            addNote(row, note)
        case .shell(let shell):
            add(
                row,
                .notice(
                    ChatNotice(
                        kind: .shellCommand, title: shell.command ?? "Shell command",
                        detail: shell.output.map { ChatToolPreview(capping: $0).text })))
        case .agentSwitched(let agent?):
            add(row, .notice(ChatNotice(kind: .modelChange, title: "Agent: \(agent)")))
        case .modelSwitched(let model?):
            add(row, .notice(ChatNotice(kind: .modelChange, title: "Model: \(model)")))
        case .locationSwitched(let directory?, _):
            add(row, .notice(ChatNotice(kind: .system, title: "Moved to \(directory)")))
        case .oversized where row.type == "user":
            open(row, id: entryID(row))
            add(row, .notice(ChatNotice(kind: .system, title: "This message is too large to show in Chat.")))
            transcript.latestPromptOffset = OpenCodeTranscriptReducer.offset(row.seq)
        case .oversized:
            if row.type == "assistant" { resume() }
            add(row, .notice(ChatNotice(kind: .system, title: "This step is too large to show in Chat.")))
        case .agentSwitched, .modelSwitched, .locationSwitched, .unknown, .invalid:
            break
        }
    }

    /// Ends the open run at its declined step when the step is its last.
    /// While herdr says Blocked, the open run's newest running call is the
    /// one OpenCode asks about.
    mutating func finish() {
        settleDecline()
        guard !run.isEnded, context.activity == .blocked, let index = run.runningTools.last,
            case .tool(var tool) = transcript.entries[index].content
        else { return }
        tool.status = .awaitingApproval
        transcript.entries[index].content = .tool(tool)
        transcript.pendingRequests.append(
            ChatPendingRequest(
                entryID: transcript.entries[index].id, callID: tool.callID, kind: tool.kind, toolName: tool.name,
                summary: tool.title, detail: tool.subtitle, questions: tool.questions))
    }

    mutating func append(_ entry: ChatEntry) {
        transcript.entries.append(entry)
    }

    /// A prompt OpenCode has taken but not yet written as a row.
    mutating func addQueued(_ item: OpenCodeInbox.Item, id: ChatEntryID) {
        let text = item.text ?? ""
        let isCut = Self.isCut(text, length: item.length)
        let offset = OpenCodeTranscriptReducer.offset(item.seq ?? 0)
        append(
            ChatEntry(
                id: id, sourceOffset: offset,
                content: .user(
                    ChatUserMessage(
                        text: Self.shown(Self.trimmed(text), isCut: isCut), attachmentLabels: item.files,
                        wasQueued: true))))
        transcript.unrecordedEntryIDs.insert(id)
        // A long one echoes once its row holds the whole text.
        if !isCut {
            transcript.recordedPrompts.append(ChatRecordedPrompt(offset: offset, text: text, entryID: id))
        }
    }

    // MARK: Rows

    private mutating func addPrompt(_ row: OpenCodeRow, _ message: OpenCodeUserMessage) {
        let id = entryID(row)
        let steers = open(row, id: id)
        let text = message.text ?? ""
        let labels = message.files.compactMap { $0.name ?? $0.mime }
        add(
            row,
            .user(
                ChatUserMessage(
                    text: Self.shown(Self.trimmed(text), isCut: Self.isCut(text, length: message.length)),
                    attachmentLabels: labels, wasQueued: steers)))
        // A prompt of only an image or a PDF records no text to match a send.
        let attachesOnly =
            Self.trimmed(text).isEmpty
            && message.files.contains { $0.mime?.hasPrefix("image/") == true || $0.mime == "application/pdf" }
        let offset = OpenCodeTranscriptReducer.offset(row.seq)
        transcript.recordedPrompts.append(
            ChatRecordedPrompt(offset: offset, text: text, entryID: id, pastedImagePaths: attachesOnly ? [] : nil))
        transcript.latestPromptOffset = offset
    }

    private mutating func addStep(_ row: OpenCodeRow, _ step: OpenCodeStep, length: Int, directory: String?) {
        resume()
        for item in step.items {
            let suffix = ":\(item.index)"
            switch item.kind {
            // Text fills in only when its block ends; an empty item is one
            // still being written.
            case .text(let text) where !text.text.isEmpty:
                let shown = Self.shown(text.text, isCut: Self.isCut(text.text, length: text.length))
                add(row, .assistant(ChatAssistantMessage(text: shown)), suffix)
            case .reasoning(let text) where !text.text.isEmpty:
                let duration = text.started.flatMap { started in text.completed.map { Int($0 - started) } }
                add(
                    row,
                    .reasoning(
                        ChatReasoning(
                            text: Self.shown(text.text, isCut: Self.isCut(text.text, length: text.length)),
                            durationMilliseconds: duration)),
                    suffix)
            case .tool(let call):
                let tool = OpenCodeToolSummary.activity(
                    call, output: ChatOutputReference(offset: OpenCodeTranscriptReducer.offset(row.seq), length: length),
                    directory: directory)
                if tool.status == .running { run.runningTools.append(transcript.entries.count) }
                add(row, .tool(tool), suffix)
            case .text, .reasoning, .other:
                break
            }
        }
        if !row.isFinal, let retry = step.retry {
            let attempt = retry.attempt.map { " (attempt \($0))" } ?? ""
            let reason = retry.error?.message.map { ": \($0)" } ?? ""
            add(row, .notice(ChatNotice(kind: .system, title: "Retrying\(attempt)\(reason)")), ":retry")
        }
        switch step.finish {
        case "length":
            add(row, .notice(ChatNotice(kind: .system, title: "The model stopped at its output limit.")), ":finish")
        case "content-filter":
            add(row, .notice(ChatNotice(kind: .system, title: "The provider filtered the reply.")), ":finish")
        default:
            break
        }
        if let error = step.error, error.type != "aborted" {
            let message = error.message ?? "The step failed"
            add(row, .notice(ChatNotice(kind: .error, title: message)), ":error")
            run.failure = message
        }
        if step.finish == "error", step.tools.contains(where: Self.isDeclined) {
            run.decline = Run.Decline(endedAt: OpenCodeTranscriptReducer.date(step.completed ?? row.updated))
        }
        let ending: ChatTurn.Ending =
            if step.error?.type == "aborted" {
                .interrupted
            } else if step.error != nil || step.finish == "error" {
                .failed
            } else {
                .completed
            }
        run.lastStep = ChatTurnEnd(ending: ending, endedAt: OpenCodeTranscriptReducer.date(step.completed ?? row.updated))
    }

    private mutating func addNote(_ row: OpenCodeRow, _ note: OpenCodeNote) {
        switch row.type {
        case "synthetic":
            // OpenCode tells the model about a command the user ran in its
            // shell mode, which the command's own row shows.
            if note.source == "shell", note.jobID == nil, note.description == nil { return }
            // Text with neither metadata nor a description is for the model
            // alone, such as Plan mode's reminders: OpenCode's own screen
            // never draws it.
            if !note.hasMetadata, Self.trimmed(note.description ?? "").isEmpty { return }
            resume()
            if note.notice == "restart" {
                add(row, .notice(ChatNotice(kind: .system, title: "Continuing after a restart")))
            } else if note.source == "subagent" || note.source == "shell" {
                add(
                    row,
                    .notice(
                        ChatNotice(
                            kind: .taskNotification, title: note.description ?? "Background work finished",
                            detail: note.text)))
            } else {
                add(row, .notice(ChatNotice(kind: .system, title: note.description ?? "Note", detail: note.text)))
            }
        case "skill":
            let name = (note.name ?? note.skill).map { "Skill \($0)" } ?? "Skill"
            add(row, .notice(ChatNotice(kind: .command, title: name)))
        default:
            add(row, .notice(ChatNotice(kind: .system, title: note.description ?? "Instructions updated")))
        }
    }

    /// OpenCode records a `/compact` with nothing new to compact as a
    /// failed compaction whose error says so ("Nothing to compact yet"),
    /// and a `/compact` the user stopped as one whose `aborted` error says
    /// "Compaction cancelled". Nothing failed, so Chat shows those words as
    /// a notice; a stop's own "Interrupted" comes from its `idle` row. Any
    /// other failure, or a refusal without a message, is "Compaction
    /// failed", with the message as its detail.
    private mutating func addFailedCompaction(_ row: OpenCodeRow, _ error: OpenCodeError?) {
        let message = error?.message.flatMap { Self.trimmed($0).isEmpty ? nil : $0 }
        if error?.type == "aborted" {
            add(row, .notice(ChatNotice(kind: .system, title: message ?? "Compaction cancelled")), ":notice")
        } else if error?.type == "compaction.unavailable", let message {
            add(row, .notice(ChatNotice(kind: .system, title: message)), ":notice")
        } else {
            add(row, .notice(ChatNotice(kind: .error, title: "Compaction failed", detail: message)), ":error")
        }
    }

    // MARK: Turns

    /// Places a prompt or `/compact`: it steers a turn still running, and
    /// otherwise opens one. Returns whether it steered. In a session
    /// imported from 1.x, until an `idle` row, it always opens one, and the
    /// run before ends with its last step.
    @discardableResult
    private mutating func open(_ row: OpenCodeRow, id: ChatEntryID) -> Bool {
        settleDecline()
        if isImported, !sawIdle {
            if let last = run.lastStep { end(last.ending, at: last.endedAt) }
        } else if run.takesSteers {
            return true
        }
        endQuietly()
        transcript.turns.append(ChatTurn(firstEntryID: id, startedAt: OpenCodeTranscriptReducer.date(row.created)))
        run = Run(place: .turn(transcript.turns.count - 1))
        return false
    }

    /// A step or a note that shows OpenCode working: a run that ended goes
    /// on as rows no prompt opened, and a declined step is no longer the
    /// run's last.
    private mutating func resume() {
        if run.isEnded {
            run = Run(place: .loose)
        } else if case .above = run.place {
            run.place = .above(seen: true)
        }
        run.decline = nil
    }

    private mutating func settleDecline() {
        guard !run.isEnded, let decline = run.decline else { return }
        end(.interrupted, at: decline.endedAt)
    }

    private mutating func end(_ ending: ChatTurn.Ending, at endedAt: Date?) {
        guard !run.isEnded else { return }
        switch run.place {
        case .turn(let index):
            transcript.turns[index].ending = ending
            transcript.turns[index].endedAt = endedAt
        case .above:
            transcript.precedingTurnEnd = ChatTurnEnd(ending: ending, endedAt: endedAt)
        case .loose:
            break
        }
        endQuietly()
    }

    /// Ends the run without an ending of its own: its tools still running
    /// never completed.
    private mutating func endQuietly() {
        for index in run.runningTools {
            guard case .tool(var tool) = transcript.entries[index].content else { continue }
            tool.status = .notCompleted
            transcript.entries[index].content = .tool(tool)
        }
        run.runningTools = []
        run.isEnded = true
    }

    // MARK: Entries

    private func entryID(_ row: OpenCodeRow, _ suffix: String = "") -> ChatEntryID {
        ChatEntryID("oc:\(row.id)\(suffix)")
    }

    private mutating func add(_ row: OpenCodeRow, _ content: ChatEntry.Content, _ suffix: String = "") {
        append(
            ChatEntry(id: entryID(row, suffix), sourceOffset: OpenCodeTranscriptReducer.offset(row.seq), content: content))
    }

    private static func isDeclined(_ tool: OpenCodeTool) -> Bool {
        tool.status == "error" && tool.error?.type == "aborted"
            && OpenCodeToolSummary.declinedMessages.contains(tool.error?.message ?? "")
    }

    /// Whether the source cut `text`: `length` counts what OpenCode stored,
    /// in characters as SQLite counts them.
    private static func isCut(_ text: String, length: Int?) -> Bool {
        (length ?? 0) > text.unicodeScalars.count
    }

    /// Text as its entry shows it, saying when the source cut it.
    private static func shown(_ text: String, isCut: Bool) -> String {
        isCut ? text + "\n\n(truncated in Chat)" : text
    }

    /// OpenCode stores a prompt as typed, trailing space included.
    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension OpenCodeStep {
    /// The step's tool calls, in order.
    var tools: [OpenCodeTool] {
        items.compactMap { item in
            guard case .tool(let tool) = item.kind else { return nil }
            return tool
        }
    }
}
