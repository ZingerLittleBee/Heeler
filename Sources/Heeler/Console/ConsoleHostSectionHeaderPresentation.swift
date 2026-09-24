import Foundation

/// Pure presentation values for one Console Host-section header (#245).
///
/// Built from a projected `ConsoleHostSection` so VoiceOver labels, readiness
/// copy, and attention wording stay unit-testable without hosting a List.
struct ConsoleHostSectionHeaderPresentation: Equatable {
    let hostDisplayName: String
    /// Short connection / Agent Inventory readiness, aligned with Host-list
    /// chip language rather than the longer flat-list issue sentences.
    let readinessText: String
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

    init(section: ConsoleHostSection) {
        hostDisplayName = section.hostDisplayName
        readinessText = Self.readinessText(for: section)
        isCollapsed = section.isCollapsed
        let projectedStatusItems = section.statusCounts.items
        statusItems = projectedStatusItems
        showsStatusPills = section.isCollapsed && !projectedStatusItems.isEmpty
        statusText = Self.statusText(items: projectedStatusItems)
        disclosureSystemImage = section.isCollapsed ? "chevron.right" : "chevron.down"
        accessibilityValue = section.isCollapsed ? "Collapsed" : "Expanded"
        accessibilityHint =
            section.isCollapsed
            ? "Expands this Host."
            : "Collapses this Host."

        var labelParts = [section.hostDisplayName, readinessText]
        if let statusText {
            labelParts.append(statusText)
        }
        accessibilityLabel = labelParts.joined(separator: ", ")
    }

    /// Honest short readiness: connected-empty is distinct from connecting,
    /// loading, failed, and reconnecting.
    static func readinessText(for section: ConsoleHostSection) -> String {
        readinessText(
            connectionStatus: section.connectionStatus,
            isAwaitingSnapshot: section.isAwaitingSnapshot,
            statusSeverity: section.statusPresentation?.severity,
            isEmpty: section.agents.isEmpty,
            inventoryNoun: "Agents")
    }

    /// The same readiness for any Host-scoped inventory; the Terminals tab
    /// passes its own noun.
    static func readinessText(
        connectionStatus: EventsSessionStatus?,
        isAwaitingSnapshot: Bool,
        statusSeverity: ConsoleHostStatusPresentation.Severity?,
        isEmpty: Bool,
        inventoryNoun: String
    ) -> String {
        switch connectionStatus {
        case .connected:
            if isAwaitingSnapshot {
                return "Loading \(inventoryNoun)…"
            }
            if statusSeverity != nil {
                return "Sync issue"
            }
            return isEmpty ? "No \(inventoryNoun)" : "Connected"
        case .reconnecting:
            return "Reconnecting…"
        case .connecting:
            if let statusSeverity, statusSeverity != .informational {
                return "Unavailable"
            }
            return "Connecting…"
        case .failed, .ended:
            return "Unavailable"
        case .suspended:
            return "Paused"
        case nil:
            if statusSeverity != nil {
                return "Unavailable"
            }
            return "Connecting…"
        }
    }

    static func statusText(items: [ConsoleHostAgentStatusCount]) -> String? {
        guard !items.isEmpty else { return nil }
        return items.map { "\($0.count) \($0.status.rawValue)" }.joined(separator: ", ")
    }
}
