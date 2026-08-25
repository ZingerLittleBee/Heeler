import Foundation
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Keys keyboard")
struct TerminalKeysKeyboardTests {
    @Test func composerSuppressesTheSystemKeyboardBehindTheToolsDock() throws {
        let textView = AgentComposerUITextView()

        textView.updateKeyboard(presentation: .system)
        #expect(textView.inputView == nil)
        // UIKit owns its candidate and paste area. Adding an accessory here
        // changes the keyboard stack's frame during an in-place replacement.
        #expect(textView.inputAccessoryView == nil)

        textView.updateKeyboard(presentation: .tools)
        let suppressedSystemKeyboard = try #require(
            textView.inputView as? TerminalSuppressedSoftKeyboardView)
        #expect(suppressedSystemKeyboard.intrinsicContentSize.height == 0)
        #expect(textView.inputAccessoryView == nil)

        textView.updateKeyboard(presentation: .system)
        #expect(textView.inputView == nil)
        #expect(textView.inputAccessoryView == nil)

        textView.updateKeyboard(presentation: .tools)
        #expect(textView.inputView === suppressedSystemKeyboard)
    }

    /// The terminal makes the same move the Composer does: Keys mode only
    /// suppresses the software keyboard, and nothing rides the keyboard in
    /// either mode. A real input view here is the regression this replaces —
    /// swapping one tears down the IME's candidate row for good.
    @Test func keysModeSuppressesTheSystemKeyboardInPlace() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: NotificationCenter())
        #expect(terminal.keyboardMode == .text)
        #expect(terminal.inputView == nil)
        #expect(terminal.inputAccessoryView == nil)

        terminal.setKeyboardMode(.controls)
        let suppressed = try #require(
            terminal.inputView as? TerminalSuppressedSoftKeyboardView)
        #expect(suppressed.intrinsicContentSize.height == 0)
        #expect(terminal.inputAccessoryView == nil)
        #expect(terminal.keyboardMode == .controls)

        terminal.setKeyboardMode(.text)
        #expect(terminal.inputView == nil)
        #expect(terminal.keyboardMode == .text)
    }

    @Test func controlPadKeysFireTheClosureWhenTheFingerLifts() throws {
        var sent: [TerminalControlKey] = []
        let pad = TerminalControlPadView { sent.append($0) }
        let escape = try #require(Self.button(labelled: "Escape", in: pad))

        // A key fires on release, not on touch down: the pad's ancestor may
        // claim the gesture, and a swipe that starts on a key must not also
        // send an Esc down the wire.
        escape.sendActions(for: .touchDown)
        #expect(sent.isEmpty)
        escape.sendActions(for: .touchUpInside)
        #expect(sent == [.escape])

        escape.sendActions(for: .touchDown)
        escape.sendActions(for: .touchDragExit)
        #expect(sent == [.escape])
    }

    @Test func controlPadCoversEveryControlKey() {
        let pad = TerminalControlPadView { _ in }
        let labels = Set(Self.buttons(in: pad).compactMap(\.accessibilityLabel))

        #expect(labels == Set(TerminalControlKey.allCases.map(\.accessibilityLabel)))
    }

    /// Skills sits right beside the control keys when the agent has a skills
    /// source; without one the tab does not exist at all.
    @Test func skillsTabAppearsOnlyWithASkillsContext() throws {
        let suiteName = "hm-keys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults))

        let plain = TerminalKeysContext(settings: settings, manageSnippets: {})
        #expect(plain.tabs == [.controls, .snippets, .appearance])

        let withSkills = TerminalKeysContext(
            settings: settings,
            skills: TerminalSkillsContext(store: SkillsPaneStore { _ in [] }),
            manageSnippets: {})
        #expect(withSkills.tabs == [.controls, .skills, .snippets, .appearance])
    }

    /// The in-place swap back to Text passes through a transient will-hide
    /// that zeroes the measured inset while the terminal keeps first
    /// responder. Reading hidden off the height alone tore the input row down
    /// for a frame and let it ride back up with the keyboard.
    @Test func aTransientZeroInsetDoesNotHideTheInputRowMidSwap() {
        // The regression: height dipped to zero mid-swap, responder retained.
        #expect(
            ShellTerminalView.keyboardPresentation(
                mode: .text, insetHeight: 0, keyboardIsUp: true) == .system)

        #expect(
            ShellTerminalView.keyboardPresentation(
                mode: .text, insetHeight: 336, keyboardIsUp: true) == .system)
        // A real dismissal resigns first responder before its will-hide.
        #expect(
            ShellTerminalView.keyboardPresentation(
                mode: .text, insetHeight: 0, keyboardIsUp: false) == .hidden)
        // Keys mode is the tools presentation no matter what the inset says.
        #expect(
            ShellTerminalView.keyboardPresentation(
                mode: .controls, insetHeight: 0, keyboardIsUp: true) == .tools)
    }

    @Test func everyTabHasItsOwnIconAndLabel() {
        let icons = Set(TerminalKeysTab.allCases.map(\.systemImageName))
        let labels = Set(TerminalKeysTab.allCases.map(\.accessibilityLabel))

        #expect(icons.count == TerminalKeysTab.allCases.count)
        #expect(labels.count == TerminalKeysTab.allCases.count)
        for icon in icons {
            #expect(UIImage(systemName: icon) != nil, "missing SF Symbol \(icon)")
        }
    }

    private static func buttons(in view: UIView) -> [UIButton] {
        view.subviews.flatMap { subview -> [UIButton] in
            if let button = subview as? UIButton { return [button] }
            return buttons(in: subview)
        }
    }

    private static func button(labelled label: String, in view: UIView) -> UIButton? {
        buttons(in: view).first { $0.accessibilityLabel == label }
    }
}
