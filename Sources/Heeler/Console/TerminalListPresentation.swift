import Foundation
import Observation

/// The Console's bottom tabs (#316). Hosts is Host management, the screen
/// the toolbar's Hosts button used to present, and Settings the sheet its
/// gear used to. Agents and Terminals each search their own list.
enum ConsoleTab: String, CaseIterable, Identifiable, Sendable {
    case agents
    case terminals
    case hosts
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .terminals: "Terminals"
        case .hosts: "Hosts"
        case .settings: "Settings"
        }
    }

    /// Agents and Terminals are the lists the Console reopens on; Hosts and
    /// Settings sit on top of the remembered one.
    var isList: Bool { self == .agents || self == .terminals }
}

/// The Terminals tab's two groupings. By Workspace flattens every Host's
/// Workspaces into one sequence of cards; By Host nests those cards under
/// collapsible Host sections, as the Agents tab's By Host does.
enum TerminalListPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case byWorkspace
    case byHost

    var id: Self { self }

    var title: String {
        switch self {
        case .byWorkspace: "By Workspace"
        case .byHost: "By Host"
        }
    }

    var systemImage: String {
        switch self {
        case .byWorkspace: "rectangle.3.group"
        case .byHost: "server.rack"
        }
    }
}

/// One Workspace card: its ordinary shell panes, in tab order, then New
/// Terminal. Agent panes stay on the Agents tab, so a Workspace running only
/// Agents holds New Terminal alone.
struct TerminalWorkspaceGroup: Identifiable, Equatable {
    /// Workspace ids are opaque and scoped to their Host.
    struct ID: Hashable, Sendable {
        let hostID: Host.ID
        let workspaceID: String
    }

    let hostID: Host.ID
    let hostName: String
    let workspaceID: String
    let title: String
    let terminals: [ConsoleTerminal]
    /// Where a new shell tab opens from the card's New Terminal: the
    /// Workspace's checkout, else a shell's launch directory, else an
    /// Agent's. Nil when nothing in the Workspace reports an absolute path.
    let directory: String?
    let isCollapsed: Bool

    var id: ID { ID(hostID: hostID, workspaceID: workspaceID) }
}

/// One Host section of the By Host presentation.
struct TerminalHostGroup: Identifiable, Equatable {
    let hostID: Host.ID
    let hostName: String
    let readiness: HostReadiness
    let issue: ConsoleHostStatusPresentation?
    /// A failing Host opens its connection sheet instead of expanding.
    let opensConnectionDetail: Bool
    let workspaces: [TerminalWorkspaceGroup]
    let isCollapsed: Bool

    var id: Host.ID { hostID }
    var terminalCount: Int { workspaces.reduce(0) { $0 + $1.terminals.count } }
}

/// What one shell row shows. An idle shell's terminal title is its
/// directory, so shells side by side in one directory would read alike: a
/// Tab the user named leads the row, and a card holding several shells
/// names each row's Tab beside its path.
struct TerminalRowPresentation: Equatable {
    let title: String
    let subtitle: String

    init(terminal: ConsoleTerminal, showsWorkspace: Bool = false, showsTab: Bool = false) {
        let namedTitle = terminal.paneLabel.flatMap { $0.isEmpty ? nil : $0 }
        title = namedTitle ?? terminal.customTabLabel ?? terminal.displayTitle
        let titleIsTab = namedTitle == nil && terminal.customTabLabel != nil
        var parts: [String] = []
        if showsWorkspace { parts.append(terminal.workspaceLabel ?? terminal.hostName) }
        if showsTab && !titleIsTab { parts.append(terminal.displayTabTitle) }
        parts.append(terminal.displayCwd.isEmpty ? "Path unavailable" : terminal.displayCwd)
        subtitle = parts.joined(separator: " · ")
    }
}

/// How far closing one shell reaches, widest first.
enum TerminalCloseScope: String, Equatable {
    case workspace = "Workspace"
    case tab = "Tab"
    case pane = "Pane"

    /// Names the Tab and Workspace being closed, since rows in one directory
    /// can share a title.
    func message(for terminal: ConsoleTerminal) -> String {
        let workspace = terminal.workspaceLabel ?? "this Workspace"
        switch self {
        case .workspace:
            return "Are you sure you want to also close workspace \(workspace)? It is the workspace's last tab."
        case .tab:
            return "Closes \(terminal.displayTabTitle) in \(workspace)."
        case .pane:
            return "Closes this pane of \(terminal.displayTabTitle) in \(workspace). The tab's other panes stay open."
        }
    }
}

/// Projects the Console's terminal inventory into Workspace cards. Pure, so
/// ordering, grouping, and search stay testable without hosting a List.
struct TerminalListProjection {
    let hosts: [Host]
    let terminals: [ConsoleTerminal]
    let workspacesByHost: [Host.ID: [ConsoleWorkspace]]
    let agents: [ConsoleAgent]
    let hostStatuses: [Host.ID: EventsSessionStatus]
    let hostStandingFailures: [Host.ID: TransportError]
    let hostsAwaitingSnapshot: Set<Host.ID>
    let hostSyncErrors: [Host.ID: String]
    var collapsedWorkspaces: Set<TerminalWorkspaceGroup.ID> = []
    var collapsedHosts: Set<Host.ID> = []

    /// Every Workspace card, Host catalog order first, then herdr's
    /// Workspace order. A query keeps matching shells only and drops cards
    /// left empty; without one, an empty Workspace stays listed.
    func workspaces(filteredHostID: Host.ID? = nil, searchQuery: String = "")
        -> [TerminalWorkspaceGroup]
    {
        visibleHosts(filteredHostID).flatMap { workspaces(on: $0, searchQuery: searchQuery) }
    }

    /// A query drops Hosts without a match unless they have a problem to
    /// report, as the Agents list does (#292), and opens every Host so no
    /// match hides behind a collapsed one.
    func hostGroups(filteredHostID: Host.ID? = nil, searchQuery: String = "")
        -> [TerminalHostGroup]
    {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return visibleHosts(filteredHostID).compactMap { host in
            let workspaces = workspaces(on: host, searchQuery: searchQuery)
            let issue = issue(for: host)
            if isSearching && workspaces.isEmpty {
                guard let severity = issue?.severity, severity != .informational else { return nil }
            }
            return TerminalHostGroup(
                hostID: host.id,
                hostName: host.displayName,
                readiness: readiness(for: host, isEmpty: workspaces.isEmpty),
                issue: issue,
                opensConnectionDetail: HostConnectionDetailPresentation(
                    host: host, status: hostStatuses[host.id],
                    standingFailure: hostStandingFailures[host.id]) != nil,
                workspaces: workspaces,
                isCollapsed: !isSearching && collapsedHosts.contains(host.id))
        }
    }

    /// Host problems in catalog order, for the By Workspace presentation,
    /// which has no Host headers to carry them.
    func issues(filteredHostID: Host.ID? = nil) -> [ConsoleHostStatusPresentation] {
        visibleHosts(filteredHostID).compactMap(issue(for:))
    }

    private func visibleHosts(_ filteredHostID: Host.ID?) -> [Host] {
        var seen: Set<Host.ID> = []
        return hosts.filter {
            (filteredHostID == nil || $0.id == filteredHostID) && seen.insert($0.id).inserted
        }
    }

    private func workspaces(on host: Host, searchQuery: String) -> [TerminalWorkspaceGroup] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let shells = terminals
            .filter { $0.hostID == host.id && !$0.isAgent }
            .sorted {
                ($0.workspaceOrder, $0.tabPosition ?? Int.max, $0.snapshotOrder)
                    < ($1.workspaceOrder, $1.tabPosition ?? Int.max, $1.snapshotOrder)
            }
        let shellsByWorkspace = Dictionary(grouping: shells, by: \.workspaceID)
        let known = (workspacesByHost[host.id] ?? []).sorted { $0.order < $1.order }
        // A pane can outrun its Workspace between snapshots; keep it listed
        // under its own id rather than dropping a live shell.
        var ordered: [(id: String, workspace: ConsoleWorkspace?)] = known.map { ($0.id, $0) }
        for shell in shells where !ordered.contains(where: { $0.id == shell.workspaceID }) {
            ordered.append((shell.workspaceID, nil))
        }
        return ordered.compactMap { id, workspace in
            let all = shellsByWorkspace[id] ?? []
            let matching = needle.isEmpty ? all : all.filter { $0.matchesSearch(needle) }
            if !needle.isEmpty && matching.isEmpty { return nil }
            let label = (workspace?.label ?? all.first?.workspaceLabel)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let groupID = TerminalWorkspaceGroup.ID(hostID: host.id, workspaceID: id)
            return TerminalWorkspaceGroup(
                hostID: host.id,
                hostName: host.displayName,
                workspaceID: id,
                title: label.flatMap { $0.isEmpty ? nil : $0 } ?? "Workspace \(id)",
                terminals: matching,
                directory: directory(of: workspace, hostID: host.id, workspaceID: id, shells: all),
                // A search result is never hidden behind a collapsed card.
                isCollapsed: needle.isEmpty && collapsedWorkspaces.contains(groupID))
        }
    }

    private func directory(
        of workspace: ConsoleWorkspace?, hostID: Host.ID, workspaceID: String,
        shells: [ConsoleTerminal]
    ) -> String? {
        let agentDirectories = agents
            .filter { $0.hostID == hostID && $0.agent.workspaceID == workspaceID }
            .map(\.agent.cwd)
        let candidates: [String?] =
            [workspace?.checkoutPath] + shells.map(\.pane.cwd) + agentDirectories.map { $0 }
        return candidates.lazy.compactMap { $0 }.first { $0.hasPrefix("/") }
    }

    private func issue(for host: Host) -> ConsoleHostStatusPresentation? {
        ConsoleHostStatusPresentation(
            host: host,
            status: hostStatuses[host.id],
            standingFailure: hostStandingFailures[host.id],
            isAwaitingSnapshot: hostsAwaitingSnapshot.contains(host.id),
            syncError: hostSyncErrors[host.id],
            inventoryNoun: "Terminals")
    }

    private func readiness(for host: Host, isEmpty: Bool) -> HostReadiness {
        ConsoleHostSectionHeaderPresentation.readiness(
            connectionStatus: hostStatuses[host.id],
            isAwaitingSnapshot: hostsAwaitingSnapshot.contains(host.id),
            statusSeverity: issue(for: host)?.severity,
            isEmpty: isEmpty,
            inventoryNoun: "Terminals")
    }
}

extension TerminalListProjection {
    /// Reads the observable Console inputs on each render, as the Agents
    /// sections do, so status and inventory changes re-project directly.
    @MainActor
    init(
        hosts: [Host], console: ConsoleStore,
        collapsedWorkspaces: Set<TerminalWorkspaceGroup.ID> = [],
        collapsedHosts: Set<Host.ID> = []
    ) {
        self.init(
            hosts: hosts,
            terminals: console.terminals,
            workspacesByHost: console.workspacesByHost,
            agents: console.agents,
            hostStatuses: console.hostStatuses,
            hostStandingFailures: console.hostStandingFailures,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostSyncErrors: console.hostSyncErrors,
            collapsedWorkspaces: collapsedWorkspaces,
            collapsedHosts: collapsedHosts)
    }
}

/// Persists the Terminals tab's grouping and collapsed Workspace cards and
/// Host sections. Like the Agents tab's store, collapsed ids outlive a Host
/// disconnecting so a reconnect restores the choice.
@MainActor
@Observable
final class TerminalListPresentationStore {
    private static let modeDefaultsKey = "terminal-list.presentation-mode"
    private static let collapsedWorkspacesDefaultsKey = "terminal-list.collapsed-workspaces"
    private static let collapsedHostsDefaultsKey = "terminal-list.collapsed-hosts"

    private(set) var mode: TerminalListPresentationMode
    private(set) var collapsedWorkspaces: Set<TerminalWorkspaceGroup.ID>
    private(set) var collapsedHosts: Set<Host.ID>
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode =
            defaults.string(forKey: Self.modeDefaultsKey)
            .flatMap(TerminalListPresentationMode.init(rawValue:)) ?? .byWorkspace
        collapsedWorkspaces = Set(
            (defaults.stringArray(forKey: Self.collapsedWorkspacesDefaultsKey) ?? [])
                .compactMap(Self.workspaceID(from:)))
        collapsedHosts = Set(
            (defaults.stringArray(forKey: Self.collapsedHostsDefaultsKey) ?? [])
                .compactMap(UUID.init(uuidString:)))
    }

    func select(_ mode: TerminalListPresentationMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
    }

    func toggleCollapsed(_ id: TerminalWorkspaceGroup.ID) {
        if collapsedWorkspaces.remove(id) == nil { collapsedWorkspaces.insert(id) }
        defaults.set(
            collapsedWorkspaces.map(Self.key(for:)).sorted(),
            forKey: Self.collapsedWorkspacesDefaultsKey)
    }

    func toggleCollapsed(_ hostID: Host.ID) {
        if collapsedHosts.remove(hostID) == nil { collapsedHosts.insert(hostID) }
        defaults.set(
            collapsedHosts.map(\.uuidString).sorted(),
            forKey: Self.collapsedHostsDefaultsKey)
    }

    func projection(hosts: [Host], console: ConsoleStore) -> TerminalListProjection {
        TerminalListProjection(
            hosts: hosts, console: console,
            collapsedWorkspaces: collapsedWorkspaces, collapsedHosts: collapsedHosts)
    }

    /// Host UUID first: it never contains the separator, so everything after
    /// the first one is the opaque Workspace id, whatever it contains.
    private static func key(for id: TerminalWorkspaceGroup.ID) -> String {
        "\(id.hostID.uuidString)/\(id.workspaceID)"
    }

    private static func workspaceID(from key: String) -> TerminalWorkspaceGroup.ID? {
        guard let separator = key.firstIndex(of: "/"),
            let hostID = UUID(uuidString: String(key[..<separator]))
        else { return nil }
        return .init(hostID: hostID, workspaceID: String(key[key.index(after: separator)...]))
    }
}
