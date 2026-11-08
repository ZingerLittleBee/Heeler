import Foundation

/// Reads Antigravity CLI's input box from a screen (agy 1.5.3), in agy's
/// colors or under `NO_COLOR` (`AgyScreen`). Only an empty box with nothing
/// drawn under it, an idle footer and no running turn reads `.empty`; a
/// mode's hint never counts as typed. Every other state carries the reason
/// Chat holds a message with.
///
/// herdr 0.9.5 reports agy's file edit and file creation dialogs, and its
/// trust prompt at narrow widths, as idle, and Enter there accepts the
/// default answer, so its Blocked check never keeps a message out of them.
/// A dialog draws no box, so a screen that shows one holds. A running turn
/// holds too: a dialog can open from one at any moment, after a pending
/// tool row such as `○ Running (…)` or straight from a spinner such as
/// `Generating...`, and one that opens between Chat's read and herdr's
/// Enter, written 300 ms after its paste, takes that Enter. What remains
/// is a turn that starts after Chat's read and opens a dialog before
/// herdr's Enter: one sent from another client, or one agy starts itself
/// when a background command it left running ends.
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
        if agy.showsRunningTurn { return .disabled(working) }
        // A footer Chat doesn't know may change what Enter does, such as
        // code search mode's (its strings; not captured) or Vim mode's
        // `-- INSERT --` and `-- VISUAL --` before the hint. Vim's Normal
        // mode draws no badge, so a box in it reads as idle here, and
        // herdr 0.9.5's paste and Enter submitted from it as typed (1.5.3).
        if let hint = agy.footerHint, !AgyScreen.readyHints.contains(hint) { return .overlay(hint) }
        return .empty(placeholder: composer.placeholder)
    }

    /// agy queues a message sent while a turn runs, but herdr's Enter could
    /// answer a dialog that opens first.
    static let working = "Antigravity CLI is working. Send once it's idle, or steer from the terminal."
}
