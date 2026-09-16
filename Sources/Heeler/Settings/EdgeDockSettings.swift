import Foundation
import Observation

/// Where each floating terminal control rests along the terminal's trailing
/// edge, as a fraction of the room it has there (0 at the top, 1 at the
/// bottom). A fraction rather than points, so one remembered position fits
/// every terminal height, rotation, and keyboard state.
@MainActor
@Observable
final class EdgeDockSettings {
    enum Control: String, CaseIterable, Sendable {
        case workspaceDrawer = "workspace-drawer"
        case messageJump = "message-jump"

        /// Where a control sits until the user moves it: the drawer handle
        /// midway, the jump buttons as low as the keyboard band allows.
        var defaultFraction: CGFloat {
            switch self {
            case .workspaceDrawer: 0.5
            case .messageJump: 1
            }
        }

        fileprivate var defaultsKey: String { "edge-dock-\(rawValue)" }
    }

    private var fractions: [Control: CGFloat]
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var fractions: [Control: CGFloat] = [:]
        for control in Control.allCases {
            if let stored = defaults.object(forKey: control.defaultsKey) as? Double {
                fractions[control] = Self.clamped(CGFloat(stored))
            }
        }
        self.fractions = fractions
    }

    func fraction(for control: Control) -> CGFloat {
        fractions[control] ?? control.defaultFraction
    }

    func setFraction(_ fraction: CGFloat, for control: Control) {
        let clamped = Self.clamped(fraction)
        guard clamped != self.fraction(for: control) else { return }
        fractions[control] = clamped
        defaults.set(Double(clamped), forKey: control.defaultsKey)
    }

    /// The single clamping policy: anything unreadable docks at the top.
    nonisolated static func clamped(_ fraction: CGFloat) -> CGFloat {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}
