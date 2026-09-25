import Foundation

/// A Host header's short readiness and the tone of the badge on its server
/// glyph (`HostStatusGlyph`). The header shows only the glyph; the text is
/// what VoiceOver reads.
struct HostReadiness: Equatable {
    let text: String
    let tone: HostConnectionTone

    /// A Host stopped on a failure recedes until the user acts on it.
    var dimsName: Bool { tone == .unavailable }
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
            opensConnectionDetail ? "" : section.isCollapsed ? "Collapsed" : "Expanded"
        accessibilityHint =
            opensConnectionDetail
            ? "Shows why this Host can't connect."
            : section.isCollapsed
                ? "Expands this Host."
                : "Collapses this Host."

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
    /// passes its own noun.
    static func readiness(
        connectionStatus: EventsSessionStatus?,
        isAwaitingSnapshot: Bool,
        statusSeverity: ConsoleHostStatusPresentation.Severity?,
        isEmpty: Bool,
        inventoryNoun: String
    ) -> HostReadiness {
        switch connectionStatus {
        case .connected:
            if isAwaitingSnapshot {
                return HostReadiness(text: "Loading \(inventoryNoun)…", tone: .pending)
            }
            if statusSeverity != nil {
                return HostReadiness(text: "Sync issue", tone: .warning)
            }
            return HostReadiness(
                text: isEmpty ? "No \(inventoryNoun)" : "Connected", tone: .connected)
        case .reconnecting:
            return HostReadiness(text: "Reconnecting…", tone: .reconnecting)
        case .connecting:
            if let statusSeverity, statusSeverity != .informational {
                return HostReadiness(text: "Unavailable", tone: .unavailable)
            }
            return HostReadiness(text: "Connecting…", tone: .pending)
        case .failed, .ended:
            return HostReadiness(text: "Unavailable", tone: .unavailable)
        case .suspended:
            return HostReadiness(text: "Paused", tone: .paused)
        case nil:
            if statusSeverity != nil {
                return HostReadiness(text: "Unavailable", tone: .unavailable)
            }
            return HostReadiness(text: "Connecting…", tone: .pending)
        }
    }

    static func statusText(items: [ConsoleHostAgentStatusCount]) -> String? {
        guard !items.isEmpty else { return nil }
        return items.map { "\($0.count) \($0.status.rawValue)" }.joined(separator: ", ")
    }
}
