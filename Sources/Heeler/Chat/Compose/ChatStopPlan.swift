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

/// What Chat's Stop presses after its keys went: what is still running
/// when it is done, or nil.
typealias ChatStopFollowThrough = @MainActor () async -> String?

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
        case .agy:
            // Antigravity CLI's Esc stops the turn, from a dialog too, and
            // puts a queued message back in the box. At an idle box it
            // leaves a draft as it is, but in bash mode it drops the command
            // typed there, so the guard reads the screen first. Ctrl+C would
            // arm an exit at idle that a second press carries out (1.5.3,
            // live).
            ChatStopPlan(
                keys: ["esc"], screenGuard: AgyStopGuard.verdict, wait: .escape,
                accessibilityHint: AgentComposerInterrupt.escapeHint)
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
                        String(localized: "Ctrl+C went, but the Agent still shows Working. A queued message may have started."),
                    minimumGap: .milliseconds(1500)),
                accessibilityHint: String(localized: "Presses Ctrl+C to cancel the turn"))
        case .opencode:
            // OpenCode 2.0.32 interrupts at a second Esc within 5 s of the
            // first; herdr writes both in one PTY write. Ctrl+C would exit
            // it when its input is empty.
            ChatStopPlan(
                keys: ["esc", "esc"], screenGuard: OpenCodeStopGuard.verdict,
                wait: AgentStopWait(window: .seconds(3), unconfirmedNotice: openCodeUnconfirmedNotice),
                accessibilityHint: String(localized: "Presses Esc twice to interrupt OpenCode"))
        }
    }

    /// The plan on a herdr-core Template's Terminal: the Template's stop key, with
    /// the program's guard, window and gap as they are (ADR 0035). What Stop says
    /// is the core's, since the key may not be Esc. The core's own window is not:
    /// it is shortened for a watch this path does not run.
    func pressing(templateStopKey key: String) -> ChatStopPlan {
        var plan = self
        plan.keys = [key]
        plan.wait.unconfirmedNotice = AgentStopWait.coreInterrupt.unconfirmedNotice
        plan.accessibilityHint = AgentComposerInterrupt.coreHint
        return plan
    }

    /// OpenCode's interrupt resumes: a message waiting during the turn
    /// runs after it.
    private static let openCodeUnconfirmedNotice =
        String(localized: "Esc went twice, but OpenCode still shows Working. If a message was waiting during this turn, OpenCode runs it after a stop; tap Stop again to stop that too. In the terminal, use Esc, not Ctrl+C, which exits OpenCode when its input is empty.")

    /// The request failed, so the keys may not have arrived.
    static let unreachableMessage = String(localized: "Couldn't reach the Agent, so it may still be working.")
    /// A guard had no screen to decide on, so nothing was pressed.
    static let unreadableScreenMessage = String(localized: "Heeler couldn't check the Agent's screen, so Stop pressed nothing.")

    /// The Composer's Stop for this plan, in line with the Agent page's keys.
    /// A tap calls `agentKeys.deliver(keys, unless: check)`. Without a guard
    /// there is no check and nothing is read. With one, the check runs inside
    /// the keys queue: `context()` (a throw gives `unreadableScreenMessage`),
    /// then the guard (`.refuse(r)` gives `r`). `.sent` maps to `.sent`,
    /// `.withheld(r)` to `.failed(r)`, and `.failed` to
    /// `.failed(unreachableMessage)`.
    ///
    /// - Parameter followThrough: Called as Stop is tapped, so it sees the
    ///   turn the keys stop. What it returns runs in the keys queue once the
    ///   keys went, and says what they left running, which maps `.sent` to
    ///   `.sentLeavingWork`: Antigravity CLI's background commands.
    @MainActor func composerInterrupt(
        context: @escaping @MainActor () async throws -> ChatStopContext,
        agentKeys: ChatAgentKeysStore,
        followThrough: (@MainActor () -> ChatStopFollowThrough?)? = nil
    ) -> AgentComposerInterrupt {
        let keys = keys
        let check = screenGuard.map { Self.check($0, context: context) }
        return AgentComposerInterrupt(wait: wait, accessibilityHint: accessibilityHint) {
            let after = followThrough?()
            switch await agentKeys.deliver(keys, unless: check) {
            case .sent:
                guard let after, let left = await agentKeys.afterQueued(after) else { return .sent }
                return .sentLeavingWork(left)
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
