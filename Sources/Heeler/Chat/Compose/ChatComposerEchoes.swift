import Foundation

/// Chat's reading of the Composer's messages (ADR 0024): what the Chat
/// store matches against the transcript, and the echoes still to show
/// below it. Messages the terminal sent are not Chat's and never echo.
enum ChatComposerEchoes {
    /// Chat's messages as herdr typed them: `rules` rewrites each one the
    /// way Send did.
    static func sentMessages(
        _ messages: [AgentComposerStore.Message], rules: ChatSendRules
    ) -> [AgentChatStore.SentMessage] {
        messages.compactMap { message in
            guard message.route == .chat else { return nil }
            let isDelivered =
                switch message.state {
                // A step with no answer may still have reached the program,
                // and the Transcript is what can show that it did.
                case .delivered, .undelivered, .outcomeUnknown: true
                case .sending, .failed: false
                }
            let mayNotHaveGone =
                switch message.state {
                case .undelivered, .outcomeUnknown: true
                case .sending, .delivered, .failed: false
                }
            return AgentChatStore.SentMessage(
                id: message.id, text: rules.outgoingText(message.text), isDelivered: isDelivered,
                mayNotHaveGone: mayNotHaveGone)
        }
    }

    /// Whether a send of Chat's may still be on its way into the transcript:
    /// one typing, or one whose echo clock still runs. An overdue send is
    /// not: its clock ran out with the Agent not Working, so it is no
    /// prompt of the turn the Agent works on now, in a program whose clock
    /// stops while it works (Antigravity CLI).
    static func awaitsRecord(
        _ messages: [AgentComposerStore.Message], statuses: [UUID: AgentChatStore.SendStatus]
    ) -> Bool {
        pending(messages, statuses: statuses).contains { echo in
            switch echo.state {
            case .sending, .sent: true
            // Unanswered, it may have gone; it waits while its clock runs.
            case .outcomeUnknown: statuses[echo.id] == .awaiting
            default: false
            }
        }
    }

    /// The echoes below the transcript. A message the transcript recorded
    /// gives way to its entry, and a failure shows only while it is Chat's
    /// latest message, the one the Composer offers to retry. So does a send
    /// the user cleared from the Agent's input box. A send the program
    /// refused says what it said instead.
    static func pending(
        _ messages: [AgentComposerStore.Message], statuses: [UUID: AgentChatStore.SendStatus]
    ) -> [ChatPendingEcho] {
        let chatMessages = messages.filter { $0.route == .chat }
        let latest = chatMessages.last?.id
        return chatMessages.compactMap { message in
            let status = statuses[message.id]
            guard status != .recorded, status != .abandoned else { return nil }
            if status == .discarded, message.id != latest { return nil }
            let state: ChatPendingEcho.State
            switch message.state {
            case .sending:
                state = .sending
            case .delivered:
                // Unknown to the store: sent before this Chat was watching.
                guard let status else { return nil }
                switch status {
                case .overdue: state = .unconfirmed
                case .returned: state = .notDelivered
                case .discarded: state = .discarded
                case .refused(let refusal): state = .refused(refusal)
                case .misdirected: state = .misdirected
                case .awaiting, .recorded, .abandoned: state = .sent
                }
            case .undelivered:
                // The store's later look at the input box, or the program's
                // own log of what it took, outranks the check after the send.
                guard let status else { return nil }
                switch status {
                case .discarded: state = .discarded
                case .misdirected: state = .misdirected
                default: state = .notDelivered
                }
            case .failed(let detail):
                guard message.id == latest else { return nil }
                state = .failed(detail)
            case .outcomeUnknown:
                // Only the program's log naming another session says more.
                state = status == .misdirected ? .misdirected : .outcomeUnknown
            }
            return ChatPendingEcho(id: message.id, text: message.text, state: state)
        }
    }
}
