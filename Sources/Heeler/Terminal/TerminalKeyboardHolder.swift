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
/// It is a text view, not a bare `UIKeyInput`, so it presents the keyboard
/// the terminal will present: a keyboard with a candidate row (Pinyin on an
/// iPhone, measured at 348pt) keeps that row for any `UITextInput` and drops
/// it for a plain key-input responder (320pt), which made the keyboard dip
/// and grow back within the switch. Its traits are the Shell Terminal's — no
/// autocorrection or prediction — so nothing changes when the terminal takes
/// over.
struct TerminalKeyboardHolderView: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalKeyboardHolder {
        TerminalKeyboardHolder()
    }

    func updateUIView(_ uiView: TerminalKeyboardHolder, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: TerminalKeyboardHolder, context: Context
    ) -> CGSize? {
        .zero
    }
}

final class TerminalKeyboardHolder: UITextView {
    init() {
        super.init(frame: .zero, textContainer: nil)
        isScrollEnabled = false
        backgroundColor = .clear
        tintColor = .clear
        isAccessibilityElement = false
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { window != nil }

    // Keys pressed while the terminal is still on its way go nowhere.
    override func insertText(_ text: String) {}
    override func deleteBackward() {}

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        becomeFirstResponder()
    }
}
