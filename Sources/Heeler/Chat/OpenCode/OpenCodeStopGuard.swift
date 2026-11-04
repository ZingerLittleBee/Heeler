import Foundation

/// Whether Chat's Stop may press OpenCode 2.0.32's two Escs on the screen
/// it read. On the conversation's input box while a turn runs, the first
/// Esc arms the interrupt and the second interrupts; on a screen already
/// armed, the first interrupts and the second only arms again. Elsewhere
/// Esc does something else: it rejects a permission, dismisses a question,
/// closes a menu or leaves shell mode. A draft doesn't stop it, because
/// the interrupt leaves the box as it is.
enum OpenCodeStopGuard {
    static func verdict(_ context: ChatStopContext) -> ChatStopVerdict {
        guard context.activity == .working else {
            return .refuse("The turn already ended, so Stop pressed nothing.")
        }
        // herdr may not report Blocked yet.
        switch OpenCodeDialogParser.parse(context.screen) {
        case .dialog, .unrecognized:
            return .refuse(
                "OpenCode is asking for an answer, and Esc would reject it. Answer the card, or stop in the terminal.")
        case .none:
            break
        }
        let screen = OpenCodeScreenReader.read(context.screen)
        guard screen.route == .session else {
            return .refuse(
                "OpenCode isn't showing this conversation's prompt, so Stop pressed nothing. Stop it in the terminal.")
        }
        guard screen.overlayTitle == nil else {
            return .refuse(
                "A menu is open over OpenCode's prompt, and Esc would only close it. Close it in the terminal first.")
        }
        if case .shellMode = screen.state {
            return .refuse("OpenCode's prompt is in shell mode, where Esc only leaves it. Stop it in the terminal.")
        }
        guard screen.isRunning else {
            return .refuse("OpenCode's screen shows no running turn, so Stop pressed nothing.")
        }
        return .press
    }
}
