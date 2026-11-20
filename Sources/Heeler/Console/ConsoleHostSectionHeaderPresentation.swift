import Foundation

/// A Host header's short readiness and the tone of the badge on its server
/// glyph (`HostStatusGlyph`). VoiceOver reads the text; the Agents list's
/// header also shows it while the Host is not connected, as do the saved
/// Chat entry points listed under it.
struct HostReadiness: Equatable, Sendable {
    let text: String
    let tone: HostConnectionTone
    /// How strongly the Host's name reads beside this readiness.
    let nameEmphasis: HostNameEmphasis

    /// A reachable Host reads at full strength, one still trying recedes,
    /// and one stopped on a failure recedes further until the user acts.
    init(text: String, tone: HostConnectionTone) {
        self.text = text
        self.tone = tone
        nameEmphasis = Self.emphasis(of: tone)
    }

    private init(text: String, tone: HostConnectionTone, nameEmphasis: HostNameEmphasis) {
        self.text = text
        self.tone = tone
        self.nameEmphasis = nameEmphasis
    }

    /// A Host's readiness from those of the Servers it has on, in catalog
    /// order, as the Hosts tab reads a Host (`HostMachineRowPresentation`):
    /// while `servers` are connected (`readiness(servers:isEmpty:inventoryNoun:)`
    /// narrows to connected Servers first), one out of sync or still loading
    /// leads one that is ready; when none is connected, one that cannot connect
    /// comes before one still trying, and a paused one last; the first among
    /// equals. The name stays at full strength while any Server is reachable,
    /// since what that Server lists is live under it. Nil for no Servers.
    static func combining(_ servers: [HostReadiness]) -> HostReadiness? {
        guard let lead = servers.min(by: { attentionRank($0.tone) < attentionRank($1.tone) })
        else { return nil }
        let reachable = servers.contains { emphasis(of: $0.tone) == .full }
        return HostReadiness(
            text: lead.text, tone: lead.tone, nameEmphasis: reachable ? .full : lead.nameEmphasis)
    }

    private static func emphasis(of tone: HostConnectionTone) -> HostNameEmphasis {
        switch tone {
        case .connected, .warning: .full
        case .pending, .paused, .reconnecting: .receded
        case .unavailable: .dimmed
        }
    }

    private static func attentionRank(_ tone: HostConnectionTone) -> Int {
        switch tone {
        case .unavailable: 0
        case .reconnecting, .pending: 1
        case .warning: 2
        case .connected: 3
        case .paused: 4
        }
    }
}

enum HostNameEmphasis: Equatable {
    case full, receded, dimmed
}

/// One of a Host's Servers that are on, as a By Host section reads it: its
/// connection, and the condition row it adds under the Host's header.
struct ConsoleHostServerState: Equatable {
    /// The Server's catalog record.
    let hostID: Host.ID
    let connectionStatus: EventsSessionStatus?
    let isAwaitingSnapshot: Bool
    let issue: ConsoleHostStatusPresentation?
}

/// A By Host section's place for one Host: each Host once, by its name, in
/// the Hosts tab's order, holding the Servers it has on that the list shows,
/// each in catalog order (ADR 0047).
struct ConsoleHostSectionGroup {
    let name: String
    let servers: [Host]

    /// `hosts`, the records of the Servers that are on, by their Hosts. A
    /// Host goes by the name its records' rows give it, which the catalog
    /// makes the Hosts tab's (`Host.hostName`).
    static func grouping(_ hosts: [Host]) -> [Self] {
        var seen: Set<Host.ID> = []
        let unique = hosts.filter { seen.insert($0.id).inserted }
        return HostMachine.grouped(unique).map {
            Self(name: $0.members.first?.hostName ?? $0.name, servers: $0.members)
        }
    }

    /// Whether this Host has a section with nothing to list: it does while a
    /// Server has something to say (not connected, still loading, out of
    /// sync), or while one can offer something from it, by its kind, so a
    /// Host still being located keeps its place. A Host with neither would
    /// be a bare header, as a connected Rex Host whose terminals are all
    /// Agents is in Terminals, and one that lists no Agents is in Agents
    /// (ADR 0054): Rex starts neither.
    func keepsEmptySection(_ states: [ConsoleHostServerState], listsTerminals: Bool) -> Bool {
        let offers = servers.contains {
            listsTerminals ? $0.capabilities.startsTerminals : $0.capabilities.startsAgents
        }
        let noun = listsTerminals ? "Terminals" : "Agents"
        return offers || states.contains { $0.issue != nil }
            || ConsoleHostSectionHeaderPresentation.readiness(
                servers: states, isEmpty: true, inventoryNoun: noun
            ).tone != .connected
    }
}

/// Pure presentation values for one Console Host-section header (#245).
///
/// Built from a projected `ConsoleHostSection` so VoiceOver labels, readiness
/// copy, and attention wording stay unit-testable without hosting a List.
struct ConsoleHostSectionHeaderPresentation: Equatable {
    /// The Host's name alone, whichever of its Servers the section lists.
    let hostName: String
    /// Short connection / Agent Inventory readiness, aligned with Host-list
    /// chip language rather than the longer flat-list issue sentences.
    let readiness: HostReadiness
    let isCollapsed: Bool
    let statusItems: [ConsoleHostAgentStatusCount]
    /// Visual status pills only while collapsed; VoiceOver still hears the
    /// status breakdown whenever one of the counts is non-zero.
    let showsStatusPills: Bool
    let statusText: String?
    let disclosureSystemImage: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityHint: String
    /// A failing Host opens its connection sheet instead of expanding: it
    /// has no inventory to show. Only for a Host with one Server on: one with
    /// more expands, and each Server's problem opens its own sheet from the
    /// row under the header.
    let opensConnectionDetail: Bool

    init(section: ConsoleHostSection, opensConnectionDetail: Bool = false) {
        hostName = section.hostName
        readiness = Self.readiness(for: section)
        self.opensConnectionDetail = opensConnectionDetail
        isCollapsed = section.isCollapsed || opensConnectionDetail
        let projectedStatusItems = section.statusCounts.items
        statusItems = projectedStatusItems
        showsStatusPills = section.isCollapsed && !projectedStatusItems.isEmpty
        statusText = Self.statusText(items: projectedStatusItems)
        disclosureSystemImage = isCollapsed ? "chevron.right" : "chevron.down"
        accessibilityValue =
            opensConnectionDetail
            ? "" : section.isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
        accessibilityHint =
            opensConnectionDetail
            ? String(localized: "Shows why this Host can't connect.")
            : section.isCollapsed
                ? String(localized: "Expands this Host.")
                : String(localized: "Collapses this Host.")

        var labelParts = [section.hostName, readiness.text]
        if let statusText {
            labelParts.append(statusText)
        }
        accessibilityLabel = labelParts.joined(separator: ", ")
    }

    /// Honest short readiness: connected-empty is distinct from connecting,
    /// loading, failed, and reconnecting. A Host with several Servers on
    /// reads as the one that most needs the user (`HostReadiness.combining`).
    static func readiness(for section: ConsoleHostSection) -> HostReadiness {
        readiness(servers: section.servers, isEmpty: section.agents.isEmpty, inventoryNoun: "Agents")
    }

    /// One Host's readiness from each of its Servers' states. `isEmpty` is
    /// the whole Host's: a connected Server with nothing of its own still
    /// reads Connected beside another Server's Agents or Terminals.
    static func readiness(
        servers: [ConsoleHostServerState], isEmpty: Bool, inventoryNoun: String
    ) -> HostReadiness {
        let connected = servers.filter { $0.connectionStatus == .connected }
        let relevant = connected.isEmpty ? servers : connected
        let each = relevant.map {
            readiness(
                connectionStatus: $0.connectionStatus, isAwaitingSnapshot: $0.isAwaitingSnapshot,
                statusSeverity: $0.issue?.severity, isEmpty: isEmpty, inventoryNoun: inventoryNoun)
        }
        return HostReadiness.combining(each)
            ?? readiness(
                connectionStatus: nil, isAwaitingSnapshot: false, statusSeverity: nil,
                isEmpty: isEmpty, inventoryNoun: inventoryNoun)
    }

    /// The same readiness for any Host-scoped inventory; the Terminals tab
    /// passes its own noun. The noun is a token, "Agents" or "Terminals",
    /// never shown as it is: each one has its own localized sentences.
    static func readiness(
        connectionStatus: EventsSessionStatus?,
        isAwaitingSnapshot: Bool,
        statusSeverity: ConsoleHostStatusPresentation.Severity?,
        isEmpty: Bool,
        inventoryNoun: String
    ) -> HostReadiness {
        switch connectionStatus {
        case .connected:
            // A failed sync outranks the snapshot still awaited after it, in
            // `ConsoleHostStatusPresentation`'s order: the header and the
            // Host's issue row never give one state two looks. A connected
            // Host's only quieter condition is that wait itself.
            if let statusSeverity, statusSeverity != .informational {
                return HostReadiness(text: String(localized: "Sync issue"), tone: .warning)
            }
            if isAwaitingSnapshot {
                return HostReadiness(text: loadingText(inventoryNoun: inventoryNoun), tone: .pending)
            }
            return HostReadiness(
                text: isEmpty ? emptyText(inventoryNoun: inventoryNoun) : String(localized: "Connected"),
                tone: .connected)
        case .reconnecting:
            return HostReadiness(text: String(localized: "Reconnecting…"), tone: .reconnecting)
        case .connecting:
            if let statusSeverity, statusSeverity != .informational {
                return HostReadiness(text: String(localized: "Unavailable"), tone: .unavailable)
            }
            return HostReadiness(text: String(localized: "Connecting…"), tone: .pending)
        case .failed, .ended:
            return HostReadiness(text: String(localized: "Unavailable"), tone: .unavailable)
        case .suspended:
            return HostReadiness(text: String(localized: "Paused"), tone: .paused)
        case nil:
            if statusSeverity != nil {
                return HostReadiness(text: String(localized: "Unavailable"), tone: .unavailable)
            }
            return HostReadiness(text: String(localized: "Connecting…"), tone: .pending)
        }
    }

    private static func loadingText(inventoryNoun: String) -> String {
        inventoryNoun == "Terminals"
            ? String(localized: "Loading Terminals…") : String(localized: "Loading Agents…")
    }

    private static func emptyText(inventoryNoun: String) -> String {
        inventoryNoun == "Terminals" ? String(localized: "No Terminals") : String(localized: "No Agents")
    }

    static func statusText(items: [ConsoleHostAgentStatusCount]) -> String? {
        guard !items.isEmpty else { return nil }
        return items.map(countText).joinedAsPhrases()
    }

    private static func countText(_ item: ConsoleHostAgentStatusCount) -> String {
        let count = item.count
        switch item.status {
        case .blocked: return String(localized: "\(count) blocked")
        case .working: return String(localized: "\(count) working")
        case .done: return String(localized: "\(count) done")
        case .error: return count == 1 ? String(localized: "1 error") : String(localized: "\(count) errors")
        default: return "\(count) \(item.status.displayTitle ?? item.status.rawValue)"
        }
    }
}
