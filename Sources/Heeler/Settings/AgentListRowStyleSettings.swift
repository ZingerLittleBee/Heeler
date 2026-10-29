import Observation
import SwiftUI

/// How an Agents list row shows its Agent's program and status. Both lead
/// with the program's mark (`AgentKindMark`).
enum AgentListRowStyle: String, CaseIterable, Identifiable, Sendable {
    /// The mark on a tile; the status capsule ends Row 1.
    case tile
    /// The mark in an avatar whose ring is the status, in place of the
    /// capsule.
    case statusRing

    var id: Self { self }

    var title: String {
        switch self {
        case .tile: "Tile"
        case .statusRing: "Status Ring"
        }
    }

    /// Fields the style keeps out of a row: the Status Ring's ring is the
    /// status, so a status field shows there only where the user asks.
    func hiddenFields(showingStatusField: Bool) -> Set<AgentRowToken> {
        self == .statusRing && !showingStatusField ? [.status] : []
    }
}

/// The app-wide Agents list row style, the same in every window. Tile is the
/// default; unknown stored values fall back to it. The Status Ring style
/// hides a layout's status field until the user shows it.
@MainActor
@Observable
final class AgentListRowStyleSettings {
    private static let defaultsKey = "console-list.row-style"
    private static let ringStatusFieldKey = "console-list.ring-status-field"

    private(set) var style: AgentListRowStyle
    private(set) var ringShowsStatusField: Bool
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(AgentListRowStyle.init(rawValue:)) ?? .tile
        ringShowsStatusField = defaults.bool(forKey: Self.ringStatusFieldKey)
    }

    /// What the chosen style keeps out of every row.
    var hiddenFields: Set<AgentRowToken> { style.hiddenFields(showingStatusField: ringShowsStatusField) }

    func select(_ style: AgentListRowStyle) {
        guard style != self.style else { return }
        self.style = style
        defaults.set(style.rawValue, forKey: Self.defaultsKey)
    }

    func setRingShowsStatusField(_ shows: Bool) {
        guard shows != ringShowsStatusField else { return }
        ringShowsStatusField = shows
        defaults.set(shows, forKey: Self.ringStatusFieldKey)
    }
}

extension EnvironmentValues {
    /// Set once by `ConsoleView` from `AgentListRowStyleSettings`, so every
    /// Agent row and the Agent List Fields preview draw the same style.
    @Entry var agentListRowStyle: AgentListRowStyle = .tile
    /// `AgentListRowStyleSettings.ringShowsStatusField`, set beside it.
    @Entry var agentListRingShowsStatusField = false
}
