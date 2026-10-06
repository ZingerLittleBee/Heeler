import Foundation

/// Chat's reading of the Composer's messages (ADR 0020): what the Chat
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
                case .delivered, .undelivered: true
                case .sending, .failed: false
                }
            return AgentChatStore.SentMessage(
                id: message.id, text: rules.outgoingText(message.text), isDelivered: isDelivered)
        }
    }

    /// The echoes below the transcript. A message the transcript recorded
    /// gives way to its entry, and a failure shows only while it is Chat's
    /// latest message, the one the Composer offers to retry.
    static func pending(
        _ messages: [AgentComposerStore.Message], statuses: [UUID: AgentChatStore.SendStatus]
    ) -> [ChatPendingEcho] {
        let chatMessages = messages.filter { $0.route == .chat }
        let latest = chatMessages.last?.id
        return chatMessages.compactMap { message in
            let status = statuses[message.id]
            guard status != .recorded, status != .abandoned else { return nil }
            let state: ChatPendingEcho.State
            switch message.state {
            case .sending:
                state = .sending
            case .delivered:
                // Unknown to the store: sent before this Chat was watching.
                guard let status else { return nil }
                state = status == .overdue ? .unconfirmed : .sent
            case .undelivered:
                guard status != nil else { return nil }
                state = .notDelivered
            case .failed(let detail):
                guard message.id == latest else { return nil }
                state = .failed(detail)
            }
            return ChatPendingEcho(id: message.id, text: message.text, state: state)
        }
    }
}
