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
            // A terminal handed off mid-jump must not be left with its
            // renderer stopped: nothing else would ever thaw it.
            oldValue?.thawDisplay()
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

    /// Whether a scroll step can actually move the remote application's own
    /// view.
    ///
    /// `herdr terminal attach` always puts the client on the alternate screen,
    /// so `isAlternateScreen` says nothing about the application inside it.
    /// Every agent CLI measured — claude, codex, grok — asks for mouse
    /// reporting and scrolls on a wheel report. An application that asks for
    /// none does not: `applyScroll` falls back to cursor keys, which a shell
    /// reads as line editing. Nothing else can stand in, because an
    /// alternate-screen application leaves no herdr-side scrollback for
    /// `pane.read` to return. `refs #268`.
    private(set) var canScrollRemoteContent = false

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

    /// Pins a snapshot of the origin frame so a jump's intermediate frames
    /// never reach the screen. See ``HeelerTerminalView/freezeDisplay()``.
    /// `refs #268`.
    func freezeDisplay() {
        terminal?.freezeDisplay()
    }

    /// Resumes rendering. Safe to call when no freeze is in effect.
    func thawDisplay() {
        terminal?.thawDisplay()
    }

    private func syncAlternateScreen() {
        let nextAlternate = terminal?.isAlternateScreen ?? false
        if isAlternateScreen != nextAlternate {
            isAlternateScreen = nextAlternate
        }
        let nextScrollable = terminal?.remoteTracksMouse ?? false
        if canScrollRemoteContent != nextScrollable {
            canScrollRemoteContent = nextScrollable
        }
    }
}
