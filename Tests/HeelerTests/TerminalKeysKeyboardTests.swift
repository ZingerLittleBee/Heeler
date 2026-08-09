import Foundation
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Keys keyboard")
struct TerminalKeysKeyboardTests {
    /// An iPhone 17's width, the pane pager's page size in these tests.
    private static let pageWidth: CGFloat = 402

    private func makeContext(
        defaults: UserDefaults,
        skills: TerminalSkillsContext? = nil,
        onManage: @escaping () -> Void = {}
    ) -> TerminalKeysContext {
        TerminalKeysContext(
            settings: TerminalSettings(
                themes: TerminalThemeSettings(defaults: defaults),
                zoom: TerminalZoomSettings(defaults: defaults),
                fonts: TerminalFontSettings(defaults: defaults),
                snippets: SnippetStore(defaults: defaults)),
            skills: skills,
            manageSnippets: onManage)
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-keys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func composerSuppressesTheSystemKeyboardBehindTheToolsDock() throws {
        let textView = AgentComposerUITextView()

        textView.updateKeyboard(presentation: .system)
        #expect(textView.inputView == nil)
        // UIKit owns its candidate and paste area. Adding an accessory here
        // changes the keyboard stack's frame during an in-place replacement.
        #expect(textView.inputAccessoryView == nil)

        textView.updateKeyboard(presentation: .tools)
        let suppressedSystemKeyboard = try #require(
            textView.inputView as? AgentSuppressedSoftKeyboardView)
        #expect(suppressedSystemKeyboard.intrinsicContentSize.height == 0)
        #expect(textView.inputAccessoryView == nil)

        textView.updateKeyboard(presentation: .system)
        #expect(textView.inputView == nil)
        #expect(textView.inputAccessoryView == nil)

        textView.updateKeyboard(presentation: .tools)
        #expect(textView.inputView === suppressedSystemKeyboard)
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

    /// The panes have to be laid out side by side for a swipe to have anything
    /// to drag: a single reused container can only be tapped between.
    @Test func panesArePagedSideBySide() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            keysContext: makeContext(defaults: defaults))
        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)
        keyboard.frame = CGRect(x: 0, y: 0, width: Self.pageWidth, height: 224)
        keyboard.layoutIfNeeded()

        #expect(keyboard.pager.isPagingEnabled)
        #expect(keyboard.pager.contentSize.width == Self.pageWidth * 3)
    }

    @Test func selectingATabScrollsToItsPage() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            keysContext: makeContext(defaults: defaults))
        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)
        keyboard.frame = CGRect(x: 0, y: 0, width: Self.pageWidth, height: 224)
        keyboard.layoutIfNeeded()

        keyboard.select(.appearance)
        #expect(keyboard.pager.contentOffset.x == Self.pageWidth * 2)

        keyboard.returnToControls()
        #expect(keyboard.pager.contentOffset.x == 0)
    }

    /// The offset a drag settles on is the only thing standing between the
    /// gesture and the selection, so pin the mapping rather than the gesture.
    @Test func aSettledOffsetPicksThePaneUnderIt() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            keysContext: makeContext(defaults: defaults))
        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)

        #expect(keyboard.tab(nearestTo: 0, pageWidth: Self.pageWidth) == .controls)
        // Mid-drag, past the halfway point: the tab bar lights the pane the
        // finger is bringing in, not the one it is pushing out.
        #expect(keyboard.tab(nearestTo: 250, pageWidth: Self.pageWidth) == .snippets)
        #expect(keyboard.tab(nearestTo: 804, pageWidth: Self.pageWidth) == .appearance)
        // Rubber-banding past either end, and a pager that has yet to be laid
        // out, must not name a tab that isn't there.
        #expect(keyboard.tab(nearestTo: -60, pageWidth: Self.pageWidth) == .controls)
        #expect(keyboard.tab(nearestTo: 1_100, pageWidth: Self.pageWidth) == nil)
        #expect(keyboard.tab(nearestTo: 0, pageWidth: 0) == nil)
    }

    /// Swiping is only ever offered for the tabs the keyboard was built with.
    @Test func aTerminalWithoutContextHasNothingToSwipeTo() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)
        keyboard.frame = CGRect(x: 0, y: 0, width: Self.pageWidth, height: 224)
        keyboard.layoutIfNeeded()

        #expect(keyboard.pager.contentSize.width == Self.pageWidth)
        #expect(keyboard.tab(nearestTo: Self.pageWidth, pageWidth: Self.pageWidth) == nil)
    }

    /// Skills sits right beside the control keys; Snippets and Appearance
    /// shift over. Without a skills context the old order is untouched.
    @Test func skillsIsTheSecondTabWhenAvailable() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = SkillsPaneStore { _ in [] }
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            keysContext: makeContext(
                defaults: defaults, skills: TerminalSkillsContext(store: store)))
        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)
        keyboard.frame = CGRect(x: 0, y: 0, width: Self.pageWidth, height: 224)
        keyboard.layoutIfNeeded()

        #expect(keyboard.pager.contentSize.width == Self.pageWidth * 4)
        #expect(
            keyboard.tab(nearestTo: Self.pageWidth, pageWidth: Self.pageWidth) == .skills)
        #expect(
            keyboard.tab(nearestTo: Self.pageWidth * 2, pageWidth: Self.pageWidth)
                == .snippets)
    }

    /// The pager builds every pane the moment the keyboard comes up, so the
    /// probe must wait for the one signal that means "the user wants the
    /// list": the Skills tab actually being reached.
    @Test func skillsLoadLazilyOnFirstSelection() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var fetches = 0
        let store = SkillsPaneStore { _ in
            fetches += 1
            return []
        }
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            keysContext: makeContext(
                defaults: defaults, skills: TerminalSkillsContext(store: store)))
        terminal.setKeyboardMode(.controls)
        let keyboard = try #require(terminal.keysKeyboard)
        keyboard.frame = CGRect(x: 0, y: 0, width: Self.pageWidth, height: 224)
        keyboard.layoutIfNeeded()

        // Raising the keyboard built all four panes; none of that may probe.
        for _ in 0..<10 { await Task.yield() }
        #expect(fetches == 0)

        keyboard.select(.skills)
        for _ in 0..<100 where store.phase != .loaded { await Task.yield() }
        #expect(store.phase == .loaded)
        #expect(fetches == 1)

        // Leaving and coming back reuses what is loaded.
        keyboard.returnToControls()
        keyboard.select(.skills)
        for _ in 0..<10 { await Task.yield() }
        #expect(fetches == 1)
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
