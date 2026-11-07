import Foundation

/// Whether Chat's Stop may press Esc in Antigravity CLI 1.5.3, decided on
/// one fresh screen read. One Esc stops a running turn, from a dialog too,
/// and puts a queued message back in the box; at an idle box it leaves a
/// draft as it is. In bash mode it leaves bash mode and drops the command
/// typed there (agy-93, captured idle), so Stop presses nothing while one
/// is typed. What Esc does to a turn from bash mode was not captured.
enum AgyStopGuard {
    static func verdict(_ context: ChatStopContext) -> ChatStopVerdict {
        if case .shellMode(let command) = AgyInputBoxDetector.detect(context.screen), !command.isEmpty {
            return .refuse(bashCommand)
        }
        return .press
    }

    static let bashCommand =
        "Antigravity CLI's input box is in bash mode with a command typed, and Esc would drop it. Stop it in the terminal."
}
