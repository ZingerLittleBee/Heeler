import Observation

/// A handle on the live terminal's scroll path for chrome that sits outside
/// it. Same lifetime rules as ``TerminalKeyboardControl``: the reference is
/// weak and set by the surface, so an Agent switch rebuilding the terminal
/// cannot leave a jump control driving a dead one.
///
/// ``isAlternateScreen`` is observable so the message-jump chrome can hide
/// itself on the primary screen, where local scrollback already works and
/// remote wheel reports would be the wrong tool. `refs #268`.
@MainActor
@Observable
final class TerminalScrollControl {
    weak var terminal: HeelerTerminalView? {
        didSet {
            oldValue?.onAlternateScreenChange = nil
            terminal?.onAlternateScreenChange = { [weak self] in
                self?.syncAlternateScreen()
            }
            syncAlternateScreen()
        }
    }

    /// Mirrors the surface's DECSET 1049/47/1047 state. False when no terminal
    /// is attached.
    private(set) var isAlternateScreen = false

    /// One scroll step of `rows` lines. Same branch `scrollTouch` takes
    /// (remote sequence when the mode tracker supplies one, local
    /// `scroll_page_lines` otherwise), without touching the gesture
    /// accumulator.
    func scrollRows(towardOlderContent: Bool, rows: Int) {
        terminal?.scrollRows(towardOlderContent: towardOlderContent, rows: rows)
    }

    /// Rows the live grid shows, or nil when unknown. Bounds the jump loop's
    /// step size so no row can pass by unrendered.
    var viewportRows: Int? { terminal?.viewportRows }

    private func syncAlternateScreen() {
        let next = terminal?.isAlternateScreen ?? false
        guard isAlternateScreen != next else { return }
        isAlternateScreen = next
    }
}
