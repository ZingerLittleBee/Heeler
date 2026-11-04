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
        case .pi, .omp:
            // Oh My Pi rewrites its title slot in place and its whole file
            // atomically, header included, keeping every entry's id.
            ChatTranscriptAdapter(
                revision: PiTranscriptReducer.revision,
                wantsFirstLine: true,
                joinsCachedHistory: false,
                makeReducer: { seed in
                    var reducer = PiTranscriptReducer(program: program)
                    if let firstLine = seed.firstLine { reducer.append([firstLine]) }
                    return reducer
                },
                identity: { PiTranscriptLocator.sessionID(inHead: $0) },
                echoesByEntry: true)
        case .grok:
            .grok
        case .opencode:
            // Read by query from OpenCode's session store (ADR 0025).
            openCode
        }
    }

    /// OpenCode's conversations, read by query from its session store (ADR
    /// 0025). A committed `/undo` deletes rows at or above its boundary, so
    /// a saved prefix may hold rows the store no longer has: older pages,
    /// cheap point queries, are read instead of joining the cache. Rows keep
    /// their ids when OpenCode rewrites them.
    static let openCode = ChatTranscriptAdapter(
        revision: OpenCodeTranscriptReducer.revision,
        joinsCachedHistory: false,
        makeReducer: { _ in OpenCodeTranscriptReducer() },
        echoesByEntry: true,
        makeRecordSource: { OpenCodeSessionID($0).map { OpenCodeRecordSource(session: $0) } })
}
