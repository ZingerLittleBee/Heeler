import Foundation

/// What a Stop guard reads, built inside the keys queue. A branch adds a
/// field with a default and fills it only in the surface's `stopContext`, so
/// other guards and their tests keep compiling.
struct ChatStopContext: Sendable {
    var screen: ANSIScreen
    var activity: ChatAgentActivity
}

/// A Stop guard's answer for the screen it read.
enum ChatStopVerdict: Equatable, Sendable {
    case press
    /// Pressing now could quit the program, clear a draft, act on a picker
    /// or a dialog, or do nothing; why, shown beside Stop.
    case refuse(String)
}

/// What Chat's Stop does in one program (ADR 0024).
struct ChatStopPlan: Sendable {
    /// herdr key names, sent in one `agent.send_keys`; herdr 0.9.5 writes
    /// them to the PTY in one write.
    var keys: [String]
    /// nil presses without reading the screen.
    var screenGuard: (@Sendable (ChatStopContext) -> ChatStopVerdict)?
    var wait: AgentStopWait
    var accessibilityHint: String

    /// One Esc, pressed without reading the screen, with Esc's wait and hint.
    static let escape = ChatStopPlan(
        keys: ["esc"], screenGuard: nil, wait: .escape,
        accessibilityHint: AgentComposerInterrupt.escapeHint)

    /// Chat's Stop in each program.
    static func standard(for program: ChatProgram) -> ChatStopPlan {
        switch program {
        case .claude, .codex, .pi, .omp: .escape
        case .grok:
            // Ctrl+C cancels Grok Build's turn; Esc only shows a toast. Ctrl+C
            // can also clear a draft, answer a card or quit, so the guard
            // reads the screen first.
            ChatStopPlan(
                keys: ["ctrl+c"],
                screenGuard: { GrokStopGuard.verdict($0) },
                wait: AgentStopWait(
                    window: .seconds(3),
                    unconfirmedNotice:
                        "Ctrl+C went, but the Agent still shows Working. A queued message may have started.",
                    minimumGap: .milliseconds(1500)),
                accessibilityHint: "Presses Ctrl+C to cancel the turn")
        case .opencode:
            // OpenCode 2.0.32 interrupts at a second Esc within 5 s of the
            // first; herdr writes both in one PTY write. Ctrl+C would exit
            // it when its input is empty.
            ChatStopPlan(
                keys: ["esc", "esc"], screenGuard: OpenCodeStopGuard.verdict,
                wait: AgentStopWait(window: .seconds(3), unconfirmedNotice: openCodeUnconfirmedNotice),
                accessibilityHint: "Presses Esc twice to interrupt OpenCode")
        }
    }

    /// OpenCode's interrupt resumes: a message waiting during the turn
    /// runs after it.
    private static let openCodeUnconfirmedNotice =
        "Esc went twice, but OpenCode still shows Working. If a message was waiting during this turn, OpenCode runs "
        + "it after a stop; tap Stop again to stop that too. In the terminal, use Esc, not Ctrl+C, which exits "
        + "OpenCode when its input is empty."

    /// The request failed, so the keys may not have arrived.
    static let unreachableMessage = "Couldn't reach the Agent, so it may still be working."
    /// A guard had no screen to decide on, so nothing was pressed.
    static let unreadableScreenMessage = "Heeler couldn't check the Agent's screen, so Stop pressed nothing."

    /// The Composer's Stop for this plan, in line with the Agent page's keys.
    /// A tap calls `agentKeys.deliver(keys, unless: check)`. Without a guard
    /// there is no check and nothing is read. With one, the check runs inside
    /// the keys queue: `context()` (a throw gives `unreadableScreenMessage`),
    /// then the guard (`.refuse(r)` gives `r`). `.sent` maps to `.sent`,
    /// `.withheld(r)` to `.failed(r)`, and `.failed` to
    /// `.failed(unreachableMessage)`.
    @MainActor func composerInterrupt(
        context: @escaping @MainActor () async throws -> ChatStopContext,
        agentKeys: ChatAgentKeysStore
    ) -> AgentComposerInterrupt {
        let keys = keys
        let check = screenGuard.map { Self.check($0, context: context) }
        return AgentComposerInterrupt(wait: wait, accessibilityHint: accessibilityHint) {
            switch await agentKeys.deliver(keys, unless: check) {
            case .sent: return .sent
            case .withheld(let reason): return .failed(reason)
            case .failed: return .failed(Self.unreachableMessage)
            }
        }
    }

    /// The guard's check over a fresh context: why to press nothing, or nil
    /// to press.
    @MainActor private static func check(
        _ screenGuard: @escaping @Sendable (ChatStopContext) -> ChatStopVerdict,
        context: @escaping @MainActor () async throws -> ChatStopContext
    ) -> @MainActor () async -> String? {
        {
            guard let stopContext = try? await context() else { return unreadableScreenMessage }
            switch screenGuard(stopContext) {
            case .press: return nil
            case .refuse(let reason): return reason
            }
        }
    }
}
