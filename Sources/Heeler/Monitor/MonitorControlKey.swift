import Foundation

/// A control key on Monitor's strip (#183): a labeled shortcut mapped to the
/// exact `agent.send_keys` spelling herdr expects. The set covers answering a
/// Blocked Agent's confirmation prompt and interrupting work without Attach —
/// Enter, Esc, Ctrl+C, and the four arrows.
///
/// Spellings are load-bearing, not cosmetic. Verified live against herdr
/// 0.8.0 (shared with `pane.send_keys` / `pane.send_input`): `enter`, `esc`,
/// `ctrl+c` / `C-c` accepted case-insensitively; the near-miss `ctrl-c` is
/// rejected with `invalid_key`. Arrows are `up`/`down`/`left`/`right`.
enum MonitorControlKey: String, CaseIterable, Identifiable, Sendable {
    case enter
    case escape
    case interrupt
    case up
    case down
    case left
    case right

    var id: String { rawValue }

    /// The herdr `agent.send_keys` key sequence this shortcut sends.
    var keys: [String] {
        switch self {
        case .enter: ["enter"]
        case .escape: ["esc"]
        case .interrupt: ["ctrl+c"]
        case .up: ["up"]
        case .down: ["down"]
        case .left: ["left"]
        case .right: ["right"]
        }
    }

    /// Short label for the button; nil when an SF Symbol carries it instead.
    var label: String? {
        switch self {
        case .enter: "Enter"
        case .escape: "Esc"
        case .interrupt: "Ctrl+C"
        case .up, .down, .left, .right: nil
        }
    }

    /// SF Symbol for the arrow keys; nil when a text label carries it.
    var systemImage: String? {
        switch self {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        default: nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .enter: "Enter"
        case .escape: "Escape"
        case .interrupt: "Control C"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        }
    }
}
