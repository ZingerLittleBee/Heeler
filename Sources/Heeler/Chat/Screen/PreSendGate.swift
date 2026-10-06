import Foundation

/// Whether Chat may type a message into the Agent's input box now.
enum PreSendDecision: Equatable, Sendable {
    /// The box is empty: herdr may type the message and press Enter.
    case send
    /// herdr reports the Agent Blocked. A prompt waits for an answer, and
    /// Codex refuses messages until it gets one.
    case holdBlocked
    /// The box is not empty, or Heeler cannot tell; the state says what to
    /// show beside Open in Terminal.
    case hold(InputBoxState)
}

/// The check before Chat sends a message. Only a box positively read as
/// empty passes; Heeler never clears one that is not.
enum PreSendGate {
    static func check(_ state: InputBoxState, activity: ChatAgentActivity) -> PreSendDecision {
        // Blocked wins over the screen: Codex keeps its composer in view
        // while queued questions wait.
        if activity == .blocked { return .holdBlocked }
        return state.isSendable ? .send : .hold(state)
    }

    static func check(_ screen: ANSIScreen, program: ChatProgram, activity: ChatAgentActivity) -> PreSendDecision {
        check(InputBoxStateDetector.detect(screen, program: program), activity: activity)
    }
}

/// What a re-read after sending says about the message.
enum DeliveryVerdict: Equatable, Sendable {
    /// The box emptied, or a dialog or Blocked took over: the program took
    /// the message.
    case delivered
    /// Text still sits in the box, so Enter did not submit it. Chat never
    /// resends; the user finishes it in the terminal.
    case notDelivered(String)
    /// The screen does not say; the message stays marked as sent.
    case unconfirmed
}

/// The check after Chat sends a message.
enum DeliveryCheck {
    /// How long after the `agent.prompt` acknowledgement to re-read.
    static let delay: Duration = .seconds(3)

    static func verdict(_ state: InputBoxState, activity: ChatAgentActivity) -> DeliveryVerdict {
        if activity == .blocked { return .delivered }
        switch state {
        case .empty, .dialog:
            return .delivered
        case .text(let text):
            return .notDelivered(text)
        case .shellMode(let command) where !command.isEmpty:
            return .notDelivered(command)
        case .shellMode, .disabled, .overlay, .unknown:
            return .unconfirmed
        }
    }

    static func verdict(_ screen: ANSIScreen, program: ChatProgram, activity: ChatAgentActivity) -> DeliveryVerdict {
        verdict(InputBoxStateDetector.detect(screen, program: program), activity: activity)
    }
}
