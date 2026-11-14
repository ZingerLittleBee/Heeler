import Foundation

/// One line of an Antigravity CLI `transcript_full.jsonl`: one step of the
/// conversation, which agy writes once the step is done and never rewrites.
///
/// Every line has `step_index`, `source`, `type`, `status` and `created_at`,
/// in that order, so a line cut short still says what it was. The full file
/// records tool arguments as JSON values; the compact `transcript.jsonl`
/// beside it encodes them as strings and cuts long fields.
struct AgyStep: Sendable {
    enum Kind: Equatable, Sendable {
        /// `USER_INPUT`: a prompt, wrapped in `<USER_REQUEST>`.
        case userInput
        /// `PLANNER_RESPONSE`: the model's thinking, text and tool calls.
        case plannerResponse
        /// `GENERIC`: one tool call's result.
        case toolResult
        /// `SYSTEM_MESSAGE`: a background task's end, a restart notice, a
        /// message from another agent or a reminder.
        case systemMessage
        /// `CHECKPOINT`: a compaction's summary.
        case checkpoint
        /// `ERROR_MESSAGE`: an error the agent carries on after.
        case errorMessage
        /// `EPHEMERAL_MESSAGE`, which issue #644 names and 1.5.3 never
        /// wrote: nothing to show.
        case ephemeral
        case unknown(String)
    }

    enum Status: Equatable, Sendable {
        case done
        /// A tool result sent to the background; its end comes in a later
        /// system message.
        case running
        case error
        case other(String)
    }

    /// One `tool_calls` element. agy records no call id: results follow
    /// their planner response in call order.
    struct Call: Sendable {
        let name: String
        let args: JSONValue?
    }

    struct Media: Sendable {
        let mimeType: String?
        let uri: String?
    }

    let offset: UInt64
    let length: Int
    let isTruncated: Bool
    let stepIndex: Int?
    let kind: Kind
    let status: Status
    /// The step's start, UTC to the second.
    let createdAt: Date?
    /// The model slug recorded on a `PLANNER_RESPONSE` step (agy 1.5.9+).
    let model: String?
    let content: String?
    let thinking: String?
    let calls: [Call]
    let error: String?
    let media: [Media]

    static func decode(_ line: ChatLine) -> AgyStep? {
        // A cut line still parses up to its last complete value, which keeps
        // the step's index, type and status ahead of any long field.
        let data = line.isTruncated ? CodexJSONPrefix.repaired(line.data) : line.data
        guard let data, let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            let type = value["type"]?.stringValue
        else { return nil }
        var calls: [Call] = []
        if case .array(let items)? = value["tool_calls"] {
            for item in items {
                guard let name = item["name"]?.stringValue else { continue }
                calls.append(Call(name: name, args: item["args"]))
            }
        }
        var media: [Media] = []
        if case .array(let items)? = value["media"] {
            for item in items {
                media.append(Media(mimeType: item["mime_type"]?.stringValue, uri: item["uri"]?.stringValue))
            }
        }
        return AgyStep(
            offset: line.offset, length: line.length, isTruncated: line.isTruncated,
            stepIndex: integer(value["step_index"]), kind: kind(type), status: status(value["status"]?.stringValue),
            createdAt: value["created_at"]?.stringValue.flatMap(date), model: value["model"]?.stringValue,
            content: value["content"]?.stringValue, thinking: value["thinking"]?.stringValue, calls: calls,
            error: value["error"]?.stringValue, media: media)
    }

    private static func kind(_ type: String) -> Kind {
        switch type {
        case "USER_INPUT": .userInput
        case "PLANNER_RESPONSE": .plannerResponse
        case "GENERIC": .toolResult
        case "SYSTEM_MESSAGE": .systemMessage
        case "CHECKPOINT": .checkpoint
        case "ERROR_MESSAGE": .errorMessage
        case "EPHEMERAL_MESSAGE": .ephemeral
        default: .unknown(type)
        }
    }

    private static func status(_ text: String?) -> Status {
        switch text {
        case "DONE": .done
        case "RUNNING": .running
        case "ERROR": .error
        default: .other(text ?? "")
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value else { return nil }
        return Int(exactly: number)
    }

    /// `2026-11-07T15:52:19Z`, UTC to the second.
    static func date(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }

    // MARK: Content

    /// The prompt in a `USER_INPUT`: the text between `<USER_REQUEST>` and
    /// its closing tag, which agy writes on lines of their own.
    /// `isComplete` is false when the closing tag is missing, as on a cut
    /// line.
    var request: (text: String, isComplete: Bool)? {
        guard let content else { return nil }
        guard let open = content.range(of: "<USER_REQUEST>") else {
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (text, !isTruncated)
        }
        let body = content[open.upperBound...]
        guard let close = body.range(of: "</USER_REQUEST>") else {
            return (body.trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
        return (body[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    /// The model and effort a `USER_INPUT`'s `<USER_SETTINGS_CHANGE>` block
    /// recorded after `</USER_REQUEST>`. Read only outside `<USER_REQUEST>` so
    /// pasted prompt text cannot impersonate a setting change.
    var modelSelection: (model: String, effort: String?)? {
        guard kind == .userInput, let content,
            let afterRequest = content.range(of: "</USER_REQUEST>")?.upperBound
        else { return nil }
        let prefix = "The user changed setting `Model Selection` from "
        var search = content[afterRequest...]
        var latest: (model: String, effort: String?)?
        while let open = search.range(of: "<USER_SETTINGS_CHANGE>"),
            let close = search[open.upperBound...].range(of: "</USER_SETTINGS_CHANGE>")
        {
            for rawLine in search[open.upperBound..<close.lowerBound].split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix(prefix) else { continue }
                var rest = String(line.dropFirst(prefix.count))
                if let comment = rest.range(of: ". No need to comment") {
                    rest = String(rest[..<comment.lowerBound])
                } else if rest.hasSuffix(".") {
                    rest.removeLast()
                }
                guard let sep = rest.range(of: " to ") else { continue }
                let rawLabel = rest[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawLabel.isEmpty, rawLabel != "None" else { continue }
                latest = AgyModelCatalog.resolveDisplayLabel(rawLabel, in: AgyModelCatalog.defaultChoices)
            }
            search = search[close.upperBound...]
        }
        return latest
    }

    /// The model and effort a `PLANNER_RESPONSE` step recorded in its `"model"`
    /// slug (such as `"gemini-4-carbon-high"`). Keeps long conversations whose
    /// initial `<USER_SETTINGS_CHANGE>` sits above the 256 KiB tail window
    /// reporting their active model.
    var plannerModel: (model: String, effort: String?)? {
        guard kind == .plannerResponse, let model else { return nil }
        return AgyModelCatalog.resolveModelSlug(model)
    }

    /// A tool result's text without the `Created At` and `Completed At`
    /// lines agy starts it with.
    var resultBody: String {
        var lines = (content ?? "")[...]
        for prefix in ["Created At: ", "Completed At: "] where lines.hasPrefix(prefix) {
            if let newline = lines.firstIndex(of: "\n") {
                lines = lines[lines.index(after: newline)...]
            } else {
                lines = ""
            }
        }
        return String(lines)
    }

    /// The text of a `<SYSTEM_MESSAGE>`: after the preamble agy puts before
    /// the tag, which names the tag too, and for a message from another
    /// sender, after its `[Message] … content=` header.
    var systemMessageText: String? {
        guard let content else { return nil }
        var body = content[...]
        if let open = body.range(of: "<SYSTEM_MESSAGE>\n") {
            body = body[open.upperBound...]
            if let close = body.range(of: "</SYSTEM_MESSAGE>", options: .backwards) {
                body = body[..<close.lowerBound]
            }
        }
        body = body.drop { $0.isNewline }
        if body.hasPrefix("[Message]"), let header = body.range(of: " content=") {
            body = body[header.upperBound...]
        }
        return String(body)
    }
}
