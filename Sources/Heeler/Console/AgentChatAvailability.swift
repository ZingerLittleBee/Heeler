import Foundation

/// Whether an Agent's detail offers Chat (ADR 0024). Chat reads what the
/// Agent program records of its conversation, so it needs a program with a
/// transcript adapter (`ChatTranscriptAdapter.standard(for:)`) and a Host
/// known to be POSIX: transcript files are found through POSIX home paths, a
/// store is read by a POSIX shell script (ADR 0025), and native Windows Hosts
/// are out of scope. A platform not learned yet hides the entry rather than
/// offering a Chat whose first read would fail. A program with no adapter yet
/// is neither offered nor prefetched, so its `ChatProgram` case can land
/// before its adapter.
enum AgentChatAvailability {
    /// Whether Chat can read the program's transcript: the lookup both checks
    /// use unless the caller passes its own, as `ConsoleStore` does with the
    /// adapters it was given.
    static func hasStandardAdapter(_ program: ChatProgram) -> Bool {
        ChatTranscriptAdapter.standard(for: program) != nil
    }

    static func program(
        for agent: Agent, platform: HostPlatform?,
        hasAdapter: (ChatProgram) -> Bool = AgentChatAvailability.hasStandardAdapter
    ) -> ChatProgram? {
        guard platform == .posix, let program = ChatProgram(rawValue: agent.kind), hasAdapter(program) else {
            return nil
        }
        return program
    }

    /// Whether the Agent's program has a Chat adapter at all, before the
    /// Host's platform is known. Decides whether asking for it is worth it.
    static func mayOfferChat(
        for agent: Agent, hasAdapter: (ChatProgram) -> Bool = AgentChatAvailability.hasStandardAdapter
    ) -> Bool {
        guard let program = ChatProgram(rawValue: agent.kind) else { return false }
        return hasAdapter(program)
    }
}
