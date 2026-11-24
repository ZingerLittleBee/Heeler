import Foundation

/// A Claude Code teammate's own files beside the session's transcript
/// (Claude Code 2.1.331): `subagents/agent-<agentId>.meta.json` says who it
/// is, and `subagents/agent-<agentId>.jsonl` records its turns.
enum ClaudeTeammateFiles {
    struct Meta: Equatable, Sendable {
        var name: String
        /// The task the lead gave it, its row's title.
        var description: String?
    }

    /// The agent id in a meta file's name, for a named agent only: a
    /// teammate's id is `a<name>-<16 hex>`, and a Subagent without a name
    /// has one with no hyphen, whose meta is not read.
    static func agentID(metaFileName name: String) -> String? {
        let prefix = "agent-"
        let suffix = ".meta.json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else {
            return nil
        }
        let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard id.contains("-"), ClaudeTranscriptLocation.isSafeComponent(id) else { return nil }
        return id
    }

    /// A teammate's meta file; nil for any other agent's.
    static func teammate(meta data: Data) -> Meta? {
        struct Raw: Decodable {
            var taskKind: String?
            var name: String?
            var description: String?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.taskKind == "in_process_teammate",
            let name = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        let description = raw.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Meta(name: name, description: description?.isEmpty == false ? description : nil)
    }
}

/// Where a teammate's latest turn stands, as the end of its own transcript
/// says. A turn opens with a prompt, its first message or one from its
/// mailbox, and ends with an answer that calls no tool; the teammate then
/// waits on its mailbox.
enum ClaudeTeammateTurn: Equatable, Sendable {
    /// A turn runs, since its prompt: nil when the prompt was not read.
    case running(since: Date?)
    /// Its latest turn ended: done, failed on an API error, or interrupted
    /// or shut down.
    case ended(at: Date?, state: ChatBackgroundWorkItem.State)

    /// The latest turn the records in `data` show, a file's last bytes:
    /// unless they start at the file's start, the first line may be cut
    /// and is skipped, as is a last line not yet finished. Nil when no
    /// record says.
    static func latest(in data: Data, startsAtFileStart: Bool) -> ClaudeTeammateTurn? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        // The last element follows the last newline: a line still written.
        lines.removeLast()
        if !startsAtFileStart, !lines.isEmpty { lines.removeFirst() }
        // The oldest step after the boundary found, read from the end.
        var firstStepAfter: Date?
        var sawStep = false
        for line in lines.reversed() {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                continue
            }
            let at = ClaudeTranscriptProjection.date(record["timestamp"] as? String)
            switch Self.mark(of: record) {
            case .step:
                sawStep = true
                firstStepAfter = at ?? firstStepAfter
            case .prompt:
                return .running(since: at)
            case .end(let state):
                // Steps after an end with no prompt between: a turn that
                // opened some other way.
                return sawStep ? .running(since: firstStepAfter) : .ended(at: at, state: state)
            case nil:
                continue
            }
        }
        return sawStep ? .running(since: nil) : nil
    }

    private enum Mark {
        case step
        case prompt
        case end(ChatBackgroundWorkItem.State)
    }

    private static func mark(of record: [String: Any]) -> Mark? {
        let message = record["message"] as? [String: Any]
        switch record["type"] as? String {
        case "assistant":
            if let stop = message?["stop_reason"] as? String, stop != "tool_use" {
                return .end(record["isApiErrorMessage"] as? Bool == true ? .failed : .completed)
            }
            // Approving the lead's shutdown request is its last act: it
            // exits before the call's result is written.
            return Self.approvesShutdown(message?["content"]) ? .end(.stopped) : .step
        case "user":
            if record["isMeta"] as? Bool == true || record["isCompactSummary"] as? Bool == true { return nil }
            let text: String
            switch message?["content"] {
            case let content as String:
                text = content
            case let blocks as [[String: Any]]:
                if !blocks.isEmpty, blocks.allSatisfy({ $0["type"] as? String == "tool_result" }) { return .step }
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
            default:
                return nil
            }
            if text.hasPrefix("[Request interrupted") { return .end(.stopped) }
            if text.hasPrefix("This session is being continued") { return nil }
            return .prompt
        default:
            return nil
        }
    }

    /// A `SendMessage` call whose message is
    /// `{"type": "shutdown_response", "approve": true}`.
    private static func approvesShutdown(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { block in
            guard block["type"] as? String == "tool_use", block["name"] as? String == "SendMessage",
                let message = (block["input"] as? [String: Any])?["message"] as? [String: Any]
            else { return false }
            return message["type"] as? String == "shutdown_response" && message["approve"] as? Bool == true
        }
    }
}
