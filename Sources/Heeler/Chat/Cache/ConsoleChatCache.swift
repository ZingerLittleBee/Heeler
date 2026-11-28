import Foundation
import Observation

/// Saved Chat entry points are display data, never live Agent inventory.
/// Notifications, Live Activities and command eligibility keep using the
/// Console's authoritative projection.
@MainActor
@Observable
final class ConsoleChatCache {
    private(set) var records: [Host.ID: [ChatCachedAgent]] = [:]
    /// The Workspace structure of each Host's last snapshot, saved with its
    /// entries.
    private(set) var structures: [Host.ID: [ChatCachedWorkspace]] = [:]
    /// Each Host's last loaded plugin sidebar snapshot, saved with its
    /// entries so layout fields and sort order do not jump while connecting.
    private(set) var sidebarSnapshots: [Host.ID: AgentRowLayoutSnapshot] = [:]
    @ObservationIgnored var onChange: (@MainActor (Host.ID?) -> Void)?
    @ObservationIgnored private let cache: any ChatTranscriptCache
    @ObservationIgnored private let writeDebounce: Duration
    @ObservationIgnored private var hosts: [Host.ID: Host] = [:]
    @ObservationIgnored private var loads: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var writes: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var debounceTasks: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingDirectoryContents:
        [Host.ID: (host: Host, contents: ChatAgentDirectory.Contents)] = [:]
    @ObservationIgnored private var revisions: [Host.ID: Int] = [:]
    @ObservationIgnored private var confirmed: [ConsoleAgent.ID: ConfirmedSession] = [:]
    /// Live updates must merge with the disk directory, not cancel its
    /// restore before a missing session field can reuse a known binding.
    @ObservationIgnored private var pendingUpdates: [Host.ID: [Update]] = [:]

    private enum Update {
        case snapshot([ConsoleAgent], conversationTitles: [ConsoleAgent.ID: String], coreScope: String?)
        case confirmation(Agent, ConsoleAgent, conversationTitle: String?, coreScope: String?)
        case removal(paneID: String)
        case branch(CheckoutHead.Branch, checkoutPath: String)
        case sidebarSnapshot(AgentRowLayoutSnapshot?)
    }

    private struct ConfirmedSession {
        let terminalID: String
        let workspaceID: String
        let tabID: String
        let kind: String
        let snapshot: AgentSessionInfo?
        let current: AgentSessionInfo?
        let fresh: Agent
        let conversationTitle: String?
        let coreScope: String?
    }

    init(cache: any ChatTranscriptCache, writeDebounce: Duration = .seconds(2)) {
        self.cache = cache
        self.writeDebounce = writeDebounce
    }

    func setHosts(_ next: [Host]) {
        let incoming = Dictionary(next.map { ($0.id, $0) }) { _, last in last }
        var removedAny = false
        for id in hosts.keys where hosts[id] != incoming[id] {
            loads[id]?.cancel()
            loads[id] = nil
            flushPendingDirectoryWrite(for: id)
            if records[id] != nil || structures[id] != nil || sidebarSnapshots[id] != nil {
                records[id] = nil
                structures[id] = nil
                sidebarSnapshots[id] = nil
                removedAny = true
            }
            pendingUpdates[id] = nil
            revisions[id, default: 0] += 1
            confirmed = confirmed.filter { $0.key.hostID != id }
        }
        let changed = incoming.values.filter { hosts[$0.id] != $0 }
        hosts = incoming
        if removedAny {
            onChange?(nil)
        }
        for host in changed {
            let revision = revisions[host.id, default: 0]
            loads[host.id] = Task { [weak self, cache] in
                let saved = await cache.loadAgentDirectory(for: host)
                guard !Task.isCancelled, let self, hosts[host.id] == host,
                    revisions[host.id, default: 0] == revision else { return }
                let changedLoaded =
                    records[host.id] != saved.agents || structures[host.id] != saved.workspaces
                    || sidebarSnapshots[host.id] != saved.sidebarSnapshot
                records[host.id] = saved.agents
                structures[host.id] = saved.workspaces
                sidebarSnapshots[host.id] = saved.sidebarSnapshot
                loads[host.id] = nil
                applyPendingUpdates(on: host)
                if changedLoaded {
                    onChange?(host.id)
                }
            }
        }
    }

    /// Re-proves the saved bindings on a new connection. Trusting a replaced
    /// host key leaves the Host record unchanged, so the same Host may now
    /// reach another machine; until the cache confirms the saved directory
    /// still belongs to the Host, live updates queue as during the initial
    /// restore. A load already in flight reads the current trust itself.
    func revalidate(on host: Host) {
        guard hosts[host.id] == host, loads[host.id] == nil else { return }
        flushPendingDirectoryWrite(for: host.id)
        let revision = revisions[host.id, default: 0]
        loads[host.id] = Task { [weak self, cache, write = writes[host.id]] in
            await write?.value
            let belongs = await cache.agentDirectoryBelongs(to: host)
            guard !Task.isCancelled, let self, hosts[host.id] == host,
                revisions[host.id, default: 0] == revision else { return }
            loads[host.id] = nil
            var cleared = false
            if !belongs {
                cleared =
                    records[host.id] != nil || structures[host.id] != nil
                    || sidebarSnapshots[host.id] != nil
                records[host.id] = nil
                structures[host.id] = nil
                sidebarSnapshots[host.id] = nil
                confirmed = confirmed.filter { $0.key.hostID != host.id }
            }
            applyPendingUpdates(on: host)
            if cleared {
                onChange?(host.id)
            }
        }
    }

    /// Applies everything that arrived during a disk read before another
    /// task can use the restored entries.
    private func applyPendingUpdates(on host: Host) {
        for update in pendingUpdates.removeValue(forKey: host.id) ?? [] {
            switch update {
            case .snapshot(let agents, let titles, let coreScope):
                observe(agents, conversationTitles: titles, coreScope: coreScope, on: host)
            case .confirmation(let fresh, let snapshot, let title, let coreScope):
                confirm(fresh, for: snapshot, conversationTitle: title, coreScope: coreScope, on: host)
            case .removal(let paneID):
                remove(paneID: paneID, on: host)
            case .branch(let branch, let path):
                record(branch, atCheckoutPath: path, on: host)
            case .sidebarSnapshot(let snapshot):
                record(sidebarSnapshot: snapshot, on: host)
            }
        }
    }

    func observe(
        _ agents: [ConsoleAgent],
        conversationTitles: [ConsoleAgent.ID: String] = [:],
        coreScope: String? = nil,
        on host: Host
    ) {
        guard hosts[host.id] == host else { return }
        if loads[host.id] != nil {
            pendingUpdates[host.id, default: []].append(
                .snapshot(agents, conversationTitles: conversationTitles, coreScope: coreScope))
            return
        }
        let ids = Set(agents.map(\.id))
        confirmed = confirmed.filter { $0.key.hostID != host.id || ids.contains($0.key) }
        let next = agents.compactMap { agent -> ChatCachedAgent? in
            guard AgentChatAvailability.mayOfferChat(for: agent.agent) else { return nil }
            var entry: ChatCachedAgent
            if let known = confirmed[agent.id], known.snapshot == agent.agent.agentSession,
                known.terminalID == agent.agent.terminalID, known.workspaceID == agent.agent.workspaceID,
                known.tabID == agent.agent.tabID, known.kind == agent.agent.kind,
                Self.coreScope(known.coreScope, matches: coreScope) {
                if known.current != agent.agent.agentSession {
                    var source = agent
                    source.agent = known.fresh
                    entry = ChatCachedAgent(
                        source, conversationTitle: known.conversationTitle,
                        coreScope: known.coreScope ?? coreScope)
                } else {
                    entry = ChatCachedAgent(
                        agent, conversationTitle: conversationTitles[agent.id],
                        coreScope: known.coreScope ?? coreScope)
                    entry.agentSession = known.current
                }
            } else {
                confirmed[agent.id] = nil
                entry = ChatCachedAgent(
                    agent, conversationTitle: conversationTitles[agent.id], coreScope: coreScope)
            }
            if entry.agentSession == nil, let saved = savedBinding(for: agent, on: host, coreScope: coreScope) {
                entry.agentSession = saved.session
                entry.coreScope = saved.coreScope ?? entry.coreScope
            }
            guard entry.isValid(for: host) else { return nil }
            return entry
        }.sorted { $0.paneID < $1.paneID }
        let structure = ChatCachedWorkspace.structure(of: agents, keeping: structures[host.id] ?? [])
        replace(next, structure: structure, sidebarSnapshot: sidebarSnapshots[host.id], on: host)
    }

    func confirm(
        _ fresh: Agent, for snapshot: ConsoleAgent, conversationTitle: String? = nil,
        coreScope: String? = nil, on host: Host
    ) {
        guard hosts[host.id] == host, fresh.paneID == snapshot.agent.paneID,
            fresh.terminalID == snapshot.agent.terminalID, fresh.workspaceID == snapshot.agent.workspaceID,
            fresh.tabID == snapshot.agent.tabID, fresh.kind == snapshot.agent.kind else { return }
        if loads[host.id] != nil {
            pendingUpdates[host.id, default: []].append(
                .confirmation(fresh, snapshot, conversationTitle: conversationTitle, coreScope: coreScope))
            return
        }
        confirmed[snapshot.id] = ConfirmedSession(
            terminalID: fresh.terminalID, workspaceID: fresh.workspaceID, tabID: fresh.tabID, kind: fresh.kind,
            snapshot: snapshot.agent.agentSession, current: fresh.agentSession,
            fresh: fresh, conversationTitle: conversationTitle, coreScope: coreScope)
        var source = snapshot
        source.agent = fresh
        var entry = ChatCachedAgent(source, conversationTitle: conversationTitle, coreScope: coreScope)
        if fresh.agentSession == nil, let saved = savedBinding(for: source, on: host, coreScope: coreScope) {
            entry.agentSession = saved.session
            entry.coreScope = saved.coreScope ?? entry.coreScope
        }
        var next = (records[host.id] ?? []).filter { $0.paneID != fresh.paneID }
        if entry.isValid(for: host), AgentChatAvailability.mayOfferChat(for: fresh) {
            next.append(entry)
        }
        replace(
            next.sorted { $0.paneID < $1.paneID },
            structure: structures[host.id] ?? [],
            sidebarSnapshot: sidebarSnapshots[host.id],
            on: host)
    }

    /// A Changes read found the checkout at `path` on `branch`. Only a
    /// checkout of the saved structure keeps it.
    func record(_ branch: CheckoutHead.Branch, atCheckoutPath path: String, on host: Host) {
        guard hosts[host.id] == host else { return }
        if loads[host.id] != nil {
            pendingUpdates[host.id, default: []].append(.branch(branch, checkoutPath: path))
            return
        }
        let current = structures[host.id] ?? []
        let next = current.map { workspace in
            guard workspace.checkout.checkoutPath == path else { return workspace }
            var updated = workspace
            updated.branch = branch
            return updated
        }
        guard next != current else { return }
        replace(
            records[host.id] ?? [], structure: next,
            sidebarSnapshot: sidebarSnapshots[host.id], on: host)
    }

    /// The Host's plugin sidebar snapshot loaded on a connection (`nil` when
    /// the plugin file was absent).
    func record(sidebarSnapshot: AgentRowLayoutSnapshot?, on host: Host) {
        guard hosts[host.id] == host else { return }
        if loads[host.id] != nil {
            pendingUpdates[host.id, default: []].append(.sidebarSnapshot(sidebarSnapshot))
            return
        }
        replace(
            records[host.id] ?? [],
            structure: structures[host.id] ?? [],
            sidebarSnapshot: sidebarSnapshot,
            on: host)
    }

    /// The user's removal of a saved entry: it and its saved messages leave
    /// this device, unless another entry still shows that conversation. A
    /// later snapshot still lists the Agent if it is running on the Host.
    func remove(paneID: String, on host: Host) {
        guard hosts[host.id] == host else { return }
        if loads[host.id] != nil {
            pendingUpdates[host.id, default: []].append(.removal(paneID: paneID))
            return
        }
        let entries = records[host.id] ?? []
        guard let removed = entries.first(where: { $0.paneID == paneID }) else { return }
        let remaining = entries.filter { $0.paneID != paneID }
        confirmed[ConsoleAgent.ID(hostID: host.id, paneID: paneID)] = nil
        replace(
            remaining, structure: structures[host.id] ?? [],
            sidebarSnapshot: sidebarSnapshots[host.id], on: host)
        guard case .bound(let reference) = ConversationReference.resolve(removed.agentSession),
            !remaining.contains(where: {
                ConversationReference.resolve($0.agentSession) == .bound(reference)
                    && $0.coreScope == removed.coreScope
            })
        else { return }
        flushPendingDirectoryWrite(for: host.id)
        let key = ChatCacheKey(
            hostID: host.id, socketLocation: host.socketLocation, reference: reference,
            coreScope: removed.coreScope)
        writes[host.id] = Task { [previous = writes[host.id], cache] in
            await previous?.value
            await cache.remove(key)
        }
    }

    func agents(on host: Host) -> [ConsoleAgent] {
        guard hosts[host.id] == host else { return [] }
        return (records[host.id] ?? []).map { $0.consoleAgent(for: host) }
    }

    func structure(on host: Host) -> [ChatCachedWorkspace] {
        guard hosts[host.id] == host else { return [] }
        return structures[host.id] ?? []
    }

    func sidebarSnapshot(on host: Host) -> AgentRowLayoutSnapshot? {
        guard hosts[host.id] == host else { return nil }
        return sidebarSnapshots[host.id]
    }

    /// Synchronous lookup of a cached client-resolved conversation title for
    /// the exact same pane and bound session while SFTP has not resolved it yet.
    func cachedConversationTitle(for agent: Agent, on host: Host) -> String? {
        guard hosts[host.id] == host, let session = agent.agentSession else { return nil }
        return records[host.id]?.first {
            $0.paneID == agent.paneID && $0.terminalID == agent.terminalID
                && $0.workspaceID == agent.workspaceID && $0.tabID == agent.tabID
                && $0.kind == agent.kind && $0.agentSession == session
        }?.conversationTitle
    }

    func cachedSession(for agent: Agent, on host: Host, coreScope: String? = nil) async -> AgentSessionInfo? {
        await loads[host.id]?.value
        guard !Task.isCancelled, hosts[host.id] == host else { return nil }
        return records[host.id]?.first {
            $0.hostID == host.id && $0.paneID == agent.paneID && $0.terminalID == agent.terminalID
                && $0.workspaceID == agent.workspaceID && $0.tabID == agent.tabID && $0.kind == agent.kind
                && Self.coreScope($0.coreScope, matches: coreScope)
                && $0.isValid(for: host)
        }?.agentSession
    }

    func cachedCoreScope(for agent: Agent, on host: Host) -> String? {
        guard hosts[host.id] == host else { return nil }
        return records[host.id]?.first {
            $0.hostID == host.id && $0.paneID == agent.paneID && $0.terminalID == agent.terminalID
                && $0.workspaceID == agent.workspaceID && $0.tabID == agent.tabID && $0.kind == agent.kind
                && $0.isValid(for: host)
        }?.coreScope
    }

    func settled() async {
        for task in Array(loads.values) { await task.value }
        for id in Array(pendingDirectoryContents.keys) {
            flushPendingDirectoryWrite(for: id)
        }
        for task in Array(writes.values) { await task.value }
    }

    private func savedBinding(
        for agent: ConsoleAgent, on host: Host, coreScope: String?
    ) -> (session: AgentSessionInfo, coreScope: String?)? {
        guard let record = records[host.id]?.first(where: {
            $0.paneID == agent.agent.paneID && $0.terminalID == agent.agent.terminalID
                && $0.workspaceID == agent.agent.workspaceID && $0.tabID == agent.agent.tabID
                && $0.kind == agent.agent.kind
                && Self.coreScope($0.coreScope, matches: coreScope)
        }), let session = record.agentSession else { return nil }
        return (session, record.coreScope)
    }

    private static func coreScope(_ entryScope: String?, matches liveScope: String?) -> Bool {
        guard let liveScope else { return true }
        guard let entryScope else { return false }
        return entryScope == liveScope || entryScope.hasPrefix(liveScope + "/")
    }

    private func flushPendingDirectoryWrite(for id: Host.ID) {
        debounceTasks.removeValue(forKey: id)?.cancel()
        guard let pending = pendingDirectoryContents.removeValue(forKey: id) else { return }
        writes[id] = Task { [previous = writes[id], cache] in
            await previous?.value
            await cache.saveAgentDirectory(pending.contents, for: pending.host)
        }
    }

    private func scheduleDirectoryWrite(_ contents: ChatAgentDirectory.Contents, on host: Host) {
        pendingDirectoryContents[host.id] = (host, contents)
        guard debounceTasks[host.id] == nil else { return }
        let delay = writeDebounce
        debounceTasks[host.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounceTasks[host.id] = nil
            self.flushPendingDirectoryWrite(for: host.id)
        }
    }

    private func replace(
        _ next: [ChatCachedAgent],
        structure: [ChatCachedWorkspace],
        sidebarSnapshot: AgentRowLayoutSnapshot?,
        on host: Host
    ) {
        // Invalidate a cold restore even when a fresh empty snapshot matches
        // the initial empty in-memory value.
        revisions[host.id, default: 0] += 1
        loads[host.id]?.cancel()
        loads[host.id] = nil
        guard
            records[host.id] != next || structures[host.id] != structure
                || sidebarSnapshots[host.id] != sidebarSnapshot
        else { return }
        records[host.id] = next
        structures[host.id] = structure
        sidebarSnapshots[host.id] = sidebarSnapshot
        onChange?(host.id)
        let contents = ChatAgentDirectory.Contents(
            agents: next, workspaces: structure, sidebarSnapshot: sidebarSnapshot)
        scheduleDirectoryWrite(contents, on: host)
    }
}
