import Foundation
import Testing
import UIKit

@testable import HerdrMobile

@MainActor
@Suite("Keys keyboard")
struct TerminalKeysKeyboardTests {
    private func makeContext(
        defaults: UserDefaults,
        onManage: @escaping () -> Void = {}
    ) -> TerminalKeysContext {
        TerminalKeysContext(
            settings: TerminalSettings(
                themes: TerminalThemeSettings(defaults: defaults),
                zoom: TerminalZoomSettings(defaults: defaults),
                fonts: TerminalFontSettings(defaults: defaults),
                snippets: SnippetStore(defaults: defaults)),
            manageSnippets: onManage)
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-keys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func controlKeysAreTheDefaultTab() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            keysContext: makeContext(defaults: defaults))

        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)

        // Keys mode used to be nothing but the control pad; gaining two
        // neighbours must not cost the old behaviour an extra tap.
        #expect(keyboard.selectedTab == .controls)
    }

    @Test func sendingASnippetReturnsToTheControlKeys() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            keysContext: makeContext(defaults: defaults))
        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)

        keyboard.select(.snippets)
        #expect(keyboard.selectedTab == .snippets)

        // Enter lives on the control pad, and a Snippet never brings its own.
        keyboard.returnToControls()
        #expect(keyboard.selectedTab == .controls)
    }

    @Test func aTerminalWithoutContextShowsTheControlKeysAlone() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)

        keyboard.select(.snippets)

        #expect(keyboard.selectedTab == .controls)
    }

    @Test func snippetTapsSendTheBodyWithoutSubmitting() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var sent: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSnippet: { text, _ in sent.append(text) },
            keysContext: makeContext(defaults: defaults))
        let snippet = try Snippet.make(title: "Continue", body: "继续")

        terminal.sendSnippet(snippet)
        #expect(sent == ["继续"])

        terminal.setLocalInputEnabled(false)
        terminal.sendSnippet(snippet)
        #expect(sent == ["继续"])
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
}
