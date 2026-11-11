import Foundation

/// A Host header's short readiness and the tone of the badge on its server
/// glyph (`HostStatusGlyph`). VoiceOver reads the text; the Agents list's
/// header also shows it while the Host is not connected, as do the saved
/// Chat entry points listed under it.
struct HostReadiness: Equatable {
    let text: String
    let tone: HostConnectionTone

    /// A reachable Host reads at full strength, one still trying recedes,
    /// and one stopped on a failure recedes further until the user acts.
    var nameEmphasis: HostNameEmphasis {
        switch tone {
        case .connected, .warning: .full
        case .pending, .paused, .reconnecting: .receded
        case .unavailable: .dimmed
        }
    }
}

enum HostNameEmphasis: Equatable {
    case full, receded, dimmed
}

/// Pure presentation values for one Console Host-section header (#245).
///
/// Built from a projected `ConsoleHostSection` so VoiceOver labels, readiness
/// copy, and attention wording stay unit-testable without hosting a List.
struct ConsoleHostSectionHeaderPresentation: Equatable {
    let hostDisplayName: String
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
    /// has no inventory to show.
    let opensConnectionDetail: Bool

    init(section: ConsoleHostSection, opensConnectionDetail: Bool = false) {
        hostDisplayName = section.hostDisplayName
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

        var labelParts = [section.hostDisplayName, readiness.text]
        if let statusText {
            labelParts.append(statusText)
        }
        accessibilityLabel = labelParts.joined(separator: ", ")
    }

    /// Honest short readiness: connected-empty is distinct from connecting,
    /// loading, failed, and reconnecting.
    static func readiness(for section: ConsoleHostSection) -> HostReadiness {
        readiness(
            connectionStatus: section.connectionStatus,
            isAwaitingSnapshot: section.isAwaitingSnapshot,
            statusSeverity: section.statusPresentation?.severity,
            isEmpty: section.agents.isEmpty,
            inventoryNoun: "Agents")
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
