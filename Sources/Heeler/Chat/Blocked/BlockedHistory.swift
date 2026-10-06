import Foundation

/// What answers given on Blocked cards did that the transcript can't tell
/// (ADR 0020), for the timeline's history rows. Neither program records an
/// approval, so one given in Chat reads like an automatic one, and Stop
/// reads like a decline. Codex records an asynchronous answer only once it
/// sends it, after its next tool call. Kept while the Chat lives, never
/// saved.
struct BlockedHistory: Equatable, Sendable {
    /// Card answers by the call they answered.
    private(set) var calls: [String: ChatToolActivity.CardAnswer] = [:]
    /// Codex's asynchronous answers by question id.
    private(set) var queuedAnswers: [String: String] = [:]

    var isEmpty: Bool { calls.isEmpty && queuedAnswers.isEmpty }

    mutating func record(_ answer: ChatToolActivity.CardAnswer, forCall id: String) {
        calls[id] = answer
    }

    mutating func queue(_ answer: String, forQuestion id: String) {
        queuedAnswers[id] = answer
    }

    /// `entries` with each answer marked where the transcript agrees: an
    /// allowed call that ran, a stopped one that didn't, and a queued answer
    /// to a question the transcript still shows open.
    func marking(_ entries: [ChatEntry]) -> [ChatEntry] {
        guard !isEmpty else { return entries }
        return entries.map { entry in
            var entry = entry
            switch entry.content {
            case .tool(var tool):
                guard let id = tool.callID, let answer = calls[id], Self.agrees(answer, with: tool.status) else {
                    break
                }
                tool.cardAnswer = answer
                entry.content = .tool(tool)
            case .questions(var set):
                var isMarked = false
                for index in set.questions.indices where set.questions[index].answer == nil {
                    guard let id = set.questions[index].id, let answer = queuedAnswers[id] else { continue }
                    set.questions[index].queuedAnswer = answer
                    isMarked = true
                }
                if isMarked { entry.content = .questions(set) }
            default:
                break
            }
            return entry
        }
    }

    private static func agrees(_ answer: ChatToolActivity.CardAnswer, with status: ChatToolActivity.Status) -> Bool {
        switch answer {
        case .allowed: [.running, .succeeded, .failed].contains(status)
        case .stopped: [.declined, .interrupted, .notCompleted, .noResult].contains(status)
        }
    }
}
