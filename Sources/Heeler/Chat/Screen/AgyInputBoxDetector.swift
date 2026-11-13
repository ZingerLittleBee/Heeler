import Foundation

/// Reads Antigravity CLI's input box from a screen (agy 1.5.3), in agy's
/// colors or under `NO_COLOR` (`AgyScreen`). Only an empty box with nothing
/// drawn under it and an idle or running-turn footer reads `.empty`; a
/// mode's hint never counts as typed. Every other state carries the reason
/// Chat holds a message with.
///
/// herdr 0.9.5 reports agy's file edit and file creation dialogs, and its
/// trust prompt at narrow widths, as idle, and Enter there accepts the
/// default answer, so its Blocked check never keeps a message out of them.
/// A dialog draws no box, so a screen that shows one holds.
enum AgyInputBoxDetector {
    static func detect(_ screen: ANSIScreen) -> InputBoxState {
        let agy = AgyScreen(screen)
        if agy.hasExited {
            return .noComposer(String(localized: "Antigravity CLI has exited. Start it again in the terminal first."))
        }
        if let below = agy.below { return .overlay(below) }
        guard let composer = agy.composer else {
            return agy.showsDialog
                ? .dialog(title: nil)
                : .unknown(String(localized: "Heeler can't find Antigravity CLI's input box on screen."))
        }
        if composer.mode == .bash { return .shellMode(composer.draft) }
        if !composer.draft.isEmpty { return .text(composer.draft) }
        if let press = agy.pendingDoublePress {
            // What a paste does to a second press other than an exit's is
            // not known.
            return .disabled(
                String(
                    localized: "Antigravity CLI is waiting for a second key press (\u{201C}\(press)\u{201D}). Finish it in the terminal first.",
                    comment: "Why Chat holds a message: the hint Antigravity CLI shows, such as press ctrl+b again to send command to background"))
        }
        // A footer Chat doesn't know may change what Enter does, such as
        // code search mode's (its strings; not captured) or Vim mode's
        // `-- INSERT --` and `-- VISUAL --` before the hint. Vim's Normal
        // mode draws no badge, so a box in it reads as idle here, and
        // herdr 0.9.5's paste and Enter submitted from it as typed (1.5.3).
        if let hint = agy.footerHint, !AgyScreen.readyHints.contains(hint), !AgyScreen.workingHints.contains(hint) {
            return .overlay(hint)
        }
        return .empty(placeholder: composer.placeholder)
    }
}
