import UIKit

extension AgentStatus {
    /// The one status palette in the app: the Console badge and the keyboard
    /// switcher's dot read from it, so a colour never means two things.
    var tintUIColor: UIColor {
        switch self {
        case .blocked: AgentStatusPalette.red
        case .done: AgentStatusPalette.green
        case .working: AgentStatusPalette.yellow
        // Idle, Unknown, and anything this build cannot read: not asking for
        // the user, so it stays out of the way.
        default: AgentStatusPalette.muted
        }
    }
}

/// herdr's own agent colours, so the phone and the TUI agree on what green
/// means. herdr paints agent state from its Catppuccin palette; the two
/// flavours it ships pair straight into dynamic colours — Mocha on dark,
/// Latte on light.
enum AgentStatusPalette {
    static let green = flavoured(mocha: 0xA6E3A1, latte: 0x40A02B)
    static let yellow = flavoured(mocha: 0xF9E2AF, latte: 0xDF8E1D)
    static let red = flavoured(mocha: 0xF38BA8, latte: 0xD20F39)
    /// herdr's muted-text role. Its Mocha `overlay0` is too dim to carry a
    /// label on a phone, so each flavour takes the legible end of the role:
    /// Mocha `overlay1`, Latte `subtext0`.
    static let muted = flavoured(mocha: 0x7F849C, latte: 0x6C6F85)

    private static func flavoured(mocha: UInt32, latte: UInt32) -> UIColor {
        UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? mocha : latte)
        }
    }
}

extension UIColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
}
