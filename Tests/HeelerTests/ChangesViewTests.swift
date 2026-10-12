import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Changes opened in place of Agent detail. The presentation owns the only
/// reference to its store, so closing it discards the content.
@MainActor
@Suite("Changes presentation")
struct AgentChangesPresentationTests {
    @Test func openingMakesOneStoreAndClosingDiscardsIt() {
        var made = 0
        let presentation = AgentChangesPresentation {
            made += 1
            return ChangesStore(directory: { "/home/dev/src/app" }) { _ in
                throw ChangesReadError.unavailable
            }
        }
        #expect(presentation.store == nil)

        presentation.open()
        let first = presentation.store
        presentation.open()
        #expect(first != nil)
        #expect(presentation.store === first)
        #expect(made == 1)

        presentation.close()
        #expect(presentation.store == nil)

        presentation.open()
        #expect(presentation.store !== first)
        #expect(presentation.store?.phase == .loading)
        #expect(made == 2)
    }

    /// Worktree Details and the dirty-removal refusal hand that Worktree's
    /// directory. The Agent menu hands nil, so the next open follows the Agent
    /// again instead of keeping the Worktree path.
    @Test func openingForAWorktreeReadsThatDirectory() async throws {
        let transport = ScriptedTransport()
        var handed: [String?] = []
        let presentation = AgentChangesPresentation(makeStoreIn: { fixed in
            handed.append(fixed)
            return ChangesStore(directory: { fixed ?? "/home/dev/src/app/pkg" }) { request in
                try await transport.readChanges(request)
            }
        })

        presentation.open(directory: "/work/Heeler-wt")
        let store = try #require(presentation.store)
        await store.appear()
        #expect(handed == ["/work/Heeler-wt"])
        #expect(
            await transport.changesReadRequests
                == [ChangesReadRequest(directory: "/work/Heeler-wt")])

        let shown = presentation.store
        presentation.open(directory: "/other")
        #expect(presentation.store === shown)
        #expect(handed == ["/work/Heeler-wt"])

        await store.refresh()
        #expect(
            await transport.changesReadRequests.map(\.directory)
                == ["/work/Heeler-wt", "/work/Heeler-wt"])

        presentation.close()
        #expect(presentation.store == nil)

        presentation.open()
        let followed = try #require(presentation.store)
        await followed.appear()
        #expect(handed == ["/work/Heeler-wt", nil])
        #expect(
            await transport.changesReadRequests.map(\.directory)
                == [
                    "/work/Heeler-wt", "/work/Heeler-wt",
                    "/home/dev/src/app/pkg",
                ])
    }
    @Test func insertingClosesChangesAndHandsTheReferenceBackExactlyOnce() async throws {
        let read = try ChangesStoreTests.read(GitProbeRecordings.subdir)
        let presentation = AgentChangesPresentation {
            ChangesStore(directory: { "/home/dev/src/app/pkg" }) { _ in read }
        }
        presentation.open()
        let store = try #require(presentation.store)
        await store.appear()
        let file = ChangedFile(
            path: Data("pkg/renamed.txt".utf8), originalPath: nil,
            kind: .modified, staging: .unstaged)
        store.insert(file: file)
        #expect(presentation.store == nil)
        #expect(presentation.takePendingInsertion() == "renamed.txt ")
        #expect(presentation.takePendingInsertion() == nil)

        // A departing menu cannot hand another reference to the next view.
        store.insert(file: file)
        #expect(presentation.takePendingInsertion() == nil)
    }

    @Test func worktreeInsertionsStayAbsoluteAndAnOrdinaryBackInsertsNothing() async throws {
        let read = try ChangesStoreTests.read(GitProbeRecordings.subdir)
        let presentation = AgentChangesPresentation(makeStoreIn: { directory in
            ChangesStore(directory: { directory }) { _ in read }
        })
        presentation.open(directory: "/work/other/pkg")
        let store = try #require(presentation.store)
        await store.appear()
        let file = ChangedFile(
            path: Data("pkg/renamed.txt".utf8), originalPath: nil,
            kind: .modified, staging: .unstaged)
        store.insert(file: file)
        #expect(presentation.takePendingInsertion() == "/home/dev/src/app/pkg/renamed.txt ")

        presentation.open()
        presentation.close()
        #expect(presentation.takePendingInsertion() == nil)
    }
}

/// The Changes view hosted in a window, read the way VoiceOver reads it.
@MainActor
@Suite("Changes view", .timeLimit(.minutes(1)))
struct ChangesViewTests {
    @Test func theHeaderIsOneSummaryAndEachRowReadsItsPathAndKind() async throws {
        let (controller, window) = try await Self.host(GitProbeRecordings.hostile)
        defer { window.isHidden = true }

        var labels = Set<String>()
        let loaded = try await Self.eventually {
            labels = Self.labels(in: controller)
            return labels.contains("conflict.txt, conflicted, 4 lines added, 0 lines removed")
        }
        try #require(loaded, "rows never appeared: \(labels.sorted())")

        let header = labels.filter {
            $0.hasPrefix(
                #"Checkout ~/src/app. Branch main. Latest commit: Main edit to "conflict.txt", "#)
        }
        #expect(header.count == 1, "header summary missing: \(labels.sorted())")
        // The summary replaces its fragments rather than repeating them.
        #expect(!labels.contains("~/src/app"))
        #expect(!labels.contains("main"))
        // Rows are lazy, so only the first screenful exists: conflicts
        // first, then by path.
        #expect(labels.contains("conflict.txt, conflicted, 4 lines added, 0 lines removed"))
        #expect(labels.contains("--, modified, unstaged, 1 line added, 0 lines removed"))
        #expect(labels.contains("[ab].txt, modified, unstaged, 1 line added, 0 lines removed"))
        #expect(labels.contains("added.txt, added, staged, 1 line added, 0 lines removed"))
    }

    @Test func aCleanCheckoutSaysSoUnderItsHeader() async throws {
        let (controller, window) = try await Self.host(GitProbeRecordings.clean)
        defer { window.isHidden = true }

        var labels = Set<String>()
        let clean = try await Self.eventually {
            labels = Self.labels(in: controller)
            return labels.contains(ChangesStore.cleanMessage)
        }
        #expect(clean, "clean state missing: \(labels.sorted())")
        #expect(
            labels.contains {
                $0.hasPrefix("Checkout ~/src/clean. Branch main. Latest commit: Clean tree, ")
            })
    }

    /// A staged rename moved on with `git add -N` lists each path once:
    /// the rename, now also deleted from the working tree, and the addition.
    @Test func aMovedStagedRenameShowsItsRenameAndItsAddition() async throws {
        let (controller, window) = try await Self.host(
            GitProbeRecordings.intentToAddMoveAfterStagedRename)
        defer { window.isHidden = true }

        var labels = Set<String>()
        let shown = try await Self.eventually {
            labels = Self.labels(in: controller)
            return labels.contains("b.txt, renamed from a.txt, staged and unstaged")
                && labels.contains("c.txt, added, unstaged")
        }
        #expect(shown, "rows missing: \(labels.sorted())")
    }

    @Test func aDirectoryOutsideAWorkingTreeSaysSo() async throws {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([.failure(ChangesReadError.notAGitWorkingTree)])
        let (controller, window) = try await Self.host(transport: transport)
        defer { window.isHidden = true }

        var labels = Set<String>()
        let shown = try await Self.eventually {
            labels = Self.labels(in: controller)
            return labels.contains("Not a Git Working Tree")
        }
        #expect(shown, "state missing: \(labels.sorted())")
    }

    /// Try Again's read belongs to the view, as the first read does: leaving
    /// Changes cancels it instead of letting it run on for a store nobody
    /// shows.
    @Test func leavingChangesCancelsATryAgainRead() async throws {
        let reads = ReadRecorder()
        let store = ChangesStore(directory: { "/home/dev/src/app" }) { _ in
            if await reads.begin() == 1 { throw ChangesReadError.notAGitWorkingTree }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await reads.markCancelled()
                throw error
            }
            throw ChangesReadError.unavailable
        }
        let controller = UIHostingController(
            rootView: AnyView(NavigationStack { ChangesView(store: store) }))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(
            await Self.eventually {
                Self.labels(in: controller).contains("Not a Git Working Tree")
            })

        try #require(await Self.eventually { Self.activate("Try Again", in: controller.view) })
        try #require(await Self.eventually { await reads.count == 2 })
        controller.rootView = AnyView(Text("Agent detail"))

        let cancelled = try await Self.eventually {
            controller.view.layoutIfNeeded()
            return await reads.wasCancelled
        }
        #expect(cancelled, "the Try Again read outlived Changes")
    }

    private actor ReadRecorder {
        private(set) var count = 0
        private(set) var wasCancelled = false

        func begin() -> Int {
            count += 1
            return count
        }

        func markCancelled() { wasCancelled = true }
    }

    // MARK: Hosting

    static func host(
        _ recording: (stdout: Data, stderr: Data)
    ) async throws -> (UIHostingController<AnyView>, UIWindow) {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([.success(try ChangesStoreTests.read(recording))])
        return try await host(transport: transport)
    }

    static func host(
        transport: ScriptedTransport
    ) async throws -> (UIHostingController<AnyView>, UIWindow) {
        let store = ChangesStore(directory: { "/home/dev/src/app" }) { request in
            try await transport.readChanges(request)
        }
        let controller = UIHostingController(
            rootView: AnyView(NavigationStack { ChangesView(store: store) }))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        return (controller, window)
    }

    static func labels(in controller: UIViewController) -> Set<String> {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view)
    }

    /// The system Back: pops the innermost stack that has pushed a screen,
    /// as its bar button and its swipe both do.
    static func goBack(in controller: UIViewController) -> Bool {
        guard let stack = navigationControllers(in: controller)
            .last(where: { $0.viewControllers.count > 1 && $0.transitionCoordinator == nil })
        else { return false }
        stack.popViewController(animated: true)
        return true
    }

    /// No push or pop is still animating.
    static func isSettled(_ controller: UIViewController) -> Bool {
        isNavigationSettled(controller)
    }

    static func navigationControllers(in root: UIViewController) -> [UINavigationController] {
        (root as? UINavigationController).map { [$0] } ?? []
            + root.children.flatMap { navigationControllers(in: $0) }
    }

    /// Activates the first accessibility element labelled `label`, as
    /// VoiceOver's double tap does; a bar button is a control that takes
    /// the tap itself.
    static func activate(_ label: String, in root: UIView) -> Bool {
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: NSObject) -> Bool {
            guard visited.insert(ObjectIdentifier(node)).inserted,
                !node.accessibilityElementsHidden
            else { return false }
            if node.accessibilityLabel == label {
                if let control = node as? UIControl {
                    control.sendActions(for: .touchUpInside)
                    return true
                }
                if node.accessibilityActivate() { return true }
            }
            for object in node.accessibilityElements ?? [] {
                if let object = object as? NSObject, visit(object) { return true }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject,
                        visit(object)
                    {
                        return true
                    }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews where visit(subview) { return true }
            }
            return false
        }
        root.layoutIfNeeded()
        return visit(root.window ?? root)
    }

    static func eventually(
        timeout: Duration = .seconds(5),
        _ condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

/// Changes pushed over a hosted Agent detail: the system's Back brings the
/// same Agent detail back with its draft and input mode.
@MainActor
@Suite("Agent detail Changes", .timeLimit(.minutes(1)))
struct AgentDetailChangesTests {
    @Test(arguments: [AgentInputMode.composer, .direct])
    func backRestoresAgentDetailWithTheDraftAndInputModeUntouched(
        mode: AgentInputMode
    ) async throws {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([
            .success(try ChangesStoreTests.read(GitProbeRecordings.hostile))
        ])
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        composer.replaceDraft(with: "keep this draft")
        let attach = try await Self.makeLiveAttach(transport: transport)
        let suiteName = "changes-detail-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let inputMode = AgentInputModeSettings(defaults: defaults)
        inputMode.select(mode)
        let changes = AgentChangesPresentation {
            ChangesStore(directory: { "/home/dev/src/app" }) { request in
                try await transport.readChanges(request)
            }
        }
        var shownChanges: [Bool] = []
        let detail = Self.makeDetail(
            attach: attach, composer: composer, inputMode: inputMode, defaults: defaults,
            changes: changes, onShowsChanges: { shownChanges.append($0) })
        let controller = UIHostingController(rootView: NavigationStack { detail })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(
            await ChangesViewTests.eventually {
                controller.view.layoutIfNeeded()
                return !AgentSurfaceReplacementTests.terminals(in: controller.view).isEmpty
            })

        changes.open()
        var labels = Set<String>()
        let opened = try await ChangesViewTests.eventually {
            labels = ChangesViewTests.labels(in: controller)
            return labels.contains("conflict.txt, conflicted, 4 lines added, 0 lines removed")
                && AgentSurfaceReplacementTests.terminals(in: controller.view).isEmpty
        }
        try #require(opened, "Changes never covered the terminal: \(labels.sorted())")
        #expect(shownChanges.last == true)

        let wentBack = try await ChangesViewTests.eventually {
            ChangesViewTests.isSettled(controller) && ChangesViewTests.goBack(in: controller)
        }
        try #require(wentBack)
        // The pop animates, so Changes' rows linger until it finishes.
        let returned = try await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            return !AgentSurfaceReplacementTests.terminals(in: controller.view).isEmpty
                && !ChangesViewTests.labels(in: controller)
                    .contains("conflict.txt, conflicted, 4 lines added, 0 lines removed")
                && ChangesViewTests.isSettled(controller)
        }
        #expect(returned)
        #expect(changes.store == nil)
        #expect(shownChanges.last == false)
        #expect(composer.draft == "keep this draft")
        #expect(inputMode.mode == mode)

        await attach.leave().value
    }

    /// Changes leaving the screen while they stay open, for another tab,
    /// hand the chrome back to the terminal theme's owner, and coming back
    /// claims it for Changes again.
    @Test func changesClaimTheChromeAgainWhenAgentDetailComesBack() async throws {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([
            .success(try ChangesStoreTests.read(GitProbeRecordings.clean))
        ])
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let attach = try await Self.makeLiveAttach(transport: transport)
        let suiteName = "changes-chrome-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let changes = AgentChangesPresentation {
            ChangesStore(directory: { "/home/dev/src/clean" }) { request in
                try await transport.readChanges(request)
            }
        }
        var shownChanges: [Bool] = []
        let detail = Self.makeDetail(
            attach: attach, composer: composer,
            inputMode: AgentInputModeSettings(defaults: defaults), defaults: defaults,
            changes: changes, onShowsChanges: { shownChanges.append($0) })
        let cover = CoveringTab()
        let controller = UIHostingController(
            rootView: CoverableTabs(cover: cover, detail: detail))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(
            await ChangesViewTests.eventually {
                controller.view.layoutIfNeeded()
                return !AgentSurfaceReplacementTests.terminals(in: controller.view).isEmpty
            })

        changes.open()
        try #require(
            await ChangesViewTests.eventually {
                ChangesViewTests.labels(in: controller).contains(ChangesStore.cleanMessage)
            })
        #expect(shownChanges.last == true)

        cover.selection = 1
        let covered = try await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            return shownChanges.last == false
        }
        try #require(covered, "another tab never released the chrome: \(shownChanges)")

        cover.selection = 0
        let reclaimed = try await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            return shownChanges.last == true
        }
        #expect(reclaimed, "Changes never reclaimed the chrome: \(shownChanges)")
        #expect(changes.store != nil)
        // Hiding the window mid-transition leaves the scene's keyboard layout
        // guide offset by it, which later keyboard tests then read.
        let settled = try await ChangesViewTests.eventually {
            ChangesViewTests.isSettled(controller)
        }
        #expect(settled, "the transition never finished")

        await attach.leave().value
    }

    private static func makeDetail(
        attach: AgentAttachStore,
        composer: AgentComposerStore,
        inputMode: AgentInputModeSettings,
        defaults: UserDefaults,
        changes: AgentChangesPresentation,
        onShowsChanges: @escaping (Bool) -> Void
    ) -> AgentDetailView {
        let console = ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "fixture") },
                reconnectPolicy: .default,
                keepalive: .default)
        }
        let terminal = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults))
        return AgentDetailView(
            agent: AgentSurfaceReplacementTests.makeAgent(pane: "w1:p1"),
            console: console,
            terminal: terminal,
            inputMode: inputMode,
            detailSurface: AgentDetailSurfaceSettings(defaults: defaults),
            hosts: [],
            activity: AppActivityCoordinator(),
            keyboardHandoff: TerminalKeyboardHandoff(),
            keyboardInset: TerminalKeyboardInset(),
            stage: AgentDetailStage(isVisible: { true }, terminalAccess: { .holds }),
            onSwitch: { _ in },
            onClosed: {},
            onShowsChanges: onShowsChanges,
            composerSession: AgentComposerSession(composer: composer),
            attachStore: attach,
            changesPresentation: changes)
    }

    private static func makeLiveAttach(transport: ScriptedTransport) async throws -> AgentAttachStore {
        let attach = AgentAttachStore(
            target: "w1:p1",
            paneTitle: "Claude",
            transportGeneration: 1,
            isOnStage: { true },
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            },
            closePane: {})
        attach.viewDidResize(cols: 80, rows: 24)
        try #require(
            await ChangesViewTests.eventually { await transport.attachRequests.count == 1 })
        #expect(await transport.emitAttachOutput(Data("live".utf8)))
        try #require(
            await ChangesViewTests.eventually {
                attach.terminalStatus == AttachTerminalStore.Status.live
            })
        return attach
    }
    @Test(arguments: [AgentInputMode.composer, .direct])
    func insertingARemovedLineReturnsWithoutSendingAndWaitsForAttach(mode: AgentInputMode) async throws {
        let transport = ScriptedTransport()
        await transport.scriptChangesReads([
            .success(try ChangesStoreTests.read(GitProbeRecordings.subdir))
        ])
        let patch = FilePatch(
            files: GitProbe.parsePatchFiles(Data("""
                diff --git a/pkg/modified.txt b/pkg/modified.txt
                @@ -1,3 +1,3 @@
                 first
                -old
                +new
                 last

                """.utf8), isTruncated: false), isTruncated: false)
        await transport.scriptFilePatchReads([.success(patch)])
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        composer.replaceDraft(with: "keep this draft")
        let attach = try await Self.makeLiveAttach(transport: transport)
        let suiteName = "changes-reference-detail-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let inputMode = AgentInputModeSettings(defaults: defaults)
        inputMode.select(mode)
        let changes = AgentChangesPresentation {
            ChangesStore(
                directory: { "/home/dev/src/app/pkg" },
                read: { try await transport.readChanges($0) },
                readPatch: { try await transport.readFilePatch($0) })
        }
        let detail = Self.makeDetail(
            attach: attach, composer: composer, inputMode: inputMode, defaults: defaults,
            changes: changes, onShowsChanges: { _ in })
        let controller = UIHostingController(rootView: NavigationStack { detail })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            return !AgentSurfaceReplacementTests.terminals(in: controller.view).isEmpty
        })

        changes.open()
        let store = try #require(changes.store)
        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            return store.checkout != nil && attach.terminalStatus == .stopped
        })
        let file = ChangedFile(
            path: Data("pkg/modified.txt".utf8), originalPath: nil,
            kind: .modified, staging: .unstaged)
        store.openDiff(file)
        let diff = try #require(store.fileDiff.current)
        await diff.appear()
        try #require(await ChangesViewTests.eventually {
            ChangesViewTests.labels(in: controller).contains("Removed, line 2: old")
        })
        composer.setDraftSelection(NSRange(location: 5, length: 0))
        let gate = ScriptedTransportCallGate()
        defer { Task { await gate.open() } }
        if mode == .direct { await transport.gateNextAttach(using: gate) }

        store.insert(line: 1)
        try #require(await ChangesViewTests.eventually {
            controller.view.layoutIfNeeded()
            return changes.store == nil && !AgentSurfaceReplacementTests.terminals(in: controller.view).isEmpty
        })
        if mode == .direct {
            await gate.waitForEntry()
            #expect(await transport.attachInputs.compactMap(Self.keystrokes).isEmpty)
            await gate.open()
            try #require(await ChangesViewTests.eventually { attach.input.liveGeneration != nil })
            #expect(attach.terminalStatus == .connecting)
            #expect(await transport.attachInputs.compactMap(Self.keystrokes).isEmpty)
            #expect(await transport.emitAttachOutput(Data("rebuilt".utf8)))
            try #require(await ChangesViewTests.eventually {
                await transport.attachInputs.compactMap(Self.keystrokes) == [Data("modified.txt:2 ".utf8)]
            })
            #expect(composer.draft == "keep this draft")
        } else {
            try #require(await ChangesViewTests.eventually {
                composer.draft == "keep modified.txt:2 this draft"
            })
            #expect(await transport.attachInputs.compactMap(Self.keystrokes).isEmpty)
        }
        #expect(inputMode.mode == mode)
        #expect(composer.messages.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
        await attach.leave().value
        let writes = await transport.attachInputs.compactMap(Self.keystrokes)
        #expect(writes == (mode == .direct ? [Data("modified.txt:2 ".utf8)] : []))
        #expect(!writes.contains { $0.contains(0x0D) || $0.contains(0x0A) })
        // Inserting popped the diff and Changes together.
        await hideTestWindowWhenSettled(window)
    }

    nonisolated private static func keystrokes(_ input: TerminalAttachInput) -> Data? {
        if case .keystrokes(let data) = input { data } else { nil }
    }
}

/// The tab the test selects to take Agent detail, and Changes over it, off
/// screen.
@MainActor
@Observable
private final class CoveringTab {
    var selection = 0
}

private struct CoverableTabs: View {
    @Bindable var cover: CoveringTab
    let detail: AgentDetailView

    var body: some View {
        TabView(selection: $cover.selection) {
            Tab("Agent", systemImage: "sparkles", value: 0) {
                NavigationStack { detail }
            }
            Tab("Other", systemImage: "circle", value: 1) {
                Text("Covering")
            }
        }
    }
}
