import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("File diff view", .timeLimit(.minutes(1)))
struct FileDiffViewTests {
    @Test func openingAnUntrackedFileAndGoingBackThroughTheSystemBackKeepsTheList() async throws {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([.success(Self.changesRead())])
        await transport.scriptFilePatchReads([.success(Self.patch())])
        let store = Self.store(transport: transport)
        let controller = UIHostingController(
            rootView: NavigationStack { ChangesView(store: store) })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }

        try #require(await ChangesViewTests.eventually {
            ChangesViewTests.activate("untracked.txt, untracked", in: controller.view)
        })
        try #require(await ChangesViewTests.eventually {
            ChangesViewTests.labels(in: controller).contains("Added, line 1: new content")
                && ChangesViewTests.isSettled(controller)
        })
        #expect(!ChangesViewTests.labels(in: controller).contains("untracked.txt, untracked"))
        #expect(await transport.filePatchRequests.count == 1)

        try #require(ChangesViewTests.goBack(in: controller))
        try #require(await ChangesViewTests.eventually {
            ChangesViewTests.isSettled(controller)
                && !ChangesViewTests.labels(in: controller).contains("Added, line 1: new content")
        })
        #expect(ChangesViewTests.labels(in: controller).contains("untracked.txt, untracked"))
        #expect(store.fileDiff.current == nil)
        #expect(await transport.changesReadRequests.count == 1)
    }

    @Test func allLineKindsAndTheMissingNewlineReadAtAccessibilityTextSizes() async throws {
        let lines = [
            DiffLine(id: 0, kind: .removed, oldNumber: 8, newNumber: nil, text: "old value"),
            DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 8, text: "new value"),
            DiffLine(
                id: 2, kind: .context, oldNumber: 9, newNumber: 9, text: "closing line",
                missingNewline: true),
        ]
        let patch = FilePatch(
            files: [
                DiffFile(
                    id: 0, oldPath: "sample.txt", newPath: "sample.txt", summary: nil,
                    isBinary: false,
                    hunks: [
                        DiffHunk(
                            id: 0, oldStart: 8, oldCount: 2, newStart: 8, newCount: 2,
                            section: "updateValue()", lines: lines)
                    ])
            ], isTruncated: false)
        let store = FileDiffStore(
            file: Self.file, checkout: Self.changesRead().changes.checkout, read: { _ in patch })
        let controller = UIHostingController(
            rootView: FileDiffView(store: store)
                .environment(\.dynamicTypeSize, .accessibility1)
                .environment(\.colorScheme, .dark))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 1200),
            rootViewController: controller)
        defer { window.isHidden = true }

        var labels = Set<String>()
        try #require(await ChangesViewTests.eventually {
            labels = ChangesViewTests.labels(in: controller)
            return labels.contains("Unchanged, line 9: closing line. No newline at end of file.")
        })
        #expect(labels.contains("Removed, line 8: old value"))
        #expect(labels.contains("Added, line 8: new value"))
        #expect(labels.contains("@@ -8,2 +8,2 @@ updateValue()"))
    }

    @Test func loadMoreTurnsIntoTheModelsTooLargeFooter() async throws {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([.success(Self.changesRead())])
        await transport.scriptFilePatchReads([
            .success(Self.patch(isTruncated: true)), .success(Self.patch(isTruncated: true)),
        ])
        let changes = Self.store(transport: transport)
        await changes.appear()
        changes.openDiff(Self.file)
        let diff = try #require(changes.fileDiff.current)
        let controller = UIHostingController(rootView: FileDiffView(store: diff))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }

        try #require(await ChangesViewTests.eventually {
            ChangesViewTests.activate("Load More", in: controller.view)
        })
        try #expect(await ChangesViewTests.eventually {
            ChangesViewTests.labels(in: controller).contains(diff.tooLargeMessage)
        })
        #expect(!ChangesViewTests.labels(in: controller).contains("Load More"))
        #expect(await transport.changesReadRequests.count == 1)
    }

    @Test func anUntrackedDirectoryRemainsOnTheFileList() async throws {
        let directory = ChangedFile(
            path: Data("newdir/".utf8), originalPath: nil, kind: .untracked, staging: nil)
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([.success(Self.changesRead(files: [directory]))])
        let store = Self.store(transport: transport)
        let controller = UIHostingController(rootView: ChangesView(store: store))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await ChangesViewTests.eventually {
            ChangesViewTests.labels(in: controller).contains("newdir/, untracked")
        })
        // A later directory-expansion feature can make this row actionable;
        // it must still never request a patch for the directory itself.
        _ = ChangesViewTests.activate("newdir/, untracked", in: controller.view)
        #expect(store.fileDiff.current == nil)
        #expect(await transport.filePatchRequests.isEmpty)
    }

    @Test func aFailedRefreshKeepsTheReadableDiffBesideItsError() async throws {
        let transport = ScriptedTransport()
        await transport.scriptFilePatchReads([
            .success(Self.patch()), .failure(ChangesReadError.gitFailed("file moved during read")),
        ])
        let store = FileDiffStore(
            file: Self.file, checkout: Self.changesRead().changes.checkout,
            read: { try await transport.readFilePatch($0) })
        let controller = UIHostingController(rootView: FileDiffView(store: store))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await ChangesViewTests.eventually {
            ChangesViewTests.labels(in: controller).contains("Added, line 1: new content")
        })

        await store.refresh()

        try #require(await ChangesViewTests.eventually {
            ChangesViewTests.labels(in: controller).contains("file moved during read")
        })
        #expect(ChangesViewTests.labels(in: controller).contains("Added, line 1: new content"))
    }

    /// Signs and line numbers sit on the line's and the gutter's washes;
    /// code in the label colour sits on the line's and a changed word's.
    /// Both palettes, as Differentiate Without Color switches between them.
    @Test func diffInksHaveReadableContrastInLightAndDarkMode() {
        for (name, palette) in [("GitHub", DiffPalette.github), ("blue and mauve", .blueMauve)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for kind in [DiffLine.Kind.added, .removed] {
                    guard let change = palette.change(kind) else {
                        Issue.record("\(name) has no \(kind) colours")
                        continue
                    }
                    let pairs: [(String, UIColor, UIColor)] = [
                        ("ink on line", change.ink, change.line),
                        ("ink on gutter", change.ink, change.gutter),
                        ("code on line", palette.code, change.line),
                        ("code on word", palette.code, change.word),
                    ]
                    for (pair, foreground, background) in pairs {
                        let contrast = Self.contrast(foreground, on: background, style: style)
                        #expect(
                            contrast >= 4.5,
                            "\(name) \(kind) \(pair) in \(style) has contrast \(contrast)")
                    }
                }
                for (pair, foreground) in [
                    ("context numbers", palette.contextNumber), ("code", palette.code),
                ] {
                    let contrast = Self.contrast(foreground, on: DiffSurface.system.background, style: style)
                    #expect(contrast >= 4.5, "\(pair) in \(style) has contrast \(contrast)")
                }
                let band = Self.contrast(DiffSurface.system.secondaryText, on: DiffSurface.system.hunkBand, style: style)
                #expect(band >= 4.5, "hunk band in \(style) has contrast \(band)")
            }
        }
    }

    @Test func differentiateWithoutColorSwitchesToBlueAndMauve() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        func hex(_ color: UIColor) -> String {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: dark).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(
                format: "%02X%02X%02X", Int(round(red * 255)), Int(round(green * 255)),
                Int(round(blue * 255)))
        }
        #expect(hex(DiffPalette.current(differentiatingWithoutColor: false, on: .system).added.ink) == "3FB950")
        #expect(hex(DiffPalette.current(differentiatingWithoutColor: true, on: .system).added.ink) == "9ECDFB")
        #expect(hex(DiffPalette.current(differentiatingWithoutColor: true, on: .system).removed.ink) == "F1B5D8")
    }

    /// Composites a translucent foreground over its background before
    /// comparing, as the screen does.
    static func contrast(
        _ foreground: UIColor, on background: UIColor, style: UIUserInterfaceStyle
    ) -> CGFloat {
        let traits = UITraitCollection(userInterfaceStyle: style)
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        foreground.resolvedColor(with: traits).getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        background.resolvedColor(with: traits).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let composite = UIColor(
            red: fr * fa + br * (1 - fa), green: fg * fa + bg * (1 - fa),
            blue: fb * fa + bb * (1 - fa), alpha: 1)
        let front = luminance(composite, style: style)
        let back = luminance(background, style: style)
        return (max(front, back) + 0.05) / (min(front, back) + 0.05)
    }

    private static func luminance(_ color: UIColor, style: UIUserInterfaceStyle) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let linear = [red, green, blue].map { value in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    static func store(transport: ScriptedTransport) -> ChangesStore {
        ChangesStore(
            directory: { "/home/dev/src/app" },
            read: { try await transport.readChanges($0) },
            readPatch: { try await transport.readFilePatch($0) })
    }

    static func changesRead(files: [ChangedFile] = [file]) -> CheckoutChangesRead {
        CheckoutChangesRead(
            changes: CheckoutChanges(
                checkout: CheckoutLocation(
                    topLevel: Data("/home/dev/src/app".utf8),
                    isLinkedWorktree: false, displayPath: "~/src/app"),
                head: CheckoutHead(branch: .named("main"), commit: nil, latestCommit: nil),
                files: files),
            directoryPrefix: Data())
    }

    static let file = ChangedFile(
        path: Data("untracked.txt".utf8), originalPath: nil, kind: .untracked, staging: nil)

    static func patch(isTruncated: Bool = false) -> FilePatch {
        FilePatch(
            files: [
                DiffFile(
                    id: 0, oldPath: nil, newPath: "untracked.txt", summary: nil,
                    isBinary: false,
                    hunks: [
                        DiffHunk(
                            id: 0, oldStart: 0, oldCount: 0, newStart: 1, newCount: 1,
                            section: "new section",
                            lines: [
                                DiffLine(
                                    id: 0, kind: .added, oldNumber: nil, newNumber: 1,
                                    text: "new content", missingNewline: false)
                            ])
                    ])
            ], isTruncated: isTruncated)
    }
}
