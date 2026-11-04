import Foundation

extension ComposerDeliveryPolicy {
    /// Chat's delivery (ADR 0024). Text the rules refuse stays a draft.
    /// Otherwise the Agent's screen is read first, and the message goes only
    /// into an input box read as empty; a second read `DeliveryCheck.delay`
    /// after `agent.prompt` tells whether Enter took it. Both reads go
    /// through `agent.read`, and a Blocked Agent refuses: nothing here
    /// touches the Attach PTY. `sendConcern` gets the text as sent and the
    /// screen the input box passed on, and may hold the message for what
    /// Chat knows beyond the box; nothing is awaited between them.
    /// `willReadScreen` runs just before the first read, once the Agent is
    /// not Blocked: Chat registers the send there, so a send witness's mark
    /// is on its way before `agent.read` rather than after it.
    ///
    /// `confirmSession`, for a program that can leave its conversation
    /// without herdr reporting it (`ChatProgram.confirmsSessionBeforeSend`),
    /// runs before `willReadScreen` and the screen read: why the message
    /// would land outside the conversation Chat shows, or nil to go on.
    static func chat(
        rules: ChatSendRules,
        activity: @escaping @MainActor () -> ChatAgentActivity,
        readScreen: @escaping @MainActor () async throws -> ANSIScreen,
        confirmSession: (@MainActor () async -> String?)? = nil,
        sendConcern: @escaping @MainActor (_ outgoing: String, _ screen: ANSIScreen) -> String? = { _, _ in nil },
        willReadScreen: @escaping @MainActor () -> Void = {},
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> ComposerDeliveryPolicy {
        let program = rules.program
        return ComposerDeliveryPolicy(
            route: .chat,
            insertsIntoAttachWhenBlocked: false,
            outgoingText: { rules.outgoingText($0) },
            validate: { rules.validate($0) },
            preflight: { text in
                if activity() == .blocked { return .agentBlocked }
                if let confirmSession, let reason = await confirmSession() { return .inputNotReady(reason) }
                willReadScreen()
                let screen: ANSIScreen
                do {
                    screen = try await readScreen()
                } catch {
                    return .inputNotReady(Self.unreadableScreenReason(error))
                }
                switch PreSendGate.check(screen, program: program, activity: activity()) {
                case .send:
                    return sendConcern(rules.outgoingText(text), screen).map { .inputNotReady($0) }
                case .holdBlocked: return .agentBlocked
                case .hold(let state): return .inputNotReady(state.holdReason(for: program))
                }
            },
            verify: { sent in
                await pause(DeliveryCheck.delay)
                // A screen that cannot be read says nothing; the message
                // stays marked as sent.
                guard let screen = try? await readScreen() else { return true }
                if case .notDelivered = DeliveryCheck.verdict(
                    screen, program: program, activity: activity(), sent: sent)
                {
                    return false
                }
                return true
            })
    }

    private static func unreadableScreenReason(_ error: any Error) -> String {
        let prefix = "Heeler couldn't check the Agent's input box."
        guard let error = error as? TransportError else { return prefix }
        return "\(prefix) \(error.presentation.explanation)"
    }
}

extension InputBoxState {
    /// Why Chat holds a message while the input box reads this way. Every
    /// case is one the terminal can resolve.
    func holdReason(for program: ChatProgram) -> String {
        switch self {
        case .empty:
            "The Agent's input box is ready."
        case .text:
            switch program {
            case .claude:
                "The Agent's input box already has text. Send or clear it in the terminal first."
            case .codex:
                // Codex 0.162.1's Esc puts follow-ups queued with Tab back
                // in the box.
                "The Agent's input box already has text, such as a draft or a message Stop returned. Send or clear it in the terminal first."
            case .pi, .omp:
                // Their Esc returns steers the turn has not taken to the
                // box, but the text may as well be a draft typed there.
                "The Agent's input box already has text, such as a draft or a steer that Stop returned. Send or clear it in the terminal first."
            case .grok:
                // Ctrl+C before the first output puts the turn's prompt back
                // in the box.
                "Grok Build's input box already has text, such as a draft or a message Stop put back. Send or clear it in the terminal first."
            case .opencode:
                // OpenCode's `/undo` puts the undone prompt back in the box,
                // and Up recalls an earlier one.
                "The Agent's input box already has text, such as a draft, a prompt /undo put back, or one recalled with Up. Send or clear it in the terminal first."
            }
        case .shellMode:
            "The Agent's input box is in shell mode. Leave it in the terminal first."
        case .disabled(let explanation):
            "The Agent isn't taking messages: \(explanation)"
        case .overlay:
            "A menu is open over the Agent's input box. Close it in the terminal first."
        case .dialog(let title):
            if program == .codex, title == CodexPlanPrompt.title {
                "Codex is asking whether to implement the plan. Answer it in the terminal first."
            } else {
                "The Agent is showing a dialog. Answer it in the terminal first."
            }
        case .noComposer(let reason):
            reason
        case .unknown:
            "Heeler can't find the Agent's input box on screen."
        }
    }
}
