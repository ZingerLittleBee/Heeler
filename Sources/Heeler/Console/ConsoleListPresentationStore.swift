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

/// Coarse scroll-zone classification for the Console Agent list so
/// `.onScrollGeometryChange` fires only across zone boundaries rather than on
/// every scroll frame.
struct ConsoleListScrollPosition: Equatable, Sendable {
    let isPastTopThreshold: Bool
    let isPinnedAtOverflowBottom: Bool
    let isAtTopEdge: Bool

    init(offsetFromTop: CGFloat, maxOffsetFromTop: CGFloat = .infinity) {
        isPastTopThreshold = offsetFromTop > ConsoleListPresentationStore.topScrollThreshold
        let minOverflow = ConsoleListPresentationStore.bottomFreezeThreshold
        let tolerance = ConsoleListPresentationStore.bottomPinTolerance
        isPinnedAtOverflowBottom =
            maxOffsetFromTop.isFinite
            && maxOffsetFromTop > minOverflow
            && offsetFromTop > minOverflow
            && offsetFromTop >= maxOffsetFromTop - tolerance
        isAtTopEdge = offsetFromTop <= minOverflow
    }
}

/// Persists the Console presentation choice and Host/Workspace collapse state,
/// and projects grouped sections without taking ownership of Agent sorting.
/// Collapsed Host ids are deliberately retained when a Host disconnects or
/// leaves the catalog so a reconnect or later return restores the choice.
@MainActor
@Observable
final class ConsoleListPresentationStore {
    /// Offset past the top content inset at which resting in the list freezes
    /// automatic priority reordering until the user scrolls back to Row 1.
    /// Clears the 52-point collapsing search drawer so both launch tucking and
    /// returning to Row 1 without pulling the search field open stay un-frozen.
    nonisolated static let topScrollThreshold: CGFloat = 64
    /// Minimum scrollable overflow and top-edge clearance required for a
    /// barely-overflowing list (`maxOffset <= topScrollThreshold`) to freeze
    /// when the user scrolls to its bottom.
    nonisolated static let bottomFreezeThreshold: CGFloat = 4
    /// Distance from `maxOffsetFromTop` within which a scrolled list counts as
    /// resting at its bottom edge.
    nonisolated static let bottomPinTolerance: CGFloat = 4

    private var orderFreezeGeneration: UInt64 = 0
    @ObservationIgnored private(set) var isScrollActive = false
    @ObservationIgnored private(set) var isScrolledFromTop = false
    @ObservationIgnored private var hasUserScrolledSinceTop = false
    @ObservationIgnored private var lastScrollPosition = ConsoleListScrollPosition(offsetFromTop: 0)
    @ObservationIgnored private var frozenAgentRanks: [ConsoleAgent.ID: Int] = [:]
    @ObservationIgnored private var nextFrozenAgentRank = 0
    @ObservationIgnored private var lastDisplayedAgentIDs: [ConsoleAgent.ID] = []
    @ObservationIgnored private var frozenWorkspaceRanks: [ConsoleWorkspaceSection.ID: Int] = [:]
    @ObservationIgnored private var nextFrozenWorkspaceRank = 0
    @ObservationIgnored private var lastDisplayedWorkspaceIDs: [ConsoleWorkspaceSection.ID] = []
    @ObservationIgnored private var lastPinnedPaneIDs: [Host.ID: [String]]?
    @ObservationIgnored private var lastOrderSearchQuery = ""
    @ObservationIgnored private var hadDeferredReorder = false
    @ObservationIgnored private var cachedQualifierByAgent: [ConsoleAgent.ID: QualifierAgentKey] = [:]
    @ObservationIgnored private var cachedQualifierShownByAgent: [ConsoleAgent.ID: AgentTitleQualifier.Shown] = [:]
    @ObservationIgnored private var cachedQualifierResolved: [QualifierResolvedEntry] = []
    @ObservationIgnored private var cachedQualifiers: [ConsoleAgent.ID: String] = [:]
    @ObservationIgnored private var cachedFilteredSlice: (key: FilteredAgentSliceKey, value: FilteredAgentSlice)?
    @ObservationIgnored private var cachedConsoleSections:
        (key: ConsoleSectionsCacheKey, sections: [ConsoleHostSection], visibleAgentIDs: [ConsoleAgent.ID])?
    @ObservationIgnored private var cachedConsoleWorkspaceCards:
        (key: ConsoleWorkspaceCardsCacheKey, cards: [ConsoleWorkspaceCard], visibleAgentIDs: [ConsoleAgent.ID])?

    struct FilteredAgentSlice: Equatable {
        let hostFiltered: [ConsoleAgent]
        let searched: [ConsoleAgent]
        let filtered: [ConsoleAgent]
        let filteredIDs: [ConsoleAgent.ID]
    }

    private struct FilteredAgentSliceKey: Equatable {
        let consoleID: ObjectIdentifier
        let pinsID: ObjectIdentifier
        let pinsRevision: UInt64
        let orderFreezeGeneration: UInt64
        let isOrderFrozen: Bool
        let rawAgents: [ConsoleAgent]
        let filteredHostIDs: Set<Host.ID>
        let trimmedSearch: String
        let statusFilter: Set<ConsoleAgentStatusFilter>
    }

    private struct ConsoleSectionsCacheKey: Equatable {
        let consoleID: ObjectIdentifier
        let pinsID: ObjectIdentifier
        let pinsRevision: UInt64
        let orderFreezeGeneration: UInt64
        let isOrderFrozen: Bool
        let hosts: [Host]
        let rawAgents: [ConsoleAgent]
        let hostStatuses: [Host.ID: EventsSessionStatus]
        let awaitingSnapshot: Set<Host.ID>
        let issues: [ConsoleHostStatusPresentation]
        let filteredHostIDs: Set<Host.ID>
        let trimmedSearch: String
        let statusFilter: Set<ConsoleAgentStatusFilter>
        let collapsedHostIDs: Set<Host.ID>
    }

    private struct ConsoleWorkspaceCardsCacheKey: Equatable {
        let consoleID: ObjectIdentifier
        let pinsID: ObjectIdentifier
        let pinsRevision: UInt64
        let orderFreezeGeneration: UInt64
        let isOrderFrozen: Bool
        let hosts: [Host]
        let rawAgents: [ConsoleAgent]
        let savedStructures: [Host.ID: [ChatCachedWorkspace]]
        let filteredHostIDs: Set<Host.ID>
        let trimmedSearch: String
        let statusFilter: Set<ConsoleAgentStatusFilter>
        let collapsedWorkspaceIDs: Set<ConsoleWorkspaceSection.ID>
    }

    private struct QualifierAgentKey: Equatable {
        let isByWorkspace: Bool
        let checkoutPath: String?
        let layout: AgentRowLayout
        let hostName: String
        let backend: AgentBackend?
        let hostUsername: String?
        let workspaceLabel: String?
        let tabLabel: String?
        let paneLabel: String?
        let tabPosition: Int?
        let workspaceTabCount: Int
        let repoName: String?
        let kind: String
        let name: String?
        let title: String
        let paneTitle: String?
        let terminalTitle: String?
        let terminalTitleStripped: String?
        let cwd: String
        let tokens: [String: String]?
        let status: AgentStatus?
    }

    private struct QualifierResolvedEntry: Equatable {
        let id: ConsoleAgent.ID
        let title: String
        let namesAgent: Bool
        let program: String
    }

    /// True while the user is actively scrolling or resting mid-list away from
    /// the top, holding row and Workspace card positions steady while live
    /// status, title, and diff updates apply in place.
    var isOrderFrozen: Bool { isScrollActive || isScrolledFromTop }

    func setScrollActive(_ active: Bool, userInitiated: Bool = false) {
        let becameUserScrolled = active && userInitiated && !hasUserScrolledSinceTop
        if becameUserScrolled {
            hasUserScrolledSinceTop = true
        }
        guard isScrollActive != active || becameUserScrolled else { return }
        let wasFrozen = isOrderFrozen
        isScrollActive = active
        if becameUserScrolled {
            isScrolledFromTop = resolvedScrolledFromTop(for: lastScrollPosition)
        }
        if !isOrderFrozen {
            hasUserScrolledSinceTop = false
        }
        transitionOrderFreeze(from: wasFrozen, to: isOrderFrozen)
    }

    func updateScrollPosition(_ position: ConsoleListScrollPosition) {
        lastScrollPosition = position
        if position.isAtTopEdge, !isScrollActive {
            hasUserScrolledSinceTop = false
        }
        let next: Bool
        if isScrolledFromTop, !isScrollActive, !position.isAtTopEdge {
            next = true
        } else {
            next = resolvedScrolledFromTop(for: position)
        }
        setScrolledFromTop(next)
    }

    func updateScrollOffsetFromTop(_ offset: CGFloat, maxOffset: CGFloat = .infinity) {
        let position = ConsoleListScrollPosition(offsetFromTop: offset, maxOffsetFromTop: maxOffset)
        lastScrollPosition = position
        if position.isAtTopEdge, !isScrollActive {
            hasUserScrolledSinceTop = false
        }
        setScrolledFromTop(resolvedScrolledFromTop(for: position))
    }

    func setScrolledFromTop(_ scrolled: Bool) {
        guard isScrolledFromTop != scrolled else { return }
        let wasFrozen = isOrderFrozen
        isScrolledFromTop = scrolled
        if !isOrderFrozen {
            hasUserScrolledSinceTop = false
        }
        transitionOrderFreeze(from: wasFrozen, to: isOrderFrozen)
    }

    func resetScrollTracking() {
        isScrollActive = false
        isScrolledFromTop = false
        hasUserScrolledSinceTop = false
        lastScrollPosition = ConsoleListScrollPosition(offsetFromTop: 0)
        clearFrozenRanks()
    }

    private func resolvedScrolledFromTop(for position: ConsoleListScrollPosition) -> Bool {
        if position.isPastTopThreshold {
            return true
        }
        if position.isAtTopEdge {
            return false
        }
        return position.isPinnedAtOverflowBottom && hasUserScrolledSinceTop
    }

    private func transitionOrderFreeze(from wasFrozen: Bool, to nowFrozen: Bool) {
        if !wasFrozen, nowFrozen {
            if !lastDisplayedAgentIDs.isEmpty {
                frozenAgentRanks = Dictionary(
                    lastDisplayedAgentIDs.enumerated().map { ($0.element, $0.offset) },
                    uniquingKeysWith: { first, _ in first })
                nextFrozenAgentRank = lastDisplayedAgentIDs.count
            }
            if !lastDisplayedWorkspaceIDs.isEmpty {
                frozenWorkspaceRanks = Dictionary(
                    lastDisplayedWorkspaceIDs.enumerated().map { ($0.element, $0.offset) },
                    uniquingKeysWith: { first, _ in first })
                nextFrozenWorkspaceRank = lastDisplayedWorkspaceIDs.count
            }
        } else if wasFrozen, !nowFrozen {
            let shouldFlush = hadDeferredReorder
            clearFrozenRanks(preservingLastDisplayed: !shouldFlush)
            if shouldFlush {
                orderFreezeGeneration &+= 1
            }
        }
    }

    private func clearFrozenRanks(preservingLastDisplayed: Bool = false) {
        frozenAgentRanks.removeAll(keepingCapacity: true)
        nextFrozenAgentRank = 0
        frozenWorkspaceRanks.removeAll(keepingCapacity: true)
        nextFrozenWorkspaceRank = 0
        if !preservingLastDisplayed {
            lastDisplayedAgentIDs.removeAll(keepingCapacity: true)
            lastDisplayedWorkspaceIDs.removeAll(keepingCapacity: true)
        }
        hadDeferredReorder = false
        cachedFilteredSlice = nil
        cachedConsoleSections = nil
        cachedConsoleWorkspaceCards = nil
    }

    /// Returns `agents` in canonical priority order when at the top of the list,
    /// or preserves each live Agent's visual rank while updating its fields in
    /// place while scrolling or viewing mid-list.
    func orderedAgents(
        _ agents: [ConsoleAgent],
        pinnedByHost: [Host.ID: [String]]? = nil,
        searchQuery: String = ""
    ) -> [ConsoleAgent] {
        _ = orderFreezeGeneration
        let trimmedSearch = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSearch != lastOrderSearchQuery {
            lastOrderSearchQuery = trimmedSearch
            clearFrozenRanks()
        }
        if let pinnedByHost {
            if let lastPinnedPaneIDs, lastPinnedPaneIDs != pinnedByHost {
                clearFrozenRanks()
            }
            self.lastPinnedPaneIDs = pinnedByHost
        }
        guard isOrderFrozen, trimmedSearch.isEmpty else {
            lastDisplayedAgentIDs = agents.map(\.id)
            frozenAgentRanks.removeAll(keepingCapacity: true)
            nextFrozenAgentRank = 0
            hadDeferredReorder = false
            return agents
        }
        if frozenAgentRanks.isEmpty {
            let seed = lastDisplayedAgentIDs.isEmpty ? agents.map(\.id) : lastDisplayedAgentIDs
            frozenAgentRanks = Dictionary(
                seed.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first })
            nextFrozenAgentRank = seed.count
        }
        for agent in agents where frozenAgentRanks[agent.id] == nil {
            frozenAgentRanks[agent.id] = nextFrozenAgentRank
            nextFrozenAgentRank += 1
        }
        let ordered = agents.sorted {
            (frozenAgentRanks[$0.id] ?? Int.max) < (frozenAgentRanks[$1.id] ?? Int.max)
        }
        if !hadDeferredReorder, ordered.map(\.id) != agents.map(\.id) {
            hadDeferredReorder = true
        }
        lastDisplayedAgentIDs = ordered.map(\.id)
        return ordered
    }

    func orderedAgents(in console: ConsoleStore, searchQuery: String = "") -> [ConsoleAgent] {
        let agents = console.chatDisplayAgents
        var pinnedByHost: [Host.ID: [String]] = [:]
        for agent in agents where pinnedByHost[agent.hostID] == nil {
            pinnedByHost[agent.hostID] = console.pins.pinnedPaneIDs(for: agent.hostID)
        }
        return orderedAgents(agents, pinnedByHost: pinnedByHost, searchQuery: searchQuery)
    }

    /// Memoizes Host-filtered, searched, and status-filtered Agent lists across
    /// repeated intra-frame reads (such as iPadOS key-command menu validation).
    func filteredAgentSlice(
        in console: ConsoleStore,
        filteredHostIDs: Set<Host.ID> = [],
        searchQuery: String = ""
    ) -> FilteredAgentSlice {
        let freezeGen = orderFreezeGeneration
        let statusFilter = self.statusFilter
        let rawAgents = console.chatDisplayAgents
        let pinsRevision = console.pins.revision
        let trimmedSearch = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = FilteredAgentSliceKey(
            consoleID: ObjectIdentifier(console),
            pinsID: ObjectIdentifier(console.pins),
            pinsRevision: pinsRevision,
            orderFreezeGeneration: freezeGen,
            isOrderFrozen: isOrderFrozen,
            rawAgents: rawAgents,
            filteredHostIDs: filteredHostIDs,
            trimmedSearch: trimmedSearch,
            statusFilter: statusFilter)
        if let cached = cachedFilteredSlice, cached.key == key {
            return cached.value
        }
        return PerfTrace.span("console.list.filtered-agents") {
            let ordered = orderedAgents(in: console, searchQuery: trimmedSearch)
            let hostFiltered =
                filteredHostIDs.isEmpty
                ? ordered
                : ordered.filter { filteredHostIDs.contains($0.hostID) }
            let searched =
                trimmedSearch.isEmpty
                ? hostFiltered
                : hostFiltered.filter { $0.matchesAgentSearch(trimmedSearch) }
            let filtered =
                statusFilter.isEmpty
                ? searched
                : searched.filter { statusFilter.admits($0) }
            let slice = FilteredAgentSlice(
                hostFiltered: hostFiltered,
                searched: searched,
                filtered: filtered,
                filteredIDs: filtered.map(\.id))
            cachedFilteredSlice = (key, slice)
            return slice
        }
    }

    /// Memoized program qualifiers for rows sharing a headline. Status flips
    /// skip `AgentCardPresentation` completely unless the layout renders status
    /// text in its fields.
    func titleQualifiers(
        for agents: [ConsoleAgent],
        isByWorkspace: Bool,
        savedStructures: [Host.ID: [ChatCachedWorkspace]] = [:],
        rowLayout: (Host.ID) -> AgentRowLayout
    ) -> [ConsoleAgent.ID: String] {
        var layouts: [Host.ID: AgentRowLayout] = [:]
        var layoutReadsStatus: [Host.ID: Bool] = [:]
        var resolved: [QualifierResolvedEntry] = []
        resolved.reserveCapacity(agents.count)

        for agent in agents {
            let layout = layouts[agent.hostID] ?? {
                let value = rowLayout(agent.hostID)
                layouts[agent.hostID] = value
                return value
            }()
            let readsStatus = layoutReadsStatus[agent.hostID] ?? {
                let value = Self.layoutRendersStatus(layout)
                layoutReadsStatus[agent.hostID] = value
                return value
            }()
            let checkoutPath = isByWorkspace
                ? (agent.checkoutPath
                    ?? savedStructures[agent.hostID]?.first { $0.id == agent.agent.workspaceID }?.checkout.checkoutPath)
                : nil
            let key = QualifierAgentKey(
                isByWorkspace: isByWorkspace,
                checkoutPath: checkoutPath,
                layout: layout,
                hostName: agent.hostName,
                backend: agent.backend,
                hostUsername: agent.hostUsername,
                workspaceLabel: agent.workspaceLabel,
                tabLabel: agent.tabLabel,
                paneLabel: agent.paneLabel,
                tabPosition: agent.tabPosition,
                workspaceTabCount: agent.workspaceTabCount,
                repoName: agent.repoName,
                kind: agent.agent.kind,
                name: agent.agent.name,
                title: agent.agent.title,
                paneTitle: agent.agent.paneTitle,
                terminalTitle: agent.agent.terminalTitle,
                terminalTitleStripped: agent.agent.terminalTitleStripped,
                cwd: agent.agent.cwd,
                tokens: agent.agent.tokens,
                status: readsStatus ? agent.agent.status : nil)

            let shown: AgentTitleQualifier.Shown
            if cachedQualifierByAgent[agent.id] == key,
                let cached = cachedQualifierShownByAgent[agent.id]
            {
                shown = cached
            } else {
                let card = AgentCardPresentation(
                    agent: agent, layout: layout,
                    hiding: isByWorkspace
                        ? ConsoleWorkspaceCard.hiddenTokens(
                            for: agent, checkoutPath: checkoutPath, showsHost: false)
                        : [],
                    leadsWithMark: true)
                shown = .init(title: card.headline, namesAgent: card.cardNamesAgent)
                cachedQualifierByAgent[agent.id] = key
                cachedQualifierShownByAgent[agent.id] = shown
            }
            resolved.append(QualifierResolvedEntry(
                id: agent.id,
                title: shown.title,
                namesAgent: shown.namesAgent,
                program: AgentNotificationIdentity.kindLabel(agent.agent.kind)))
        }

        if resolved == cachedQualifierResolved {
            return cachedQualifiers
        }
        if cachedQualifierByAgent.count > agents.count * 2 + 16 {
            let live = Set(agents.map(\.id))
            cachedQualifierByAgent = cachedQualifierByAgent.filter { live.contains($0.key) }
            cachedQualifierShownByAgent = cachedQualifierShownByAgent.filter { live.contains($0.key) }
        }
        let programsByTitle = Dictionary(grouping: resolved, by: \.title)
            .mapValues { Set($0.map(\.program)) }
        var qualifiers: [ConsoleAgent.ID: String] = [:]
        for entry in resolved where !entry.namesAgent {
            guard let programs = programsByTitle[entry.title], programs.count > 1 else { continue }
            qualifiers[entry.id] = entry.program
        }
        cachedQualifierResolved = resolved
        cachedQualifiers = qualifiers
        return qualifiers
    }

    private static func layoutRendersStatus(_ layout: AgentRowLayout) -> Bool {
        let allRows = layout.rows + layout.rowsByAgent.values.flatMap { $0 } + (layout.trailing ?? [])
        return allRows.contains { row in
            row.contains { field in
                switch field.token {
                case .status, .stateText, .stateIcon, .statusBadge: true
                default: false
                }
            }
        }
    }

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
        let effectiveAgents = orderedAgents(agents, searchQuery: searchQuery)
        let collapsedIDs = collapsedWorkspaceIDs
        let searched = searchedAgents(effectiveAgents, searchQuery: searchQuery)
        let agentsByHost = Dictionary(grouping: searched, by: \.hostID)
        let agentPositions = Dictionary(
            searched.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        let groups = ConsoleHostSectionGroup.grouping(
            hosts.filter { filteredHostIDs.isEmpty || filteredHostIDs.contains($0.id) })
        let freezeSections = isOrderFrozen && !isSearching
        if freezeSections, frozenWorkspaceRanks.isEmpty, !lastDisplayedWorkspaceIDs.isEmpty {
            frozenWorkspaceRanks = Dictionary(
                lastDisplayedWorkspaceIDs.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first })
            nextFrozenWorkspaceRank = lastDisplayedWorkspaceIDs.count
        }

        let projected = groups.flatMap { group -> [ConsoleWorkspaceSection] in
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
                let everyAgent = effectiveAgents.filter { $0.hostID == host.id }
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
                    var children = [ConsoleWorkspaceSection]()
                    for child in childrenOf[top] ?? [] where emitted.insert(child).inserted {
                        children.append(section(child))
                    }
                    if freezeSections {
                        for item in [tree[0]] + children where frozenWorkspaceRanks[item.id] == nil {
                            frozenWorkspaceRanks[item.id] = nextFrozenWorkspaceRank
                            nextFrozenWorkspaceRank += 1
                        }
                        let canonicalChildren = children.map(\.id)
                        children.sort {
                            (frozenWorkspaceRanks[$0.id] ?? Int.max) < (frozenWorkspaceRanks[$1.id] ?? Int.max)
                        }
                        if !hadDeferredReorder, children.map(\.id) != canonicalChildren {
                            hadDeferredReorder = true
                        }
                    }
                    tree.append(contentsOf: children)
                    trees.append(tree)
                }
                return trees.enumerated().map { treeOffset, tree in
                    let rank: Int
                    if freezeSections, let first = tree.first {
                        rank = frozenWorkspaceRanks[first.id] ?? Int.max
                    } else {
                        rank = tree.lazy.flatMap(\.agents).compactMap { agentPositions[$0.id] }.min() ?? Int.max
                    }
                    return (rank, serverOffset, treeOffset, tree)
                }
            }
            if group.servers.count <= 1 && !freezeSections {
                return serverTrees.flatMap(\.sections)
            }
            let sortedTrees = serverTrees
                .sorted { ($0.rank, $0.serverOffset, $0.treeOffset) < ($1.rank, $1.serverOffset, $1.treeOffset) }
            if freezeSections, !hadDeferredReorder,
                sortedTrees.map({ $0.sections.first?.id }) != serverTrees.map({ $0.sections.first?.id })
            {
                hadDeferredReorder = true
            }
            return sortedTrees.flatMap(\.sections)
        }

        if freezeSections {
            lastDisplayedWorkspaceIDs = projected.map(\.id)
        } else if !isSearching {
            lastDisplayedWorkspaceIDs = projected.map(\.id)
            frozenWorkspaceRanks.removeAll(keepingCapacity: true)
            nextFrozenWorkspaceRank = 0
        }
        return projected
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
        clearFrozenRanks()
        hostFilter = hostIDs
        persistHostFilter()
    }

    /// Selects `host` with every Server it has on, or drops it.
    func toggleHostFilter(_ host: HostMachine) {
        setHostFilter(host.toggled(in: hostFilter))
    }

    func clearHostFilter() {
        guard !hostFilter.isEmpty else { return }
        clearFrozenRanks()
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
        clearFrozenRanks()
        if !statusFilter.insert(filter).inserted { statusFilter.remove(filter) }
        if statusFilter.isEmpty {
            defaults.removeObject(forKey: Self.statusFilterDefaultsKey)
        } else {
            defaults.set(statusFilter.map(\.rawValue).sorted(), forKey: Self.statusFilterDefaultsKey)
        }
    }

    func clearStatusFilter() {
        clearFrozenRanks()
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
        resetScrollTracking()
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
        sectionsWithVisibleIDs(
            hosts: hosts,
            console: console,
            filteredHostIDs: filteredHostIDs,
            searchQuery: searchQuery
        ).sections
    }

    func sectionsWithVisibleIDs(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostIDs: Set<Host.ID> = [],
        searchQuery: String = ""
    ) -> (sections: [ConsoleHostSection], visibleAgentIDs: [ConsoleAgent.ID]) {
        let freezeGen = orderFreezeGeneration
        let statusFilter = self.statusFilter
        let collapsedHosts = self.collapsedHostIDs
        let rawAgents = console.chatDisplayAgents
        let pinsRevision = console.pins.revision
        let hostStatuses = console.hostStatuses
        let awaitingSnapshot = console.hostsAwaitingSnapshot
        let issues = console.hostIssues(for: hosts)
        let trimmedSearch = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ConsoleSectionsCacheKey(
            consoleID: ObjectIdentifier(console),
            pinsID: ObjectIdentifier(console.pins),
            pinsRevision: pinsRevision,
            orderFreezeGeneration: freezeGen,
            isOrderFrozen: isOrderFrozen,
            hosts: hosts,
            rawAgents: rawAgents,
            hostStatuses: hostStatuses,
            awaitingSnapshot: awaitingSnapshot,
            issues: issues,
            filteredHostIDs: filteredHostIDs,
            trimmedSearch: trimmedSearch,
            statusFilter: statusFilter,
            collapsedHostIDs: collapsedHosts)
        if let cached = cachedConsoleSections, cached.key == key {
            return (cached.sections, cached.visibleAgentIDs)
        }
        return PerfTrace.span("console.list.host-sections") {
            let issuesByHost = Dictionary(
                issues.map { ($0.hostID, $0) },
                uniquingKeysWith: { first, _ in first })
            let built = sections(
                hosts: hosts,
                agents: orderedAgents(in: console, searchQuery: trimmedSearch),
                hostStatuses: hostStatuses,
                hostsAwaitingSnapshot: awaitingSnapshot,
                statusPresentations: issuesByHost,
                filteredHostIDs: filteredHostIDs,
                searchQuery: trimmedSearch)
            let visibleIDs = built.filter { !$0.isCollapsed }.flatMap { $0.agents.map(\.id) }
            cachedConsoleSections = (key, built, visibleIDs)
            return (built, visibleIDs)
        }
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
            hosts: hosts,
            agents: orderedAgents(in: console, searchQuery: searchQuery),
            savedStructures: console.savedWorkspaceStructures,
            filteredHostIDs: filteredHostIDs, searchQuery: searchQuery)
    }

    func workspaceCardsWithVisibleIDs(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostIDs: Set<Host.ID> = [],
        searchQuery: String = ""
    ) -> (cards: [ConsoleWorkspaceCard], visibleAgentIDs: [ConsoleAgent.ID]) {
        let freezeGen = orderFreezeGeneration
        let statusFilter = self.statusFilter
        let collapsedWorkspaces = self.collapsedWorkspaceIDs
        let rawAgents = console.chatDisplayAgents
        let pinsRevision = console.pins.revision
        let savedStructures = console.savedWorkspaceStructures
        let trimmedSearch = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ConsoleWorkspaceCardsCacheKey(
            consoleID: ObjectIdentifier(console),
            pinsID: ObjectIdentifier(console.pins),
            pinsRevision: pinsRevision,
            orderFreezeGeneration: freezeGen,
            isOrderFrozen: isOrderFrozen,
            hosts: hosts,
            rawAgents: rawAgents,
            savedStructures: savedStructures,
            filteredHostIDs: filteredHostIDs,
            trimmedSearch: trimmedSearch,
            statusFilter: statusFilter,
            collapsedWorkspaceIDs: collapsedWorkspaces)
        if let cached = cachedConsoleWorkspaceCards, cached.key == key {
            return (cached.cards, cached.visibleAgentIDs)
        }
        return PerfTrace.span("console.list.workspace-cards") {
            let cards = ConsoleWorkspaceCard.cards(
                workspaceSections(
                    hosts: hosts,
                    agents: orderedAgents(in: console, searchQuery: trimmedSearch),
                    savedStructures: savedStructures,
                    filteredHostIDs: filteredHostIDs,
                    searchQuery: trimmedSearch))
            let visibleIDs = cards.flatMap(\.visibleAgentIDs)
            cachedConsoleWorkspaceCards = (key, cards, visibleIDs)
            return (cards, visibleIDs)
        }
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
        let effectiveAgents = orderedAgents(agents, searchQuery: searchQuery)
        let searched = searchedAgents(effectiveAgents, searchQuery: searchQuery)
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
