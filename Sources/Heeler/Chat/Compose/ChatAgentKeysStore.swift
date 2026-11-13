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
/// `agent.send_keys` (ADR 0024), never through the Attach PTY, or on herdr-core
/// through an attach of Chat's own (ADR 0035). One request at a time, in the
/// order pressed, as typed keys would arrive. One queue per Agent
/// (`AgentComposerSession.agentKeys`), shared by every Chat and window
/// showing it and kept by a rebuilt one, as its Composer is.
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

    /// Whether work queued with `afterQueued` has yet to end. A Composer
    /// send, from Chat or the Agent's terminal page in any window, waits
    /// meanwhile (`AgentComposerSession.heldSend`): it goes outside this
    /// queue and could land between two of its keys, such as into a
    /// `/tasks` typed for Stop.
    var isRunningQueuedWork: Bool { queuedWork > 0 }
    @ObservationIgnored private var queuedWork = 0
    /// What runs once no queued work is left (`holdSend`).
    @ObservationIgnored private var whenQueuedWorkEnds: [@MainActor () -> Void] = []

    /// Holds a Composer send while queued work runs: the refusal saying
    /// `reason`, or nil when none runs. Once that work ends, `composer`'s
    /// notice of it gives way to one saying `ended`, since nothing sends the
    /// draft and nothing else would change the notice: Antigravity CLI is
    /// Idle by then, so no Agent Status change comes, and the notice stayed
    /// until the draft changed (live). Ending it with the work hid a send
    /// held at the work's end. A notice noted for anything else, or already
    /// ended, stays as it is.
    func holdSend(saying reason: String, then ended: String, in composer: AgentComposerStore) -> ComposerRefusal? {
        guard isRunningQueuedWork else { return nil }
        let hold = ComposerRefusal.inputNotReady(reason)
        whenQueuedWorkEnds.append { [weak composer] in composer?.replaceNotice(hold, with: .inputNotReady(ended)) }
        return hold
    }

    /// Runs `action` in line with queued keys without marking queued background work,
    /// as a projection-supplied Chat Stop does before its follow-through.
    func inOrder<Result: Sendable>(_ action: @escaping @MainActor () async -> Result) async -> Result {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            return await action()
        }
        tail = Task { @MainActor in
            _ = await task.value
            return .sent
        }
        return await task.value
    }

    /// Runs `work` once the keys queued before it have gone, and holds keys
    /// queued after it until it ends: work that types over several screens,
    /// such as Antigravity CLI's Stop ending a turn's background commands,
    /// where a second Stop's Esc must not land halfway.
    ///
    /// The work ends in the main-actor job `work` returns in. The caller
    /// resumes a job later, and a send in between would otherwise be held
    /// for work already over, with nothing to send its draft.
    func afterQueued<Result: Sendable>(_ work: @escaping @MainActor () async -> Result) async -> Result {
        queuedWork += 1
        let previous = tail
        let task = Task { @MainActor [self] in
            _ = await previous?.value
            let result = await work()
            queuedWorkDidEnd()
            return result
        }
        tail = Task { @MainActor in
            _ = await task.value
            return .sent
        }
        return await task.value
    }

    /// One piece of queued work ended; once none is left, what waits for
    /// that runs.
    private func queuedWorkDidEnd() {
        queuedWork -= 1
        guard queuedWork == 0 else { return }
        let ended = whenQueuedWorkEnds
        whenQueuedWorkEnds = []
        for action in ended { action() }
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
            } catch let refusal as HerdrCoreChatTyping.Refusal {
                return .withheld(refusal.message)
            } catch {
                self?.failure = String(localized: "Couldn't reach the Agent, so the key may not have gone.")
                return .failed
            }
        }
        tail = task
        return task
    }
}
