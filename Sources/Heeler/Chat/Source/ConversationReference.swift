import Foundation

/// The conversation an Agent's herdr session record names: which program
/// wrote it and the session id its transcript is filed under.
///
/// herdr 0.9.3 reports `agent_session` only through the official integration
/// hooks, as `{source: "herdr:<program>", agent: "<program>", kind: "id"}`.
/// Chat binds by that exact pair and never parses `source`. herdr accepts any
/// value up to 512 characters, `../x` included, so the value must be a UUID
/// before it becomes part of a Host path.
struct ConversationReference: Hashable, Sendable {
    let program: ChatProgram
    /// Lowercased canonical UUID text, safe as one path component.
    let sessionID: String

    enum Resolution: Hashable, Sendable {
        case bound(ConversationReference)
        /// herdr has no session for the Agent yet. Codex reports one only
        /// after the first prompt.
        case noSession
        /// A session from another program, or of a kind Chat cannot read.
        case unsupported
        /// The right program, but the value is not a session id Chat can
        /// file-locate, such as a Codex thread name after `resume <name>`.
        case unidentified
    }

    static func resolve(_ session: AgentSessionInfo?) -> Resolution {
        guard let session else { return .noSession }
        let program: ChatProgram
        switch (session.source, session.agent) {
        case ("herdr:claude", "claude"): program = .claude
        case ("herdr:codex", "codex"): program = .codex
        default: return .unsupported
        }
        guard session.kind == .id else { return .unsupported }
        guard let sessionID = canonicalUUID(session.value) else { return .unidentified }
        return .bound(ConversationReference(program: program, sessionID: sessionID))
    }

    /// The UUID's lowercased hyphenated text, or nil for anything else.
    /// Both programs name files with lowercase ids.
    static func canonicalUUID(_ text: String) -> String? {
        guard text.utf8.count == 36, let uuid = UUID(uuidString: text) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
