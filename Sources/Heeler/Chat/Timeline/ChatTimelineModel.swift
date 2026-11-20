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

    private struct Request: Equatable {
        let conversation: Int
        let input: ChatTimelineInput
        let turns: [ChatTurn]
        let precedingTurnEnd: ChatTurnEnd?
        let signals: ChatTurnSignals
        let isReady: Bool
    }

    @ObservationIgnored private var builder = ChatRowBuilder()
    @ObservationIgnored private var waiting: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerID: UUID?
    @ObservationIgnored private var conversation: Int?
    @ObservationIgnored private var builtInput: ChatTimelineInput?
    @ObservationIgnored private var latestRequest: Request?
    /// Cell heights measured on `measuredConversationGeneration`, kept across
    /// view mounts so re-entering Chat lays out rows at their measured heights
    /// on the first pass.
    @ObservationIgnored private(set) var measuredHeights: [ChatRowID: ChatMeasuredHeight] = [:]
    @ObservationIgnored private(set) var measuredConversationGeneration: Int?

    /// Shows `input` as the conversation `conversation` numbers. Another
    /// conversation reloads the list at its end; `isReady` stays set within
    /// one conversation once it is. `turns`, `precedingTurnEnd` and
    /// `signals` decide what folds.
    func update(
        conversation: Int, input: ChatTimelineInput, turns: [ChatTurn] = [], precedingTurnEnd: ChatTurnEnd? = nil,
        signals: ChatTurnSignals = ChatTurnSignals(), isReady: Bool
    ) {
        let request = Request(
            conversation: conversation, input: input, turns: turns, precedingTurnEnd: precedingTurnEnd,
            signals: signals, isReady: isReady)
        latestRequest = request
        if worker == nil, waiting == nil, self.conversation == conversation, builtInput == input {
            var next = state
            next.revision += 1
            next.turns = turns
            next.precedingTurnEnd = precedingTurnEnd
            next.signals = signals
            next.isReady = next.isReady || isReady
            state = next
            return
        }
        waiting = request
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        let builder = self.builder
        worker = Task { [weak self] in
            await self?.drain(id: id, builder: builder)
        }
    }

    /// Updates the timeline only when `conversation`, `input`, fold metadata,
    /// or readiness actually changed from the latest request, avoiding
    /// redundant work when a view re-mounts over an already-warmed store.
    func updateIfNeeded(
        conversation: Int, input: ChatTimelineInput, turns: [ChatTurn] = [], precedingTurnEnd: ChatTurnEnd? = nil,
        signals: ChatTurnSignals = ChatTurnSignals(), isReady: Bool
    ) {
        if let latest = latestRequest,
            latest.conversation == conversation,
            latest.input == input,
            latest.turns == turns,
            latest.precedingTurnEnd == precedingTurnEnd,
            latest.signals == signals
        {
            if worker != nil || waiting != nil {
                if !isReady || latest.isReady { return }
            } else if !isReady || state.isReady {
                return
            }
        }
        update(
            conversation: conversation, input: input, turns: turns, precedingTurnEnd: precedingTurnEnd,
            signals: signals, isReady: isReady)
    }

    func recordMeasuredHeight(_ height: ChatMeasuredHeight, for id: ChatRowID, generation: Int) {
        guard generation == state.generation else { return }
        if measuredConversationGeneration != generation {
            measuredConversationGeneration = generation
            measuredHeights.removeAll()
        }
        measuredHeights[id] = height
    }

    func forgetMeasuredHeights(keeping kept: Set<ChatRowID>, generation: Int) {
        guard measuredConversationGeneration == generation else { return }
        measuredHeights = measuredHeights.filter { kept.contains($0.key) }
    }

    /// Clears built rows, Markdown memos, and measured heights when the owning
    /// Chat store ends.
    func reset() {
        worker?.cancel()
        worker = nil
        workerID = nil
        waiting = nil
        conversation = nil
        builtInput = nil
        latestRequest = nil
        measuredHeights.removeAll()
        measuredConversationGeneration = nil
        builder = ChatRowBuilder()
        state = .empty
    }

    /// Resolves once every request so far is published, for tests.
    func settled() async {
        await worker?.value
    }

    private func drain(id: UUID, builder: ChatRowBuilder) async {
        while !Task.isCancelled, workerID == id, let request = waiting {
            waiting = nil
            let isNewConversation = request.conversation != conversation
            if isNewConversation { await builder.reset() }
            let build = PerfTrace.beginInterval("chat.rows.build", "entries=\(request.input.entries.count)")
            let rows = await builder.rows(for: request.input)
            PerfTrace.endInterval(build, "rows=\(rows.count)")
            guard !Task.isCancelled, workerID == id else { return }
            var next = state
            if isNewConversation {
                conversation = request.conversation
                next.generation += 1
                next.isReady = false
                measuredHeights.removeAll()
                measuredConversationGeneration = next.generation
            }
            builtInput = request.input
            next.revision += 1
            next.rows = rows
            next.turns = request.turns
            next.precedingTurnEnd = request.precedingTurnEnd
            next.signals = request.signals
            next.isReady = next.isReady || request.isReady
            state = next
        }
        if workerID == id {
            worker = nil
            workerID = nil
        }
    }
}
