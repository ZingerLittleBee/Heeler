import Foundation

/// How a recorded user message reads in Chat, following the Codex TUI's own
/// display rules (`user_messages.rs`): an answer to an async question is an
/// Answered row rather than a bubble, an IDE preamble folds into a chip, and
/// a recognized `$skill` prompt reads as `/skill`.
enum CodexMessageFormatter {
    /// Ends the IDE context the desktop app and IDE extension prepend; the
    /// request follows the last occurrence.
    static let ideRequestMarker = "## My request for Codex:"
    static let ideContextPrefix = "# Context from my IDE setup:\n"
    /// The chip that stands in for a folded IDE preamble.
    static let ideContextLabel = "IDE context"

    private static let replyOpen = "<send_user_message_question_reply>"
    private static let replyClose = "</send_user_message_question_reply>"

    /// One answer in an async-question reply envelope.
    struct QuestionReply: Equatable, Sendable, Decodable {
        var questionItemID: String
        var question: String
        var answer: String

        init(questionItemID: String, question: String, answer: String) {
            self.questionItemID = questionItemID
            self.question = question
            self.answer = answer
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodexKey.self)
            questionItemID = try container.decode(String.self, forKey: "questionItemId")
            question = try container.decode(String.self, forKey: "question")
            answer = try container.decode(String.self, forKey: "answer")
        }
    }

    enum Display: Equatable, Sendable {
        case message(ChatUserMessage)
        case reply([QuestionReply])
    }

    /// The display for a user message. `skillNames` are the Host's skills,
    /// for `$name` prompts the TUI recorded without a skill part (plugin
    /// skills, legacy rollouts).
    static func display(
        _ content: CodexUserContent, skillNames: Set<String>, wasQueued: Bool = false
    ) -> Display {
        if let replies = questionReplies(in: content.text) {
            return .reply(replies)
        }
        var labels = content.attachmentLabels
        var body = content.text
        if let request = ideRequest(in: body) {
            body = request
            labels.insert(ideContextLabel, at: 0)
        }
        let known = skillNames.union(content.skillNames)
        return .message(
            ChatUserMessage(
                text: body, imageCount: content.imageCount, attachmentLabels: labels,
                command: skillInvocation(in: body, knownSkills: known), wasQueued: wasQueued))
    }

    /// The request after the last IDE marker, trimmed; nil when the text has
    /// no marker (`extract_prompt_request_with_offset`).
    static func ideRequest(in text: String) -> String? {
        guard let marker = text.range(of: ideRequestMarker, options: .backwards) else { return nil }
        return String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answers in an async-question reply: optionally after the IDE
    /// preamble, exactly one `<send_user_message_question_reply>` element
    /// whose body is a JSON array or object of `{questionItemId, question,
    /// answer}` (`async_question_reply.rs`). JSON escapes newlines, so the
    /// IDE marker cannot match inside an answer.
    static func questionReplies(in text: String) -> [QuestionReply]? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(ideContextPrefix) {
            guard let marker = text.range(of: "\n" + ideRequestMarker + "\n", options: .backwards) else {
                return nil
            }
            text = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.hasPrefix(replyOpen), text.hasSuffix(replyClose),
            text.count >= replyOpen.count + replyClose.count
        else { return nil }
        let json = Data(text.dropFirst(replyOpen.count).dropLast(replyClose.count).utf8)
        let decoder = JSONDecoder()
        if let replies = try? decoder.decode([QuestionReply].self, from: json) {
            return replies.isEmpty ? nil : replies
        }
        if let reply = try? decoder.decode(QuestionReply.self, from: json) {
            return [reply]
        }
        return nil
    }

    /// `$name rest` as a skill invocation when `name` is a known skill.
    /// Names follow Codex core (`[A-Za-z0-9_:-]`, which admits plugin skills
    /// `plugin:skill`) and must be followed by whitespace or the end, so
    /// `$HOME/x` or an unknown `$word` stays text.
    static func skillInvocation(in text: String, knownSkills: Set<String>) -> ChatCommandInvocation? {
        guard text.hasPrefix("$") else { return nil }
        let name = text.dropFirst().prefix { character in
            character.isASCII && (character.isLetter || character.isNumber || "_:-".contains(character))
        }
        guard !name.isEmpty, knownSkills.contains(String(name)) else { return nil }
        let rest = text.dropFirst(1 + name.count)
        if let next = rest.first, !next.isWhitespace {
            return nil
        }
        let arguments = rest.drop { $0.isWhitespace }
        return ChatCommandInvocation(name: String(name), arguments: String(arguments))
    }

    /// The id the TUI gives question `index` of an async question message:
    /// `JSON.stringify(["request_user_input_async", itemID, index])`.
    static func asyncQuestionID(itemID: String, index: Int) -> String {
        "[\"request_user_input_async\",\(jsonString(itemID)),\(index)]"
    }

    /// `value` as a JSON string literal, escaped the way `serde_json` and
    /// `JSON.stringify` escape it.
    static func jsonString(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    /// True for legacy `user_message` events that carried model context
    /// rather than a prompt. Codex 0.45 still emitted them for the
    /// environment and user instructions and tagged them with `kind`.
    static func isContextualLegacyMessage(_ text: String, kind: String?) -> Bool {
        if let kind, kind == "environment_context" || kind == "user_instructions" {
            return true
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (trimmed.hasPrefix("<environment_context>") && trimmed.hasSuffix("</environment_context>"))
            || (trimmed.hasPrefix("<user_instructions>") && trimmed.hasSuffix("</user_instructions>"))
    }

    /// An assistant message's text: its parts joined.
    static func assistantText(_ parts: [String]) -> String {
        parts.joined()
    }
}
