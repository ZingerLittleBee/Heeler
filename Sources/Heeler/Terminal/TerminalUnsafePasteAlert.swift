import GhosttyTerminal
import UIKit

/// Presents the alert for the one clipboard request Heeler can actually
/// receive: text committed by dictation or an IME that carries a newline into a
/// program with bracketed paste off. The package routes newline-carrying text
/// to `ghostty_surface_text`, which lands in its paste path and asks this
/// delegate. `refs #243`
@MainActor
enum TerminalUnsafePasteAlertPresenter {
    /// Presents the alert and returns it, or nil when there was no controller
    /// able to present. Settles `request` exactly once on every path: Allow
    /// responds true, Don't Allow responds false, a missing presenter responds
    /// false immediately, and a presentation that never landed is refused as
    /// soon as the attempt finishes.
    ///
    /// The caller keeps the returned alert weakly rather than tracking a
    /// separate flag. A presenter torn down while the alert is up — a screen
    /// pop dismisses the controllers it presented — answers nothing, so a flag
    /// would stay raised and mute every later paste. The alert's release
    /// releases the request with it, which cancels the paste on its own.
    @discardableResult
    static func present(
        _ request: TerminalClipboardConfirmationRequest,
        from sourceView: UIView
    ) -> UIAlertController? {
        guard let presentingViewController = sourceView.nearestPresentingViewController else {
            request.respond(allow: false)
            return nil
        }

        let alert = UIAlertController(
            title: "Allow unsafe paste?",
            message: TerminalUnsafePasteText.message(for: request.contents),
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "Don't Allow", style: .cancel) { _ in
                request.respond(allow: false)
            })
        alert.addAction(
            UIAlertAction(title: "Allow", style: .default) { _ in
                request.respond(allow: true)
            })
        presentingViewController.present(alert, animated: true) { [weak alert] in
            // Answering is idempotent, so this only speaks when nothing else
            // can: an alert that never attached — its presenter was already
            // presenting something else, or the view left its window — leaves
            // no button to tap, and dropping the request would cancel the
            // paste with no explanation.
            guard let alert, alert.presentingViewController != nil else {
                request.respond(allow: false)
                return
            }
        }
        return alert
    }
}
