import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Hosted stand-ins for the iPad detail column. Settings are injected, so
/// these tests never read `UIDevice` or `UserDefaults.standard`.
@MainActor
@Suite("File diff layout", .serialized, .timeLimit(.minutes(1)))
struct FileDiffLayoutViewTests {
    private static let pairedLabel = "Removed, line 8: old value. Added, line 8: new value"
    private static let removedLabel = "Removed, line 8: old value"
    private static let addedLabel = "Added, line 8: new value"
    private static let contextLabel = "Unchanged, line 9: closing line. No newline at end of file."

    @Test func wideDetailReadsAPairAsRemovedThenAddedAndEnablesTheToggle() async throws {
        let (settings, _, cleanup) = try makeSettings(offersSideBySide: true)
        defer { cleanup() }
        let (controller, window) = try await host(
            patch: Self.pairedPatch(), settings: settings,
            size: CGSize(width: 1376, height: 1032))
        defer { window.isHidden = true }

        var labels = Set<String>()
        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            labels = ChangesViewTests.labels(in: controller)
            return labels.contains(Self.pairedLabel)
        })
        try #require(abs(controller.view.bounds.width - 1376) < 1)
        #expect(labels.contains(Self.contextLabel))
        #expect(!labels.contains(Self.removedLabel))
        #expect(!labels.contains(Self.addedLabel))
        let control = Self.layoutControl(in: controller.view)
        #expect(labels.contains("Side by Side"))
        #expect(control.present)
        #expect(!control.disabled)
        #expect(settings.layout == .sideBySide)
    }

    @Test func narrowDetailStaysUnifiedAndDisablesTheToggle() async throws {
        let (settings, _, cleanup) = try makeSettings(offersSideBySide: true)
        defer { cleanup() }
        let (controller, window) = try await host(
            patch: Self.pairedPatch(), settings: settings,
            size: CGSize(width: 834, height: 1032))
        defer { window.isHidden = true }

        var labels = Set<String>()
        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            labels = ChangesViewTests.labels(in: controller)
            return labels.contains(Self.removedLabel) && labels.contains(Self.addedLabel)
        })
        try #require(abs(controller.view.bounds.width - 834) < 1)
        #expect(!labels.contains(Self.pairedLabel))
        #expect(labels.contains(Self.contextLabel))
        let control = Self.layoutControl(in: controller.view)
        #expect(control.present)
        #expect(control.disabled)
        #expect(settings.layout == .sideBySide)
    }

    @Test func accessibilityTextFallsBackToUnifiedAtTheWideWidth() async throws {
        let (settings, _, cleanup) = try makeSettings(offersSideBySide: true)
        defer { cleanup() }
        let (controller, window) = try await host(
            patch: Self.pairedPatch(), settings: settings,
            size: CGSize(width: 1376, height: 1032), dynamicType: .accessibility1)
        defer { window.isHidden = true }

        var labels = Set<String>()
        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            labels = ChangesViewTests.labels(in: controller)
            return labels.contains(Self.removedLabel) && labels.contains(Self.addedLabel)
        })
        #expect(!labels.contains(Self.pairedLabel))
        let control = Self.layoutControl(in: controller.view)
        #expect(control.present)
        #expect(control.disabled)
    }

    @Test func anIPhoneShowsNoToggle() async throws {
        let (settings, _, cleanup) = try makeSettings(offersSideBySide: false)
        defer { cleanup() }
        let (controller, window) = try await host(
            patch: Self.pairedPatch(), settings: settings,
            size: CGSize(width: 1376, height: 1032))
        defer { window.isHidden = true }

        var labels = Set<String>()
        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            labels = ChangesViewTests.labels(in: controller)
            return labels.contains(Self.removedLabel) && labels.contains(Self.addedLabel)
        })
        #expect(!labels.contains(Self.pairedLabel))
        #expect(!labels.contains("Side by Side"))
        #expect(!labels.contains("Unified"))
        #expect(!labels.contains("Diff Layout"))
        #expect(!Self.layoutControl(in: controller.view).present)
    }

    @Test func choosingUnifiedPersistsForTheNextPresentation() async throws {
        let (settings, defaults, cleanup) = try makeSettings(offersSideBySide: true)
        defer { cleanup() }
        let (controller, window) = try await host(
            patch: Self.pairedPatch(), settings: settings,
            size: CGSize(width: 1376, height: 1032))
        defer { window.isHidden = true }

        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            return ChangesViewTests.labels(in: controller).contains(Self.pairedLabel)
                && Self.chooseUnified(in: controller.view)
        })
        try #require(await ChangesViewTests.eventually {
            let labels = ChangesViewTests.labels(in: controller)
            return labels.contains(Self.removedLabel)
                && labels.contains(Self.addedLabel)
                && !labels.contains(Self.pairedLabel)
        })
        #expect(settings.layout == .unified)
        #expect(DiffLayoutSettings(defaults: defaults, offersSideBySide: true).layout == .unified)
        #expect(DiffLayoutSettings(defaults: defaults, offersSideBySide: false).layout == .unified)
    }

    @Test func aLayoutSwitchKeepsTheTopmostLine() async throws {
        let (settings, _, cleanup) = try makeSettings(offersSideBySide: true)
        defer { cleanup() }
        let (controller, window) = try await host(
            patch: Self.longContextPatch(), settings: settings,
            size: CGSize(width: 1376, height: 1032))
        defer { window.isHidden = true }

        // Stay in the middle of the document. A line near the end cannot sit
        // at the top once a shorter layout clamps the scroll view.
        try #require(await ChangesViewTests.eventually(timeout: .seconds(8)) {
            controller.view.layoutIfNeeded()
            guard let scroll = Self.diffScrollView(in: controller.view) else { return false }
            return scroll.contentSize.height > scroll.bounds.height + 400
        })
        var captured: Int?
        var stable = 0
        var requestedOffsetY: CGFloat?
        let initialScrollSettled = try await ChangesViewTests.eventually(timeout: .seconds(8)) {
            controller.view.layoutIfNeeded()
            guard let scroll = Self.diffScrollView(in: controller.view) else { return false }
            if requestedOffsetY == nil {
                let travel = max(0, scroll.contentSize.height - scroll.bounds.height)
                guard travel > 400 else { return false }
                let y = min(CGFloat(3200), travel * 0.35)
                requestedOffsetY = y
                // An animated offset settles through the scroll view's own
                // delegate, which is what updates `scrollPosition`. A direct
                // write plus a manual delegate call does not.
                scroll.setContentOffset(CGPoint(x: 0, y: y), animated: true)
                return false
            }
            guard let requestedOffsetY,
                !scroll.isDragging, !scroll.isDecelerating,
                abs(scroll.contentOffset.y - requestedOffsetY) < 2
            else {
                return false
            }
            guard let top = Self.topLineID(in: controller.view, viewport: scroll), top >= 40 else {
                stable = 0
                captured = nil
                return false
            }
            if captured == top {
                stable += 1
            } else {
                captured = top
                stable = 1
            }
            return stable >= 3
        }
        let observedScroll = Self.diffScrollView(in: controller.view)
        let observedTop = observedScroll.flatMap { Self.topLineID(in: controller.view, viewport: $0) }
        try #require(
            initialScrollSettled,
            """
            initial scroll target \(String(describing: requestedOffsetY)) actual offset \(String(describing: observedScroll?.contentOffset.y))
            content height \(String(describing: observedScroll?.contentSize.height)) bounds height \(String(describing: observedScroll?.bounds.height))
            top \(String(describing: observedTop)) stable \(stable)
            dragging \(String(describing: observedScroll?.isDragging)) decelerating \(String(describing: observedScroll?.isDecelerating))
            """)
        let expected = try #require(captured)

        settings.select(.unified)
        try await Self.expectTop(expected, in: controller)
        settings.select(.sideBySide)
        try await Self.expectTop(expected, in: controller)
        Self.resize(window, to: CGSize(width: 834, height: 1032))
        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            guard let scroll = Self.diffScrollView(in: controller.view) else { return false }
            return Self.topLineID(in: controller.view, viewport: scroll) == expected
                && Self.layoutControl(in: controller.view).disabled
        })
        Self.resize(window, to: CGSize(width: 1376, height: 1032))
        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            guard let scroll = Self.diffScrollView(in: controller.view) else { return false }
            let control = Self.layoutControl(in: controller.view)
            return Self.topLineID(in: controller.view, viewport: scroll) == expected
                && control.present && !control.disabled
        })
    }

    @Test func pairedRowOffersBothLinesReferenceActions() async throws {
        let (settings, _, cleanup) = try makeSettings(offersSideBySide: true)
        defer { cleanup() }
        let patch = Self.pairedPatch()
        let read = FileDiffViewTests.changesRead()
        var copied: [String] = []
        var inserted: [String] = []
        let changes = ChangesStore(
            directory: { "/home/dev/src/app" },
            read: { _ in read },
            readPatch: { _ in patch })
        changes.copyToPasteboard = { copied.append($0) }
        changes.insertReference = { inserted.append($0) }
        await changes.appear()
        changes.openDiff(FileDiffViewTests.file)
        let store = try #require(changes.fileDiff.current)
        await store.appear()
        defer {
            store.cancel()
            changes.cancel()
        }
        let controller = UIHostingController(
            rootView: AnyView(
                NavigationStack {
                    FileDiffView(store: store)
                }
                .environment(\.diffLayoutSettings, settings)
                .environment(\.changesReferenceActions, ChangesReferenceActions(store: changes))))
        let window = try await makeTestWindow(
            frame: CGRect(origin: .zero, size: CGSize(width: 1376, height: 1032)),
            rootViewController: controller)
        defer { window.isHidden = true }

        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            guard abs(controller.view.bounds.width - 1376) < 1,
                ChangesViewTests.labels(in: controller).contains(Self.pairedLabel),
                let row = Self.lineElement("file-diff-line-0", in: controller.view)
            else { return false }
            let names = Set(row.accessibilityCustomActions?.map(\.name) ?? [])
            return names.contains("Copy Removed Line") && names.contains("Copy Added Line")
        })
        let row = try #require(Self.lineElement("file-diff-line-0", in: controller.view))
        #expect(row.accessibilityLabel == Self.pairedLabel)
        try Self.perform("Copy Removed Line", on: row)
        try Self.perform("Insert Added Line Reference", on: row)
        #expect(copied == ["old value"])
        #expect(inserted == ["untracked.txt:8 "])
    }

    @Test func listChangeNoticeShowsInSideBySide() async throws {
        let (settings, _, cleanup) = try makeSettings(offersSideBySide: true)
        defer { cleanup() }
        let patch = Self.scrollablePairedPatch()
        let listed = FileDiffViewTests.changesRead()
        let store = FileDiffStore(
            file: FileDiffViewTests.file, checkout: listed.changes.checkout, read: { _ in patch })
        await store.appear()
        defer { store.cancel() }
        let controller = UIHostingController(
            rootView: AnyView(
                NavigationStack {
                    FileDiffView(store: store)
                }
                .environment(\.diffLayoutSettings, settings)))
        let window = try await makeTestWindow(
            frame: CGRect(origin: .zero, size: CGSize(width: 1376, height: 1032)),
            rootViewController: controller)
        defer { window.isHidden = true }

        var stable = 0
        try #require(await ChangesViewTests.eventually(timeout: .seconds(8)) {
            controller.view.layoutIfNeeded()
            guard abs(controller.view.bounds.width - 1376) < 1,
                ChangesViewTests.labels(in: controller).contains(Self.pairedLabel),
                let scroll = Self.diffScrollView(in: controller.view),
                let edge = Self.revealedEdge(of: scroll)
            else { return false }
            let travel = max(0, scroll.contentSize.height - scroll.bounds.height)
            guard travel > 200,
                let frame = Self.lineFrame("file-diff-line-0", in: controller.view),
                frame.height > 1
            else { return false }
            // Bring the paired row to the top where the headers above it
            // leave room; at the top of the document, settle for the line
            // there. Landing the row 2 pt above the 4 pt probe keeps the
            // probe inside it at fractional offsets.
            // The top inset under the bars lets the offset go negative; on
            // an iPhone the bars are tall enough that 0 hides the row.
            let top = -scroll.adjustedContentInset.top
            let next = min(max(top, scroll.contentOffset.y + (frame.minY - (edge + 2))), travel)
            if abs(next - scroll.contentOffset.y) < 1 {
                guard Self.topLineID(in: controller.view, viewport: scroll) != nil else {
                    stable = 0
                    return false
                }
                stable += 1
                return stable >= 2
            }
            stable = 0
            scroll.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            return false
        })
        let scroll = try #require(Self.diffScrollView(in: controller.view))
        let beforeLine = try #require(Self.topLineID(in: controller.view, viewport: scroll))

        var changed = FileDiffViewTests.file
        changed.lineCounts = .lines(added: 4, removed: 1)
        store.noteListRefresh(FileDiffViewTests.changesRead(files: [changed]).changes)

        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            let labels = ChangesViewTests.labels(in: controller)
            guard let scroll = Self.diffScrollView(in: controller.view) else { return false }
            return labels.contains(Self.pairedLabel)
                && labels.contains { $0.contains("This file changed since this diff was read.") }
                && labels.contains("Reload")
                && Self.topLineID(in: controller.view, viewport: scroll) == beforeLine
        })
    }

    private func makeSettings(
        offersSideBySide: Bool
    ) throws -> (DiffLayoutSettings, UserDefaults, () -> Void) {
        let name = "hm-diff-layout-view-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let settings = DiffLayoutSettings(defaults: defaults, offersSideBySide: offersSideBySide)
        return (settings, defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private func host(
        patch: FilePatch,
        settings: DiffLayoutSettings,
        size: CGSize,
        dynamicType: DynamicTypeSize = .large
    ) async throws -> (UIHostingController<AnyView>, UIWindow) {
        let store = FileDiffStore(
            file: FileDiffViewTests.file,
            checkout: FileDiffViewTests.changesRead().changes.checkout,
            read: { _ in patch })
        let controller = UIHostingController(
            rootView: AnyView(
                NavigationStack {
                    FileDiffView(store: store)
                }
                .environment(\.diffLayoutSettings, settings)
                .environment(\.dynamicTypeSize, dynamicType)))
        let window = try await makeTestWindow(
            frame: CGRect(origin: .zero, size: size), rootViewController: controller)
        return (controller, window)
    }

    private static func expectTop(_ expected: Int, in controller: UIViewController) async throws {
        var observed: Int?
        var offsetY: CGFloat = 0
        var insetTop: CGFloat = 0
        let matched = try await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            guard let scroll = diffScrollView(in: controller.view) else { return false }
            offsetY = scroll.contentOffset.y
            insetTop = scroll.adjustedContentInset.top
            observed = topLineID(in: controller.view, viewport: scroll)
            return observed == expected
        }
        try #require(
            matched,
            "top line \(String(describing: observed)) expected \(expected) offset \(offsetY) inset \(insetTop)")
    }

    private static func resize(_ window: UIWindow, to size: CGSize) {
        window.frame = CGRect(origin: window.frame.origin, size: size)
        window.rootViewController?.view.frame = window.bounds
        window.layoutIfNeeded()
    }

    /// The paired change stays near the top. Trailing context makes the
    /// document tall enough to put that pair on the readable edge.
    private static func scrollablePairedPatch() -> FilePatch {
        let base = pairedPatch()
        let text = String(repeating: "context ", count: 8)
        let extra = (0..<120).map { index in
            DiffLine(
                id: 100 + index, kind: .context, oldNumber: 20 + index, newNumber: 20 + index,
                text: text)
        }
        let trailing = DiffHunk(
            id: 1, oldStart: 20, oldCount: extra.count, newStart: 20, newCount: extra.count,
            section: "trailing", lines: extra)
        let file = base.files[0]
        return FilePatch(
            files: [
                DiffFile(
                    id: file.id, oldPath: file.oldPath, newPath: file.newPath, summary: file.summary,
                    isBinary: false, hunks: file.hunks + [trailing])
            ], isTruncated: false)
    }

    private static func pairedPatch() -> FilePatch {
        FilePatch(
            files: [
                DiffFile(
                    id: 0, oldPath: "sample.txt", newPath: "sample.txt", summary: nil,
                    isBinary: false,
                    hunks: [
                        DiffHunk(
                            id: 0, oldStart: 8, oldCount: 2, newStart: 8, newCount: 2,
                            section: "updateValue()",
                            lines: [
                                DiffLine(
                                    id: 0, kind: .removed, oldNumber: 8, newNumber: nil,
                                    text: "old value"),
                                DiffLine(
                                    id: 1, kind: .added, oldNumber: nil, newNumber: 8,
                                    text: "new value"),
                                DiffLine(
                                    id: 2, kind: .context, oldNumber: 9, newNumber: 9,
                                    text: "closing line", missingNewline: true),
                            ])
                    ])
            ], isTruncated: false)
    }

    /// Context rows use the same id in both layouts, and the line is long
    /// enough to wrap in a column but not across the full 1376 pt width.
    private static func longContextPatch(count: Int = 600) -> FilePatch {
        let text = String(repeating: "context ", count: 15)
        let lines = (0..<count).map { index in
            DiffLine(
                id: index, kind: .context, oldNumber: index + 1, newNumber: index + 1,
                text: text)
        }
        return FilePatch(
            files: [
                DiffFile(
                    id: 0, oldPath: "large.txt", newPath: "large.txt", summary: nil,
                    isBinary: false,
                    hunks: [
                        DiffHunk(
                            id: 0, oldStart: 1, oldCount: count, newStart: 1, newCount: count,
                            section: "wrapped context", lines: lines)
                    ])
            ], isTruncated: false)
    }

    private struct LayoutControl {
        var sawIdentifier = false
        var identifierDisabled = false
        var segments = 0
        var disabledSegments = 0

        var present: Bool { sawIdentifier || segments > 0 }
        var disabled: Bool {
            if identifierDisabled { return true }
            return segments > 0 && disabledSegments == segments
        }
    }

    private static func layoutControl(in root: UIView) -> LayoutControl {
        var control = LayoutControl()
        visit(root.window ?? root) { node in
            let label = node.accessibilityLabel
            let identifier = accessibilityIdentifier(of: node)
            if identifier == "diff-layout-picker" || label == "Diff Layout" {
                control.sawIdentifier = true
                if isDisabled(node) { control.identifierDisabled = true }
            }
            if label == "Side by Side" || label == "Unified" {
                control.segments += 1
                if isDisabled(node) { control.disabledSegments += 1 }
            }
        }
        return control
    }

    private static func chooseUnified(in root: UIView) -> Bool {
        if ChangesViewTests.activate("Unified", in: root) { return true }
        var chosen = false
        visit(root.window ?? root) { node in
            guard !chosen, let control = node as? UISegmentedControl else { return }
            for index in 0..<control.numberOfSegments where control.titleForSegment(at: index) == "Unified" {
                control.selectedSegmentIndex = index
                control.sendActions(for: .valueChanged)
                chosen = true
            }
        }
        return chosen
    }

    /// Screen y of the first point below the navigation chrome. The scroll
    /// view's bounds run under that bar; `adjustedContentInset` (or the safe
    /// area, when the inset is not applied yet) is the readable edge.
    private static func revealedEdge(of scroll: UIScrollView) -> CGFloat? {
        let viewport = UIAccessibility.convertToScreenCoordinates(scroll.bounds, in: scroll)
        guard !viewport.isNull, !viewport.isEmpty else { return nil }
        let chrome = max(scroll.adjustedContentInset.top, scroll.safeAreaInsets.top)
        return viewport.minY + chrome
    }

    private static func lineFrame(_ identifier: String, in root: UIView) -> CGRect? {
        var frame: CGRect?
        visit(root.window ?? root) { node in
            guard frame == nil, accessibilityIdentifier(of: node) == identifier else { return }
            let candidate = node.accessibilityFrame
            guard !candidate.isNull, !candidate.isEmpty, candidate.height > 1 else { return }
            frame = candidate
        }
        return frame
    }

    private static func topLineID(in root: UIView, viewport scroll: UIScrollView) -> Int? {
        let viewport = UIAccessibility.convertToScreenCoordinates(scroll.bounds, in: scroll)
        guard let edge = revealedEdge(of: scroll) else { return nil }
        let probe = CGPoint(x: viewport.midX, y: edge + 4)
        var best: (id: Int, minY: CGFloat)?
        visit(root.window ?? root) { node in
            guard let identifier = accessibilityIdentifier(of: node),
                identifier.hasPrefix("file-diff-line-"),
                let id = Int(identifier.dropFirst("file-diff-line-".count))
            else { return }
            let frame = node.accessibilityFrame
            guard frame.contains(probe) else { return }
            if best == nil || frame.minY < best!.minY {
                best = (id, frame.minY)
            }
        }
        return best?.id
    }

    private static func diffScrollView(in root: UIView) -> UIScrollView? {
        var scrolls: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView { scrolls.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        if let identified = scrolls.first(where: { $0.accessibilityIdentifier == "file-diff-scroll" }) {
            return identified
        }
        return scrolls.max { $0.contentSize.height < $1.contentSize.height }
    }

    private static func isDisabled(_ node: NSObject) -> Bool {
        if node.accessibilityTraits.contains(.notEnabled) { return true }
        if let control = node as? UIControl, !control.isEnabled { return true }
        return false
    }

    private static func accessibilityIdentifier(of node: NSObject) -> String? {
        let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard node.responds(to: getter) else { return nil }
        return node.value(forKey: "accessibilityIdentifier") as? String
    }

    private static func lineElement(_ identifier: String, in root: UIView) -> NSObject? {
        var found: NSObject?
        visit(root.window ?? root) { node in
            guard found == nil,
                accessibilityIdentifier(of: node) == identifier,
                node.accessibilityCustomActions?.isEmpty == false
            else { return }
            found = node
        }
        return found
    }

    private static func perform(_ name: String, on element: NSObject) throws {
        let action = try #require(element.accessibilityCustomActions?.first { $0.name == name })
        if let handler = action.actionHandler {
            #expect(handler(action))
        } else if let target = action.target as? NSObject {
            let selector = action.selector
            try #require(target.responds(to: selector))
            if NSStringFromSelector(selector).contains(":") {
                typealias Action = @convention(c) (NSObject, Selector, UIAccessibilityCustomAction) -> Bool
                let invoke = unsafeBitCast(target.method(for: selector), to: Action.self)
                #expect(invoke(target, selector, action))
            } else {
                typealias Action = @convention(c) (NSObject, Selector) -> Bool
                let invoke = unsafeBitCast(target.method(for: selector), to: Action.self)
                #expect(invoke(target, selector))
            }
        } else {
            Issue.record("action has no handler: \(name)")
        }
    }

    private static func visit(_ root: NSObject, _ body: (NSObject) -> Void) {
        if let view = root as? UIView { view.layoutIfNeeded() }
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted,
                !node.accessibilityElementsHidden
            else { return }
            body(node)
            for child in node.accessibilityElements ?? [] {
                if let child = child as? NSObject { walk(child) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = node.accessibilityElement(at: index) as? NSObject {
                        walk(child)
                    }
                }
            }
            if let view = node as? UIView {
                for child in view.subviews { walk(child) }
            }
        }
        walk(root)
    }
}
