import Foundation

/// The conversation an Agent's herdr session record names: which program
/// wrote it and the session id its transcript is filed under.
///
/// herdr reports `agent_session` through the official integration hooks.
/// Chat binds by the exact source/agent pair of a program's
/// `ChatSessionNaming` and never parses `source`. Claude/Codex use UUID ids;
/// Pi/OMP also report absolute transcript paths; Grok Build uses lowercase
/// UUIDv7 ids and OpenCode its own `ses_` ids. A value is validated before
/// it becomes a path, path component or query argument.
struct ConversationReference: Hashable, Sendable {
    let program: ChatProgram
    /// The id the program's naming accepted (a canonical UUID for Claude,
    /// Codex, Pi and OMP, Grok Build's id and an OpenCode session id as
    /// reported), or Pi/OMP's validated absolute JSONL path. Paths are read
    /// directly, never interpolated into an exec command.
    let sessionID: String

    enum Resolution: Hashable, Sendable {
        case bound(ConversationReference)
        /// herdr has no session for the Agent yet. Codex reports one only
        /// after the first prompt.
        case noSession
        /// A session from another program, or of a kind Chat cannot read.
        case unsupported
        /// The right program, but the value is not a session id Chat can
        /// look up, such as a Codex thread name after `resume <name>`.
        case unidentified
    }

    static func resolve(_ session: AgentSessionInfo?) -> Resolution {
        guard let session else { return .noSession }
        guard
            let program = ChatProgram.allCases.first(where: {
                $0.sessionNaming.source == session.source && $0.sessionNaming.agent == session.agent
            })
        else { return .unsupported }
        let naming = program.sessionNaming
        if naming.acceptsTranscriptPath, session.kind == .path {
            guard RemoteFilePath.isAcceptable(session.value), session.value.hasSuffix(".jsonl") else {
                return .unidentified
            }
            return .bound(ConversationReference(program: program, sessionID: session.value))
        }
        guard session.kind == .id else { return .unsupported }
        guard let sessionID = naming.sessionID(session.value) else { return .unidentified }
        return .bound(ConversationReference(program: program, sessionID: sessionID))
    }

    /// The UUID's lowercased hyphenated text, or nil for anything else.
    /// UUID-based lookup uses lowercase file ids.
    static func canonicalUUID(_ text: String) -> String? {
        guard text.utf8.count == 36, let uuid = UUID(uuidString: text) else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// The text unchanged when it is a lowercase UUIDv7, the only id Grok
    /// Build creates, or nil. It is never lowercased: Grok names the session
    /// folder and `sessionId` with the id as given, so another case would
    /// name a folder it never wrote.
    static func lowercaseUUIDv7(_ text: String) -> String? {
        guard
            text.utf8.count == 36,
            text.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil
        else { return nil }
        return text
    }
}

/// How herdr names one program's sessions, and which values Chat accepts as
/// its id.
struct ChatSessionNaming: Sendable {
    /// `agent_session.source`, matched exactly.
    var source: String
    /// `agent_session.agent`, matched exactly.
    var agent: String
    /// The id Chat files the conversation under, or nil; validated before it
    /// becomes a path, path component or query argument. A transcript's link
    /// to the session it continues in is checked the same way.
    var sessionID: @Sendable (String) -> String?
    /// Whether herdr may report an absolute `.jsonl` transcript path.
    var acceptsTranscriptPath: Bool
}

extension ChatProgram {
    /// How herdr names this program's sessions. No two programs share a
    /// source/agent pair.
    var sessionNaming: ChatSessionNaming {
        switch self {
        case .claude:
            ChatSessionNaming(
                source: "herdr:claude", agent: "claude", sessionID: ConversationReference.canonicalUUID,
                acceptsTranscriptPath: false)
        case .codex:
            ChatSessionNaming(
                source: "herdr:codex", agent: "codex", sessionID: ConversationReference.canonicalUUID,
                acceptsTranscriptPath: false)
        case .pi:
            ChatSessionNaming(
                source: "herdr:pi", agent: "pi", sessionID: ConversationReference.canonicalUUID,
                acceptsTranscriptPath: true)
        case .omp:
            ChatSessionNaming(
                source: "herdr:omp", agent: "omp", sessionID: ConversationReference.canonicalUUID,
                acceptsTranscriptPath: true)
        case .grok:
            ChatSessionNaming(
                source: "herdr:grok", agent: "grok", sessionID: ConversationReference.lowercaseUUIDv7,
                acceptsTranscriptPath: false)
        case .opencode:
            ChatSessionNaming(
                source: "herdr:opencode", agent: "opencode", sessionID: { OpenCodeSessionID($0)?.rawValue },
                acceptsTranscriptPath: false)
        }
    }
}
