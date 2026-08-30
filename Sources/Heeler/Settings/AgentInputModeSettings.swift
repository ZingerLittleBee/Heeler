import Foundation
import Observation

/// How Agent detail accepts authored input. Composer is the ADR 0013 default;
/// Direct Input is the opt-in exception that routes the system keyboard into
/// the live Attach PTY (ADR 0016).
enum AgentInputMode: String, CaseIterable, Identifiable, Sendable {
    case composer
    case direct

    var id: Self { self }

    /// Short segment title for the iPad mode control. VoiceOver speaks this
    /// value under the "Input mode" label.
    var segmentTitle: String {
        switch self {
        case .composer: "Composer"
        case .direct: "Keyboard"
        }
    }
}

/// App-wide Agent detail input mode. Persists across navigation, reconnect,
/// and Agent switches. Default remains Composer; unknown stored values fall
/// back to Composer rather than inventing Direct Input.
@MainActor
@Observable
final class AgentInputModeSettings {
    private static let defaultsKey = "agent-input-mode"

    private(set) var mode: AgentInputMode
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(AgentInputMode.init(rawValue:)) ?? .composer
    }

    var isDirect: Bool { mode == .direct }

    func select(_ mode: AgentInputMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }
}
