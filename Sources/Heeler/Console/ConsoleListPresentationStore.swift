import Foundation
import Observation

/// The two Console Agent-list presentations. Flat remains the default so
/// introducing grouped-list support does not change the existing surface
/// until the UI explicitly selects it.
enum ConsoleListPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case flat
    case grouped

    var id: Self { self }

    /// Toolbar / picker label for the presentation switcher.
    var title: String {
        switch self {
        case .flat: "Status order"
        case .grouped: "By Host"
        }
    }
}

/// One Host section projected from the Host catalog and the Console's
/// already-sorted Agent sequence. The section carries the inputs a header
/// needs to present connection and Agent Inventory readiness honestly.
struct ConsoleHostSection: Identifiable, Equatable {
    let hostID: Host.ID
    let hostDisplayName: String
    let connectionStatus: EventsSessionStatus?
    let isAwaitingSnapshot: Bool
    let statusPresentation: ConsoleHostStatusPresentation?
    let agents: [ConsoleAgent]
    let isCollapsed: Bool
    let statusCounts: ConsoleHostAgentStatusCounts

    var id: Host.ID { hostID }
}

/// The Live Activity-eligible Agent statuses shown in a collapsed Host
/// section. Keeping the same order and labels as the Live Activity makes the
/// two summaries directly comparable.
struct ConsoleHostAgentStatusCounts: Equatable {
    let blocked: Int
    let working: Int
    let done: Int

    init(blocked: Int = 0, working: Int = 0, done: Int = 0) {
        self.blocked = blocked
        self.working = working
        self.done = done
    }

    init(agents: [ConsoleAgent]) {
        blocked = agents.count { $0.agent.status == .blocked }
        working = agents.count { $0.agent.status == .working }
        done = agents.count { $0.agent.status == .done }
    }

    var items: [ConsoleHostAgentStatusCount] {
        var items: [ConsoleHostAgentStatusCount] = []
        if blocked > 0 { items.append(.init(status: .blocked, count: blocked)) }
        if working > 0 { items.append(.init(status: .working, count: working)) }
        if done > 0 { items.append(.init(status: .done, count: done)) }
        return items
    }
}

struct ConsoleHostAgentStatusCount: Identifiable, Equatable {
    let status: AgentStatus
    let count: Int

    var id: String { status.rawValue }
}

/// Persists the Console presentation choice and per-Host collapsed state,
/// and projects grouped sections without taking ownership of Agent sorting.
/// Collapsed Host ids are deliberately retained when a Host disconnects or
/// leaves the catalog so a reconnect or later return restores the choice.
@MainActor
@Observable
final class ConsoleListPresentationStore {
    private static let modeDefaultsKey = "console-list.presentation-mode"
    private static let collapsedHostsDefaultsKey = "console-list.collapsed-hosts"

    private(set) var mode: ConsoleListPresentationMode
    private var collapsedHostIDs: Set<Host.ID>
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode =
            defaults.string(forKey: Self.modeDefaultsKey)
            .flatMap(ConsoleListPresentationMode.init(rawValue:)) ?? .flat
        collapsedHostIDs = Set(
            (defaults.stringArray(forKey: Self.collapsedHostsDefaultsKey) ?? [])
                .compactMap(UUID.init(uuidString:)))
    }

    func select(_ mode: ConsoleListPresentationMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
    }

    func isCollapsed(_ hostID: Host.ID) -> Bool {
        collapsedHostIDs.contains(hostID)
    }

    func setCollapsed(_ collapsed: Bool, for hostID: Host.ID) {
        let changed: Bool
        if collapsed {
            changed = collapsedHostIDs.insert(hostID).inserted
        } else {
            changed = collapsedHostIDs.remove(hostID) != nil
        }
        guard changed else { return }
        persistCollapsedHostIDs()
    }

    func toggleCollapsed(_ hostID: Host.ID) {
        setCollapsed(!isCollapsed(hostID), for: hostID)
    }

    /// Convenience contract for the Console UI. Reading these observable
    /// inputs on each render makes status, inventory, and membership changes
    /// re-project without a second cache to reconcile.
    func sections(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostID: Host.ID? = nil
    ) -> [ConsoleHostSection] {
        sections(
            hosts: hosts,
            agents: console.agents,
            hostStatuses: console.hostStatuses,
            hostStandingFailures: console.hostStandingFailures,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostSyncErrors: console.hostSyncErrors,
            filteredHostID: filteredHostID)
    }

    /// Projects one section per catalog Host, in catalog order. `agents` is
    /// already pin/status sorted by ConsoleStore; filtering it in-place keeps
    /// that exact relative order within every Host section.
    func sections(
        hosts: [Host],
        agents: [ConsoleAgent],
        hostStatuses: [Host.ID: EventsSessionStatus] = [:],
        hostStandingFailures: [Host.ID: TransportError] = [:],
        hostsAwaitingSnapshot: Set<Host.ID> = [],
        hostSyncErrors: [Host.ID: String] = [:],
        filteredHostID: Host.ID? = nil
    ) -> [ConsoleHostSection] {
        let agentsByHost = Dictionary(grouping: agents, by: \.hostID)
        var projectedHostIDs: Set<Host.ID> = []

        return hosts.compactMap { host in
            guard filteredHostID == nil || host.id == filteredHostID else { return nil }
            guard projectedHostIDs.insert(host.id).inserted else { return nil }

            let hostAgents = agentsByHost[host.id] ?? []
            let isAwaitingSnapshot = hostsAwaitingSnapshot.contains(host.id)
            return ConsoleHostSection(
                hostID: host.id,
                hostDisplayName: host.displayName,
                connectionStatus: hostStatuses[host.id],
                isAwaitingSnapshot: isAwaitingSnapshot,
                statusPresentation: ConsoleHostStatusPresentation(
                    host: host,
                    status: hostStatuses[host.id],
                    standingFailure: hostStandingFailures[host.id],
                    isAwaitingSnapshot: isAwaitingSnapshot,
                    syncError: hostSyncErrors[host.id]),
                agents: hostAgents,
                isCollapsed: isCollapsed(host.id),
                statusCounts: ConsoleHostAgentStatusCounts(agents: hostAgents))
        }
    }

    private func persistCollapsedHostIDs() {
        defaults.set(
            collapsedHostIDs.map(\.uuidString).sorted(),
            forKey: Self.collapsedHostsDefaultsKey)
    }
}
