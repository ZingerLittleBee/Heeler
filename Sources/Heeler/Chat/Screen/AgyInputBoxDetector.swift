import Foundation

/// Reads Antigravity CLI's input box from a screen (agy 1.5.3). Only an
/// empty box with nothing drawn under it reads `.empty`; a mode's grey hint
/// never counts as typed. Every other state carries the reason Chat holds a
/// message with.
///
/// The detector alone keeps a message out of a dialog: herdr 0.9.5 reports
/// agy's file edit and file creation dialogs, and its trust prompt at narrow
/// widths, as idle, and Enter there accepts the default answer. A dialog
/// draws no box, so any screen without one holds.
enum AgyInputBoxDetector {
    static func detect(_ screen: ANSIScreen) -> InputBoxState {
        let agy = AgyScreen(screen)
        if agy.hasExited {
            return .noComposer("Antigravity CLI has exited. Start it again in the terminal first.")
        }
        if let below = agy.below { return .overlay(below) }
        guard let composer = agy.composer else {
            return agy.showsDialog
                ? .dialog(title: nil)
                : .unknown("Heeler can't find Antigravity CLI's input box on screen.")
        }
        if composer.mode == .bash { return .shellMode(composer.draft) }
        if !composer.draft.isEmpty { return .text(composer.draft) }
        if let press = agy.pendingDoublePress {
            // What a paste does to a second press other than an exit's is
            // not known.
            return .disabled(
                "Antigravity CLI is waiting for a second key press (\u{201C}\(press)\u{201D}). Finish it in the terminal first."
            )
        }
        // Code search mode, Vim's badges and anything else agy may set in
        // the footer's place change what Enter does.
        if let hint = agy.footerHint, !AgyScreen.readyHints.contains(hint) { return .overlay(hint) }
        // agy queues a message sent while a turn runs and delivers it when
        // the model next reads input, so a working box is as ready as an
        // idle one.
        return .empty(placeholder: composer.placeholder)
    }
}
