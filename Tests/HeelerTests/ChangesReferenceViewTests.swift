import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Changes reference actions", .timeLimit(.minutes(1)))
struct ChangesReferenceViewTests {
    private enum WindowScopeFailure: Error { case expected }

    @Test func failingWindowScopeStillDetachesTheHostingRoot() async throws {
        var failedWindow: UIWindow?
        let controller = UIHostingController(rootView: Text("Cleanup"))
        do {
            try await withTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
            ) { window in
                failedWindow = window
                throw WindowScopeFailure.expected
            }
            Issue.record("the window scope should rethrow its body failure")
        } catch WindowScopeFailure.expected {}
        let window = try #require(failedWindow)
        #expect(window.isHidden)
        #expect(window.rootViewController == nil)
    }

    @Test func fileRowsOfferCopyAndInsertionThroughAccessibility() async throws {
        let (store, file) = try await Self.store()
        var copied: [String] = []
        var inserted: [String] = []
        store.copyToPasteboard = { copied.append($0) }
        store.insertReference = { inserted.append($0) }
        let controller = UIHostingController(rootView: NavigationStack { ChangesView(store: store) })
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try #require(await ChangesViewTests.eventually {
                Self.element(file.rowAccessibilityLabel, in: controller.view) != nil
            })
            let row = try #require(Self.element(file.rowAccessibilityLabel, in: controller.view))
            #expect(Set(row.accessibilityCustomActions?.map(\.name) ?? []) == ["Copy Path", "Insert Path"])
            try Self.perform("Copy Path", on: row)
            try Self.perform("Insert Path", on: row)
            #expect(copied == ["file.swift"])
            #expect(inserted == ["file.swift "])
        }
    }

    @Test func diffRowsExposeLineHunkAndPathActions() async throws {
        let (store, file) = try await Self.store()
        var copied: [String] = []
        var inserted: [String] = []
        store.copyToPasteboard = { copied.append($0) }
        store.insertReference = { inserted.append($0) }
        store.openDiff(file)
        let controller = UIHostingController(rootView: NavigationStack { ChangesView(store: store) })
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try #require(await ChangesViewTests.eventually {
                Self.element("Removed, line 2: old", in: controller.view) != nil
            })
            let row = try #require(Self.element("Removed, line 2: old", in: controller.view))
            #expect(Set(row.accessibilityCustomActions?.map(\.name) ?? []) == [
                "Copy Line", "Copy Hunk", "Copy Path", "Insert Line Reference",
            ])
            try Self.perform("Copy Line", on: row)
            try Self.perform("Copy Hunk", on: row)
            try Self.perform("Copy Path", on: row)
            try Self.perform("Insert Line Reference", on: row)
            #expect(copied == ["old", "@@ -1,3 +1,3 @@\n first\n-old\n+new\n last\n", "file.swift"])
            #expect(inserted == ["file.swift:2 "])

            let header = try #require(Self.element("pkg/file.swift", in: controller.view))
            try Self.perform("Copy Path", on: header)
            let hunk = try #require(Self.element("@@ -1,3 +1,3 @@", in: controller.view))
            try Self.perform("Copy Hunk", on: hunk)
            #expect(copied.suffix(2) == ["file.swift", "@@ -1,3 +1,3 @@\n first\n-old\n+new\n last\n"])
        }
    }

    @Test func qualifiedActionsCanBeCombinedForBothSidesOfAPair() async throws {
        let (store, file) = try await Self.store()
        store.openDiff(file)
        let diff = try #require(store.fileDiff.current)
        await diff.appear()
        guard case .loaded(let patch) = diff.phase else {
            Issue.record("diff did not load")
            return
        }
        let lines = try #require(patch.files.first?.hunks.first?.lines)
        var copied: [String] = []
        var inserted: [String] = []
        store.copyToPasteboard = { copied.append($0) }
        store.insertReference = { inserted.append($0) }
        let controller = UIHostingController(rootView:
            Text("Pair")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pair")
                .diffLineAccessibilityActions(lines[1], qualifier: "Removed")
                .diffLineAccessibilityActions(lines[2], qualifier: "Added")
                .environment(\.changesReferenceActions, ChangesReferenceActions(store: store)))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try #require(await ChangesViewTests.eventually { Self.element("Pair", in: controller.view) != nil })
            let row = try #require(Self.element("Pair", in: controller.view))
            let names = Set(row.accessibilityCustomActions?.map(\.name) ?? [])
            #expect(names.contains("Copy Removed Line"))
            #expect(names.contains("Copy Added Line"))
            try Self.perform("Copy Removed Line", on: row)
            try Self.perform("Insert Added Line Reference", on: row)
            #expect(copied == ["old"])
            #expect(inserted == ["file.swift:2 "])
        }
    }

    @Test func aControlCharacterPathOffersCopyWithoutAnInsertAction() async throws {
        let (store, _) = try await Self.store()
        let file = ChangedFile(
            path: Data("pkg/line\nbreak.swift".utf8), originalPath: nil,
            kind: .modified, staging: .unstaged)
        var copied: [String] = []
        store.copyToPasteboard = { copied.append($0) }
        store.insertReference = { _ in Issue.record("unsafe path was inserted") }
        let controller = UIHostingController(rootView:
            ChangesFileRow(file: file).changedFileReferenceMenu(file, store: store))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try #require(await ChangesViewTests.eventually {
                Self.element(file.rowAccessibilityLabel, in: controller.view) != nil
            })
            let row = try #require(Self.element(file.rowAccessibilityLabel, in: controller.view))
            #expect(Set(row.accessibilityCustomActions?.map(\.name) ?? []) == ["Copy Path"])
            try Self.perform("Copy Path", on: row)
            #expect(copied == ["line\nbreak.swift"])
        }
    }

    @Test(arguments: [false, true])
    func diffLinesKeepCopyActionsWhenInsertionIsUnavailable(unsafePath: Bool) async throws {
        let (store, original) = try await Self.store()
        let file = unsafePath
            ? ChangedFile(
                path: Data("pkg/line\nbreak.swift".utf8), originalPath: nil,
                kind: .modified, staging: .unstaged)
            : original
        var copied: [String] = []
        store.copyToPasteboard = { copied.append($0) }
        if unsafePath {
            store.insertReference = { _ in Issue.record("unsafe path was inserted") }
        }
        store.openDiff(file)
        let controller = UIHostingController(rootView: NavigationStack { ChangesView(store: store) })
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try #require(await ChangesViewTests.eventually {
                Self.element("Removed, line 2: old", in: controller.view) != nil
            })
            let row = try #require(Self.element("Removed, line 2: old", in: controller.view))
            #expect(Set(row.accessibilityCustomActions?.map(\.name) ?? []) == ["Copy Line", "Copy Hunk", "Copy Path"])
            try Self.perform("Copy Line", on: row)
            try Self.perform("Copy Path", on: row)
            #expect(copied == ["old", unsafePath ? "line\nbreak.swift" : "file.swift"])
        }
    }

    @Test func anUnrepresentablePathStillOffersLineAndHunkCopies() async throws {
        let (store, _) = try await Self.store()
        let file = ChangedFile(
            path: Data("pkg/".utf8) + Data([0xFF]), originalPath: nil,
            kind: .modified, staging: .unstaged)
        var copied: [String] = []
        store.copyToPasteboard = { copied.append($0) }
        store.insertReference = { _ in Issue.record("unrepresentable path was inserted") }
        store.openDiff(file)
        let controller = UIHostingController(rootView: NavigationStack { ChangesView(store: store) })
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try #require(await ChangesViewTests.eventually {
                Self.element("Removed, line 2: old", in: controller.view) != nil
            })
            let row = try #require(Self.element("Removed, line 2: old", in: controller.view))
            #expect(Set(row.accessibilityCustomActions?.map(\.name) ?? []) == ["Copy Line", "Copy Hunk"])
            try Self.perform("Copy Line", on: row)
            try Self.perform("Copy Hunk", on: row)
            #expect(copied == ["old", "@@ -1,3 +1,3 @@\n first\n-old\n+new\n last\n"])
        }
    }

    private static func store() async throws -> (ChangesStore, ChangedFile) {
        let source = try ChangesStoreTests.read(GitProbeRecordings.subdir)
        let file = ChangedFile(
            path: Data("pkg/file.swift".utf8), originalPath: nil,
            kind: .modified, staging: .unstaged)
        let read = CheckoutChangesRead(
            changes: CheckoutChanges(checkout: source.changes.checkout, head: source.changes.head, files: [file]),
            directoryPrefix: source.directoryPrefix)
        let patch = FilePatch(files: GitProbe.parsePatchFiles(Data("""
            diff --git a/pkg/file.swift b/pkg/file.swift
            --- a/pkg/file.swift
            +++ b/pkg/file.swift
            @@ -1,3 +1,3 @@
             first
            -old
            +new
             last

            """.utf8), isTruncated: false), isTruncated: false)
        let store = ChangesStore(
            directory: { "/home/dev/src/app/pkg" }, read: { _ in read }, readPatch: { _ in patch })
        await store.appear()
        return (store, file)
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

    private static func element(_ label: String, in root: UIView) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted,
                !node.accessibilityElementsHidden
            else { return nil }
            if node.accessibilityLabel == label, node.accessibilityCustomActions?.isEmpty == false {
                return node
            }
            for child in node.accessibilityElements ?? [] {
                if let child = child as? NSObject, let found = visit(child) { return found }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = node.accessibilityElement(at: index) as? NSObject,
                        let found = visit(child) { return found }
                }
            }
            if let view = node as? UIView {
                for child in view.subviews {
                    if let found = visit(child) { return found }
                }
            }
            return nil
        }
        root.layoutIfNeeded()
        return visit(root.window ?? root)
    }
}
