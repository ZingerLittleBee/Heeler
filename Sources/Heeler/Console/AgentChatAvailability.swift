import Foundation

/// Whether an Agent's detail offers Chat (ADR 0021). Chat reads the
/// transcript the Agent program writes, so it needs a program with an
/// adapter (Claude Code or Codex) and a Host known to be POSIX: transcripts
/// are found through POSIX home paths, and native Windows Hosts are out of
/// scope. A platform not learned yet hides the entry rather than offering a
/// Chat whose first read would fail.
enum AgentChatAvailability {
    static func program(for agent: Agent, platform: HostPlatform?) -> ChatProgram? {
        guard platform == .posix else { return nil }
        return ChatProgram(rawValue: agent.kind)
    }

    /// Whether the Agent's program has a Chat adapter at all, before the
    /// Host's platform is known. Decides whether asking for it is worth it.
    static func mayOfferChat(for agent: Agent) -> Bool {
        ChatProgram(rawValue: agent.kind) != nil
    }
}
