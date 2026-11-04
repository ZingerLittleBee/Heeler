import Foundation

/// Whether Chat may type a message into the Agent's input box now.
enum PreSendDecision: Equatable, Sendable {
    /// The box is empty: herdr may type the message and press Enter.
    case send
    /// herdr reports the Agent Blocked. A prompt waits for an answer, and
    /// Codex refuses messages until it gets one.
    case holdBlocked
    /// The box is not empty, no box for this conversation shows, or Heeler
    /// cannot tell; the state says what to show beside Open in Terminal.
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
    /// The screen does not say, for example when it shows no box for this
    /// conversation; the message stays marked as sent.
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
        case .shellMode, .disabled, .overlay, .noComposer, .unknown:
            return .unconfirmed
        }
    }

    /// The verdict for `program`, which may put other text in the box
    /// after taking the message: then only text the sent message contains
    /// is the message left behind, and other text says nothing. Without the
    /// sent text the verdict is the plain one.
    static func verdict(
        _ state: InputBoxState, program: ChatProgram, activity: ChatAgentActivity, sent: String?
    ) -> DeliveryVerdict {
        let plain = verdict(state, activity: activity)
        guard program.mayRefillInputBoxAfterSend, let sent, case .notDelivered(let text) = plain else {
            return plain
        }
        let left = squeezed(text)
        return !left.isEmpty && squeezed(sent).contains(left) ? plain : .unconfirmed
    }

    static func verdict(
        _ screen: ANSIScreen, program: ChatProgram, activity: ChatAgentActivity, sent: String? = nil
    ) -> DeliveryVerdict {
        let state = InputBoxStateDetector.detect(screen, program: program)
        return verdict(state, program: program, activity: activity, sent: sent)
    }

    /// The text without whitespace: the box wraps a long message across
    /// rows and trims each, and may show only its end.
    private static func squeezed(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }
}

extension ChatProgram {
    /// Whether the program can put other text in its input box right after
    /// taking a message. Grok Build restores a draft stashed with Ctrl+S
    /// after the next send (its keyboard shortcuts guide), so a draft there
    /// is not necessarily the message.
    var mayRefillInputBoxAfterSend: Bool {
        switch self {
        case .claude, .codex, .pi, .omp, .opencode: false
        case .grok: true
        }
    }
}
