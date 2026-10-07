import Foundation

extension ComposerDeliveryPolicy {
    /// Chat's delivery (ADR 0021). Text the rules refuse stays a draft.
    /// Otherwise the Agent's screen is read first, and the message goes only
    /// into an input box read as empty; a second read `DeliveryCheck.delay`
    /// after `agent.prompt` tells whether Enter took it. Both reads go
    /// through `agent.read`, and a Blocked Agent refuses: nothing here
    /// touches the Attach PTY.
    static func chat(
        rules: ChatSendRules,
        activity: @escaping @MainActor () -> ChatAgentActivity,
        readScreen: @escaping @MainActor () async throws -> ANSIScreen,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> ComposerDeliveryPolicy {
        let program = rules.program
        return ComposerDeliveryPolicy(
            route: .chat,
            insertsIntoAttachWhenBlocked: false,
            outgoingText: { rules.outgoingText($0) },
            validate: { rules.validate($0) },
            preflight: { _ in
                if activity() == .blocked { return .agentBlocked }
                let screen: ANSIScreen
                do {
                    screen = try await readScreen()
                } catch {
                    return .inputNotReady(Self.unreadableScreenReason(error))
                }
                switch PreSendGate.check(screen, program: program, activity: activity()) {
                case .send: return nil
                case .holdBlocked: return .agentBlocked
                case .hold(let state): return .inputNotReady(state.holdReason)
                }
            },
            verify: { _ in
                await pause(DeliveryCheck.delay)
                // A screen that cannot be read says nothing; the message
                // stays marked as sent.
                guard let screen = try? await readScreen() else { return true }
                if case .notDelivered = DeliveryCheck.verdict(screen, program: program, activity: activity()) {
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
    var holdReason: String {
        switch self {
        case .empty:
            "The Agent's input box is ready."
        case .text:
            "The Agent's input box already has text. Send or clear it in the terminal first."
        case .shellMode:
            "The Agent's input box is in shell mode. Leave it in the terminal first."
        case .disabled(let explanation):
            "The Agent isn't taking messages: \(explanation)"
        case .overlay:
            "A menu is open over the Agent's input box. Close it in the terminal first."
        case .dialog:
            "The Agent is showing a dialog. Answer it in the terminal first."
        case .unknown:
            "Heeler can't find the Agent's input box on screen."
        }
    }
}
