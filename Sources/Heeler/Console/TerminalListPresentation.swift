import Foundation
import Observation

/// The Console's bottom tabs (#316). Hosts is Host management, the screen
/// the toolbar's Hosts button used to present, and Settings the sheet its
/// gear used to. Agents and Terminals each search their own list.
enum ConsoleTab: String, CaseIterable, Identifiable, Sendable {
    case agents
    case terminals
    case usage
    case hosts
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .agents: String(localized: "Agents")
        case .terminals: String(localized: "Terminals")
        case .usage: String(localized: "Usage")
        case .hosts: String(localized: "Hosts")
        case .settings: String(localized: "Settings")
        }
    }

    /// Agents and Terminals are the lists the Console reopens on; Usage,
    /// Hosts and Settings sit on top of the remembered one.
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
        case .byWorkspace: String(localized: "By Workspace")
        case .byHost: String(localized: "By Host")
        }
    }

    /// Beside the title in the picker, and alone on the toolbar button so
    /// it shows the current choice.
    var systemImage: String {
        switch self {
        case .byWorkspace: "rectangle.3.group"
        case .byHost: "list.bullet.indent"
        }
    }
}

/// One Workspace card: its ordinary shell panes, in tab order, then New
/// Terminal where its Host starts terminals. Agent panes stay on the Agents
/// tab, so a Workspace running only Agents holds New Terminal alone, and on a
/// Host that starts none it would hold nothing and is not listed.
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

    /// What VoiceOver hears for the card's header.
    var headerAccessibilityValue: String {
        let state = isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
        return [TerminalCount.text(terminals.count), state].joined(separator: ", ")
    }
}

/// Which ends of a By Host Workspace card a row closes. That plain list draws
/// no cards, so each row rounds its own slice: the first row the top, the
/// last the bottom. New Terminal ends a card where its Host starts terminals;
/// otherwise the last shell does, as the grouped By Workspace list closes it.
struct TerminalCardEdges: Equatable {
    let isFirst: Bool
    let isLast: Bool

    /// The shell at `index` of a card listing `count` shells.
    static func shell(at index: Int, of count: Int, endsInNewTerminal: Bool) -> Self {
        Self(isFirst: index == 0, isLast: !endsInNewTerminal && index == count - 1)
    }

    /// New Terminal, after the card's `shellCount` shells.
    static func newTerminal(afterShells shellCount: Int) -> Self {
        Self(isFirst: shellCount == 0, isLast: true)
    }
}

/// A count of shells as the Terminals list words it.
enum TerminalCount {
    static func text(_ count: Int) -> String {
        count == 1 ? String(localized: "1 terminal") : String(localized: "\(count) terminals")
    }
}

/// One Host section of the By Host presentation: a Host as the Hosts tab
/// shows it, holding the Workspaces of every Server it has on (ADR 0047).
struct TerminalHostGroup: Identifiable, Equatable {
    /// The first Server's record, which stands for the Host where one id is
    /// asked for: the Hosts tab opens the Host from any of them.
    let hostID: Host.ID
    /// The Host's name alone, whichever of its Servers are listed.
    let hostName: String
    /// The Servers listed, in catalog order, `hostID`'s first.
    let servers: [ConsoleHostServerState]
    let readiness: HostReadiness
    /// A failing Host opens its connection sheet instead of expanding. Only
    /// a Host with one Server on: one with more expands, and each Server's
    /// problem opens its own sheet from its row.
    let opensConnectionDetail: Bool
    /// Each Server's Workspaces in its own order, Server after Server.
    let workspaces: [TerminalWorkspaceGroup]
    let isCollapsed: Bool

    var id: Host.ID { hostID }
    var hostIDs: [Host.ID] { servers.map(\.hostID) }
    /// The Servers' conditions, in their order.
    var issues: [ConsoleHostStatusPresentation] { servers.compactMap(\.issue) }
    var terminalCount: Int { workspaces.reduce(0) { $0 + $1.terminals.count } }
}

/// What one shell row shows. An idle shell's terminal title is its
/// directory, so shells side by side in one directory would read alike: a
/// Tab the user named leads the row, and a card holding several shells
/// names each row's Tab beside its path. The Workspace drawer names shells
/// by the same rules, so one shell reads alike one tap apart.
struct TerminalRowPresentation: Equatable {
    let title: String
    let subtitle: String
    /// The shell's Tab, for a surface that shows it beside the title; nil
    /// when the title already is the Tab's name.
    let tab: String?

    init(terminal: ConsoleTerminal, showsWorkspace: Bool = false, showsTab: Bool = false) {
        let namedTitle = terminal.paneLabel.flatMap { $0.isEmpty ? nil : $0 }
        title = namedTitle ?? terminal.customTabLabel ?? terminal.displayTitle
        let titleIsTab = namedTitle == nil && terminal.customTabLabel != nil
        tab = titleIsTab ? nil : terminal.displayTabTitle
        var parts: [String] = []
        if showsWorkspace { parts.append(terminal.workspaceLabel ?? terminal.hostName) }
        if showsTab, let tab { parts.append(tab) }
        if terminal.isRestarting { parts.append(String(localized: "Restarting")) }
        parts.append(terminal.displayCwd.isEmpty ? String(localized: "Path unavailable") : terminal.displayCwd)
        subtitle = parts.joined(separator: " · ")
    }
}

/// How far closing one shell, or an Agent's pane, reaches, widest first.
enum TerminalCloseScope: Equatable {
    case workspace
    case tab
    case pane

    /// The close action: a menu item or the confirmation's button.
    var actionTitle: String {
        switch self {
        case .workspace: String(localized: "Close Workspace")
        case .tab: String(localized: "Close Tab")
        case .pane: String(localized: "Close Pane")
        }
    }

    /// The confirmation's title.
    var confirmationTitle: String {
        switch self {
        case .workspace: String(localized: "Close Workspace?")
        case .tab: String(localized: "Close Tab?")
        case .pane: String(localized: "Close Pane?")
        }
    }

    /// Names the Tab and Workspace being closed, since rows in one directory
    /// can share a title.
    func message(for terminal: ConsoleTerminal) -> String {
        let tab = terminal.displayTabTitle
        guard let workspace = terminal.workspaceLabel else {
            switch self {
            case .workspace:
                return String(localized: "Are you sure you want to also close this workspace? It is the workspace's last tab.")
            case .tab:
                return String(localized: "Closes \(tab) in this Workspace.")
            case .pane:
                return String(localized: "Closes this pane of \(tab) in this Workspace. The tab's other panes stay open.")
            }
        }
        switch self {
        case .workspace:
            return String(localized: "Are you sure you want to also close workspace \(workspace)? It is the workspace's last tab.")
        case .tab:
            return String(localized: "Closes \(tab) in \(workspace).")
        case .pane:
            return String(localized: "Closes this pane of \(tab) in \(workspace). The tab's other panes stay open.")
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

    /// Every Workspace card, in the Hosts tab's order of Hosts with a Host's
    /// Servers together in catalog order, then each Server's Workspace
    /// order. A Workspace is one Server's, so two of the same name on two
    /// Servers of a Host are two cards, both under the Host's name. A query
    /// keeps matching shells only and drops cards left empty; without one,
    /// an empty Workspace stays listed where its card offers New Terminal.
    func workspaces(filteredHostIDs: Set<Host.ID> = [], searchQuery: String = "")
        -> [TerminalWorkspaceGroup]
    {
        visibleGroups(filteredHostIDs).flatMap(\.servers)
            .flatMap { workspaces(on: $0, searchQuery: searchQuery) }
    }

    /// One group per Host, by its name, in the Hosts tab's order. A query
    /// drops Hosts without a match, whatever their state, as the Agents list
    /// does, and opens every Host so no match hides behind a collapsed one.
    /// Without one, a Host with no Workspace to list stays while it has
    /// something to say or could start a terminal, and otherwise would be a
    /// bare header.
    func hostGroups(filteredHostIDs: Set<Host.ID> = [], searchQuery: String = "")
        -> [TerminalHostGroup]
    {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return visibleGroups(filteredHostIDs).compactMap { group in
            guard let first = group.servers.first else { return nil }
            let cards = group.servers.flatMap { workspaces(on: $0, searchQuery: searchQuery) }
            let servers = group.servers.map { host in
                ConsoleHostServerState(
                    hostID: host.id, connectionStatus: hostStatuses[host.id],
                    isAwaitingSnapshot: hostsAwaitingSnapshot.contains(host.id), issue: issue(for: host))
            }
            if cards.isEmpty
                && (isSearching || !group.keepsEmptySection(servers, listsTerminals: true))
            {
                return nil
            }
            return TerminalHostGroup(
                hostID: first.id,
                hostName: group.name,
                servers: servers,
                readiness: ConsoleHostSectionHeaderPresentation.readiness(
                    servers: servers, isEmpty: cards.isEmpty, inventoryNoun: "Terminals"),
                opensConnectionDetail: group.servers.count == 1
                    && HostConnectionDetailPresentation(
                        host: first, status: hostStatuses[first.id],
                        standingFailure: hostStandingFailures[first.id]) != nil,
                workspaces: cards,
                // Folded while any of its Servers is, as the Agents list reads it.
                isCollapsed: !isSearching && group.servers.contains { collapsedHosts.contains($0.id) })
        }
    }

    /// Host problems, one per Server, in the order of the cards, for the By
    /// Workspace presentation, which has no Host headers to carry them.
    func issues(filteredHostIDs: Set<Host.ID> = []) -> [ConsoleHostStatusPresentation] {
        visibleGroups(filteredHostIDs).flatMap(\.servers).compactMap(issue(for:))
    }

    private func visibleGroups(_ filteredHostIDs: Set<Host.ID>) -> [ConsoleHostSectionGroup] {
        ConsoleHostSectionGroup.grouping(
            hosts.filter { filteredHostIDs.isEmpty || filteredHostIDs.contains($0.id) })
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
        // A card with no shell holds New Terminal alone, so where the Host
        // never starts terminals it has nothing to show or offer, as a Rex
        // session whose terminals all run Agents (ADR 0054). Read from the
        // Host's kind rather than its connection, so a herdr-core card keeps
        // its place while the core is still being located.
        let offersNewTerminal = host.capabilities.startsTerminals
        return ordered.compactMap { id, workspace in
            let all = shellsByWorkspace[id] ?? []
            if all.isEmpty && !offersNewTerminal { return nil }
            let matching = needle.isEmpty ? all : all.filter { $0.matchesSearch(needle) }
            if !needle.isEmpty && matching.isEmpty { return nil }
            let label = (workspace?.label ?? all.first?.workspaceLabel)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let groupID = TerminalWorkspaceGroup.ID(hostID: host.id, workspaceID: id)
            return TerminalWorkspaceGroup(
                hostID: host.id,
                hostName: host.hostName,
                workspaceID: id,
                title: label.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Workspace \(id)"),
                terminals: matching,
                directory: directory(of: workspace, host: host, workspaceID: id, shells: all),
                // A search result is never hidden behind a collapsed card.
                isCollapsed: needle.isEmpty && collapsedWorkspaces.contains(groupID))
        }
    }

    private func directory(
        of workspace: ConsoleWorkspace?, host: Host, workspaceID: String,
        shells: [ConsoleTerminal]
    ) -> String? {
        let agentDirectories = agents
            .filter { $0.hostID == host.id && $0.agent.workspaceID == workspaceID }
            .map(\.agent.cwd)
        let candidates: [String?] =
            [workspace?.checkoutPath] + shells.map(\.pane.cwd) + agentDirectories.map { $0 }
        return candidates.lazy.compactMap { $0 }.first(where: host.reportedDirectoryStartsTerminals)
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

    /// Unfolds the Host whose Servers have the records `hostIDs`, folded while
    /// any of them is, by dropping them all, or folds it by holding them all,
    /// as the Agents list does.
    func toggleCollapsed(_ hostIDs: [Host.ID]) {
        if hostIDs.contains(where: collapsedHosts.contains) {
            collapsedHosts.subtract(hostIDs)
        } else {
            collapsedHosts.formUnion(hostIDs)
        }
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
