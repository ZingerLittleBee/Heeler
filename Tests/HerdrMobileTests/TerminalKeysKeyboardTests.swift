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

    /// A `UIHostingController` whose view is added to a `UIInputView` without
    /// view-controller containment is the one genuinely uncertain part of this
    /// keyboard: if SwiftUI declined to draw there, both new tabs would come
    /// up blank and nothing else would fail. So render one and look at it.
    @Test func swiftUIPanesActuallyDrawInsideTheInputView() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = SnippetStore(defaults: defaults)
        try store.add(Snippet.make(title: "Continue", body: "继续"))

        let terminal = TerminalScreenView.makeConfiguredTerminal(
            keysContext: TerminalKeysContext(
                settings: TerminalSettings(
                    themes: TerminalThemeSettings(defaults: defaults),
                    zoom: TerminalZoomSettings(defaults: defaults),
                    fonts: TerminalFontSettings(defaults: defaults),
                    snippets: store),
                manageSnippets: {}))
        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)
        keyboard.frame = CGRect(x: 0, y: 0, width: 402, height: 224)

        for tab in [TerminalKeysTab.snippets, .appearance] {
            keyboard.select(tab)
            keyboard.setNeedsLayout()
            keyboard.layoutIfNeeded()

            let renderer = UIGraphicsImageRenderer(bounds: keyboard.bounds)
            let image = renderer.image { _ in
                keyboard.drawHierarchy(in: keyboard.bounds, afterScreenUpdates: true)
            }
            // Measured: 232 for Snippets, 309 for Appearance. A pane that
            // failed to render is one or two colours, so 50 separates them
            // without pinning the exact pixels of a layout that will change.
            let colors = Self.distinctColorCount(in: image)
            #expect(colors > 50, "the \(tab) pane rendered flat (\(colors) colours)")
        }
    }

    /// Samples a coarse grid; a pane that failed to render is one flat colour.
    private static func distinctColorCount(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var seen = Set<UInt32>()
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let i = (y * width + x) * 4
                seen.insert(
                    UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
            }
        }
        return seen.count
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
