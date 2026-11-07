import Foundation

/// Antigravity CLI's `<root>/history.jsonl`: every agy process under the
/// data root appends `{display, timestamp, workspace, conversationId?}` for
/// each prompt it submits, `display` trimmed, and a local `/` command with
/// `type: "slash_command"` (1.5.3, probes and live).
///
/// It witnesses only a send recorded under another conversation's id, the
/// case of a terminal resumed into another conversation. It cannot see:
/// - a conversation's first prompt, which agy records without an id, so a
///   send into the conversation `/clear` or a new launch just started;
/// - whether a queued send was taken: agy records it at Enter, and Esc can
///   put it back in the box unsent;
/// - a send under another data root, such as another Account's;
/// - a send from another pane in another conversation with the same text
///   since the mark, which makes the read name two conversations and say
///   nothing.
enum AgyPromptHistoryWitness {
    static var witness: ChatSendWitness {
        ChatSendWitness(
            logPath: { AgyTranscriptLocator.root(ofTranscript: $0) + "/history.jsonl" },
            entry: { line in
                guard let record = try? JSONDecoder().decode(Record.self, from: line), record.type == nil,
                    let conversationID = record.conversationID
                else { return nil }
                return (record.display, conversationID)
            })
    }

    private struct Record: Decodable {
        let display: String
        let conversationID: String?
        /// `slash_command` for a local command, the only value seen.
        let type: String?

        enum CodingKeys: String, CodingKey {
            case display
            case conversationID = "conversationId"
            case type
        }
    }
}
