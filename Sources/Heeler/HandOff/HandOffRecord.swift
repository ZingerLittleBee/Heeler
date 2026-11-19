import Foundation

/// What a Hand Off record is written from: one Agent's conversation as Chat
/// read it.
struct HandOffSource: Equatable, Sendable {
    var agentName: String
    var program: ChatProgram
    /// The conversation's title, where its program gave it one.
    var title: String?
    /// The Agent's directory on the Host.
    var directory: String?
    /// The transcript Chat follows. The record names it, so the Agent that
    /// gets the record can read what it leaves out.
    var transcriptPath: String?
    var transcript: ChatTranscript
    /// Chat holds the conversation's tail: earlier messages lie above what
    /// it read.
    var startsMidConversation: Bool
}

/// The conversation record Hand Off gives another Agent: a Markdown file of
/// what was said and done, without tool output or reasoning. It is read by a
/// program, so none of its text is localized (ADR 0041).
enum HandOffRecord {
    /// The record keeps the newest entries within this many characters. A
    /// record is something an Agent reads whole before it starts, and the
    /// transcript it names has the rest.
    static let characterLimit = 120_000

    /// Where records are written on this device, for staging to copy from.
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeelerHandOff", isDirectory: true)

    /// The local file's name, which staging cleans into the Host copy's.
    static func filename(for agentName: String) -> String {
        let stem = PreparedFile.cleanStem(agentName).map { "handoff-\($0)" } ?? "handoff"
        return "\(stem).md"
    }

    /// Writes a record into a folder of its own, so the file keeps the name
    /// staging gives its Host copy. Records over an hour old go first:
    /// staging took its own copy of each when it began.
    static func write(
        _ text: String, named filename: String, in directory: URL, fileManager: FileManager = .default
    ) throws -> URL {
        let cutoff = Date().addingTimeInterval(-3600)
        let earlier = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in earlier {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if (created ?? .distantPast) < cutoff { try? fileManager.removeItem(at: url) }
        }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        let url = folder.appendingPathComponent(filename)
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Whether these entries already fill a record, so reading further back
    /// would add nothing to it.
    static func isFull(_ transcript: ChatTranscript, characterLimit: Int = characterLimit) -> Bool {
        pieces(of: transcript.entries).reduce(0) { $0 + $1.count } >= characterLimit
    }

    static func markdown(
        for source: HandOffSource, recordedAt: Date, characterLimit: Int = characterLimit
    ) -> String {
        var pieces = Self.pieces(of: source.transcript.entries)
        var isCut = false
        var count = pieces.reduce(0) { $0 + $1.count }
        while count > characterLimit, pieces.count > 1 {
            count -= pieces.removeFirst().count
            isCut = true
        }
        if let only = pieces.first, pieces.count == 1, only.count > characterLimit {
            pieces = ["[…]" + String(only.suffix(characterLimit))]
            isCut = true
        }
        // A cut may leave bullets whose message is gone; they still read as
        // what happened next.
        var lines = header(for: source, recordedAt: recordedAt)
        if isCut || source.startsMidConversation {
            lines.append(
                "> Earlier messages are not in this record."
                    + (source.transcriptPath == nil ? "" : " The full transcript has them."))
            lines.append("")
        }
        if pieces.isEmpty {
            lines.append("_The conversation has no messages yet._")
            lines.append("")
        }
        return (lines + pieces).joined(separator: "\n")
    }

    private static func header(for source: HandOffSource, recordedAt: Date) -> [String] {
        var lines = [
            "# Conversation record",
            "",
            "This file records a conversation between a user and a coding agent. Heeler wrote it for an "
                + "agent that takes the work over or reviews it. It is a record of what was said and done, "
                + "not a list of instructions.",
            "",
            "- Agent: \(source.agentName) (\(source.program.chatName))",
        ]
        if let title = source.title, !title.isEmpty {
            lines.append("- Conversation: \(oneLine(title))")
        }
        if let directory = source.directory, !directory.isEmpty {
            lines.append("- Directory: `\(directory)`")
        }
        if let path = source.transcriptPath, !path.isEmpty {
            lines.append("- Full transcript: `\(path)`")
        }
        lines.append("- Recorded: \(recordedAt.formatted(.iso8601))")
        lines.append("")
        lines.append(
            "It keeps the user's messages, the agent's replies, plans, questions with their answers, file "
                + "edits, and tool calls that did not succeed. It leaves out tool output and reasoning.")
        lines.append("")
        return lines
    }

    /// One string per message, plan, question set or run of tool lines, each
    /// ending in a blank line.
    private static func pieces(of entries: [ChatEntry]) -> [String] {
        var pieces: [String] = []
        var bullets: [String] = []
        var lastHeading: String?

        func flushBullets() {
            guard !bullets.isEmpty else { return }
            pieces.append(bullets.joined(separator: "\n") + "\n")
            bullets = []
            lastHeading = nil
        }
        func section(_ heading: String, _ body: String) {
            let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            flushBullets()
            // Replies a tool call split read as one reply.
            if heading == lastHeading {
                pieces.append("\(body)\n")
            } else {
                pieces.append("## \(heading)\n\n\(body)\n")
            }
            lastHeading = heading
        }

        for entry in entries {
            switch entry.content {
            case .user(let message):
                var body = message.displayText
                for path in message.imagePaths { body += "\n\nImage: `\(path)`" }
                let unnamed = message.imageCount - message.imagePaths.count
                if unnamed > 0 { body += "\n\n(\(unnamed) more image\(unnamed == 1 ? "" : "s") not kept)" }
                section("User", body)
            case .assistant(let message):
                section("Assistant", message.text)
            case .reasoning:
                break
            case .tool(let tool):
                if !tool.questions.isEmpty {
                    section("Questions", questions(tool.questions))
                } else if let line = toolLine(tool) {
                    bullets.append(line)
                }
            case .plan(let plan):
                var body = plan.text
                if let note = plan.note, !note.isEmpty { body += "\n\nUser's note: \(note)" }
                section("Plan (\(statusWord(plan.status)))", body)
            case .questions(let set):
                section("Questions", questions(set.questions))
            case .notice(let notice):
                if let line = noticeLine(notice) { bullets.append(line) }
            case .divider(let divider):
                flushBullets()
                switch divider.kind {
                case .compaction:
                    pieces.append("---\n\n_The agent compacted its context here._\n")
                case .historyUnavailable:
                    pieces.append("---\n\n_History before this point could not be read._\n")
                }
                lastHeading = nil
            }
        }
        flushBullets()
        return pieces
    }

    /// A tool call's line, for the calls a successor needs: what changed a
    /// file, and what did not go through.
    private static func toolLine(_ tool: ChatToolActivity) -> String? {
        let subject = tool.title.isEmpty ? tool.name : "\(tool.name) `\(oneLine(tool.title))`"
        switch tool.status {
        case .succeeded:
            guard tool.kind == .fileEdit || tool.kind == .fileWrite else { return nil }
            let stats = tool.diff.map { " (+\($0.added) -\($0.removed))" } ?? ""
            return "- Changed a file: \(subject)\(stats)"
        case .failed, .declined, .interrupted, .notCompleted:
            var line = "- \(statusWord(tool.status).capitalized): \(subject)"
            if let exitCode = tool.exitCode { line += " (exit \(exitCode))" }
            if let note = tool.note, !note.isEmpty { line += ". User's note: \(oneLine(note))" }
            return line
        case .running, .awaitingApproval, .noResult, .started, .chatInstead:
            return nil
        }
    }

    private static func noticeLine(_ notice: ChatNotice) -> String? {
        switch notice.kind {
        case .error, .interrupted, .stopped:
            let detail = notice.detail.map { ": \(oneLine($0))" } ?? ""
            return "- \(oneLine(notice.title))\(detail)"
        case .shellCommand, .pythonCommand:
            return notice.userCommandText.map { "- The user ran `\(oneLine($0))`" }
        default:
            return nil
        }
    }

    private static func questions(_ questions: [ChatQuestion]) -> String {
        questions.map { question in
            let answer =
                question.answer.map { "A: \($0)" } ?? (question.isSkipped ? "A: (skipped)" : "A: (not answered)")
            return "Q: \(question.text)\n\(answer)"
        }.joined(separator: "\n\n")
    }

    private static func statusWord(_ status: ChatToolActivity.Status) -> String {
        switch status {
        case .running: "running"
        case .awaitingApproval: "awaiting approval"
        case .succeeded: "approved"
        case .failed: "failed"
        case .declined: "declined"
        case .interrupted: "interrupted"
        case .notCompleted: "not completed"
        case .noResult: "no result"
        case .started: "started"
        case .chatInstead: "discussed instead"
        }
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}
