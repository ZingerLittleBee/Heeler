import Foundation
import Observation

/// What became of keys queued with `deliver`.
enum ChatKeyDelivery: Equatable, Sendable {
    case sent
    /// The check gave this reason, so nothing was sent.
    case withheld(String)
    /// The request failed, so the keys may not have arrived.
    case failed
}

/// Chat's Agent controls: keys pressed in the Agent's program through
/// `agent.send_keys` (ADR 0024), never through the Attach PTY. One request
/// at a time, in the order pressed, as typed keys would arrive.
@MainActor
@Observable
final class ChatAgentKeysStore {
    /// Why the last key may not have arrived; cleared once one does.
    private(set) var failure: String?
    @ObservationIgnored private let send: @MainActor ([String]) async throws -> Void
    @ObservationIgnored private var tail: Task<ChatKeyDelivery, Never>?

    init(send: @escaping @MainActor ([String]) async throws -> Void) {
        self.send = send
    }

    /// Queues the key behind the ones still on their way; returns its
    /// delivery. A key herdr has no name for sends nothing.
    @discardableResult
    func press(_ key: AgentQuickKey) -> Task<Void, Never>? {
        guard let name = key.herdrKeyName else { return nil }
        let delivery = enqueue([name], unless: nil)
        return Task { _ = await delivery.value }
    }

    /// Queues `names` behind the keys still on their way and sends them in one
    /// `agent.send_keys`. `check`, when given, runs once those earlier keys have
    /// gone, so it sees their effect; a reason from it sends nothing and leaves
    /// `failure` alone. `[]` sends nothing and returns `.failed`.
    func deliver(
        _ names: [String], unless check: (@MainActor () async -> String?)? = nil
    ) async -> ChatKeyDelivery {
        guard !names.isEmpty else { return .failed }
        return await enqueue(names, unless: check).value
    }

    private func enqueue(
        _ names: [String], unless check: (@MainActor () async -> String?)?
    ) -> Task<ChatKeyDelivery, Never> {
        let previous = tail
        let task = Task<ChatKeyDelivery, Never> { @MainActor [weak self, send] in
            _ = await previous?.value
            if let check, let reason = await check() { return .withheld(reason) }
            do {
                try await send(names)
                self?.failure = nil
                return .sent
            } catch {
                self?.failure = "Couldn't reach the Agent, so the key may not have gone."
                return .failed
            }
        }
        tail = task
        return task
    }
}
