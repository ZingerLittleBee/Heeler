import Foundation
import Observation

/// Builds the timeline's rows off the main actor and publishes them in
/// order. A request that arrives while rows are being built waits, and a
/// newer one replaces it, so the list only moves forward and never shows a
/// state older than one it already showed.
@MainActor
@Observable
final class ChatTimelineModel {
    private(set) var state = ChatTimelineState.empty

    private struct Request {
        let conversation: Int
        let input: ChatTimelineInput
        let isReady: Bool
    }

    @ObservationIgnored private let builder = ChatRowBuilder()
    @ObservationIgnored private var waiting: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var conversation: Int?

    /// Shows `input` as the conversation `conversation` numbers. Another
    /// conversation reloads the list at its end; `isReady` stays set within
    /// one conversation once it is.
    func update(conversation: Int, input: ChatTimelineInput, isReady: Bool) {
        waiting = Request(conversation: conversation, input: input, isReady: isReady)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    /// Resolves once every request so far is published, for tests.
    func settled() async {
        await worker?.value
    }

    private func drain() async {
        while let request = waiting {
            waiting = nil
            let isNewConversation = request.conversation != conversation
            if isNewConversation { await builder.reset() }
            let rows = await builder.rows(for: request.input)
            var next = state
            if isNewConversation {
                conversation = request.conversation
                next.generation += 1
                next.isReady = false
            }
            next.revision += 1
            next.rows = rows
            next.isReady = next.isReady || request.isReady
            state = next
        }
        worker = nil
    }
}
