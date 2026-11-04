import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The Blocked card as Chat draws it, read through its accessibility
/// elements and its height.
@MainActor
@Suite("Blocked card view", .serialized, .timeLimit(.minutes(1)))
struct BlockedCardViewTests {
    /// Before a subagent starts, Grok Build's card asks `Allow
    /// <description>?`, and the card's title is that question. Where Grok
    /// cut the question at the card's edge, its `?` is gone; either way the
    /// card shows the words once.
    @Test(arguments: [
        ("grok-35-permission-subagent-62", "Allow Sleep 60 then reply done"),
        ("synthetic-subagent-permission-40", "Allow Sleep 60 then reply d…"),
    ])
    func aSubagentsQuestionShowsOnce(stem: String, title: String) async throws {
        let screen = try GrokCards.screen(stem)
        let store = BlockedCardStore(
            program: .grok, io: BlockedScreenIO(readScreen: { screen }, sendKeys: { _ in }, paste: { _ in }),
            clock: ManualClock().clock)
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.title == title)

        let labels = try await Self.labels(
            of: BlockedCardView(store: store, maxHeight: 600, openTerminal: {}), showing: title)

        #expect(labels.filter { $0 == title || $0 == "\(title)?" } == [title], "\(labels)")
    }

    /// A subagent's question titles its card with every line it wraps to:
    /// at a phone's width a fourth line adds as much height as a third. A
    /// second adds less, since a one-line header is as tall as its
    /// Minimize button. A title that isn't the card's own question, here a
    /// tool's name too long for two lines, stops at its second.
    @Test func aSubagentsQuestionShowsEveryLine() async throws {
        var heights: [CGFloat] = []
        for count in 1...4 {
            heights.append(try await Self.height(asking: Self.subagentQuestion(lines: count), sendsOnce: true))
        }
        let second = heights[1] - heights[0]
        let line = heights[2] - heights[1]
        #expect(second > 0, "a second line should show: \(heights)")
        #expect(line > 8, "a third line should add one to the title: \(heights)")
        #expect(
            abs(heights[3] - heights[2] - line) < 1, "the title should show its fourth line as its third: \(heights)")

        let tool = String(repeating: "LongToolName", count: 8)
        let short = try await Self.height(asking: "Allow Edit to notes.txt?", sendsOnce: false)
        let long = try await Self.height(asking: "Allow \(tool) to notes.txt?", sendsOnce: false)
        #expect(abs(long - short - second) < 1, "a tool's title should stop at its second line: \([short, long])")
    }

    /// A keyboard in another field can leave less room than the card's
    /// preferred content budget. Every answer must still scroll into view.
    @Test func permissionAnswersRemainReachableAboveAnotherFieldsKeyboard() async throws {
        try await Self.checkAnswers(
            stem: "grok-37-permission-command-62", size: CGSize(width: 944, height: 280),
            textSize: .accessibility3, answers: ["Yes, proceed", "No, reject (type to add feedback)"])
    }

    @Test(arguments: [DynamicTypeSize.xxxLarge, .accessibility3])
    func permissionAndForkAnswersRemainReachableInBothOrientations(textSize: DynamicTypeSize) async throws {
        for size in [CGSize(width: 944, height: 280), CGSize(width: 608, height: 500)] {
            try await Self.checkAnswers(
                stem: "grok-37-permission-command-62", size: size, textSize: textSize,
                answers: ["Yes, proceed", "No, reject (type to add feedback)"])
            try await Self.checkAnswers(
                stem: "grok-38-fork-question-62", size: size, textSize: textSize, answers: ["Yes", "No"])
        }
    }

    /// A trust screen's folder and warning fill a phone's share of the
    /// screen, and its answers stay in view below them as the card opens,
    /// above another field's keyboard in the largest text too.
    @Test(arguments: [
        ("codex-21-x8-phone-trust", ["Trust and continue", "Quit"]),
        ("claude-00-trust", ["Yes, I trust this folder", "No, exit"]),
    ])
    func trustAnswersShowWithoutScrolling(stem: String, answers: [String]) async throws {
        let screen = try ScreenFixture.screen(stem)
        let store = BlockedCardStore(
            program: ScreenFixture.program(stem),
            io: BlockedScreenIO(readScreen: { screen }, sendKeys: { _ in }, paste: { _ in }),
            clock: ManualClock().clock)
        store.update(activity: .blocked)
        await store.refresh()
        let layouts: [(CGSize, DynamicTypeSize, CGFloat)] = [
            (CGSize(width: Self.phoneWidth, height: 812), .large, 220),
            // Too narrow for one row: the answers stack.
            (CGSize(width: Self.phoneWidth, height: 812), .accessibility3, 400),
            (CGSize(width: 944, height: 280), .accessibility3, 400),
        ]
        for (size, textSize, budget) in layouts {
            let controller = UIHostingController(
                rootView: BlockedCardView(store: store, maxHeight: budget, openTerminal: {})
                    .environment(\.dynamicTypeSize, textSize))
            controller.safeAreaRegions = []
            try await withTestWindow(
                frame: CGRect(origin: .zero, size: size), rootViewController: controller
            ) { _ in
                var shown: [CGRect] = []
                var previous: [CGRect] = []
                for _ in 0..<40 {
                    controller.view.layoutIfNeeded()
                    shown = Self.elements(in: controller.view).filter {
                        $0.accessibilityTraits.contains(.button) && answers.contains($0.accessibilityLabel ?? "")
                    }.map(\.accessibilityFrame)
                    if shown.count == answers.count, shown == previous { break }
                    previous = shown
                    try await Task.sleep(for: .milliseconds(50))
                }
                // The card sits centered in the window; an answer outside it
                // is one its text scrolled out of view.
                let height = controller.sizeThatFits(in: size).height
                let bounds = UIAccessibility.convertToScreenCoordinates(
                    CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height), in: controller.view)
                let visible = UIAccessibility.convertToScreenCoordinates(controller.view.bounds, in: controller.view)
                #expect(shown.count == answers.count, "\(stem), \(size): \(shown)")
                for frame in shown {
                    #expect(
                        !frame.isEmpty && bounds.intersection(visible).insetBy(dx: -1, dy: -1).contains(frame),
                        "\(stem), \(size), \(textSize): \(frame) should show in \(bounds)")
                }
            }
        }
    }

    // MARK: Helpers

    private static func checkAnswers(
        stem: String, size: CGSize, textSize: DynamicTypeSize, answers: [String]
    ) async throws {
        let screen = try GrokCards.screen(stem)
        let store = BlockedCardStore(
            program: .grok, io: BlockedScreenIO(readScreen: { screen }, sendKeys: { _ in }, paste: { _ in }),
            clock: ManualClock().clock)
        store.update(activity: .blocked)
        await store.refresh()
        let controller = UIHostingController(
            rootView: BlockedCardView(store: store, maxHeight: 400, openTerminal: {})
                .environment(\.dynamicTypeSize, textSize))
        controller.safeAreaRegions = []
        try await withTestWindow(
            frame: CGRect(origin: .zero, size: size), rootViewController: controller
        ) { _ in
            var foundScroll: UIScrollView?
            var previousGeometry: [CGFloat] = []
            var stablePasses = 0
            for _ in 0..<40 {
                controller.view.layoutIfNeeded()
                foundScroll = Self.scrollView(in: controller.view)
                if let scroll = foundScroll, scroll.contentSize.height > 1, scroll.bounds.height > 1 {
                    let geometry = [scroll.contentSize.height, scroll.bounds.height, scroll.frame.minY]
                    stablePasses = geometry == previousGeometry ? stablePasses + 1 : 0
                    previousGeometry = geometry
                    if stablePasses >= 2 { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(stablePasses >= 2, "The card must finish laying out before measuring its answers")
            let scroll = try #require(foundScroll)
            let visible = UIAccessibility.convertToScreenCoordinates(controller.view.bounds, in: controller.view)
            let viewport = UIAccessibility.convertToScreenCoordinates(scroll.bounds, in: scroll)
            #expect(visible.insetBy(dx: -1, dy: -1).contains(viewport),
                "The scroll viewport must fit above the keyboard: visible=\(visible), viewport=\(viewport)")
            let bottom = max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            let buttons = Self.elements(in: controller.view).filter {
                guard $0.accessibilityTraits.contains(.button), let label = $0.accessibilityLabel else { return false }
                return answers.contains { label == $0 || label.hasPrefix($0 + ", ") }
            }
            #expect(buttons.count == answers.count, "Expected \(answers), found \(buttons.map(\.accessibilityLabel))")
            for button in buttons {
                // Long answer captions need not fit together. Each answer
                // must fit after scrolling to it within the legal range.
                let label = try #require(button.accessibilityLabel)
                let offset = scroll.contentOffset.y + button.accessibilityFrame.minY - viewport.minY
                scroll.setContentOffset(
                    CGPoint(x: 0, y: min(bottom, max(-scroll.adjustedContentInset.top, offset))), animated: false)
                try await Task.sleep(for: .milliseconds(50))
                controller.view.layoutIfNeeded()
                let shown = try #require(Self.elements(in: controller.view).first {
                    $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label
                })
                #expect(!shown.accessibilityFrame.isEmpty)
                #expect(visible.intersection(viewport).insetBy(dx: -1, dy: -1).contains(shown.accessibilityFrame),
                    "\(stem), \(size), \(textSize): \(label) must be fully reachable: \(shown.accessibilityFrame)")
            }
        }
    }

    private static func scrollView(in root: UIView) -> UIScrollView? {
        if let scroll = root as? UIScrollView { return scroll }
        return root.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    /// The narrowest iPhone's width, where a title wraps to the most lines.
    private static let phoneWidth: CGFloat = 375

    /// A subagent's question that wraps to `count` lines at `phoneWidth` in
    /// the default text size: each word after `Allow` is too wide to share
    /// its line.
    private static func subagentQuestion(lines count: Int) -> String {
        "Allow " + (1...count).map { "Line\($0)OfTheQuestionText" }.joined(separator: " ") + "?"
    }

    /// The height at `phoneWidth`, in the default text size, of a Grok
    /// Build permission's card asking `question`: before a subagent starts
    /// when `sendsOnce`, as grok-35 does, else before a tool runs.
    private static func height(asking question: String, sendsOnce: Bool) async throws -> CGFloat {
        let labels = [
            "Yes, and don't ask again for anything (always-approve mode)", sendsOnce ? "Yes, send once" : "Yes",
            "No, reject (type to add feedback)",
        ]
        let screen = GrokCardBuilder(
            columns: 160, status: sendsOnce ? "Waiting for subagent…" : nil,
            rows: [GrokCardBuilder.Row("›  \(question)", boldFrom: 3), .blank]
                + labels.enumerated().map { offset, label in
                    GrokCardBuilder.Row.option(
                        "\(offset + 1) (\(offset == 1 ? "●" : "○")) \(label)", cursor: offset == 1)
                },
            hints: ["1/3:select", "Tab:next option", "Ctrl+o:always-approve", "Ctrl+c:cancel", "Esc:scrollback"]
        ).screen
        let dialog = try #require(GrokDialogParser.parse(screen).dialog)
        try #require(dialog.body.first == question && dialog.asksInTitle == sendsOnce, "\(dialog)")
        let store = BlockedCardStore(
            program: .grok, io: BlockedScreenIO(readScreen: { screen }, sendKeys: { _ in }, paste: { _ in }),
            clock: ManualClock().clock)
        store.update(activity: .blocked)
        await store.refresh()
        try #require(store.content == .card(BlockedCard(dialog: dialog, request: nil)))
        let controller = UIHostingController(rootView: BlockedCardView(store: store, maxHeight: 600, openTerminal: {}))
        controller.safeAreaRegions = []
        controller.traitOverrides.preferredContentSizeCategory = .large
        var height: CGFloat = 0
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: phoneWidth, height: 812), rootViewController: controller
        ) { _ in
            controller.view.layoutIfNeeded()
            height = controller.sizeThatFits(in: CGSize(width: phoneWidth, height: .greatestFiniteMagnitude)).height
        }
        return height
    }

    /// The accessibility labels `view` shows at a phone's width, once one
    /// reads `expected`.
    private static func labels(of view: some View, showing expected: String) async throws -> [String] {
        let controller = UIHostingController(rootView: view)
        var labels: [String] = []
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: phoneWidth, height: 812), rootViewController: controller
        ) { _ in
            for attempt in 0..<40 {
                controller.view.layoutIfNeeded()
                labels = Self.labels(in: controller.view)
                if labels.contains(expected) { return }
                if attempt < 39 { try await Task.sleep(for: .milliseconds(50)) }
            }
        }
        return labels
    }

    /// Every accessibility label under `root`. SwiftUI containers can
    /// expose an empty or incomplete array while their indexed
    /// accessibility API owns the live elements.
    private static func labels(in root: UIView) -> [String] {
        elements(in: root).compactMap(\.accessibilityLabel).filter { !$0.isEmpty }
    }

    private static func elements(in root: UIView) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var elements: [NSObject] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            elements.append(node)
            for element in node.accessibilityElements ?? [] {
                if let object = element as? NSObject { visit(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject { visit(object) }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews { visit(subview) }
            }
        }
        visit(root)
        return elements
    }
}
