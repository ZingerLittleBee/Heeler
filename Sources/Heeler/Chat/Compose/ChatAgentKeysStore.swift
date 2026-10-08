import Foundation
import Observation

/// Chat's Agent controls: keys pressed in the Agent's program through
/// `agent.send_keys` (ADR 0021), never through the Attach PTY. One request
/// at a time, in the order pressed, as typed keys would arrive.
@MainActor
@Observable
final class ChatAgentKeysStore {
    /// Why the last key may not have arrived; cleared once one does.
    private(set) var failure: String?
    @ObservationIgnored private let send: @MainActor ([String]) async throws -> Void
    @ObservationIgnored private var tail: Task<Bool, Never>?

    init(send: @escaping @MainActor ([String]) async throws -> Void) {
        self.send = send
    }

    /// Queues the key behind the ones still on their way; returns its
    /// delivery. A key herdr has no name for sends nothing.
    @discardableResult
    func press(_ key: AgentQuickKey) -> Task<Void, Never>? {
        guard let delivery = enqueue(key) else { return nil }
        return Task { _ = await delivery.value }
    }

    /// Queues the key like `press`, and says whether it reached herdr: the
    /// Composer's Stop reports a failed Esc beside itself.
    func deliver(_ key: AgentQuickKey) async -> Bool {
        await enqueue(key)?.value ?? false
    }

    private func enqueue(_ key: AgentQuickKey) -> Task<Bool, Never>? {
        guard let name = key.herdrKeyName else { return nil }
        let previous = tail
        let task = Task { @MainActor [weak self, send] in
            _ = await previous?.value
            do {
                try await send([name])
                self?.failure = nil
                return true
            } catch {
                self?.failure = "Couldn't reach the Agent, so the key may not have gone."
                return false
            }
        }
        tail = task
        return task
    }
}
