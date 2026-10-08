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
                makeReducer: { ClaudeTranscriptReducer(role: .main, transcriptPath: $0.path) },
                echoKey: { ClaudeTranscriptReducer.echoKey($0) })
        case .codex:
            // Line 1's `session_meta` names the rollout's dialect, so a tail
            // window that starts past it still needs it.
            ChatTranscriptAdapter(
                revision: CodexRolloutReducer.revision,
                wantsFirstLine: true,
                makeReducer: { seed in
                    let fileName = seed.path.split(separator: "/").last.map(String.init) ?? seed.path
                    var reducer = CodexRolloutReducer(
                        rolloutID: CodexRolloutFileName(fileName: fileName)?.rolloutID ?? fileName)
                    if let firstLine = seed.firstLine { reducer.setSessionMeta(firstLine) }
                    return reducer
                },
                echoKey: { codexEchoKey($0) })
        }
    }
}
