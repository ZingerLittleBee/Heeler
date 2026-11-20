import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// With a hardware keyboard attached an Agent opens ready to type, where on
/// touch it opens with the keyboard down (#646). `GCKeyboard.coalesced` is
/// never nil on the Simulator, so each test says whether one is attached.
@MainActor
@Suite("Hardware keyboard focus", .serialized)
struct HardwareKeyboardFocusTests {
    // MARK: The rule

    @Test func anAttachedKeyboardOpensAgentsFocusedUntilTheKeyboardIsPutAway() {
        #expect(!TerminalKeyboardHandoff().opensFocused)

        let keyboard = AttachedKeyboard(isAttached: false)
        let handoff = TerminalKeyboardHandoff(hardwareKeyboard: HardwareKeyboard { keyboard.isAttached })
        #expect(!handoff.opensFocused)
        keyboard.isAttached = true
        #expect(handoff.opensFocused)

        handoff.keyboardWasPutAway()
        #expect(!handoff.opensFocused)
        // Raised again, or a keyboard just connected.
        handoff.keyboardCameUp()
        #expect(handoff.opensFocused)
    }

    /// An Agent's screen rebuilt under a sheet leaves the keys with the
    /// sheet, where the user is typing.
    @Test func aSheetOverTheAgentKeepsTheKeyboard() {
        let handoff = TerminalKeyboardHandoff(hardwareKeyboard: HardwareKeyboard { true })
        handoff.isCovered = { true }
        #expect(!handoff.opensFocused)
        handoff.isCovered = { false }
        #expect(handoff.opensFocused)
    }

    // MARK: The Composer

    @Test func theComposerOpensFocusedOnAHardwareKeyboard() async throws {
        let harness = ComposerHarness(keyboardAttached: true)
        try await harness.show { input in
            try #require(await Self.eventually { input()?.isFirstResponder == true })
            #expect(harness.keyboardPresentation == .system)
        }
    }

    @Test func theComposerOpensWithTheKeyboardDownOnTouch() async throws {
        let harness = ComposerHarness(keyboardAttached: false)
        try await harness.show { input in
            try #require(await Self.eventually { input() != nil })
            await Self.settle()
            #expect(input()?.isFirstResponder == false)
            #expect(harness.keyboardPresentation == .hidden)
        }
    }

    /// A Blocked card in the input's place has nothing to type into.
    @Test func aCardInTheInputsPlaceKeepsTheKeyboardDown() async throws {
        let harness = ComposerHarness(keyboardAttached: true)
        harness.inputReplacement = AnyView(Text("Allow this command?"))
        try await harness.show { input in
            try #require(
                await Self.eventually { accessibleElement(labeled: "Allow this command?", in: harness.view) != nil })
            await Self.settle()
            #expect(input()?.isFirstResponder != true)
            #expect(harness.keyboardPresentation == .hidden)
        }
    }

    /// The keyboard button puts the keyboard away for the Agents opened
    /// after, until it brings the keyboard back.
    @Test func theKeyboardButtonKeepsTheKeyboardDownOnLaterAgents() async throws {
        let harness = ComposerHarness(keyboardAttached: true)
        try await harness.show { input in
            try #require(await Self.eventually { input()?.isFirstResponder == true })

            try #require(await Self.activates("Dismiss keyboard", in: harness.view) { input()?.isFirstResponder == false })
            #expect(!harness.keyboardHandoff.opensFocused)

            try #require(await Self.activates("Show keyboard", in: harness.view) { input()?.isFirstResponder == true })
            #expect(harness.keyboardHandoff.opensFocused)
        }

        harness.keyboardHandoff.keyboardWasPutAway()
        let later = ComposerHarness(keyboardHandoff: harness.keyboardHandoff)
        try await later.show { input in
            try #require(await Self.eventually { input() != nil })
            await Self.settle()
            #expect(input()?.isFirstResponder == false)
        }
    }

    /// A switch made with the keyboard up carries it, whatever was put away
    /// before the user raised it.
    @Test func aHandoffStillCarriesTheKeyboardOverOnePutAway() async throws {
        let harness = ComposerHarness(keyboardAttached: true)
        harness.keyboardHandoff.keyboardWasPutAway()
        harness.keyboardHandoff.arm(for: ComposerHarness.agentID)
        try await harness.show { input in
            try #require(await Self.eventually { input()?.isFirstResponder == true })
            #expect(harness.keyboardHandoff.opensFocused)
        }
    }

    // MARK: Helpers

    /// Activates the control of this label until `condition` holds.
    private static func activates(
        _ label: String, in root: UIView, until condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard await eventually({ accessibleElement(labeled: label, in: root) != nil }) else { return false }
        _ = accessibleElement(labeled: label, in: root)?.accessibilityActivate()
        return await eventually(condition)
    }

    private static func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        var budget = PollBudget(.seconds(5))
        while budget.hasTimeLeft {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            budget.charge()
        }
        return condition()
    }

    /// Long enough for a focus asked for on appear to have reached UIKit.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }
}

@MainActor
private final class AttachedKeyboard {
    var isAttached: Bool

    init(isAttached: Bool) {
        self.isAttached = isAttached
    }
}

/// One Agent's Composer as its screens build it, in a window.
@MainActor
@Observable
private final class ComposerHarness {
    static let agentID = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")

    var keyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    var inputReplacement: AnyView?
    let composer = AgentComposerStore(target: "w1:p1") { _ in throw TransportError.cancelled }
    let keyboardHandoff: TerminalKeyboardHandoff
    @ObservationIgnored private var controller: UIViewController?

    init(keyboardHandoff: TerminalKeyboardHandoff) {
        self.keyboardHandoff = keyboardHandoff
    }

    convenience init(keyboardAttached: Bool) {
        self.init(keyboardHandoff: TerminalKeyboardHandoff(hardwareKeyboard: HardwareKeyboard { keyboardAttached }))
    }

    var view: UIView { controller?.view ?? UIView() }

    /// Shows the Composer and hands `body` a look at its input, which a card
    /// in its place leaves out.
    func show(_ body: @MainActor (@escaping @MainActor () -> UITextView?) async throws -> Void) async throws {
        let controller = UIHostingController(rootView: ComposerHost(harness: self))
        self.controller = controller
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try await body {
                controller.view.layoutIfNeeded()
                return Self.input(in: controller.view)
            }
        }
    }

    private static func input(in root: UIView) -> UITextView? {
        if let text = root as? UITextView, text.accessibilityLabel == "Message the Agent" { return text }
        for subview in root.subviews {
            if let found = input(in: subview) { return found }
        }
        return nil
    }
}

private struct ComposerHost: View {
    @Bindable var harness: ComposerHarness

    var body: some View {
        AgentComposerView(
            store: harness.composer,
            status: .idle,
            hostTelemetry: nil,
            chromeColorScheme: .light,
            switcher: TerminalAgentSwitcher(
                items: [], selectedID: ComposerHarness.agentID, onSelect: { _ in },
                onTogglePin: { _ in }),
            keyboardHandoff: harness.keyboardHandoff,
            keyboardHeight: 0,
            actions: AgentComposerActions(
                canBegin: true,
                attachLinkCount: 0,
                addImage: nil,
                addFile: nil,
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
                closeAgent: {},
                backToConsole: {}),
            attachLinksPopover: AttachLinksPopover(
                origin: .composerChip, presentedOrigin: .constant(nil), links: [],
                open: { _ in }, copy: { _ in }),
            skills: nil,
            keyboardPresentation: $harness.keyboardPresentation,
            prepareKeyboardPresentation: { _ in },
            inputReplacement: harness.inputReplacement,
            collapsesWithoutKeyboard: false)
    }
}
