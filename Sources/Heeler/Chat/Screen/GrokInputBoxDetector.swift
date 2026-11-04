import Foundation

/// Reads Grok Build's input box from a screen (ADR 0024). Only an empty
/// composer with prompt focus, or under the Welcome view, reads `.empty`;
/// ghost text never counts as typed. Every other state carries the reason
/// Chat holds a message with. The dashboard's view of an agent shows that
/// agent's own box, read the same way; whose agent it is, the session
/// check reads (`GrokSessionCheck`).
enum GrokInputBoxDetector {
    static func detect(_ screen: ANSIScreen) -> InputBoxState {
        let grok = GrokScreen(screen)
        if grok.isDashboard {
            return .noComposer(
                "Grok Build is showing its dashboard, where a message starts a new agent. Go back to the conversation in the terminal first."
            )
        }
        if let overlay = grok.overlay { return .overlay(overlay) }
        if let press = grok.pendingDoublePress {
            return .disabled(
                "Grok Build is waiting for a second key press (\u{201C}\(press)\u{201D}). Wait a second, then send again.")
        }
        guard let composer = grok.composer else {
            return grok.isMinimal
                ? .disabled(
                    "Grok Build is in minimal mode, which Chat can't read. Switch back with /fullscreen in the terminal.")
                : .unknown("Heeler can't find Grok Build's input box on screen.")
        }
        if composer.isMultiline {
            return .disabled(
                "Grok Build is in /multiline mode, where Enter adds a line instead of sending. Turn it off in the terminal with /multiline."
            )
        }
        if composer.isEditingQueued {
            return .disabled("Grok Build is editing a queued message. Finish it in the terminal first.")
        }
        switch composer.mode {
        case .prompt:
            break
        case .bash:
            return .shellMode(composer.draft)
        case .remember:
            return .disabled(
                "Grok Build's input box is in remember mode, where a message is saved as a memory. Leave it in the terminal first."
            )
        }
        if !composer.draft.isEmpty { return .text(composer.draft) }
        if grok.sendableWait {
            return .disabled(
                "Grok Build is waiting on a subagent or a background task, and a message now would cancel that turn.")
        }
        // Grok queues a message while a turn runs, and the Welcome view's
        // composer sends. Without prompt focus a paste goes elsewhere, and
        // Enter on a queued row sends that row now.
        if grok.isWelcome || grok.promptHasFocus { return .empty(placeholder: nil) }
        return .disabled("Grok Build's input box doesn't have focus. Go back to it in the terminal, then send again.")
    }
}
