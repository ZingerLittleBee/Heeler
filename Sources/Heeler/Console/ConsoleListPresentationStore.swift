import Foundation
import Observation

/// The three Console Agent-list presentations. Flat remains the default so
/// introducing grouped-list support does not change the existing surface
/// until the UI explicitly selects it.
enum ConsoleListPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case flat
    case grouped
    case byHostWorkspace

    var id: Self { self }

    /// Toolbar / picker label for the presentation switcher.
    var title: String {
        switch self {
        case .flat: "All Agents"
        case .grouped: "By Host"
        case .byHostWorkspace: "By Host, By Workspace"
        }
    }
}

/// One Workspace group nested inside a Host section for the
/// "By Host, By Workspace" presentation. Agents arrive already sorted by
/// ConsoleStore; the group preserves that exact relative order.
struct ConsoleWorkspaceGroup: Identifiable, Equatable {
    /// Bucket for agents whose snapshot carried no workspace label.
    static let unassignedLabel = "Unassigned"

    let label: String
    let agents: [ConsoleAgent]
    /// Linked-worktree workspaces of this group's repository, each carrying
    /// the Agents whose workspace label matches that worktree workspace.
    /// Empty for everything but a repository's main-checkout workspace.
    var worktrees: [ConsoleWorkspaceGroup] = []
    /// Resolved by the store's projection: workspace groups start collapsed
    /// unless the user expanded this host+workspace pair. The Host-level
    /// collapse is carried by the section itself and hides whole groups.
    var isCollapsed: Bool = true

    var id: String { label }
}

/// A Host section joined with its Workspace groups. The Host part is the
/// exact `ConsoleHostSection` the "By Host" mode projects, so connection
/// status, collapse state, and status counts stay identical between the
/// two grouped presentations.
struct ConsoleHostWorkspaceSection: Identifiable, Equatable {
    let host: ConsoleHostSection
    let workspaceGroups: [ConsoleWorkspaceGroup]

    var id: Host.ID { host.hostID }
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
    private static let expandedWorkspacesDefaultsKey = "console-list.expanded-workspaces"

    private(set) var mode: ConsoleListPresentationMode
    private var collapsedHostIDs: Set<Host.ID>
    /// Stores EXPANDED host+workspace keys, so a workspace never seen before
    /// defaults to collapsed. Keyed per host+workspace pair because workspace
    /// labels repeat across hosts.
    private var expandedWorkspaceKeys: Set<String>
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
        expandedWorkspaceKeys = Set(
            defaults.stringArray(forKey: Self.expandedWorkspacesDefaultsKey) ?? [])
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

    /// Workspace groups default to collapsed: an expanded key is stored
    /// explicitly, so a workspace appearing for the first time starts closed.
    func isExpanded(_ hostID: Host.ID, workspaceLabel: String) -> Bool {
        expandedWorkspaceKeys.contains(Self.expandedWorkspaceKey(hostID, workspaceLabel))
    }

    func setExpanded(_ expanded: Bool, for hostID: Host.ID, workspaceLabel: String) {
        let key = Self.expandedWorkspaceKey(hostID, workspaceLabel)
        let changed: Bool
        if expanded {
            changed = expandedWorkspaceKeys.insert(key).inserted
        } else {
            changed = expandedWorkspaceKeys.remove(key) != nil
        }
        guard changed else { return }
        defaults.set(
            expandedWorkspaceKeys.sorted(),
            forKey: Self.expandedWorkspacesDefaultsKey)
    }

    func toggleExpanded(_ hostID: Host.ID, workspaceLabel: String) {
        setExpanded(
            !isExpanded(hostID, workspaceLabel: workspaceLabel),
            for: hostID,
            workspaceLabel: workspaceLabel)
    }

    private static func expandedWorkspaceKey(_ hostID: Host.ID, _ workspaceLabel: String) -> String {
        "\(hostID.uuidString)|\(workspaceLabel)"
    }

    /// Convenience contract for the Console UI. Reading these observable
    /// inputs on each render makes status, inventory, and membership changes
    /// re-project without a second cache to reconcile.
    func sections(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostID: Host.ID? = nil,
        searchQuery: String = ""
    ) -> [ConsoleHostSection] {
        sections(
            hosts: hosts,
            agents: console.agents,
            hostStatuses: console.hostStatuses,
            hostStandingFailures: console.hostStandingFailures,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostSyncErrors: console.hostSyncErrors,
            filteredHostID: filteredHostID,
            searchQuery: searchQuery)
    }

    /// Projects one section per catalog Host, in catalog order. `agents` is
    /// already sorted by ConsoleStore; filtering it in-place keeps
    /// that exact relative order within every Host section.
    func sections(
        hosts: [Host],
        agents: [ConsoleAgent],
        hostStatuses: [Host.ID: EventsSessionStatus] = [:],
        hostStandingFailures: [Host.ID: TransportError] = [:],
        hostsAwaitingSnapshot: Set<Host.ID> = [],
        hostSyncErrors: [Host.ID: String] = [:],
        filteredHostID: Host.ID? = nil,
        searchQuery: String = ""
    ) -> [ConsoleHostSection] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchedAgents = trimmedQuery.isEmpty ? agents : agents.filter { $0.matchesAgentSearch(trimmedQuery) }
        let agentsByHost = Dictionary(grouping: searchedAgents, by: \.hostID)
        var projectedHostIDs: Set<Host.ID> = []

        return hosts.compactMap { host in
            guard filteredHostID == nil || host.id == filteredHostID else { return nil }
            guard projectedHostIDs.insert(host.id).inserted else { return nil }

            let hostAgents = agentsByHost[host.id] ?? []
            let isAwaitingSnapshot = hostsAwaitingSnapshot.contains(host.id)
            let statusPresentation = ConsoleHostStatusPresentation(
                host: host,
                status: hostStatuses[host.id],
                standingFailure: hostStandingFailures[host.id],
                isAwaitingSnapshot: isAwaitingSnapshot,
                syncError: hostSyncErrors[host.id])
            // While searching, an empty section leaves the list only while its
            // Host is nominal (#292). A reconnecting or failed Host reports
            // itself through its status row alone, so that row outranks the
            // empty-section tidy-up and holds the section open; an absent
            // presentation, or one carrying informational text only (paused,
            // connecting, loading Agents), still leaves. Without a query every
            // catalog Host stays visible, including empty ones.
            if !trimmedQuery.isEmpty && hostAgents.isEmpty {
                guard let severity = statusPresentation?.severity, severity != .informational
                else { return nil }
            }
            return ConsoleHostSection(
                hostID: host.id,
                hostDisplayName: host.displayName,
                connectionStatus: hostStatuses[host.id],
                isAwaitingSnapshot: isAwaitingSnapshot,
                statusPresentation: statusPresentation,
                agents: hostAgents,
                isCollapsed: isCollapsed(host.id),
                statusCounts: ConsoleHostAgentStatusCounts(agents: hostAgents))
        }
    }

    /// Convenience contract for the Console UI, mirroring `sections`.
    func sectionsByHostThenWorkspace(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostID: Host.ID? = nil,
        searchQuery: String = ""
    ) -> [ConsoleHostWorkspaceSection] {
        sectionsByHostThenWorkspace(
            hosts: hosts,
            agents: console.agents,
            workspacesByHost: console.workspacesByHost,
            hostStatuses: console.hostStatuses,
            hostStandingFailures: console.hostStandingFailures,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostSyncErrors: console.hostSyncErrors,
            filteredHostID: filteredHostID,
            searchQuery: searchQuery)
    }

    /// Projects the "By Host, By Workspace" presentation: the exact per-Host
    /// sections the "By Host" mode projects, each carrying its Agents grouped
    /// into Workspace buckets. Hosts with no Agents project the same empty
    /// section with no groups, matching the "By Host" behavior exactly.
    func sectionsByHostThenWorkspace(
        hosts: [Host],
        agents: [ConsoleAgent],
        workspacesByHost: [Host.ID: [ConsoleWorkspace]] = [:],
        hostStatuses: [Host.ID: EventsSessionStatus] = [:],
        hostStandingFailures: [Host.ID: TransportError] = [:],
        hostsAwaitingSnapshot: Set<Host.ID> = [],
        hostSyncErrors: [Host.ID: String] = [:],
        filteredHostID: Host.ID? = nil,
        searchQuery: String = ""
    ) -> [ConsoleHostWorkspaceSection] {
        sections(
            hosts: hosts,
            agents: agents,
            hostStatuses: hostStatuses,
            hostStandingFailures: hostStandingFailures,
            hostsAwaitingSnapshot: hostsAwaitingSnapshot,
            hostSyncErrors: hostSyncErrors,
            filteredHostID: filteredHostID,
            searchQuery: searchQuery)
        .map { section in
            var groups = Self.workspaceGroups(
                for: section.agents,
                workspaces: workspacesByHost[section.hostID] ?? [])
            for index in groups.indices {
                groups[index].isCollapsed = !isExpanded(
                    section.hostID, workspaceLabel: groups[index].label)
                for worktreeIndex in groups[index].worktrees.indices {
                    groups[index].worktrees[worktreeIndex].isCollapsed = !isExpanded(
                        section.hostID,
                        workspaceLabel: groups[index].worktrees[worktreeIndex].label)
                }
            }
            return ConsoleHostWorkspaceSection(host: section, workspaceGroups: groups)
        }
    }

    /// Groups one Host's Agents by workspace label, nesting the worktree
    /// workspaces of a repository under that repo's main-checkout workspace
    /// (herdr's sidebar grouping: a linked worktree is a child of the repo,
    /// not a sibling workspace). Buckets follow the Host's known workspace
    /// order; a label the snapshot no longer reports keeps first-appearance
    /// order among the Agents, and Agents with no workspace label fall under
    /// "Unassigned" last. Within a bucket the incoming (already-sorted) Agent
    /// order is preserved untouched.
    static func workspaceGroups(
        for agents: [ConsoleAgent],
        workspaces: [ConsoleWorkspace]
    ) -> [ConsoleWorkspaceGroup] {
        var agentsByLabel: [String: [ConsoleAgent]] = [:]
        var labelOrder: [String] = []
        var unassigned: [ConsoleAgent] = []
        for agent in agents {
            guard let label = agent.workspaceLabel, !label.isEmpty else {
                unassigned.append(agent)
                continue
            }
            if agentsByLabel[label] == nil {
                labelOrder.append(label)
            }
            agentsByLabel[label, default: []].append(agent)
        }

        // herdr nests a repository's linked-worktree workspaces under the
        // repo's main-checkout workspace (the one reporting
        // `is_linked_worktree == false`), like its sidebar tree. A parent
        // with neither Agents nor agented worktree workspaces stays hidden,
        // and a worktree whose repo has no main-checkout workspace on the
        // Host stays a top-level group.
        var mainWorkspaceByRepo: [String: ConsoleWorkspace] = [:]
        for workspace in workspaces {
            guard let checkout = workspace.checkout, !checkout.isLinkedWorktree else { continue }
            mainWorkspaceByRepo[checkout.repoKey] = workspace
        }
        let agentedWorktreeRepos: Set<String> = Set(
            workspaces.compactMap { workspace in
                guard let checkout = workspace.checkout, checkout.isLinkedWorktree,
                    agentsByLabel[workspace.label] != nil
                else { return nil }
                return checkout.repoKey
            })

        var groups: [ConsoleWorkspaceGroup] = []
        var parentIndexesByLabel: [String: Int] = [:]
        for workspace in workspaces {
            guard let checkout = workspace.checkout, !checkout.isLinkedWorktree else { continue }
            let hasAgents = !(agentsByLabel[workspace.label] ?? []).isEmpty
            guard hasAgents || agentedWorktreeRepos.contains(checkout.repoKey) else { continue }
            parentIndexesByLabel[workspace.label] = groups.count
            groups.append(
                ConsoleWorkspaceGroup(
                    label: workspace.label, agents: agentsByLabel[workspace.label] ?? []))
        }

        var projectedLabels = Set<String>(parentIndexesByLabel.keys)
        for workspace in workspaces {
            guard let agents = agentsByLabel[workspace.label], !agents.isEmpty else { continue }
            if let checkout = workspace.checkout, checkout.isLinkedWorktree,
                let main = mainWorkspaceByRepo[checkout.repoKey],
                let parentIndex = parentIndexesByLabel[main.label]
            {
                groups[parentIndex].worktrees.append(
                    ConsoleWorkspaceGroup(label: workspace.label, agents: agents))
            } else if parentIndexesByLabel[workspace.label] == nil {
                groups.append(ConsoleWorkspaceGroup(label: workspace.label, agents: agents))
            }
            projectedLabels.insert(workspace.label)
        }
        for label in labelOrder where !projectedLabels.contains(label) {
            groups.append(ConsoleWorkspaceGroup(label: label, agents: agentsByLabel[label] ?? []))
        }
        if !unassigned.isEmpty {
            groups.append(
                ConsoleWorkspaceGroup(label: ConsoleWorkspaceGroup.unassignedLabel, agents: unassigned))
        }
        return groups
    }

    private func persistCollapsedHostIDs() {
        defaults.set(
            collapsedHostIDs.map(\.uuidString).sorted(),
            forKey: Self.collapsedHostsDefaultsKey)
    }
}
