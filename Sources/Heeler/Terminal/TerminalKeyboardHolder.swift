import SwiftUI
import UIKit

/// Keeps the software keyboard up across a screen that has no terminal yet.
///
/// A Shell Terminal reached through the Console is a detail column swap: the
/// Agent's surface leaves the window in one render pass, and the terminal's
/// surface only exists once the connection pool has handed out its entry, a
/// pass or more later. UIKit hides the keyboard the moment a first
/// responder leaves the window, and the arriving surface can then only
/// re-present it after the hide has run — the keyboard visibly drops and
/// rises again. This zero-sized responder takes the keyboard over in the
/// same pass the Agent's surface is removed and holds it until the terminal
/// claims it, which is the same responder-to-responder transfer the Agent
/// screens use between themselves.
///
/// It presents the Shell Terminal's keyboard, not the Agent's: no
/// autocorrection or prediction, so nothing but the frame changes when the
/// terminal takes over.
struct TerminalKeyboardHolderView: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalKeyboardHolder {
        TerminalKeyboardHolder(frame: .zero)
    }

    func updateUIView(_ uiView: TerminalKeyboardHolder, context: Context) {}
}

final class TerminalKeyboardHolder: UIView, UIKeyInput {
    override var canBecomeFirstResponder: Bool { window != nil }

    var hasText: Bool { false }
    func insertText(_ text: String) {}
    func deleteBackward() {}

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        _ = becomeFirstResponder()
    }
}
