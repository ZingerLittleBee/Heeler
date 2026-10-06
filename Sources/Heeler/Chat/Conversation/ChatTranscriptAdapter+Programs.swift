import Foundation

extension ChatTranscriptAdapter {
    /// How Chat reads each program's own transcript; nil for a program it
    /// cannot read yet, which keeps Chat unavailable for it.
    static func standard(for program: ChatProgram) -> ChatTranscriptAdapter? {
        switch program {
        case .claude:
            // The session's own file: sidechain and team records belong to
            // the subagents that wrote them.
            ChatTranscriptAdapter(
                revision: ClaudeTranscriptReducer.revision,
                makeReducer: { _ in ClaudeTranscriptReducer(role: .main) })
        case .codex:
            nil
        }
    }
}
