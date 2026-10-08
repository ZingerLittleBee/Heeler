import Foundation
import Observation

/// Saved Chat entry points are display data, never live Agent inventory.
/// Notifications, Live Activities and command eligibility keep using the
/// Console's authoritative projection.
@MainActor
@Observable
final class ConsoleChatCache {
    private(set) var records: [Host.ID: [ChatCachedAgent]] = [:]
    @ObservationIgnored private let cache: any ChatTranscriptCache
    @ObservationIgnored private var hosts: [Host.ID: Host] = [:]
    @ObservationIgnored private var loads: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var writes: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var revisions: [Host.ID: Int] = [:]
    @ObservationIgnored private var confirmed: [ConsoleAgent.ID: ConfirmedSession] = [:]

    private struct ConfirmedSession {
        let terminalID: String
        let workspaceID: String
        let tabID: String
        let kind: String
        let snapshot: AgentSessionInfo?
        let current: AgentSessionInfo?
    }

    init(cache: any ChatTranscriptCache) { self.cache = cache }

    func setHosts(_ next: [Host]) {
        let incoming = Dictionary(next.map { ($0.id, $0) }) { _, last in last }
        for id in hosts.keys where hosts[id] != incoming[id] {
            loads[id]?.cancel()
            loads[id] = nil
            records[id] = nil
            revisions[id, default: 0] += 1
            confirmed = confirmed.filter { $0.key.hostID != id }
        }
        let changed = incoming.values.filter { hosts[$0.id] != $0 }
        hosts = incoming
        for host in changed {
            let revision = revisions[host.id, default: 0]
            loads[host.id] = Task { [weak self, cache] in
                let saved = await cache.loadAgentDirectory(for: host)
                guard !Task.isCancelled, let self, hosts[host.id] == host,
                    revisions[host.id, default: 0] == revision else { return }
                records[host.id] = saved
                loads[host.id] = nil
            }
        }
    }

    /// A completed live snapshot supersedes the saved directory, including an
    /// empty one. An unchanged older session field must not undo agent.get.
    func observe(_ agents: [ConsoleAgent], on host: Host) {
        guard hosts[host.id] == host else { return }
        let ids = Set(agents.map(\.id))
        confirmed = confirmed.filter { $0.key.hostID != host.id || ids.contains($0.key) }
        let next = agents.compactMap { agent -> ChatCachedAgent? in
            guard AgentChatAvailability.mayOfferChat(for: agent.agent) else { return nil }
            var entry = ChatCachedAgent(agent)
            if let known = confirmed[agent.id], known.snapshot == agent.agent.agentSession,
                known.terminalID == agent.agent.terminalID, known.workspaceID == agent.agent.workspaceID,
                known.tabID == agent.agent.tabID, known.kind == agent.agent.kind {
                entry.agentSession = known.current
            } else {
                confirmed[agent.id] = nil
            }
            if entry.agentSession == nil {
                entry.agentSession = savedBinding(for: agent, on: host)
            }
            guard entry.isValid(for: host) else { return nil }
            return entry
        }.sorted { $0.paneID < $1.paneID }
        replace(next, on: host)
    }

    /// Persist the exact binding that Chat actually queried, which can be
    /// newer than the Console snapshot's session field.
    func confirm(_ fresh: Agent, for snapshot: ConsoleAgent, on host: Host) {
        guard hosts[host.id] == host, fresh.paneID == snapshot.agent.paneID,
            fresh.terminalID == snapshot.agent.terminalID, fresh.workspaceID == snapshot.agent.workspaceID,
            fresh.tabID == snapshot.agent.tabID, fresh.kind == snapshot.agent.kind else { return }
        confirmed[snapshot.id] = ConfirmedSession(
            terminalID: fresh.terminalID, workspaceID: fresh.workspaceID, tabID: fresh.tabID, kind: fresh.kind,
            snapshot: snapshot.agent.agentSession, current: fresh.agentSession)
        var source = snapshot
        source.agent = fresh
        var entry = ChatCachedAgent(source)
        if fresh.agentSession == nil {
            entry.agentSession = savedBinding(for: source, on: host)
        }
        var next = (records[host.id] ?? []).filter { $0.paneID != fresh.paneID }
        if entry.isValid(for: host), AgentChatAvailability.mayOfferChat(for: fresh) {
            next.append(entry)
        }
        replace(next.sorted { $0.paneID < $1.paneID }, on: host)
    }

    func agents(on host: Host) -> [ConsoleAgent] {
        guard hosts[host.id] == host else { return [] }
        return (records[host.id] ?? []).map { $0.consoleAgent(for: host) }
    }

    /// Test and lifecycle boundary: no queued disk work remains.
    func settled() async {
        for task in Array(loads.values) { await task.value }
        for task in Array(writes.values) { await task.value }
    }

    private func savedBinding(for agent: ConsoleAgent, on host: Host) -> AgentSessionInfo? {
        records[host.id]?.first {
            $0.paneID == agent.agent.paneID && $0.terminalID == agent.agent.terminalID
                && $0.workspaceID == agent.agent.workspaceID && $0.tabID == agent.agent.tabID
                && $0.kind == agent.agent.kind
        }?.agentSession
    }

    private func replace(_ next: [ChatCachedAgent], on host: Host) {
        // Invalidate a cold restore even when a fresh empty snapshot matches
        // the initial empty in-memory value.
        revisions[host.id, default: 0] += 1
        loads[host.id]?.cancel()
        loads[host.id] = nil
        guard records[host.id] != next else { return }
        records[host.id] = next
        writes[host.id] = Task { [previous = writes[host.id], cache] in
            await previous?.value
            await cache.saveAgentDirectory(next, for: host)
        }
    }
}
