import CoreGraphics
import Foundation
import Observation

/// Focused Direct Input chrome policy: software-keyboard coverage, shortcut
/// row visibility, content inset, and the Hide/Show accessibility copy the
/// switcher control speaks. Separates Ghostty first-responder intent from the
/// software keyboard footprint so a hardware keyboard cannot leave a stale gap.
struct AgentDirectInputPresentation: Equatable, Sendable {
    var keyboardPresentation: AgentComposerKeyboardPresentation
    var showsShortcutRow: Bool
    var contentInset: CGFloat
    var availableToolsHeight: CGFloat

    /// Software keyboard coverage only. Tools mode is independent. First
    /// responder alone never counts — that is hardware-keyboard territory.
    static func keyboardPresentation(
        usesToolsKeyboard: Bool,
        softwareKeyboardHeight: CGFloat
    ) -> AgentComposerKeyboardPresentation {
        if usesToolsKeyboard { return .tools }
        if softwareKeyboardHeight > 0 { return .system }
        return .hidden
    }

    static func showsShortcutRow(
        presentation: AgentComposerKeyboardPresentation
    ) -> Bool {
        presentation == .system
    }

    static func resolve(
        usesToolsKeyboard: Bool,
        currentHeight: CGFloat,
        lastPresentedHeight: CGFloat
    ) -> AgentDirectInputPresentation {
        let presentation = keyboardPresentation(
            usesToolsKeyboard: usesToolsKeyboard,
            softwareKeyboardHeight: currentHeight)
        let layout = AgentComposerKeyboardLayout(
            currentHeight: currentHeight,
            lastPresentedHeight: lastPresentedHeight,
            presentation: presentation)
        return AgentDirectInputPresentation(
            keyboardPresentation: presentation,
            showsShortcutRow: showsShortcutRow(presentation: presentation),
            contentInset: layout.contentInset,
            availableToolsHeight: layout.availableToolsHeight)
    }

    static let hideComposerAccessibilityLabel = "Hide Composer"
    static let hideComposerAccessibilityHint =
        "Hides the Composer and types into the Agent with the iOS keyboard."
    static let showComposerAccessibilityLabel = "Show Composer"
    static let showComposerAccessibilityHint =
        "Restores the Composer. The draft is unchanged."
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
