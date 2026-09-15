import GhosttyTerminal

/// What the terminal does when ghostty asks about a clipboard request.
/// Extracted so the mapping lives in one testable place: the answers here come
/// from what herdr can actually deliver, not from a preference to be
/// re-decided per call site. `refs #243`
enum TerminalClipboardRequestDecision: Equatable, Sendable {
    /// Answer without UI.
    case allow
    /// Refuse without UI.
    case deny
    /// Ask the user, naming what makes the request unsafe.
    case askUser

    /// - `.paste`: the only request herdr can deliver to an attach client —
    ///   dictation or an IME commits text with a newline and the target has
    ///   bracketed paste off. Reviewed, never dropped.
    /// - `.osc52Write`: herdr's emulation consumes these and forwards them only
    ///   to its foreground TUI client, so this answer never runs in practice; it
    ///   stays `allow` to match the pasteboard write the default
    ///   `clipboard-write = allow` performs.
    /// - `.osc52Read`: nothing upstream registers a read callback, and letting a
    ///   program read the device clipboard is the worse default.
    static func decision(for kind: TerminalClipboardRequestKind) -> Self {
        switch kind {
        case .paste:
            return .askUser
        case .osc52Write:
            return .allow
        case .osc52Read:
            return .deny
        }
    }
}
