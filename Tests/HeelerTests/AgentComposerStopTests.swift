import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Send becomes Stop only for a Working Agent and a blank draft, so a prompt
/// typed during a turn still queues behind it.
@Suite("Agent Composer primary control")
struct AgentComposerPrimaryControlTests {
    @Test func aWorkingAgentWithABlankDraftGetsStop() {
        #expect(AgentComposerPrimaryControl(status: .working, draft: "", canStop: true) == .stop)
        #expect(AgentComposerPrimaryControl(status: .working, draft: " \n\t", canStop: true) == .stop)
    }

    @Test func textKeepsSendSoAPromptCanQueue() {
        #expect(
            AgentComposerPrimaryControl(status: .working, draft: "and the tests", canStop: true)
                == .send)
    }

    @Test func onlyWorkingOffersStop() {
        // Esc on a Blocked dialog answers it; on Claude's folder trust
        // dialog it exits Claude Code.
        for status in [AgentStatus.idle, .done, .blocked, .unknown] {
            #expect(
                AgentComposerPrimaryControl(status: status, draft: "", canStop: true) == .send,
                "status \(status.rawValue)")
        }
    }

    @Test func aSurfaceWithoutAnInterruptKeepsSend() {
        #expect(AgentComposerPrimaryControl(status: .working, draft: "", canStop: false) == .send)
    }
}

@Suite("Agent Composer collapse")
struct AgentComposerCollapseTests {
    @Test func foldsOnlyWhileNothingHoldsOrAwaitsTheKeyboard() {
        #expect(Self.folds())
        #expect(!Self.folds(isEnabled: false), "the terminal keeps its height")
        #expect(!Self.folds(isInputFocused: true))
        #expect(!Self.folds(keyboardPresentation: .system), "asked for before focus lands")
        #expect(
            !Self.folds(keyboardPresentation: .tools),
            "the iPad tools dock releases focus, but swapping keyboards never resizes the Composer")
        #expect(!Self.folds(inheritsKeyboard: true), "a handed-over keyboard opens it from the first frame")
        #expect(!Self.folds(hasInputReplacement: true), "the Blocked card keeps its own layout")
    }

    private static func folds(
        isEnabled: Bool = true,
        isInputFocused: Bool = false,
        keyboardPresentation: AgentComposerKeyboardPresentation = .hidden,
        inheritsKeyboard: Bool = false,
        hasInputReplacement: Bool = false
    ) -> Bool {
        AgentComposerCollapse.isCollapsed(
            isEnabled: isEnabled,
            isInputFocused: isInputFocused,
            keyboardPresentation: keyboardPresentation,
            inheritsKeyboard: inheritsKeyboard,
            hasInputReplacement: hasInputReplacement)
    }
}

/// One Esc per tap, then a wait on Agent Status: an Esc landing after the
/// turn ended can open the program's own history menus.
@MainActor
@Suite("Agent Composer Stop")
struct AgentComposerStopStoreTests {
    @Test func aSecondTapWaitsForTheStatusInsteadOfPressingAgain() async {
        let window = ScriptedTransportCallGate()
        let store = AgentComposerStopStore(sleep: { _ in await window.waitUntilOpen() })
        let esc = EscRecorder()

        let wait = store.stop(using: { await esc.press() })
        #expect(store.stop(using: { await esc.press() }) == nil)
        await window.waitForEntry()
        #expect(esc.count == 1)
        #expect(store.isStopping)
        #expect(store.stop(using: { await esc.press() }) == nil)

        store.agentStatusChanged(to: .idle)
        #expect(store.phase == .ready)
        await window.open()
        await wait?.value
        #expect(store.phase == .ready, "a wait the status overtook must not come back")
        #expect(esc.count == 1)
    }

    @Test func workingUpdatesKeepWaiting() async {
        let window = ScriptedTransportCallGate()
        let store = AgentComposerStopStore(sleep: { _ in await window.waitUntilOpen() })

        let wait = store.stop(using: { .sent })
        await window.waitForEntry()
        store.agentStatusChanged(to: .working)
        #expect(store.isStopping)

        await window.open()
        await wait?.value
        #expect(store.phase == .unconfirmed)
    }

    @Test func pastTheWindowStopWorksAgainAndSaysWhatItSees() async {
        let store = AgentComposerStopStore(sleep: { _ in })
        let esc = EscRecorder()

        await store.stop(using: { await esc.press() })?.value
        #expect(store.phase == .unconfirmed)
        #expect(store.notice == AgentComposerStopStore.unconfirmedMessage)
        #expect(!store.isStopping)

        await store.stop(using: { await esc.press() })?.value
        #expect(esc.count == 2)
    }

    @Test func aFailedEscSaysWhyAndSkipsTheWindow() async {
        let window = ScriptedTransportCallGate()
        await window.open()
        let store = AgentComposerStopStore(sleep: { _ in await window.waitUntilOpen() })
        let esc = EscRecorder()
        esc.outcome = .failed("Couldn't reach the Agent, so it may still be working.")

        await store.stop(using: { await esc.press() })?.value
        #expect(store.phase == .failed("Couldn't reach the Agent, so it may still be working."))
        #expect(store.notice == "Couldn't reach the Agent, so it may still be working.")
        #expect(await window.entryCount == 0)

        esc.outcome = .sent
        await store.stop(using: { await esc.press() })?.value
        #expect(esc.count == 2)
        #expect(store.phase == .unconfirmed)
    }

    @Test func aSendHoldsStopBackUntilItsOwnMomentPasses() async {
        let first = ScriptedTransportCallGate()
        let second = ScriptedTransportCallGate()
        let gates = GateQueue([first, second])
        let store = AgentComposerStopStore(sleep: { _ in await gates.next().waitUntilOpen() })

        let firstHold = store.holdAfterSend()
        #expect(store.isHeldAfterSend)
        await first.waitForEntry()
        let secondHold = store.holdAfterSend()
        await second.waitForEntry()

        await first.open()
        await firstHold.value
        #expect(store.isHeldAfterSend, "the later send's moment is still running")
        await second.open()
        await secondHold.value
        #expect(!store.isHeldAfterSend)
    }

    @Test func aStatusChangeWhileEscIsOnItsWayWins() async {
        let send = ScriptedTransportCallGate()
        let store = AgentComposerStopStore(sleep: { _ in })

        let wait = store.stop(using: {
            await send.waitUntilOpen()
            return .failed("late")
        })
        await send.waitForEntry()
        store.agentStatusChanged(to: .done)
        await send.open()
        await wait?.value
        #expect(store.phase == .ready)
        #expect(store.notice == nil)
    }
}

/// Stop belongs to the Agent's Composer store, not to a view: its status
/// stream ends the wait with no Composer on screen, and its sends hold
/// Stop back.
@MainActor
@Suite("Agent Composer Stop, per Agent")
struct AgentComposerStopOwnershipTests {
    @Test func theAgentsStatusEndsTheWaitWithNoComposerOnScreen() async {
        let window = ScriptedTransportCallGate()
        let (updates, continuation) = AsyncStream.makeStream(
            of: ConsoleStore.AgentStatusUpdate.self)
        defer { continuation.finish() }
        let composer = AgentComposerStore(
            target: "w1:p1", initialStatus: .working, statusUpdates: updates,
            stop: AgentComposerStopStore(sleep: { _ in await window.waitUntilOpen() })
        ) { _ in throw TransportError.cancelled }
        composer.open()

        let wait = composer.stop.stop(using: { .sent })
        await window.waitForEntry()
        #expect(composer.stop.isStopping)

        continuation.yield(.init(status: .idle, liveUpdatesAvailable: true))
        #expect(await Self.eventually { composer.stop.phase == .ready })
        await window.open()
        await wait?.value
        #expect(composer.stop.phase == .ready)
    }

    @Test func sendingHoldsStopBack() async {
        let hold = ScriptedTransportCallGate()
        let composer = AgentComposerStore(
            target: "w1:p1", initialStatus: .working,
            stop: AgentComposerStopStore(sleep: { _ in await hold.waitUntilOpen() })
        ) { _ in throw TransportError.cancelled }
        composer.replaceDraft(with: "and run the tests")

        let send = Task { await composer.send() }
        await hold.waitForEntry()
        #expect(composer.draft.isEmpty)
        #expect(composer.stop.isHeldAfterSend)

        await hold.open()
        _ = await send.value
        #expect(await Self.eventually { !composer.stop.isHeldAfterSend })
    }

    private static func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

/// The hosted Composer: Chat folds it to one line without replacing its
/// text view, and Stop presses Esc once until Agent Status moves.
@MainActor
@Suite("Agent Composer fold and Stop, hosted", .serialized)
struct AgentComposerFoldHostedTests {
    @Test func chatFoldsToOneLineUntilTheEditorTakesFocus() async throws {
        let harness = ComposerHarness(status: .idle)
        let controller = UIHostingController(rootView: ComposerHost(harness: harness, collapses: true))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            controller.view.layoutIfNeeded()
            let editor = try #require(Self.editor(in: controller.view))
            let foldedHeight = Self.height(of: controller)
            let foldedWidth = editor.bounds.width

            editor.becomeFirstResponder()
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return harness.keyboardPresentation == .system && editor.bounds.width > foldedWidth
            })
            let openHeight = Self.height(of: controller)
            #expect(
                openHeight - foldedHeight > 40,
                "folding should drop the action row: \(foldedHeight) against \(openHeight)")
            #expect(Self.editor(in: controller.view) === editor)

            editor.resignFirstResponder()
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return harness.keyboardPresentation == .hidden && editor.bounds.width == foldedWidth
            })
            #expect(abs(Self.height(of: controller) - foldedHeight) < 0.5)
            #expect(Self.editor(in: controller.view) === editor)

            // The iPad tools dock releases focus; the Composer stays open.
            harness.keyboardPresentation = .tools
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return editor.bounds.width > foldedWidth
            })
            #expect(abs(Self.height(of: controller) - openHeight) < 0.5)
            #expect(Self.editor(in: controller.view) === editor)
        }
    }

    @Test func aFoldedDraftShowsItsFirstLineOnly() async throws {
        let harness = ComposerHarness(status: .idle)
        harness.composer.replaceDraft(with: Self.longDraft)
        let controller = UIHostingController(rootView: ComposerHost(harness: harness, collapses: true))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            controller.view.layoutIfNeeded()
            let editor = try #require(Self.editor(in: controller.view))
            let lineHeight = try #require(editor.font?.lineHeight)

            // Typing at the end of a long draft scrolls the open editor.
            editor.becomeFirstResponder()
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return editor.isScrollEnabled && editor.contentOffset.y > lineHeight
            })

            editor.resignFirstResponder()
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return editor.textContainer.maximumNumberOfLines == 1
            })
            #expect(editor.bounds.height < lineHeight * 2)
            #expect(editor.contentOffset == .zero)
            #expect(!editor.isScrollEnabled)
            harness.close()
        }
    }

    @Test func aTapIntoTheFoldedInputKeepsTheCaretWhereTheDraftWasLeft() async throws {
        let harness = ComposerHarness(status: .idle)
        harness.composer.replaceDraft(with: Self.longDraft)
        let end = NSRange(location: (Self.longDraft as NSString).length, length: 0)
        let controller = UIHostingController(rootView: ComposerHost(harness: harness, collapses: true))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            controller.view.layoutIfNeeded()
            let editor = try #require(Self.editor(in: controller.view))
            let lineHeight = try #require(editor.font?.lineHeight)
            let foldedWidth = editor.bounds.width
            #expect(editor.selectedRange == end)

            // A tap begins editing, then puts the caret in the one line
            // the folded input shows.
            editor.becomeFirstResponder()
            editor.selectedRange = NSRange(location: 3, length: 0)
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return editor.bounds.width > foldedWidth && editor.selectedRange == end
            })
            #expect(harness.composer.draftSelection == end)
            // UIKit animates the scroll that brings the caret into view.
            #expect(
                await Self.eventually { editor.contentOffset.y > lineHeight },
                "the caret at the end of a long draft comes into view")
            harness.close()
        }
    }

    @Test func aPendingKeyboardHandoffKeepsItOpen() async throws {
        let harness = ComposerHarness(status: .idle)
        let controller = UIHostingController(rootView: ComposerHost(harness: harness, collapses: true))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            controller.view.layoutIfNeeded()
            let editor = try #require(Self.editor(in: controller.view))
            #expect(editor.textContainer.maximumNumberOfLines == 1)

            // A switch arms the handoff before the next Agent's Composer
            // lays out, and `onAppear` takes it only after that first
            // frame. Here the same view takes the new Agent, so the handoff
            // stays pending and nothing else asks for the keyboard.
            harness.keyboardHandoff.arm(for: ComposerHarness.agentID)
            harness.selectedID = ComposerHarness.agentID
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return editor.textContainer.maximumNumberOfLines == 0
            })
            #expect(!editor.isFirstResponder)
            #expect(harness.keyboardPresentation == .hidden)
            #expect(harness.keyboardHandoff.mode(for: ComposerHarness.agentID) != nil)
            harness.keyboardHandoff.cancel(for: ComposerHarness.agentID)
        }
    }

    @Test func stopPressesEscOnceUntilTheStatusMoves() async throws {
        // Real SwiftUI actions require the hosted accessibility support in iOS 27.
        guard #available(iOS 27, *) else { return }
        let harness = ComposerHarness(status: .working)
        let controller = UIHostingController(rootView: ComposerHost(harness: harness, collapses: true))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try #require(try await Self.activate(labeled: "Stop", in: controller.view))
            try #require(await Self.eventually { harness.escapes == 1 })
            _ = try await Self.activate(labeled: "Stop", in: controller.view)
            for _ in 0..<20 { await Task.yield() }
            #expect(harness.escapes == 1, "a second tap must wait for the status")

            harness.setStatus(.idle)
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return Self.accessible(labeled: "Send", in: controller.view) != nil
                    && Self.accessible(labeled: "Stop", in: controller.view) == nil
            })

            harness.setStatus(.working)
            try #require(try await Self.activate(labeled: "Stop", in: controller.view))
            try #require(await Self.eventually { harness.escapes == 2 })

            harness.composer.replaceDraft(with: "queue this behind the turn")
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return Self.accessible(labeled: "Send", in: controller.view) != nil
                    && Self.accessible(labeled: "Stop", in: controller.view) == nil
            })
            #expect(harness.escapes == 2)
            harness.close()
        }
    }

    @Test func aSendKeepsStopFromTakingItsPlaceAtOnce() async throws {
        // Real SwiftUI actions require the hosted accessibility support in iOS 27.
        guard #available(iOS 27, *) else { return }
        let harness = ComposerHarness(status: .working)
        harness.composer.replaceDraft(with: "and run the tests")
        let controller = UIHostingController(rootView: ComposerHost(harness: harness, collapses: true))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try #require(try await Self.activate(labeled: "Send", in: controller.view))
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return harness.composer.draft.isEmpty
            })
            #expect(Self.accessible(labeled: "Stop", in: controller.view) == nil)
            #expect(Self.accessible(labeled: "Send", in: controller.view) != nil)
            #expect(harness.escapes == 0)

            await harness.window.open()
            try #require(await Self.eventually {
                controller.view.layoutIfNeeded()
                return Self.accessible(labeled: "Stop", in: controller.view) != nil
            })
        }
    }

    // MARK: Helpers

    private static let longDraft = (1...12).map { "Line \($0) of a long draft" }
        .joined(separator: "\n")

    private static func editor(in root: UIView) -> UITextView? {
        if let textView = root as? UITextView, textView.accessibilityLabel == "Message the Agent" {
            return textView
        }
        for subview in root.subviews {
            if let match = editor(in: subview) { return match }
        }
        return nil
    }

    private static func height(of controller: UIHostingController<ComposerHost>) -> CGFloat {
        controller.sizeThatFits(in: CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude)).height
    }

    private static func activate(labeled label: String, in root: UIView) async throws -> Bool {
        for attempt in 0..<40 {
            root.layoutIfNeeded()
            if let element = accessible(labeled: label, in: root) {
                if let control = element as? UIControl {
                    control.sendActions(for: .touchUpInside)
                    return true
                }
                return element.accessibilityActivate()
            }
            if attempt < 39 { try await Task.sleep(for: .milliseconds(50)) }
        }
        return false
    }

    private static func accessible(labeled label: String, in root: UIView) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        var match: NSObject?
        func visit(_ node: NSObject) {
            guard match == nil, visited.insert(ObjectIdentifier(node)).inserted else { return }
            if node.accessibilityLabel == label {
                match = node
                return
            }
            for element in node.accessibilityElements ?? [] {
                if let object = element as? NSObject { visit(object) }
            }
            // SwiftUI containers can expose an empty or incomplete array
            // while their indexed accessibility API owns the live controls.
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject {
                        visit(object)
                    }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews { visit(subview) }
            }
        }
        visit(root)
        return match
    }

    private static func eventually(
        timeout: Duration = .seconds(5),
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

@MainActor
private final class EscRecorder {
    var count = 0
    var outcome: AgentInterruptOutcome = .sent

    func press() async -> AgentInterruptOutcome {
        count += 1
        return outcome
    }
}

/// Hands each sleep the next gate, so overlapping waits end one by one.
@MainActor
private final class GateQueue {
    private let gates: [ScriptedTransportCallGate]
    private var index = 0

    init(_ gates: [ScriptedTransportCallGate]) {
        self.gates = gates
    }

    func next() -> ScriptedTransportCallGate {
        defer { index += 1 }
        return gates[index]
    }
}

@MainActor
@Observable
private final class ComposerHarness {
    static let agentID = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")

    private(set) var status: AgentStatus
    var keyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    var selectedID: ConsoleAgent.ID?
    var escapes = 0
    /// Holds Stop's window and a send's hold until a test opens it.
    let window = ScriptedTransportCallGate()
    /// A send fails at once; no test needs it delivered.
    let composer: AgentComposerStore
    let keyboardHandoff = TerminalKeyboardHandoff()

    init(status: AgentStatus) {
        self.status = status
        let window = window
        composer = AgentComposerStore(
            target: "w1:p1", initialStatus: status,
            stop: AgentComposerStopStore(sleep: { _ in await window.waitUntilOpen() })
        ) { _ in throw TransportError.cancelled }
    }

    /// As Console's status stream would deliver it, to the view and to the
    /// Composer store.
    func setStatus(_ status: AgentStatus) {
        self.status = status
        composer.agentStatusDidChange(status)
    }

    /// Lets waits still holding on the window finish.
    func close() {
        Task { await window.open() }
    }
}

private struct ComposerHost: View {
    @Bindable var harness: ComposerHarness
    let collapses: Bool

    var body: some View {
        AgentComposerView(
            store: harness.composer,
            status: harness.status,
            hostTelemetry: nil,
            chromeColorScheme: .light,
            switcher: TerminalAgentSwitcher(
                items: [], selectedID: harness.selectedID, onSelect: { _ in },
                onTogglePin: { _ in }),
            keyboardHandoff: harness.keyboardHandoff,
            keyboardHeight: 0,
            actions: AgentComposerActions(
                canBegin: true,
                attachLinkCount: 0,
                addImage: {},
                addFile: {},
                showAttachLinks: {},
                openTerminal: nil,
                isOpeningTerminal: false,
                showChanges: nil,
                startAgent: {},
                manageSnippets: {},
                showSkills: nil,
                showWorktreeDetails: nil,
                renameAgent: {},
                renameWorkspace: {},
                closeAgent: {}),
            attachLinksPopover: AttachLinksPopover(
                origin: .composerChip, presentedOrigin: .constant(nil), links: [],
                open: { _ in }, copy: { _ in }),
            skills: nil,
            keyboardPresentation: $harness.keyboardPresentation,
            prepareKeyboardPresentation: { _ in },
            collapsesWithoutKeyboard: collapses,
            interruptAgent: { [harness] in
                harness.escapes += 1
                return .sent
            })
    }
}
