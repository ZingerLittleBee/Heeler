import Foundation

/// What the text of a user record is.
///
/// Claude Code stores much of what its terminal shows as system UI as user
/// text wrapped in a tag: commands, shell mode, background task
/// notifications, reminders. Only a tag at the very start of the trimmed text
/// classifies; a prompt that mentions `<command-name>` further in is still a
/// prompt, because it is what the person typed.
enum ClaudeUserText: Sendable, Equatable {
    /// Words the user wrote, with any `<pasted_content>` wrapper removed.
    case prompt(String)
    /// `/name args`: a skill or prompt command the user typed.
    case command(ChatCommandInvocation)
    /// A skill the model loaded, written without the slash
    /// (`<skill-format>true</skill-format>`).
    case skillLoaded(ChatCommandInvocation)
    /// Output of a local command, as older releases recorded it.
    case localCommandOutput(String)
    /// A shell-mode (`!`) command.
    case bashInput(String)
    /// A shell-mode command's output, unescaped.
    case bashOutput(String)
    case taskNotification(ClaudeTaskNotification)
    /// A message from outside the conversation: a channel, a teammate, a
    /// review service.
    case external(String)
    /// Model-only context: reminders, caveats, hook text.
    case hidden

    static let commandTags: Set<String> = ["command-name", "command-message", "command-args", "command-contents"]
    static let localOutputTags: Set<String> = ["local-command-stdout", "local-command-stderr"]
    static let bashOutputTags: Set<String> = ["bash-stdout", "bash-stderr", "bash-exit-code"]
    static let hiddenTags: Set<String> = [
        "local-command-caveat", "system-reminder", "system_reminder", "user-prompt-submit-hook",
        "function_results", "tool_use_error", "sandbox_violations", "persisted-output",
        "total_tokens", "tick", "fork-boilerplate", "forked-skill-launch", "fork-source",
        "message-files-missing", "skill-format",
    ]
    static let externalTags: Set<String> = [
        "teammate-message", "channel", "cross-session-message", "slack-ping", "slack-tag-message",
        "agent-message", "coordinator-relay", "remote-review", "fetched-web-content",
    ]

    /// The texts an interrupted or cut-short call is recorded with (CLI
    /// `the`, SDK `LI`), plus the expired-approval texts.
    static let markers = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
        "[Tool call did not complete:",
        "[Tool call interrupted:",
        "[Tool call result not in this copy:",
        "The user doesn't want to take this action right now.",
        "[Tool call skipped:",
        "[Tool call not completed:",
    ]

    static func isMarker(_ text: String) -> Bool {
        markers.contains { text.hasPrefix($0) }
    }

    static func classify(_ text: String) -> ClaudeUserText {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tag = ClaudeText.leadingTag(of: trimmed) else {
            return .prompt(unwrappingPastedContent(text))
        }
        if commandTags.contains(tag) {
            let rawName = (ClaudeText.content(ofTag: "command-name", in: trimmed)
                ?? ClaudeText.content(ofTag: "command-message", in: trimmed) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let arguments = (ClaudeText.content(ofTag: "command-args", in: trimmed) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isSkillFormat =
                ClaudeText.content(ofTag: "skill-format", in: trimmed)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            if !rawName.hasPrefix("/"), isSkillFormat {
                return .skillLoaded(ChatCommandInvocation(name: rawName, arguments: arguments))
            }
            let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
            return .command(ChatCommandInvocation(name: name, arguments: arguments))
        }
        if localOutputTags.contains(tag) {
            return .localCommandOutput(
                ClaudeText.joinedContent(ofTags: ["local-command-stdout", "local-command-stderr"], in: trimmed))
        }
        if tag == "bash-input" {
            return .bashInput(ClaudeText.content(ofTag: tag, in: trimmed) ?? "")
        }
        if bashOutputTags.contains(tag) {
            // The CLI escapes `&`, `<` and `>` in shell output so it cannot
            // close the tags (`processBashCommand`, chunk-w4wsehjz.js:361).
            return .bashOutput(
                ClaudeText.unescapingMarkup(
                    ClaudeText.joinedContent(ofTags: ["bash-stdout", "bash-stderr"], in: trimmed)))
        }
        if tag == "task-notification" {
            return .taskNotification(ClaudeTaskNotification(trimmed))
        }
        if hiddenTags.contains(tag) {
            return .hidden
        }
        if externalTags.contains(tag) {
            return .external(ClaudeText.content(ofTag: tag, in: trimmed) ?? trimmed)
        }
        return .prompt(unwrappingPastedContent(text))
    }

    /// Replaces each `<pasted_content id="abcd">` block with the paste it
    /// holds, as Claude Code itself does (CLI `qTt` and `Khe`,
    /// chunk-r9sh95qa.js): the id is four lowercase hex digits, and up to two
    /// newlines on either side belong to the wrapper. The CLI wraps pastes
    /// this way behind a flag that is off by default; the paste is what the
    /// user sent. The markers are ASCII, so the work happens on UTF-8 bytes.
    static func unwrappingPastedContent(_ text: String) -> String {
        guard text.contains(#"<pasted_content id=""#) else { return text }
        let bytes = Array(text.utf8)
        let opener = Array(#"<pasted_content id=""#.utf8)
        let newline = UInt8(ascii: "\n")
        var parts: [ArraySlice<UInt8>] = []
        var textStart = 0
        var searchStart = 0
        var unwrapped = false
        while let open = bytes[searchStart...].firstRange(of: opener) {
            let idEnd = open.upperBound + 4
            guard idEnd + 3 <= bytes.count, bytes[open.upperBound..<idEnd].allSatisfy(isLowercaseHexDigit),
                bytes[idEnd..<idEnd + 3].elementsEqual(#"">\#n"#.utf8)
            else {
                searchStart = open.upperBound
                continue
            }
            let bodyStart = idEnd + 3
            // The closer's own newline may be the opener's, for an empty paste.
            let closer = Array("\n</pasted_content id=\"".utf8) + bytes[open.upperBound..<idEnd] + Array("\">".utf8)
            guard let close = bytes[(bodyStart - 1)...].firstRange(of: closer) else { break }
            var textEnd = open.lowerBound
            var dropped = 0
            while dropped < 2, textEnd > textStart, bytes[textEnd - 1] == newline {
                textEnd -= 1
                dropped += 1
            }
            parts.append(bytes[textStart..<textEnd])
            parts.append(bytes[bodyStart..<max(bodyStart, close.lowerBound)])
            textStart = close.upperBound
            dropped = 0
            while dropped < 2, textStart < bytes.count, bytes[textStart] == newline {
                textStart += 1
                dropped += 1
            }
            searchStart = textStart
            unwrapped = true
        }
        guard unwrapped else { return text }
        parts.append(bytes[textStart...])
        return String(decoding: parts.joined(), as: UTF8.self)
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
}

/// A `<task-notification>`: a background task (usually an async subagent)
/// stopped.
struct ClaudeTaskNotification: Sendable, Equatable {
    var summary: String?
    /// `completed`, `failed`, `killed`, `stopped`, …
    var status: String?
    /// The tool call that launched the task.
    var toolUseID: String?
    var taskID: String?
    var result: String?
    var usage: ChatBackgroundWorkItem.Usage?

    init(
        summary: String? = nil, status: String? = nil, toolUseID: String? = nil, taskID: String? = nil,
        result: String? = nil, usage: ChatBackgroundWorkItem.Usage? = nil
    ) {
        self.summary = summary
        self.status = status
        self.toolUseID = toolUseID
        self.taskID = taskID
        self.result = result
        self.usage = usage
    }

    init(_ text: String) {
        func field(_ tag: String) -> String? {
            ClaudeText.content(ofTag: tag, in: text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.init(
            summary: field("summary"), status: field("status"), toolUseID: field("tool-use-id"),
            taskID: field("task-id"), result: field("result"),
            usage: Self.usageText(in: text).map(Self.usage))
    }

    /// The program writes `<usage>` after `<result>`, the agent's own report,
    /// which can quote one; the last is the program's.
    private static func usageText(in text: String) -> String? {
        guard let open = text.range(of: "<usage>", options: .backwards) else { return nil }
        return ClaudeText.content(ofTag: "usage", in: String(text[open.lowerBound...]))
    }

    /// `<usage>`: counts for a Subagent, and for a Workflow the counts of
    /// the agents it ran.
    private static func usage(_ text: String) -> ChatBackgroundWorkItem.Usage {
        func count(_ tag: String) -> Int? {
            ClaudeText.content(ofTag: tag, in: text).flatMap {
                Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return ChatBackgroundWorkItem.Usage(
            tokens: count("subagent_tokens"), toolUses: count("tool_uses"),
            durationMilliseconds: count("duration_ms"), agents: count("agent_count"),
            agentsDone: count("agents_done"), agentsFailed: count("agents_error"))
    }

    /// The notice's title: the summary Claude Code wrote, or the status.
    var title: String {
        if let summary, !summary.isEmpty { return summary }
        return "Background task \(status ?? "finished")"
    }
}

/// Text helpers for tagged transcript content.
enum ClaudeText {
    /// The longest title a notice takes from free text; the rest goes to its
    /// detail.
    static let maximumTitleLength = 200

    /// The name of the tag `text` starts with, if it starts with one.
    static func leadingTag(of text: String) -> String? {
        guard text.hasPrefix("<") else { return nil }
        var name = ""
        for character in text.dropFirst() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                name.append(character)
            } else if character == ">" || character.isWhitespace {
                return name.isEmpty ? nil : name
            } else {
                return nil
            }
        }
        return nil
    }

    /// The text inside the first `<tag>` (attributes allowed), up to its
    /// closing tag or, when that is missing, the end.
    static func content(ofTag tag: String, in text: String) -> String? {
        var searchStart = text.startIndex
        while let open = text.range(of: "<\(tag)", range: searchStart..<text.endIndex) {
            guard open.upperBound < text.endIndex else { return nil }
            let next = text[open.upperBound]
            guard next == ">" || next.isWhitespace else {
                searchStart = open.upperBound
                continue
            }
            guard let openEnd = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return nil }
            let body = openEnd.upperBound..<text.endIndex
            guard let close = text.range(of: "</\(tag)>", range: body) else {
                return String(text[body])
            }
            return String(text[openEnd.upperBound..<close.lowerBound])
        }
        return nil
    }

    /// The non-empty contents of `tags`, in that order, one per line, with
    /// terminal escapes removed.
    static func joinedContent(ofTags tags: [String], in text: String) -> String {
        tags.compactMap { content(ofTag: $0, in: text) }
            .map { strippingTerminalEscapes($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Removes ANSI escape sequences (CSI and OSC) that local command output
    /// carries for the terminal.
    static func strippingTerminalEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = ""
        var scalars = text.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            guard scalar == "\u{1B}" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            switch scalars.first {
            case "[":
                scalars = scalars.dropFirst()
                // Parameters and intermediates run until a final byte in @...~.
                while let next = scalars.popFirst(), !(0x40...0x7E).contains(next.value) {}
            case "]":
                scalars = scalars.dropFirst()
                // An OSC string ends at BEL or ESC \.
                while let next = scalars.popFirst() {
                    if next == "\u{07}" { break }
                    if next == "\u{1B}" {
                        if scalars.first == "\\" { scalars = scalars.dropFirst() }
                        break
                    }
                }
            default:
                scalars = scalars.dropFirst()
            }
        }
        return result
    }

    /// Reverses the CLI's `$t` escaping of `&`, `<` and `>`.
    static func unescapingMarkup(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Caps the parts joined by newlines without building more than the cap
    /// from parts that may each be megabytes long.
    static func preview(joining parts: [String], imageCount: Int = 0) -> ChatToolPreview {
        var text = ""
        var truncated = false
        for part in parts {
            let capped = ChatToolPreview(capping: part)
            text += text.isEmpty ? capped.text : "\n" + capped.text
            if capped.isTruncated {
                truncated = true
                break
            }
        }
        let preview = ChatToolPreview(capping: text, imageCount: imageCount)
        return ChatToolPreview(
            text: preview.text, isTruncated: truncated || preview.isTruncated, imageCount: imageCount)
    }

    /// A notice built from free text: its first non-empty line as the title,
    /// and the whole text, capped, as the detail when there is more.
    static func noticeParts(_ text: String) -> (title: String, detail: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine =
            trimmed.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let title = String(firstLine.prefix(maximumTitleLength))
        guard title != trimmed else { return (title, nil) }
        return (title, ChatToolPreview(capping: trimmed).text)
    }
}
