import Foundation
import Observation

/// What an Agent detail shows in its body: the live Agent terminal, or Chat,
/// the native conversation read from the Agent's own transcript (ADR 0021).
enum AgentDetailSurface: String, CaseIterable, Sendable {
    case terminal
    case chat

    /// The switcher-row glyph that brings this surface up.
    var showSystemImage: String {
        switch self {
        case .terminal: "terminal"
        case .chat: "bubble.left.and.text.bubble.right"
        }
    }

    /// The More-menu title and switcher-row label that bring this surface up.
    var showTitle: String {
        switch self {
        case .terminal: "Show Agent Terminal"
        case .chat: "Show Chat"
        }
    }

    var showAccessibilityHint: String {
        switch self {
        case .terminal: "Shows this Agent's live terminal in place of Chat."
        case .chat: "Shows this Agent's conversation in place of its terminal."
        }
    }
}

/// The app-wide surface an Agent detail opens on. Terminal is the default;
/// Chat is remembered once chosen. Each detail takes its own copy when it
/// opens, so a choice made in one window does not swap another window's
/// screen from under it. Unknown stored values fall back to Terminal.
@MainActor
@Observable
final class AgentDetailSurfaceSettings {
    private static let defaultsKey = "agent.detail-surface"

    private(set) var preferred: AgentDetailSurface
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferred =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(AgentDetailSurface.init(rawValue:)) ?? .terminal
    }

    func select(_ surface: AgentDetailSurface) {
        guard surface != preferred else { return }
        preferred = surface
        defaults.set(surface.rawValue, forKey: Self.defaultsKey)
    }
}
