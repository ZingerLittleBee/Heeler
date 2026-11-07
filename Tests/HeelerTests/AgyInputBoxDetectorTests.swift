import Foundation
import Testing

@testable import Heeler

/// Antigravity CLI's input box, read from agy 1.5.3 captures at 190, 120,
/// 62, 59 and 40 columns, and from synthetic screens laid out the way agy
/// draws, for states no capture shows.
@Suite("Antigravity CLI input box")
struct AgyInputBoxDetectorTests {
    /// What a capture reads as, short of its exact text.
    private enum Reading: Equatable {
        case empty, draft, shell, waitingForSecondPress, below, dialog, exited
    }

    /// Every capture's reading. A new capture without one fails
    /// `everyCaptureReadsAsLabelled`.
    private static let readings: [String: Reading] = [
        "agy-00-trust-prompt-191x49": .dialog,
        "agy-01-welcome-after-attach-120x40": .empty,
        "agy-02-idle-empty-120x40": .empty,
        "agy-03-ctrlc-idle-once-120x40": .empty,
        "agy-04-typed-after-ctrlc-120x40": .draft,
        "agy-05-esc-idle-draft-120x40": .draft,
        "agy-06-esc-esc-idle-draft-120x40": .empty,
        "agy-07-ctrlc-idle-draft-120x40": .draft,
        "agy-09-welcome-after-trust-answered-elsewhere-190x49": .empty,
        "agy-10-trust-prompt-no-selected-190x49": .dialog,
        "agy-11-trust-prompt-no-selected-62x41": .dialog,
        "agy-12-trust-prompt-no-selected-40x30": .dialog,
        "agy-13-first-screen-welcome-120x40": .empty,
        "agy-14-idle-draft-oneline-120x40": .draft,
        "agy-15-idle-draft-wrapped-120x40": .draft,
        "agy-16-idle-draft-multiline-120x40": .draft,
        "agy-17-prompt-newline-just-sent-120x40": .empty,
        "agy-18-idle-after-reply-120x40": .empty,
        "agy-19-help-shortcuts-120x40": .below,
        "agy-20-help-commands-tab-120x40": .below,
        "agy-25-slash-popup-120x40": .below,
        "agy-26-slash-popup-filtered-co-120x40": .below,
        "agy-27-slash-popup-after-esc-120x40": .draft,
        "agy-28-at-popup-120x40": .below,
        "agy-29-at-popup-120x40": .below,
        "agy-30-perm-run-command-default-120x40": .dialog,
        "agy-31-perm-run-command-default-40x30": .dialog,
        "agy-31-perm-run-command-default-62x20": .dialog,
        "agy-31-perm-run-command-default-62x41": .dialog,
        "agy-32-perm-after-digit2-120x40": .empty,
        "agy-33-working-with-draft-120x40": .draft,
        "agy-34-working-submitted-while-working-120x40": .empty,
        "agy-35-done-after-queued-120x40": .empty,
        "agy-36-done-final-120x40": .empty,
        "agy-38-esc-while-working-120x40": .empty,
        "agy-39-ctrlc-while-working-120x40": .empty,
        "agy-41-ask-question-single-120x40": .dialog,
        "agy-42-ask-question-single-40x30": .dialog,
        "agy-42-ask-question-single-62x20": .dialog,
        "agy-42-ask-question-single-62x41": .dialog,
        "agy-43-ask-question-after-digit2-120x40": .empty,
        "agy-44-ask-question-multi-120x40": .dialog,
        "agy-45-ask-question-multi-q2-120x40": .dialog,
        "agy-46-ask-question-multi-after-esc-120x40": .empty,
        "agy-47-perm-file-edit-default-120x40": .dialog,
        "agy-48-perm-file-edit-default-40x30": .dialog,
        "agy-48-perm-file-edit-default-62x20": .dialog,
        "agy-48-perm-file-edit-default-62x41": .dialog,
        "agy-49-prompt-sent-into-edit-dialog-120x40": .empty,
        "agy-50-after-edit-accepted-by-prompt-120x40": .empty,
        "agy-51-perm-run-command-after-esc-120x40": .empty,
        "agy-52-perm-run-command-amend-120x40": .dialog,
        "agy-54-idle-after-esc-amend-heeler-client-59x41": .empty,
        "agy-55-perm-run-command-190x49": .dialog,
        "agy-56-perm-run-command-after-digit4-190x49": .empty,
        "agy-57-idle-empty-62x41": .empty,
        "agy-58-idle-draft-oneline-62x41": .draft,
        "agy-59-idle-draft-wrapped-62x41": .draft,
        "agy-60-slash-popup-62x41": .below,
        "agy-61-at-popup-62x41": .below,
        "agy-62-help-shortcuts-62x41": .below,
        "agy-63-idle-empty-40x30": .empty,
        "agy-63-idle-empty-62x20": .empty,
        "agy-64-idle-draft-wrapped-40x30": .draft,
        "agy-64-idle-draft-wrapped-62x20": .draft,
        "agy-65-slash-popup-40x30": .below,
        "agy-65-slash-popup-62x20": .below,
        "agy-66-working-nodraft-62x41": .empty,
        "agy-67-working-tool-running-62x41": .empty,
        "agy-68-working-with-draft-62x41": .draft,
        "agy-69-working-draft-entered-then-perm-dialog-62x41": .dialog,
        "agy-70-working-queued-after-approve-62x41": .empty,
        "agy-71-working-queued-edit-up-62x41": .draft,
        "agy-72-working-altm-send-now-62x41": .empty,
        "agy-73-done-after-altm-62x41": .empty,
        "agy-74-compacting-or-after-62x41": .empty,
        "agy-75-after-compact-62x41": .empty,
        "agy-76-mode-cycle-1-120x40": .empty,
        "agy-76-mode-cycle-2-120x40": .empty,
        "agy-76-mode-cycle-3-120x40": .empty,
        "agy-76-mode-cycle-4-120x40": .empty,
        "agy-77-accept-edits-run-command-120x40": .dialog,
        "agy-78-auto-mode-result-120x40": .empty,
        "agy-79-plan-mode-result-120x40": .empty,
        "agy-80-artifact-review-ctrl-r-120x40": .below,
        "agy-81-artifact-review-after-y-120x40": .empty,
        "agy-82-plan-approved-result-120x40": .dialog,
        "agy-83-plan-edit-rejected-120x40": .empty,
        "agy-84-footer-modes-40x30-40x30": .empty,
        "agy-84-footer-modes-62x20-62x20": .empty,
        "agy-84-footer-modes-62x41-62x41": .empty,
        "agy-85-model-picker-120x40": .below,
        "agy-87-perm-after-ctrlc-120x40": .empty,
        "agy-88-exit-with-conversation-120x40": .exited,
        "agy-89-warning-notice-bad-model-120x40": .empty,
        "agy-90-first-screen-welcome-40x30": .empty,
        "agy-90-first-screen-welcome-62x20": .empty,
        "agy-90-first-screen-welcome-62x41": .empty,
        "agy-91-bang-typed-62x41": .shell,
        "agy-92-up-on-empty-box-62x41": .draft,
        "agy-93-bash-mode-with-text-62x41": .shell,
        "agy-94-working-nodraft-40x30": .empty,
        "agy-95-working-with-draft-40x30": .draft,
        "agy-96-working-queued-40x30": .empty,
        "agy-97-esc-with-queued-40x30": .draft,
        "agy-98-working-nodraft-62x20": .empty,
        "agy-99-perm-file-create-default-120x40": .dialog,
        "agy-99-perm-file-create-default-40x30": .dialog,
        "agy-99-perm-file-create-default-62x41": .dialog,
        "agy-100-ask-question-multiselect-62x41": .dialog,
        "agy-101-ask-question-multiselect-after-digit2-62x41": .dialog,
        "agy-102-ask-question-multiselect-after-3-2-62x41": .dialog,
        "agy-103-ask-question-multiselect-after-enter-62x41": .empty,
        "agy-104-ask-question-writein-after-digit-62x41": .dialog,
        "agy-105-ask-question-writein-typed-62x41": .dialog,
        "agy-106-ask-question-multi-q1-after-esc-62x41": .dialog,
        "agy-107-ask-question-multi-q2-after-digit2-62x41": .empty,
        "agy-108-perm-run-command-62x41": .dialog,
        "agy-109-perm-run-command-amend-62x41": .dialog,
        "agy-110-perm-run-command-amend-typed-62x41": .dialog,
        "agy-111-perm-run-command-tab-on-no-62x41": .dialog,
        "agy-113-ask-question-multiselect-q1-of-2-62x41": .dialog,
        "agy-114-ask-question-multiselect-q1-after-enter-62x41": .dialog,
        "agy-115-ask-question-single-after-esc-62x41": .empty,
    ]

    private static func reading(of state: InputBoxState) -> Reading? {
        switch state {
        case .empty: .empty
        case .text: .draft
        case .shellMode: .shell
        case .disabled: .waitingForSecondPress
        case .overlay: .below
        case .dialog(title: nil): .dialog
        case .noComposer: .exited
        case .dialog, .unknown: nil
        }
    }

    private static func detect(_ stem: String) throws -> InputBoxState {
        InputBoxStateDetector.detect(try ScreenFixture.screen(stem), program: .agy)
    }

    @Test(arguments: ScreenFixture.agy)
    func everyCaptureReadsAsLabelled(stem: String) throws {
        let expected = try #require(Self.readings[stem])

        let state = try Self.detect(stem)

        #expect(Self.reading(of: state) == expected)
        #expect(state.isSendable == (expected == .empty))
    }

    @Test func everyReadingNamesACapture() {
        #expect(Set(Self.readings.keys) == Set(ScreenFixture.agy))
    }

    // MARK: Dialogs

    private static var dialogs: [String] {
        ScreenFixture.agy.filter { readings[$0] == .dialog }
    }

    /// Every dialog holds at every captured width, whatever herdr reports:
    /// herdr 0.9.5 reports the file edit dialog (47, 48, 82), the Amend
    /// field (52) and the trust prompt at 40 columns (12) as idle, and Enter
    /// there takes the selected answer.
    @Test(arguments: dialogs)
    func aDialogHoldsWhateverHerdrReports(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)

        for activity in [ChatAgentActivity.idle, .working, .unknown] {
            #expect(PreSendGate.check(screen, program: .agy, activity: activity) == .hold(.dialog(title: nil)))
        }
    }

    @Test func theDialogListHoldsEveryKind() {
        let kinds = [
            "trust-prompt", "perm-run-command", "ask-question-single", "ask-question-multi", "perm-file-edit",
            "run-command-amend", "accept-edits-run-command", "plan-approved",
        ]
        for kind in kinds {
            #expect(Self.dialogs.contains { $0.contains(kind) }, "\(kind)")
        }
        // Each of the file edit dialog's captured widths.
        for size in ["120x40", "62x41", "62x20", "40x30"] {
            #expect(Self.dialogs.contains { $0.contains("perm-file-edit") && $0.hasSuffix(size) }, "\(size)")
        }
    }

    // MARK: The box

    @Test(arguments: [
        ("agy-14-idle-draft-oneline-120x40", "Reply with the single word pear"),
        (
            "agy-15-idle-draft-wrapped-120x40",
            "This is a deliberately long draft that should wrap across more than one row of the input box at one hundred and\ntwenty columns so that we can see how continuation rows are drawn and indented in agy"
        ),
        ("agy-16-idle-draft-multiline-120x40", "line one\nx\nx\nx"),
        ("agy-27-slash-popup-after-esc-120x40", "/co"),
        (
            "agy-59-idle-draft-wrapped-62x41",
            "This is a deliberately long draft that should wrap across\nmore than one row of the input box at sixty two columns\nwide"
        ),
        ("agy-64-idle-draft-wrapped-40x30", "This draft wraps on narrow phone\nscreens for sure"),
        ("agy-95-working-with-draft-40x30", "Then add the word fig"),
        // Esc put the queued message back in the box.
        ("agy-97-esc-with-queued-40x30", "Then add the word fig"),
    ])
    func readsADraft(stem: String, draft: String) throws {
        #expect(try Self.detect(stem) == .text(draft))
    }

    /// Accept-edits, auto and plan modes set a grey hint in the empty box,
    /// cut at 40 columns.
    @Test(arguments: [
        ("agy-76-mode-cycle-1-120x40", "Accept-edits mode: file edits auto-approved (shift+tab to cycle)"),
        ("agy-76-mode-cycle-2-120x40", "Auto mode: edits & safe commands auto-approved (shift+tab to cycle)"),
        ("agy-76-mode-cycle-3-120x40", "Plan mode: research & plan only (shift+tab to cycle)"),
        ("agy-84-footer-modes-40x30-40x30", "Plan mode: research & plan only (s..."),
    ])
    func aModesHintIsNotADraft(stem: String, hint: String) throws {
        #expect(try Self.detect(stem) == .empty(placeholder: hint))
    }

    /// agy queues a message sent while a turn runs, and a second one while
    /// another waits.
    @Test(arguments: [
        "agy-17-prompt-newline-just-sent-120x40", "agy-34-working-submitted-while-working-120x40",
        "agy-66-working-nodraft-62x41", "agy-70-working-queued-after-approve-62x41",
        "agy-72-working-altm-send-now-62x41", "agy-94-working-nodraft-40x30", "agy-96-working-queued-40x30",
    ])
    func aWorkingBoxTakesAMessage(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)

        #expect(PreSendGate.check(screen, program: .agy, activity: .working) == .send)
    }

    @Test func bashModeIsShellMode() throws {
        #expect(try Self.detect("agy-91-bang-typed-62x41") == .shellMode(""))
        #expect(try Self.detect("agy-93-bash-mode-with-text-62x41") == .shellMode("ls"))
    }

    /// Ctrl+C or Ctrl+D on an idle box arms an exit with no timeout, and a
    /// paste disarms it before its Enter sends (agy 1.5.3, live through
    /// herdr 0.9.5's `agent prompt`).
    @Test func aPendingExitTakesAMessage() throws {
        #expect(try Self.detect("agy-03-ctrlc-idle-once-120x40") == .empty(placeholder: nil))
        #expect(Self.detect(Self.box(footer: "press ctrl+d again to exit")) == .empty(placeholder: nil))
        #expect(try Self.detect("agy-07-ctrlc-idle-draft-120x40") == .text("draft for ctrl c"))
    }

    @Test func anotherPendingPressHolds() {
        let state = Self.detect(Self.box(footer: "press ctrl+b again to send command to background"))

        guard case .disabled(let reason) = state else {
            Issue.record("not disabled: \(state)")
            return
        }
        #expect(reason.contains("press ctrl+b again to send command to background"))
    }

    @Test(arguments: [
        ("agy-19-help-shortcuts-120x40", "Antigravity CLI   general    commands    shortcuts   (←/→ or tab to cycle)"),
        ("agy-25-slash-popup-120x40", "> /add-dir             Add a directory to the workspace"),
        ("agy-28-at-popup-120x40", "No matches"),
        ("agy-29-at-popup-120x40", "> conversation:  Conversation  Reference a past conversation"),
        ("agy-80-artifact-review-ctrl-r-120x40", "Action required (1 left)"),
        ("agy-85-model-picker-120x40", "Switch Model"),
    ])
    func whatAgyDrawsUnderTheBoxHolds(stem: String, row: String) throws {
        #expect(try Self.detect(stem) == .overlay(row))
    }

    @Test func anExitedAgyHasNoComposer() throws {
        guard case .noComposer = try Self.detect("agy-88-exit-with-conversation-120x40") else {
            Issue.record("not noComposer")
            return
        }
    }

    // MARK: Synthetic screens

    private static let grey = "\u{1B}[0m\u{1B}[38;5;8m"
    private static let blue = "\u{1B}[0m\u{1B}[38;5;12m"

    private static func rule(_ width: Int) -> String {
        Self.grey + String(repeating: "─", count: width) + SGR.reset
    }

    /// An empty box at `columns`, a past prompt above it, and `footer`.
    private static func box(columns: Int = 62, footer: String, under: [String] = []) -> ANSIScreen {
        ScreenFixture.synthetic(
            [
                Self.rule(min(60, columns - 3)),
                "\u{1B}[0m\u{1B}[1m\u{1B}[38;5;4m> Reply with only the word pear.\u{1B}[0m",
                "",
                Self.rule(columns),
                Self.blue + ">" + SGR.reset,
                Self.rule(columns),
            ] + under + [Self.grey + footer + SGR.reset])
    }

    private static func detect(_ screen: ANSIScreen) -> InputBoxState {
        InputBoxStateDetector.detect(screen, program: .agy)
    }

    /// Code search mode, Vim's badges and the background prompt change what
    /// Enter does (agy 1.5.3's strings; no capture).
    @Test(arguments: [
        "activated code search mode", "-- INSERT --", "press ctrl+b again to send command to background",
    ])
    func anUnknownFooterHolds(footer: String) {
        #expect(!Self.detect(Self.box(footer: footer)).isSendable)
    }

    /// `/compact` leaves a full-width rule labelled `Conversation compacted`
    /// above the box (agy 1.5.3, live), which is not the box's rule.
    @Test func theCompactionRuleIsNotTheBox() {
        let label = " Conversation compacted "
        let side = String(repeating: "─", count: (62 - label.count) / 2)
        let screen = ScreenFixture.synthetic([
            Self.grey + side + label + side + SGR.reset,
            "         9 steps summarized · context 8.6k → ~10.6k · took 12s",
            Self.rule(62), Self.blue + ">" + SGR.reset, Self.rule(62), Self.grey + "? for shortcuts" + SGR.reset,
        ])

        #expect(Self.detect(screen) == .empty(placeholder: nil))
    }

    @Test func theTaskPanelUnderTheBoxDoesNotHold() {
        let panel = ["   ● [00:10:32]  sleep 30; echo probe-two  running", Self.rule(62)]

        #expect(Self.detect(Self.box(footer: "esc to cancel", under: panel)) == .empty(placeholder: nil))
    }

    /// The rule over a past prompt is at most 60 columns wide, so a past
    /// prompt never reads as the box.
    @Test(arguments: [40, 62, 120])
    func aPastPromptIsNotTheBox(columns: Int) {
        let screen = ScreenFixture.synthetic([
            Self.rule(min(60, columns - 3)),
            "\u{1B}[0m\u{1B}[1m\u{1B}[38;5;4m> Reply with only the word pear.\u{1B}[0m",
            Self.rule(min(60, columns - 3)),
            Self.grey + String(repeating: " ", count: columns) + SGR.reset,
        ])

        guard case .unknown = Self.detect(screen) else {
            Issue.record("read a past prompt as the box")
            return
        }
    }

    /// A popup's or dialog's selected row draws `> ` and its label in one
    /// blue run, which is not the prompt's marker.
    @Test func aSelectedRowUnderARuleIsNotTheBox() {
        let screen = ScreenFixture.synthetic([
            Self.rule(62), Self.blue + "> 1. Yes, accept this change" + SGR.reset, "  2. No, reject this change", Self.rule(62),
        ])

        #expect(!Self.detect(screen).isSendable)
    }
}
