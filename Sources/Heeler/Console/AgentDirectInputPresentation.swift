import CoreGraphics
import Foundation
import Observation

/// Focused Direct Input chrome policy: software-keyboard coverage, shortcut
/// row visibility, keyboard layout, and the Hide/Show accessibility copy the
/// switcher control speaks. Separates Ghostty first-responder intent from the
/// software keyboard footprint so a hardware keyboard cannot leave a stale gap.
///
/// ``layout`` is the single production seam for the Agent detail bottom inset
/// and tools dock height — `AgentTerminalView` consumes it directly.
struct AgentDirectInputPresentation: Equatable, Sendable {
    var keyboardPresentation: AgentComposerKeyboardPresentation
    var showsShortcutRow: Bool
    /// Production bottom inset / tools height. Do not rebuild this beside the view.
    var layout: AgentComposerKeyboardLayout

    /// Software keyboard coverage, with an explicit Tools→iOS pre-show hold so
    /// the 60 ms inset coalesce cannot drop the terminal through `.hidden`.
    /// `expectsSystemKeyboard` is only valid until measured height becomes
    /// positive; after that, height alone drives `.system`. First responder
    /// alone never counts — that is hardware-keyboard territory.
    static func keyboardPresentation(
        usesToolsKeyboard: Bool,
        softwareKeyboardHeight: CGFloat,
        expectsSystemKeyboard: Bool
    ) -> AgentComposerKeyboardPresentation {
        if usesToolsKeyboard { return .tools }
        if softwareKeyboardHeight > 0 || expectsSystemKeyboard { return .system }
        return .hidden
    }

    static func showsShortcutRow(
        presentation: AgentComposerKeyboardPresentation
    ) -> Bool {
        presentation == .system
    }

    static func resolve(
        usesToolsKeyboard: Bool,
        expectsSystemKeyboard: Bool,
        currentHeight: CGFloat,
        lastPresentedHeight: CGFloat
    ) -> AgentDirectInputPresentation {
        let presentation = keyboardPresentation(
            usesToolsKeyboard: usesToolsKeyboard,
            softwareKeyboardHeight: currentHeight,
            expectsSystemKeyboard: expectsSystemKeyboard)
        let layout = AgentComposerKeyboardLayout(
            currentHeight: currentHeight,
            lastPresentedHeight: lastPresentedHeight,
            presentation: presentation)
        return AgentDirectInputPresentation(
            keyboardPresentation: presentation,
            showsShortcutRow: showsShortcutRow(presentation: presentation),
            layout: layout)
    }

    static let hideComposerAccessibilityLabel = "Hide Composer"
    static let hideComposerAccessibilityHint =
        "Hides the Composer and types into the Agent with the iOS keyboard."
    static let showComposerAccessibilityLabel = "Show Composer"
    static let showComposerAccessibilityHint =
        "Restores the Composer. The draft is unchanged."
    /// Source-specific identity for the software-keyboard shortcut-row Escape
    /// control. Distinct from Tools keypad Escape, which shares the spoken
    /// accessibility label but must not carry this identifier.
    static let shortcutRowAccessibilityIdentifier = "direct-input.shortcut-row"
}

/// Survives same-screen terminal pipeline replacement so Direct Input can
/// reclaim a keyboard that was up without raising one that was down. Distinct
/// from ``TerminalKeyboardHandoff``, which carries intent across Agent switches
/// that tear the whole view down.
@MainActor
@Observable
final class DirectInputKeyboardIntent {
    private(set) var wantsKeyboard = false

    func setWantsKeyboard(_ wantsKeyboard: Bool) {
        self.wantsKeyboard = wantsKeyboard
    }
}
