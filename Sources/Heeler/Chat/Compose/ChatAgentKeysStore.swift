import Foundation
import Observation

/// Chat's Agent controls: keys pressed in the Agent's program through
/// `agent.send_keys` (ADR 0020), never through the Attach PTY. One request
/// at a time, in the order pressed, as typed keys would arrive.
@MainActor
@Observable
final class ChatAgentKeysStore {
    /// Why the last key may not have arrived; cleared once one does.
    private(set) var failure: String?
    @ObservationIgnored private let send: @MainActor ([String]) async throws -> Void
    @ObservationIgnored private var tail: Task<Void, Never>?

    init(send: @escaping @MainActor ([String]) async throws -> Void) {
        self.send = send
    }

    /// Queues the key behind the ones still on their way; returns its
    /// delivery. A key herdr has no name for sends nothing.
    @discardableResult
    func press(_ key: AgentQuickKey) -> Task<Void, Never>? {
        guard let name = key.herdrKeyName else { return nil }
        let previous = tail
        let task = Task { @MainActor [weak self, send] in
            await previous?.value
            do {
                try await send([name])
                self?.failure = nil
            } catch {
                self?.failure = "Couldn't reach the Agent, so the key may not have gone."
            }
        }
        tail = task
        return task
    }
}
