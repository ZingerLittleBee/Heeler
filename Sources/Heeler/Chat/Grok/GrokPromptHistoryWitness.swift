import Foundation

/// Grok Build's `<group>/prompt_history.jsonl`: every Grok process working
/// in the folder appends `{timestamp, session_id, prompt, is_bash}` for each
/// prompt it submits, just before the prompt reaches the session's
/// transcript, and a prompt it queued once it submits it (1.0.45
/// `session/prompt_history.rs`; 1.0.62 captures). The file keeps 10,000
/// entries, and Grok may rewrite it through a rename when a session starts.
enum GrokPromptHistoryWitness {
    static var witness: ChatSendWitness {
        ChatSendWitness(
            logPath: { GrokTranscriptLocator.groupDirectory(ofTranscript: $0) + "/prompt_history.jsonl" },
            entry: { line in
                // `!command` lines record a shell command, never a send.
                guard let record = try? JSONDecoder().decode(Record.self, from: line), record.isBash != true else {
                    return nil
                }
                return (record.prompt, record.sessionID)
            })
    }

    private struct Record: Decodable {
        let prompt: String
        let sessionID: String
        let isBash: Bool?

        enum CodingKeys: String, CodingKey {
            case prompt
            case sessionID = "session_id"
            case isBash = "is_bash"
        }
    }
}
