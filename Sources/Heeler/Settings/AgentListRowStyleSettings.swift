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
}

/// The app-wide Agents list row style, the same in every window. Tile is the
/// default; unknown stored values fall back to it.
@MainActor
@Observable
final class AgentListRowStyleSettings {
    private static let defaultsKey = "console-list.row-style"

    private(set) var style: AgentListRowStyle
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(AgentListRowStyle.init(rawValue:)) ?? .tile
    }

    func select(_ style: AgentListRowStyle) {
        guard style != self.style else { return }
        self.style = style
        defaults.set(style.rawValue, forKey: Self.defaultsKey)
    }
}

extension EnvironmentValues {
    /// Set once by `ConsoleView` from `AgentListRowStyleSettings`, so every
    /// Agent row and the Agent List Fields preview draw the same style.
    @Entry var agentListRowStyle: AgentListRowStyle = .tile
}
