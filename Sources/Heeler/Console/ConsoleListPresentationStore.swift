import Foundation
import Observation

/// The Console Agent-list presentations. Flat remains the default so
/// introducing grouped-list support does not change the existing surface
/// until the UI explicitly selects it.
enum ConsoleListPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case flat
    case grouped
    case byWorkspace

    var id: Self { self }

    /// Toolbar / picker label for the presentation switcher.
    var title: String {
        switch self {
        case .flat: String(localized: "All Agents")
        case .grouped: String(localized: "By Host")
        case .byWorkspace: String(localized: "By Workspace")
        }
    }

    /// Beside the title in the picker, and alone on the toolbar button so
    /// it shows the current choice.
    var systemImage: String {
        switch self {
        case .flat: "list.bullet"
        case .grouped: "list.bullet.indent"
        case .byWorkspace: "rectangle.3.group"
        }
    }
}

/// Workspace identity includes the Host: pane and Workspace ids are local
/// to one herdr session, and labels can be shared or renamed.
struct ConsoleWorkspaceSection: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Codable, Sendable {
        let hostID: Host.ID
        let workspaceID: String
    }

    let id: ID
    let title: String
    let hostName: String
    let agents: [ConsoleAgent]
    let isCollapsed: Bool
    /// The main-checkout section this linked-worktree section nests under;
    /// nil for a top-level section.
    var parentID: ID?
    /// The git checkout the Workspace reported, if any.
    var checkout: RepositoryCheckout?
    /// The checkout's path as rows print directories, with `~` for home.
    var pathText: String?

    var isNested: Bool { parentID != nil }
    var statusCounts: ConsoleHostAgentStatusCounts { .init(agents: agents) }
    var accessibilityValue: String {
        let count = agents.count == 1 ? String(localized: "1 Agent") : String(localized: "\(agents.count) Agents")
        return [count, isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded"),
                ConsoleHostSectionHeaderPresentation.statusText(items: statusCounts.items)]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// One By Workspace card: a top-level Workspace and the linked worktrees
/// nested under it, which make it its repository's card. A card titles each
/// checkout once, so its rows drop what the card already says.
struct ConsoleWorkspaceCard: Identifiable, Equatable, Sendable {
    enum Row: Equatable, Sendable {
        /// A repository's header, or the header of a Workspace with several
        /// Agents.
        case header
        /// A collapsed card's summary under its header: a row of its own,
        /// so a fold adds or removes rows and never resizes the header.
        /// With nothing to summarize the header ends the card instead, as
        /// an empty row would be too short for the card's corners.
        case summary
        /// A checkout with several Agents inside a repository's card.
        case checkout(ConsoleWorkspaceSection)
        /// `standsAlone`: the only Agent of its checkout or Workspace, so
        /// its row carries that checkout's title.
        case agent(ConsoleAgent, of: ConsoleWorkspaceSection, standsAlone: Bool)
    }

    /// The rule a row draws above itself. Agents of one checkout have none
    /// between them, as in the other presentations.
    enum Rule: Equatable, Sendable {
        case none
        /// Between checkouts: across the card.
        case full
    }

    struct Placed: Identifiable, Equatable, Sendable {
        enum ID: Hashable, Sendable {
            case header(ConsoleWorkspaceSection.ID)
            case summary(ConsoleWorkspaceSection.ID)
            case checkout(ConsoleWorkspaceSection.ID)
            case agent(ConsoleAgent.ID)
        }

        let id: ID
        let row: Row
        let rule: Rule
        let isFirst: Bool
        let isLast: Bool
        /// Right under a card's or checkout's header.
        let followsHeader: Bool
    }

    let primary: ConsoleWorkspaceSection
    let nested: [ConsoleWorkspaceSection]

    var id: ConsoleWorkspaceSection.ID { primary.id }
    var isRepository: Bool { !nested.isEmpty }
    var isCollapsed: Bool { primary.isCollapsed }
    /// The checkouts that have Agents to list, the main checkout first. A
    /// search can keep a main checkout none of whose Agents match.
    var checkouts: [ConsoleWorkspaceSection] { ([primary] + nested).filter { !$0.agents.isEmpty } }
    var agents: [ConsoleAgent] { primary.agents + nested.flatMap(\.agents) }
    /// Whether a collapsed card has anything to say under its header: who
    /// needs the user and, for a repository, its checkouts.
    var hasSummary: Bool {
        !ConsoleHostAgentStatusCounts(agents: agents).items.isEmpty || (isRepository && !checkouts.isEmpty)
    }

    var rows: [Placed] {
        var items: [(Row, Rule)] = []
        func list(_ section: ConsoleWorkspaceSection) {
            for agent in section.agents {
                items.append((.agent(agent, of: section, standsAlone: false), .none))
            }
        }
        if isRepository {
            items.append((.header, .none))
            if isCollapsed {
                if hasSummary { items.append((.summary, .none)) }
            } else {
                for (index, checkout) in checkouts.enumerated() {
                    let rule: Rule = index == 0 ? .none : .full
                    if checkout.agents.count == 1 {
                        items.append((.agent(checkout.agents[0], of: checkout, standsAlone: true), rule))
                    } else {
                        items.append((.checkout(checkout), rule))
                        // The main checkout folds with its card.
                        if !(checkout.isNested && checkout.isCollapsed) { list(checkout) }
                    }
                }
            }
        } else if primary.agents.count == 1 {
            items.append((.agent(primary.agents[0], of: primary, standsAlone: true), .none))
        } else {
            items.append((.header, .none))
            if !isCollapsed {
                list(primary)
            } else if hasSummary {
                items.append((.summary, .none))
            }
        }
        return items.enumerated().map { index, item in
            let id: Placed.ID =
                switch item.0 {
                case .header: .header(primary.id)
                case .summary: .summary(primary.id)
                case .checkout(let section): .checkout(section.id)
                case .agent(let agent, _, _): .agent(agent.id)
                }
            let followsHeader: Bool =
                switch index > 0 ? items[index - 1].0 : nil {
                case .header?, .checkout?: true
                default: false
                }
            return Placed(
                id: id, row: item.0, rule: item.1,
                isFirst: index == 0, isLast: index == items.count - 1, followsHeader: followsHeader)
        }
    }

    var visibleAgentIDs: [ConsoleAgent.ID] {
        rows.compactMap { if case .agent(let agent, _, _) = $0.row { agent.id } else { nil } }
    }

    var accessibilityValue: String {
        let count = agents.count == 1 ? String(localized: "1 Agent") : String(localized: "\(agents.count) Agents")
        return [count, isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded"),
                ConsoleHostSectionHeaderPresentation.statusText(
                    items: ConsoleHostAgentStatusCounts(agents: agents).items)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Sections in `workspaceSections` order: each top-level section, then
    /// the sections nested under it.
    static func cards(_ sections: [ConsoleWorkspaceSection]) -> [Self] {
        var cards: [Self] = []
        for section in sections {
            if let parentID = section.parentID,
                let index = cards.lastIndex(where: { $0.id == parentID })
            {
                cards[index] = Self(primary: cards[index].primary, nested: cards[index].nested + [section])
            } else {
                cards.append(Self(primary: section, nested: []))
            }
        }
        return cards
    }

    /// The fields a row in a card leaves to the card: the Workspace, the
    /// Host where a header names it, and a directory or path that is the
    /// checkout at `checkoutPath`, its section's.
    static func hiddenTokens(
        for agent: ConsoleAgent, checkoutPath: String?, showsHost: Bool
    ) -> Set<AgentRowToken> {
        var hidden: Set<AgentRowToken> = [.workspace]
        if !showsHost { hidden.insert(.host) }
        if let checkoutPath, agent.agent.cwd == checkoutPath {
            hidden.insert(.directory)
            hidden.insert(.path)
        }
        return hidden
    }
}

/// How a repository's card titles a checkout: the main checkout by its
/// branch, a worktree by its Workspace with the branch after it when that
/// says something more.
struct ConsoleCheckoutTitle: Equatable, Sendable {
    /// What the title names, which VoiceOver says where the icon shows it.
    enum Role: Equatable, Sendable {
        /// A Workspace on its own card.
        case workspace
        case mainCheckout
        case worktree
    }

    let title: String
    let detail: String?
    /// The main checkout's branch is not read yet: its Workspace stands in,
    /// quieter.
    let isPending: Bool
    let role: Role

    static let detachedText = "detached"

    init(title: String, detail: String? = nil, isPending: Bool = false, role: Role = .workspace) {
        self.title = title
        self.detail = detail
        self.isPending = isPending
        self.role = role
    }

    /// `branch` is nil until a read of the checkout has named it.
    init(label: String, isMainCheckout: Bool, branch: CheckoutHead.Branch?) {
        let role: Role = isMainCheckout ? .mainCheckout : .worktree
        switch (isMainCheckout, branch) {
        case (true, .named(let name)?): self.init(title: name, role: role)
        case (true, nil): self.init(title: label, isPending: true, role: role)
        case (_, .detached?): self.init(title: label, detail: Self.detachedText, role: role)
        case (false, .named(let name)?):
            self.init(title: label, detail: name == label ? nil : name, role: role)
        case (false, nil): self.init(title: label, role: role)
        }
    }

    /// The branch an Agent's Changes read found, when that read is of the
    /// checkout at `path`: an Agent can work in another checkout than its
    /// Workspace's.
    static func branch(at path: String?, in reads: [CheckoutChanges]) -> CheckoutHead.Branch? {
        guard let path else { return nil }
        return reads.first { String(decoding: $0.checkout.topLevel, as: UTF8.self) == path }?.head.branch
    }

    /// Each shape is one whole phrase; git's "detached" stays git's word.
    var accessibilityLabel: String {
        switch role {
        case .workspace:
            return title
        case .mainCheckout:
            if detail != nil { return String(localized: "\(title), detached") }
            return isPending ? title : String(localized: "Branch \(title)")
        case .worktree:
            guard let detail else { return String(localized: "\(title), worktree") }
            if detail == Self.detachedText { return String(localized: "\(title), worktree, detached") }
            return String(localized: "\(title), worktree, branch \(detail)")
        }
    }
}

/// One Host section projected from the Host catalog and the Console's
/// already-sorted Agent sequence: a Host as the Hosts tab shows it, holding
/// the Agents of every Server it has on (ADR 0047). The section carries the
/// inputs a header needs to present connection and Agent Inventory
/// readiness honestly.
struct ConsoleHostSection: Identifiable, Equatable {
    /// The first Server's record, which stands for the Host where one id
    /// is asked for: the Hosts tab opens the Host from any of them.
    let hostID: Host.ID
    /// The Host's name alone, whichever of its Servers are listed.
    let hostName: String
    /// The Servers listed, in catalog order, `hostID`'s first.
    let servers: [ConsoleHostServerState]
    /// The Host's Agents across its Servers, in the Console's order.
    let agents: [ConsoleAgent]
    let isCollapsed: Bool
    let statusCounts: ConsoleHostAgentStatusCounts

    var hostIDs: [Host.ID] { servers.map(\.hostID) }
    var id: Host.ID { hostID }
    /// The Servers' conditions, in their order. Under a header that names
    /// only the Host, a row of a Host with several Servers says which.
    var issues: [ConsoleHostStatusPresentation] { servers.compactMap(\.issue) }
}

/// Active and attention statuses shown in a collapsed Host section. Core
/// errors retain their own wording rather than being counted as Blocked.
struct ConsoleHostAgentStatusCounts: Equatable {
    let blocked: Int
    let error: Int
    let working: Int
    let done: Int

    init(blocked: Int = 0, error: Int = 0, working: Int = 0, done: Int = 0) {
        self.blocked = blocked
        self.error = error
        self.working = working
        self.done = done
    }

    init(agents: [ConsoleAgent]) {
        blocked = agents.count { $0.agent.status == .blocked }
        error = agents.count { $0.agent.status == .error }
        working = agents.count { $0.agent.status == .working }
        done = agents.count { $0.agent.status == .done }
    }

    var items: [ConsoleHostAgentStatusCount] {
        var items: [ConsoleHostAgentStatusCount] = []
        if blocked > 0 { items.append(.init(status: .blocked, count: blocked)) }
        if error > 0 { items.append(.init(status: .error, count: error)) }
        if working > 0 { items.append(.init(status: .working, count: working)) }
        if done > 0 { items.append(.init(status: .done, count: done)) }
        return items
    }
}

/// One choice of the Agents list's status filter. Blocked carries Error:
/// both ask for the user, and the list already sorts them together.
enum ConsoleAgentStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case blocked, working, done, idle

    var id: String { rawValue }

    init?(_ status: AgentStatus) {
        switch status {
        case .blocked, .error: self = .blocked
        case .working: self = .working
        case .done: self = .done
        case .idle: self = .idle
        default: return nil
        }
    }

    /// The choice as the filter lists it, with how many Agents it admits.
    /// The raw value is the saved token, never shown.
    func title(count: Int) -> String {
        switch self {
        case .blocked: String(localized: "Blocked (\(count))")
        case .working: String(localized: "Working (\(count))")
        case .done: String(localized: "Done (\(count))")
        case .idle: String(localized: "Idle (\(count))")
        }
    }
}

extension Set<ConsoleAgentStatusFilter> {
    /// Empty admits everything; an unknown status shows only unfiltered.
    func admits(_ agent: ConsoleAgent) -> Bool {
        isEmpty || ConsoleAgentStatusFilter(agent.agent.status).map(contains) == true
    }
}

struct ConsoleHostAgentStatusCount: Identifiable, Equatable {
    let status: AgentStatus
    let count: Int

    var id: String { status.rawValue }

    /// "2 working", as a count pill says it. The statuses
    /// `ConsoleHostAgentStatusCounts` counts each have a whole phrase, the
    /// same ones VoiceOver hears from the Host header.
    var text: String {
        switch status {
        case .blocked: String(localized: "\(count) blocked")
        case .error: count == 1 ? String(localized: "1 error") : String(localized: "\(count) errors")
        case .working: String(localized: "\(count) working")
        case .done: String(localized: "\(count) done")
        default: "\(count) \(status.displayTitle ?? status.rawValue)"
        }
    }
}

/// Persists the Console presentation choice and Host/Workspace collapse state,
/// and projects grouped sections without taking ownership of Agent sorting.
/// Collapsed Host ids are deliberately retained when a Host disconnects or
/// leaves the catalog so a reconnect or later return restores the choice.
@MainActor
@Observable
final class ConsoleListPresentationStore {
    /// Hosts follow the Hosts tab's order; within each Host, Workspaces across
    /// its Servers follow their first Agent in the supplied priority order. A
    /// Workspace is one Server's, so two of the same name on two Servers of a
    /// Host are two sections, both under the Host's name. Grouping never
    /// re-sorts Agents or pins.
    /// `savedStructures` holds the Workspace structure of each Host whose
    /// rows may be saved Chat entries, which report no checkout: its
    /// Workspaces had Agents at the last snapshot and count as Workspaces
    /// with Agents, so the cards keep the shape the live Agents gave them.
    func workspaceSections(
        hosts: [Host], agents: [ConsoleAgent],
        savedStructures: [Host.ID: [ChatCachedWorkspace]] = [:],
        filteredHostIDs: Set<Host.ID> = [], searchQuery: String = ""
    ) -> [ConsoleWorkspaceSection] {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !statusFilter.isEmpty
        let collapsedIDs = collapsedWorkspaceIDs
        let searched = searchedAgents(agents, searchQuery: searchQuery)
        let agentsByHost = Dictionary(grouping: searched, by: \.hostID)
        let agentPositions = Dictionary(
            searched.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        let groups = ConsoleHostSectionGroup.grouping(
            hosts.filter { filteredHostIDs.isEmpty || filteredHostIDs.contains($0.id) })
        return groups.flatMap { group in
            let serverTrees = group.servers.enumerated().flatMap { serverOffset, host
                -> [(rank: Int, serverOffset: Int, treeOffset: Int, sections: [ConsoleWorkspaceSection])] in
                let hostAgents = agentsByHost[host.id] ?? []
                let buckets = Dictionary(grouping: hostAgents, by: \.agent.workspaceID)
                var order: [String] = []
                for agent in hostAgents where !order.contains(agent.agent.workspaceID) {
                    order.append(agent.agent.workspaceID)
                }

                // Nesting is decided on every Agent of the Host, so a search
                // that matches only a worktree still finds its main checkout.
                // Workspaces exist here only through their Agents, or through
                // the saved structure, whose Workspaces had Agents at the last
                // snapshot: a main checkout with neither is not projected and
                // cannot be a parent.
                let everyAgent = agents.filter { $0.hostID == host.id }
                let allBuckets = Dictionary(grouping: everyAgent, by: \.agent.workspaceID)
                let saved = savedStructures[host.id] ?? []
                let savedByID = Dictionary(saved.map { ($0.id, $0) }) { first, _ in first }
                var allOrder: [String] = []
                for agent in everyAgent where !allOrder.contains(agent.agent.workspaceID) {
                    allOrder.append(agent.agent.workspaceID)
                }
                for workspace in saved where !allOrder.contains(workspace.id) {
                    allOrder.append(workspace.id)
                }
                func checkout(_ workspaceID: String) -> RepositoryCheckout? {
                    allBuckets[workspaceID]?.compactMap(\.repositoryCheckout).first
                        ?? savedByID[workspaceID]?.checkout
                }
                func mainCheckouts(_ repoKey: String, in ids: [String]) -> [String] {
                    ids.filter {
                        let info = checkout($0)
                        return info?.repoKey == repoKey && info?.isLinkedWorktree == false
                    }
                }
                func parent(of workspaceID: String) -> String? {
                    guard let info = checkout(workspaceID), info.isLinkedWorktree else { return nil }
                    return mainCheckouts(info.repoKey, in: order).first
                        ?? mainCheckouts(info.repoKey, in: allOrder).first
                }
                var parentOf: [String: String] = [:]
                for workspaceID in order {
                    if let parent = parent(of: workspaceID) { parentOf[workspaceID] = parent }
                }
                var childrenOf: [String: [String]] = [:]
                for workspaceID in order {
                    if let parent = parentOf[workspaceID] { childrenOf[parent, default: []].append(workspaceID) }
                }
                // A saved worktree none of whose Agents is listed yet still makes
                // its main checkout's card a repository's. It has no rows; a
                // search, which lists only matches, leaves it out.
                if !isSearching {
                    for workspace in saved where buckets[workspace.id] == nil {
                        guard let parent = parent(of: workspace.id) else { continue }
                        parentOf[workspace.id] = parent
                        childrenOf[parent, default: []].append(workspace.id)
                    }
                }

                func members(_ workspaceID: String) -> [ConsoleAgent] { buckets[workspaceID] ?? [] }
                func section(_ workspaceID: String) -> ConsoleWorkspaceSection {
                    let label = ((allBuckets[workspaceID] ?? []).map(\.workspaceLabel) + [savedByID[workspaceID]?.label])
                        .compactMap { $0 }
                        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    let id = ConsoleWorkspaceSection.ID(hostID: host.id, workspaceID: workspaceID)
                    let parentID = parentOf[workspaceID].map {
                        ConsoleWorkspaceSection.ID(hostID: host.id, workspaceID: $0)
                    }
                    var section = ConsoleWorkspaceSection(
                        id: id, title: label ?? (workspaceID.isEmpty ? String(localized: "Unknown Workspace") : workspaceID),
                        hostName: host.hostName, agents: members(workspaceID),
                        isCollapsed: !isSearching && collapsedIDs.contains(id),
                        parentID: parentID)
                    if let info = checkout(workspaceID) {
                        section.checkout = info
                        // Every Agent of a Host shortens its paths alike.
                        section.pathText = (allBuckets[workspaceID]?.first ?? everyAgent.first)?
                            .displayPath(info.checkoutPath)
                    }
                    return section
                }

                var emitted: Set<String> = []
                var trees: [[ConsoleWorkspaceSection]] = []
                for workspaceID in order {
                    let top = parentOf[workspaceID] ?? workspaceID
                    guard emitted.insert(top).inserted else { continue }
                    var tree = [section(top)]
                    for child in childrenOf[top] ?? [] where emitted.insert(child).inserted {
                        tree.append(section(child))
                    }
                    trees.append(tree)
                }
                return trees.enumerated().map { treeOffset, tree in
                    let rank = tree.lazy.flatMap(\.agents).compactMap { agentPositions[$0.id] }.min() ?? Int.max
                    return (rank, serverOffset, treeOffset, tree)
                }
            }
            if group.servers.count <= 1 {
                return serverTrees.flatMap(\.sections)
            }
            return serverTrees
                .sorted { ($0.rank, $0.serverOffset, $0.treeOffset) < ($1.rank, $1.serverOffset, $1.treeOffset) }
                .flatMap(\.sections)
        }
    }

    func toggleWorkspace(_ id: ConsoleWorkspaceSection.ID) {
        if !collapsedWorkspaceIDs.insert(id).inserted {
            collapsedWorkspaceIDs.remove(id)
        }
        let sorted = collapsedWorkspaceIDs.sorted {
            ($0.hostID.uuidString, $0.workspaceID) < ($1.hostID.uuidString, $1.workspaceID)
        }
        defaults.set(try? JSONEncoder().encode(sorted), forKey: Self.collapsedWorkspacesDefaultsKey)
    }

    private static let modeDefaultsKey = "console-list.presentation-mode"
    private static let collapsedHostsDefaultsKey = "console-list.collapsed-hosts"
    private static let collapsedWorkspacesDefaultsKey = "console-list.collapsed-workspaces"
    private static let hostFilterDefaultsKey = "console-list.host-filter"
    private static let statusFilterDefaultsKey = "console-list.status-filter"

    /// The Hosts both lists show, held as the records of their Servers: a
    /// record's id outlasts an edit of its Host, and any one of them selects
    /// the whole Host (ADR 0047). Empty shows every Host.
    private(set) var hostFilter: Set<Host.ID>

    func setHostFilter(_ hostIDs: Set<Host.ID>) {
        guard hostFilter != hostIDs else { return }
        hostFilter = hostIDs
        persistHostFilter()
    }

    /// Selects `host` with every Server it has on, or drops it.
    func toggleHostFilter(_ host: HostMachine) {
        setHostFilter(host.toggled(in: hostFilter))
    }

    func clearHostFilter() {
        guard !hostFilter.isEmpty else { return }
        hostFilter = []
        defaults.removeObject(forKey: Self.hostFilterDefaultsKey)
    }

    /// Settles the filter on `hosts`, the records of the Servers that are on.
    /// A selected Host holds every one of its Servers, so a Server turned on
    /// later shows too, and a selection saved when the filter listed each
    /// Server selects that Server's Host. A Host with no Server left drops
    /// out; the last one falls back to All Hosts. So does a filter with one
    /// Host left to list, which the filter no longer offers: it would show
    /// what All Hosts shows while reading as filtered, with nothing to clear
    /// it, and would hide a Host added later.
    func pruneHostFilter(keeping hosts: [Host]) {
        let machines = HostMachine.grouped(hosts)
        guard machines.count > 1 else {
            clearHostFilter()
            return
        }
        let filter = hostFilter
        setHostFilter(Set(machines.filter { $0.isSelected(by: filter) }.flatMap(\.servers).map(\.id)))
    }

    private func persistHostFilter() {
        if hostFilter.isEmpty {
            defaults.removeObject(forKey: Self.hostFilterDefaultsKey)
        } else {
            defaults.set(hostFilter.map(\.uuidString).sorted(), forKey: Self.hostFilterDefaultsKey)
        }
    }

    /// The statuses the Agents list shows; empty shows every Agent.
    private(set) var statusFilter: Set<ConsoleAgentStatusFilter>

    func toggleStatusFilter(_ filter: ConsoleAgentStatusFilter) {
        if !statusFilter.insert(filter).inserted { statusFilter.remove(filter) }
        if statusFilter.isEmpty {
            defaults.removeObject(forKey: Self.statusFilterDefaultsKey)
        } else {
            defaults.set(statusFilter.map(\.rawValue).sorted(), forKey: Self.statusFilterDefaultsKey)
        }
    }

    func clearStatusFilter() {
        statusFilter = []
        defaults.removeObject(forKey: Self.statusFilterDefaultsKey)
    }

    private(set) var mode: ConsoleListPresentationMode
    private var collapsedHostIDs: Set<Host.ID>
    private var collapsedWorkspaceIDs: Set<ConsoleWorkspaceSection.ID>
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
        collapsedWorkspaceIDs = Set(
            defaults.data(forKey: Self.collapsedWorkspacesDefaultsKey)
                .flatMap { try? JSONDecoder().decode([ConsoleWorkspaceSection.ID].self, from: $0) } ?? [])
        hostFilter = Set(
            (defaults.stringArray(forKey: Self.hostFilterDefaultsKey) ?? [])
                .compactMap(UUID.init(uuidString:)))
        statusFilter = Set(
            (defaults.stringArray(forKey: Self.statusFilterDefaultsKey) ?? [])
                .compactMap(ConsoleAgentStatusFilter.init(rawValue:)))
    }

    func select(_ mode: ConsoleListPresentationMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
    }

    /// Whether the Host whose Servers have the records `hostIDs` is folded:
    /// any of them is, as the Host filter reads a Host (ADR 0047). A Host
    /// folded while the list showed a section for each Server stays folded
    /// if any of them was.
    func isCollapsed(_ hostIDs: [Host.ID]) -> Bool {
        hostIDs.contains(where: collapsedHostIDs.contains)
    }

    /// Folds one record's section, as a build that listed a section for
    /// each Server saved it.
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

    /// Unfolds the Host of `hostIDs` by dropping every one of them, or folds
    /// it by holding them all, so it stays folded while any Server is on and
    /// a build that lists each Server folds them all.
    func toggleCollapsed(_ hostIDs: [Host.ID]) {
        if isCollapsed(hostIDs) {
            collapsedHostIDs.subtract(hostIDs)
        } else {
            collapsedHostIDs.formUnion(hostIDs)
        }
        persistCollapsedHostIDs()
    }

    /// Convenience contract for the Console UI. Reading these observable
    /// inputs on each render makes status, inventory, and membership changes
    /// re-project without a second cache to reconcile.
    func sections(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostIDs: Set<Host.ID> = [],
        searchQuery: String = ""
    ) -> [ConsoleHostSection] {
        let issuesByHost = Dictionary(
            console.hostIssues(for: hosts).map { ($0.hostID, $0) },
            uniquingKeysWith: { first, _ in first })
        return sections(
            hosts: hosts,
            agents: console.chatDisplayAgents,
            hostStatuses: console.hostStatuses,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            statusPresentations: issuesByHost,
            filteredHostIDs: filteredHostIDs,
            searchQuery: searchQuery)
    }

    /// Reads the same inventory as `sections(hosts:console:)`, so saved Chat
    /// entry points of an unproven Host appear By Workspace too.
    func workspaceSections(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostIDs: Set<Host.ID> = [],
        searchQuery: String = ""
    ) -> [ConsoleWorkspaceSection] {
        workspaceSections(
            hosts: hosts, agents: console.chatDisplayAgents,
            savedStructures: console.savedWorkspaceStructures,
            filteredHostIDs: filteredHostIDs, searchQuery: searchQuery)
    }

    /// Projects one section per Host, by its name, in the Hosts tab's order,
    /// holding the Servers it has on that `hosts` lists (ADR 0047). `agents`
    /// is already sorted by ConsoleStore; filtering it in-place keeps that
    /// exact relative order across every Server of the Host.
    func sections(
        hosts: [Host],
        agents: [ConsoleAgent],
        hostStatuses: [Host.ID: EventsSessionStatus] = [:],
        hostStandingFailures: [Host.ID: TransportError] = [:],
        hostsAwaitingSnapshot: Set<Host.ID> = [],
        hostSyncErrors: [Host.ID: String] = [:],
        statusPresentations: [Host.ID: ConsoleHostStatusPresentation]? = nil,
        filteredHostIDs: Set<Host.ID> = [],
        searchQuery: String = ""
    ) -> [ConsoleHostSection] {
        // A status filter narrows like a query: only matches, never folded away.
        let isNarrowed = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !statusFilter.isEmpty
        let searched = searchedAgents(agents, searchQuery: searchQuery)
        let agentsByHost = Dictionary(grouping: searched, by: \.hostID)
        let visible = hosts.filter { filteredHostIDs.isEmpty || filteredHostIDs.contains($0.id) }

        return ConsoleHostSectionGroup.grouping(visible).compactMap { group in
            guard let first = group.servers.first else { return nil }
            let servers = group.servers.map { host in
                let isAwaitingSnapshot = hostsAwaitingSnapshot.contains(host.id)
                let issue: ConsoleHostStatusPresentation? =
                    if let statusPresentations {
                        statusPresentations[host.id]
                    } else {
                        ConsoleHostStatusPresentation(
                            host: host,
                            status: hostStatuses[host.id],
                            standingFailure: hostStandingFailures[host.id],
                            isAwaitingSnapshot: isAwaitingSnapshot,
                            syncError: hostSyncErrors[host.id])
                    }
                return ConsoleHostServerState(
                    hostID: host.id, connectionStatus: hostStatuses[host.id],
                    isAwaitingSnapshot: isAwaitingSnapshot, issue: issue)
            }
            let hostAgents: [ConsoleAgent]
            if group.servers.count == 1 {
                hostAgents = agentsByHost[first.id] ?? []
            } else {
                let serverIDs = Set(group.servers.map(\.id))
                hostAgents = searched.filter { serverIDs.contains($0.hostID) }
            }
            // While searching, a section without a match leaves the list
            // whatever its Host's state (#292, #316): a query asks for Agents,
            // and Hosts that cannot answer only bury the matches. Without a
            // query a Host with no Agents stays visible while it has
            // something to say or could start one, and otherwise would be a
            // bare header.
            if hostAgents.isEmpty
                && (isNarrowed || !group.keepsEmptySection(servers, listsTerminals: false))
            {
                return nil
            }
            return ConsoleHostSection(
                hostID: first.id,
                hostName: group.name,
                servers: servers,
                agents: hostAgents,
                // A match is never hidden behind a collapsed Host.
                isCollapsed: !isNarrowed && isCollapsed(group.servers.map(\.id)),
                statusCounts: ConsoleHostAgentStatusCounts(agents: hostAgents))
        }
    }

    /// `agents` that the search and the status filter keep, in order.
    private func searchedAgents(_ agents: [ConsoleAgent], searchQuery: String) -> [ConsoleAgent] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return agents.filter {
            (trimmedQuery.isEmpty || $0.matchesAgentSearch(trimmedQuery)) && statusFilter.admits($0)
        }
    }

    private func persistCollapsedHostIDs() {
        defaults.set(
            collapsedHostIDs.map(\.uuidString).sorted(),
            forKey: Self.collapsedHostsDefaultsKey)
    }
}

/// How the Console's Host filter, a set of record ids, reads a Host: by the
/// Host, never by one of its Servers (ADR 0047).
extension HostMachine {
    /// Whether `filter` holds a record of any of this Host's Servers.
    func isSelected(by filter: Set<Host.ID>) -> Bool {
        servers.contains { filter.contains($0.id) }
    }

    /// `filter` with this Host dropped when it is selected, or else added with
    /// every Server it has on.
    func toggled(in filter: Set<Host.ID>) -> Set<Host.ID> {
        isSelected(by: filter)
            ? filter.subtracting(members.map(\.id))
            : filter.union(servers.map(\.id))
    }
}
