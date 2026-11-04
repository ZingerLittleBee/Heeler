import Foundation

/// Whether Chat's Stop may press Ctrl+C in Grok Build (ADR 0024), decided
/// on one fresh screen read and herdr's status. Ctrl+C cancels a running
/// turn, but it also clears a draft, cancels a permission, skips a
/// question, and quits Grok Build, at once or on a second press. So Stop
/// presses only while a turn shows on the conversation's own view, with
/// the prompt focused and empty and no second press pending. Every
/// condition must hold; the first that fails says why nothing was pressed.
enum GrokStopGuard {
    static func verdict(_ context: ChatStopContext) -> ChatStopVerdict {
        let grok = GrokScreen(context.screen)
        // A card replaces the composer, and herdr reports it as Blocked a
        // moment after it shows.
        if context.activity == .blocked || grok.card != nil { return .refuse(asking) }
        guard context.activity == .working else { return .refuse(notWorking) }
        // The dashboard's view of an agent passes Ctrl+C to whichever agent
        // it shows, and it stayed until Grok Build restarted (1.0.62, live),
        // so the reason names Ctrl+C in the terminal, not closing the view,
        // unless Ctrl+C there would quit Grok Build or only clear a draft.
        if grok.isDashboardOverlay {
            if let reason = pendingRefusal(grok) { return .refuse(reason) }
            if grok.composer?.draft.isEmpty == false { return .refuse(draft) }
            return .refuse(
                "Grok Build is showing an agent from its dashboard, so Stop pressed nothing. Stop it in the terminal with Ctrl+C."
            )
        }
        // Minimal mode draws no box either.
        let showsConversation = grok.overlay == nil && !grok.isDashboard && !grok.isWelcome
        guard let composer = grok.composer, composer.mode == .prompt, showsConversation else {
            return .refuse(
                "Grok Build is showing a menu or another view, so Stop pressed nothing. Close it in the terminal first.")
        }
        if let reason = pendingRefusal(grok) { return .refuse(reason) }
        // Grok offers the cancel in every pane while a turn runs.
        let offersCancel = grok.footer?.contains("Ctrl+c:cancel") == true
        guard grok.statusRow != nil || offersCancel else { return .refuse(notWorking) }
        // Ghost text is not a draft: with nothing typed, Ctrl+C cancels. A
        // draft's own hints lead the footer and push the focus hints past a
        // phone's 62 columns, so the draft is checked before focus.
        guard composer.draft.isEmpty else { return .refuse(draft) }
        guard grok.promptHasFocus || offersCancel else {
            return .refuse(
                "Grok Build's input box doesn't have focus, so Stop pressed nothing. Stop it in the terminal.")
        }
        return .press
    }

    /// Why Stop presses nothing while Grok Build waits for a second press
    /// or a cancel: Ctrl+C may confirm a pending quit, and while a cancel
    /// is pending it maps to Quit (`app/agent_view/input.rs`).
    private static func pendingRefusal(_ grok: GrokScreen) -> String? {
        if let press = grok.pendingDoublePress {
            return press.contains("press again to quit")
                ? "Grok Build is waiting for a second key press to quit, so Stop pressed nothing."
                : "Grok Build is waiting for a second key press, so Stop pressed nothing."
        }
        return grok.isCancelling ? "Grok Build is already cancelling the turn." : nil
    }

    private static let asking =
        "Grok Build is asking something, so Stop pressed nothing. Answer it in Chat or the terminal."
    private static let notWorking =
        "Heeler can't see Grok Build working, so Stop pressed nothing. Stop it in the terminal with Ctrl+C."
    private static let draft =
        "Grok Build's input box has text, and Ctrl+C would only clear it. Stop it in the terminal."
}
