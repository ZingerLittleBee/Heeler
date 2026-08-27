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
    let attentionCount: Int
    /// Visual badge only while collapsed; VoiceOver still hears attention
    /// whenever the count is non-zero.
    let showsAttentionBadge: Bool
    let attentionText: String?
    let disclosureSystemImage: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityHint: String

    init(section: ConsoleHostSection) {
        hostDisplayName = section.hostDisplayName
        readinessText = Self.readinessText(for: section)
        isCollapsed = section.isCollapsed
        attentionCount = section.attentionCount
        showsAttentionBadge = section.isCollapsed && section.attentionCount > 0
        attentionText = Self.attentionText(count: section.attentionCount)
        disclosureSystemImage = section.isCollapsed ? "chevron.right" : "chevron.down"
        accessibilityValue = section.isCollapsed ? "Collapsed" : "Expanded"
        accessibilityHint =
            section.isCollapsed
            ? "Expands this Host."
            : "Collapses this Host."

        var labelParts = [section.hostDisplayName, readinessText]
        if let attentionText {
            labelParts.append(attentionText)
        }
        accessibilityLabel = labelParts.joined(separator: ", ")
    }

    /// Honest short readiness: connected-empty is distinct from connecting,
    /// loading, failed, and reconnecting.
    static func readinessText(for section: ConsoleHostSection) -> String {
        switch section.connectionStatus {
        case .connected:
            if section.isAwaitingSnapshot {
                return "Loading Agents…"
            }
            if section.statusPresentation != nil {
                return "Sync issue"
            }
            return section.agents.isEmpty ? "No Agents" : "Connected"
        case .reconnecting:
            return "Reconnecting…"
        case .connecting:
            if let presentation = section.statusPresentation,
                presentation.severity != .informational
            {
                return "Unavailable"
            }
            return "Connecting…"
        case .failed, .ended:
            return "Unavailable"
        case .suspended:
            return "Paused"
        case nil:
            if section.statusPresentation != nil {
                return "Unavailable"
            }
            return "Connecting…"
        }
    }

    static func attentionText(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 {
            return "1 Agent needs attention"
        }
        return "\(count) Agents need attention"
    }
}
