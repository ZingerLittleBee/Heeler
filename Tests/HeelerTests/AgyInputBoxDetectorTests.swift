import Foundation
import Testing

@testable import Heeler

/// Antigravity CLI's input box, read from agy 1.5.3 captures at 190, 120,
/// 62, 59 and 40 columns, from captures of agy under `NO_COLOR` at 93, 92
/// and 45 columns (`nocolor`, herdr 0.9.5), and from synthetic screens laid
/// out the way agy draws, for states no capture shows.
@Suite("Antigravity CLI input box")
struct AgyInputBoxDetectorTests {
    /// What a capture reads as, short of its exact text.
    private enum Reading: Equatable {
        case empty, draft, shell, working, waitingForSecondPress, below, dialog, exited
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
        "agy-17-prompt-newline-just-sent-120x40": .working,
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
        "agy-32-perm-after-digit2-120x40": .working,
        "agy-33-working-with-draft-120x40": .draft,
        "agy-34-working-submitted-while-working-120x40": .working,
        "agy-35-done-after-queued-120x40": .working,
        "agy-36-done-final-120x40": .empty,
        "agy-38-esc-while-working-120x40": .empty,
        "agy-39-ctrlc-while-working-120x40": .empty,
        "agy-41-ask-question-single-120x40": .dialog,
        "agy-42-ask-question-single-40x30": .dialog,
        "agy-42-ask-question-single-62x20": .dialog,
        "agy-42-ask-question-single-62x41": .dialog,
        "agy-43-ask-question-after-digit2-120x40": .working,
        "agy-44-ask-question-multi-120x40": .dialog,
        "agy-45-ask-question-multi-q2-120x40": .dialog,
        "agy-46-ask-question-multi-after-esc-120x40": .working,
        "agy-47-perm-file-edit-default-120x40": .dialog,
        "agy-48-perm-file-edit-default-40x30": .dialog,
        "agy-48-perm-file-edit-default-62x20": .dialog,
        "agy-48-perm-file-edit-default-62x41": .dialog,
        "agy-49-prompt-sent-into-edit-dialog-120x40": .working,
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
        "agy-66-working-nodraft-62x41": .working,
        "agy-67-working-tool-running-62x41": .working,
        "agy-68-working-with-draft-62x41": .draft,
        "agy-69-working-draft-entered-then-perm-dialog-62x41": .dialog,
        "agy-70-working-queued-after-approve-62x41": .working,
        "agy-71-working-queued-edit-up-62x41": .draft,
        "agy-72-working-altm-send-now-62x41": .working,
        "agy-73-done-after-altm-62x41": .empty,
        "agy-74-compacting-or-after-62x41": .working,
        "agy-75-after-compact-62x41": .empty,
        "agy-76-mode-cycle-1-120x40": .empty,
        "agy-76-mode-cycle-2-120x40": .empty,
        "agy-76-mode-cycle-3-120x40": .empty,
        "agy-76-mode-cycle-4-120x40": .empty,
        "agy-77-accept-edits-run-command-120x40": .dialog,
        "agy-78-auto-mode-result-120x40": .working,
        "agy-79-plan-mode-result-120x40": .empty,
        "agy-80-artifact-review-ctrl-r-120x40": .below,
        "agy-81-artifact-review-after-y-120x40": .working,
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
        "agy-94-working-nodraft-40x30": .working,
        "agy-95-working-with-draft-40x30": .draft,
        "agy-96-working-queued-40x30": .working,
        "agy-97-esc-with-queued-40x30": .draft,
        "agy-98-working-nodraft-62x20": .working,
        "agy-99-perm-file-create-default-120x40": .dialog,
        "agy-99-perm-file-create-default-40x30": .dialog,
        "agy-99-perm-file-create-default-62x41": .dialog,
        "agy-100-ask-question-multiselect-62x41": .dialog,
        "agy-101-ask-question-multiselect-after-digit2-62x41": .dialog,
        "agy-102-ask-question-multiselect-after-3-2-62x41": .dialog,
        "agy-103-ask-question-multiselect-after-enter-62x41": .working,
        "agy-104-ask-question-writein-after-digit-62x41": .dialog,
        "agy-105-ask-question-writein-typed-62x41": .dialog,
        "agy-106-ask-question-multi-q1-after-esc-62x41": .dialog,
        "agy-107-ask-question-multi-q2-after-digit2-62x41": .working,
        "agy-108-perm-run-command-62x41": .dialog,
        "agy-109-perm-run-command-amend-62x41": .dialog,
        "agy-110-perm-run-command-amend-typed-62x41": .dialog,
        "agy-111-perm-run-command-tab-on-no-62x41": .dialog,
        "agy-113-ask-question-multiselect-q1-of-2-62x41": .dialog,
        "agy-114-ask-question-multiselect-q1-after-enter-62x41": .dialog,
        "agy-115-ask-question-single-after-esc-62x41": .working,
        "agy-116-nocolor-idle-empty-45x45": .empty,
        "agy-117-nocolor-idle-draft-45x45": .draft,
        "agy-118-nocolor-draft-cleared-45x45": .empty,
        "agy-119-nocolor-bash-mode-empty-45x45": .shell,
        "agy-120-nocolor-bash-mode-with-text-45x45": .shell,
        "agy-121-nocolor-after-bash-mode-45x45": .empty,
        "agy-122-nocolor-accept-edits-hint-cut-45x45": .empty,
        "agy-123-nocolor-mode-cycle-accept-edits-92x47": .empty,
        "agy-124-nocolor-mode-cycle-auto-92x47": .empty,
        "agy-125-nocolor-mode-cycle-plan-92x47": .empty,
        "agy-126-nocolor-mode-cycle-default-92x47": .empty,
        "agy-127-nocolor-mode-cycle-accept-edits-again-92x47": .empty,
        "agy-128-nocolor-idle-accept-edits-92x47": .empty,
        "agy-129-nocolor-idle-draft-accept-edits-92x47": .draft,
        "agy-130-nocolor-back-to-default-92x47": .empty,
        "agy-131-nocolor-slash-popup-92x47": .below,
        "agy-132-nocolor-help-shortcuts-93x45": .below,
        "agy-133-nocolor-after-help-92x47": .empty,
        "agy-134-nocolor-working-nodraft-92x47": .working,
        "agy-135-nocolor-perm-run-command-92x47": .dialog,
        "agy-136-nocolor-working-after-run-command-92x47": .working,
        "agy-137-nocolor-working-markdown-prompt-92x47": .working,
        "agy-138-nocolor-idle-after-markdown-reply-92x47": .empty,
        "agy-139-nocolor-perm-file-create-92x47": .dialog,
        "agy-140-nocolor-working-after-file-create-92x47": .working,
        "agy-141-nocolor-perm-file-edit-92x47": .dialog,
        "agy-142-nocolor-perm-file-edit-no-selected-92x47": .dialog,
        "agy-143-nocolor-idle-after-file-edit-declined-92x47": .empty,
        "agy-144-nocolor-ask-question-multi-q1-92x47": .dialog,
        "agy-145-nocolor-ask-question-multi-q1-down-92x47": .dialog,
        "agy-146-nocolor-ask-question-multi-q2-92x47": .dialog,
        "agy-147-nocolor-working-after-questions-92x47": .working,
        "agy-148-nocolor-ask-question-multiselect-92x47": .dialog,
        "agy-149-nocolor-ask-question-multiselect-toggled-92x47": .dialog,
        "agy-150-nocolor-idle-after-multiselect-92x47": .empty,
        "agy-151-nocolor-exit-with-conversation-92x47": .exited,
        "agy-152-nocolor-trust-prompt-92x47": .dialog,
        "agy-153-nocolor-trust-prompt-no-selected-93x45": .dialog,
    ]

    private static func reading(of state: InputBoxState) -> Reading? {
        switch state {
        case .empty: .empty
        case .text: .draft
        case .shellMode: .shell
        case .disabled(AgyInputBoxDetector.working): .working
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
        // Without colors the draft shares the marker's run, and in
        // accept-edits mode the footer's plain mode name follows a blank
        // left side.
        ("agy-117-nocolor-idle-draft-45x45", "hello draft"),
        ("agy-129-nocolor-idle-draft-accept-edits-92x47", "hello draft"),
    ])
    func readsADraft(stem: String, draft: String) throws {
        #expect(try Self.detect(stem) == .text(draft))
    }

    /// Accept-edits, auto and plan modes set a grey hint in the empty box,
    /// cut at 40 columns. Under `NO_COLOR` the hint is plain, cut at 45.
    @Test(arguments: [
        ("agy-76-mode-cycle-1-120x40", "Accept-edits mode: file edits auto-approved (shift+tab to cycle)"),
        ("agy-76-mode-cycle-2-120x40", "Auto mode: edits & safe commands auto-approved (shift+tab to cycle)"),
        ("agy-76-mode-cycle-3-120x40", "Plan mode: research & plan only (shift+tab to cycle)"),
        ("agy-84-footer-modes-40x30-40x30", "Plan mode: research & plan only (s..."),
        ("agy-122-nocolor-accept-edits-hint-cut-45x45", "Accept-edits mode: file edits auto-appr..."),
        (
            "agy-123-nocolor-mode-cycle-accept-edits-92x47",
            "Accept-edits mode: file edits auto-approved (shift+tab to cycle)"
        ),
        (
            "agy-124-nocolor-mode-cycle-auto-92x47",
            "Auto mode: edits & safe commands auto-approved (shift+tab to cycle)"
        ),
        ("agy-125-nocolor-mode-cycle-plan-92x47", "Plan mode: research & plan only (shift+tab to cycle)"),
        (
            "agy-127-nocolor-mode-cycle-accept-edits-again-92x47",
            "Accept-edits mode: file edits auto-approved (shift+tab to cycle)"
        ),
        ("agy-128-nocolor-idle-accept-edits-92x47", "Accept-edits mode: file edits auto-approved (shift+tab to cycle)"),
    ])
    func aModesHintIsNotADraft(stem: String, hint: String) throws {
        #expect(try Self.detect(stem) == .empty(placeholder: hint))
    }

    /// agy queues a message sent while a turn runs, but a dialog can open
    /// from the turn before herdr's Enter and take it: 67 is a command's
    /// pending row and spinner over an empty box, which a `Run this
    /// command?` dialog replaced (69). Every running turn holds, whatever
    /// herdr reports, as do one with a message queued (34, 70, 72, 96) and
    /// a compaction (74).
    @Test(arguments: [
        "agy-17-prompt-newline-just-sent-120x40", "agy-34-working-submitted-while-working-120x40",
        "agy-66-working-nodraft-62x41", "agy-67-working-tool-running-62x41",
        "agy-70-working-queued-after-approve-62x41", "agy-72-working-altm-send-now-62x41",
        "agy-74-compacting-or-after-62x41", "agy-94-working-nodraft-40x30", "agy-96-working-queued-40x30",
        "agy-98-working-nodraft-62x20", "agy-134-nocolor-working-nodraft-92x47",
        "agy-136-nocolor-working-after-run-command-92x47", "agy-137-nocolor-working-markdown-prompt-92x47",
        "agy-140-nocolor-working-after-file-create-92x47", "agy-147-nocolor-working-after-questions-92x47",
    ])
    func aRunningTurnHolds(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let working = InputBoxState.disabled(
            "Antigravity CLI is working. Send once it's idle, or steer from the terminal.")

        #expect(Self.detect(screen) == working)
        for activity in [ChatAgentActivity.idle, .working, .unknown] {
            #expect(PreSendGate.check(screen, program: .agy, activity: activity) == .hold(working))
        }
    }

    /// agy's braille spinner over the box holds on its own, as herdr's
    /// `spinner_working` rule reads it as Working.
    @Test func theSpinnerAloneHolds() {
        let spinner = Self.box(footer: "? for shortcuts", over: ["\u{287F}  Generating..."])

        #expect(Self.detect(spinner) == .disabled(AgyInputBoxDetector.working))
        // An idle box over a finished reply.
        #expect(Self.detect(Self.box(footer: "? for shortcuts", over: ["  pear"])) == .empty(placeholder: nil))
    }

    @Test func bashModeIsShellMode() throws {
        #expect(try Self.detect("agy-91-bang-typed-62x41") == .shellMode(""))
        #expect(try Self.detect("agy-93-bash-mode-with-text-62x41") == .shellMode("ls"))
        // Without colors bash mode's `!` is bold.
        #expect(try Self.detect("agy-119-nocolor-bash-mode-empty-45x45") == .shellMode(""))
        #expect(try Self.detect("agy-120-nocolor-bash-mode-with-text-45x45") == .shellMode("ls"))
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
        // Without colors the `/` popup's selected row, right under the box,
        // draws `> ` plain as the prompt's marker is drawn, and no rule
        // follows it.
        ("agy-131-nocolor-slash-popup-92x47", "> /add-dir             Add a directory to the workspace"),
        (
            "agy-132-nocolor-help-shortcuts-93x45",
            "Antigravity CLI   general    commands    shortcuts   (←/→ or tab to cycle)"
        ),
    ])
    func whatAgyDrawsUnderTheBoxHolds(stem: String, row: String) throws {
        #expect(try Self.detect(stem) == .overlay(row))
    }

    @Test(arguments: ["agy-88-exit-with-conversation-120x40", "agy-151-nocolor-exit-with-conversation-92x47"])
    func anExitedAgyHasNoComposer(stem: String) throws {
        guard case .noComposer = try Self.detect(stem) else {
            Issue.record("not noComposer")
            return
        }
    }

    // MARK: Without colors

    /// agy under `NO_COLOR` reads as it does in its colors: each capture
    /// beside a colored one of the same state reads the same, text and
    /// all, and the gate decides the same.
    @Test(arguments: [
        ("agy-116-nocolor-idle-empty-45x45", "agy-57-idle-empty-62x41"),
        ("agy-123-nocolor-mode-cycle-accept-edits-92x47", "agy-76-mode-cycle-1-120x40"),
        ("agy-124-nocolor-mode-cycle-auto-92x47", "agy-76-mode-cycle-2-120x40"),
        ("agy-125-nocolor-mode-cycle-plan-92x47", "agy-76-mode-cycle-3-120x40"),
        ("agy-126-nocolor-mode-cycle-default-92x47", "agy-76-mode-cycle-4-120x40"),
        ("agy-119-nocolor-bash-mode-empty-45x45", "agy-91-bang-typed-62x41"),
        ("agy-120-nocolor-bash-mode-with-text-45x45", "agy-93-bash-mode-with-text-62x41"),
        ("agy-131-nocolor-slash-popup-92x47", "agy-25-slash-popup-120x40"),
        ("agy-132-nocolor-help-shortcuts-93x45", "agy-19-help-shortcuts-120x40"),
        ("agy-134-nocolor-working-nodraft-92x47", "agy-66-working-nodraft-62x41"),
        ("agy-135-nocolor-perm-run-command-92x47", "agy-30-perm-run-command-default-120x40"),
        ("agy-139-nocolor-perm-file-create-92x47", "agy-99-perm-file-create-default-120x40"),
        ("agy-141-nocolor-perm-file-edit-92x47", "agy-47-perm-file-edit-default-120x40"),
        ("agy-144-nocolor-ask-question-multi-q1-92x47", "agy-44-ask-question-multi-120x40"),
        ("agy-148-nocolor-ask-question-multiselect-92x47", "agy-100-ask-question-multiselect-62x41"),
        ("agy-152-nocolor-trust-prompt-92x47", "agy-00-trust-prompt-191x49"),
        ("agy-143-nocolor-idle-after-file-edit-declined-92x47", "agy-83-plan-edit-rejected-120x40"),
    ])
    func aColorlessScreenReadsAsItsColoredCounterpart(colorless: String, colored: String) throws {
        let screen = try ScreenFixture.screen(colorless)
        let twin = try ScreenFixture.screen(colored)

        #expect(Self.detect(screen) == Self.detect(twin))
        for activity in [ChatAgentActivity.idle, .working, .unknown] {
            #expect(
                PreSendGate.check(screen, program: .agy, activity: activity)
                    == PreSendGate.check(twin, program: .agy, activity: activity))
        }
    }

    private static func plainRule(_ width: Int) -> String {
        String(repeating: "─", count: width)
    }

    private static let boldPrompt = "\(SGR.reset)\(SGR.bold)> Reply with only the word pear.\(SGR.reset)"

    /// A box at `columns` as agy draws it under `NO_COLOR`: a past prompt
    /// and its reply, the box with `prompt` in it, and `footer` at the
    /// left of the footer's dim model and effort.
    private static func colorlessBox(columns: Int = 62, prompt: String, footer: String) -> ANSIScreen {
        ScreenFixture.synthetic([
            Self.plainRule(min(60, columns - 3)), Self.boldPrompt, "", "  pear", "",
            Self.plainRule(columns), prompt, Self.plainRule(columns),
            footer + String(repeating: " ", count: 16) + "\(SGR.reset)\(SGR.dim)Gemini 4 Argon · high\(SGR.reset)",
        ])
    }

    /// A mode's hint is plain without colors, so only its text and the
    /// footer tell it from a draft: `? for shortcuts`, which a typed key
    /// clears, or a running turn's footer, which holds anyway. The same
    /// text over a footer without its hint is typed, as it is over an
    /// armed exit's, which a draft keeps (07), and so is a start that ends
    /// in `...` short of the screen's edge.
    @Test func aColorlessModeHintNeedsItsTextAndTheFootersHint() {
        let hint = "Plan mode: research & plan only (shift+tab to cycle)"

        #expect(
            Self.detect(Self.colorlessBox(prompt: "> \(hint)", footer: "? for shortcuts")) == .empty(placeholder: hint))
        #expect(Self.detect(Self.colorlessBox(prompt: "> \(hint)", footer: "")) == .text(hint))
        for exit in ["press ctrl+c again to exit", "press ctrl+d again to exit"] {
            let armed = Self.colorlessBox(prompt: "> \(hint)", footer: exit)
            #expect(Self.detect(armed) == .text(hint))
            #expect(PreSendGate.check(armed, program: .agy, activity: .idle) == .hold(.text(hint)))
        }
        #expect(
            Self.detect(Self.colorlessBox(prompt: "> Plan mode...", footer: "? for shortcuts")) == .text("Plan mode..."))
        #expect(
            Self.detect(Self.colorlessBox(prompt: "> Plan mode: research", footer: "? for shortcuts"))
                == .text("Plan mode: research"))
        #expect(Self.detect(Self.colorlessBox(prompt: ">", footer: "? for shortcuts")) == .empty(placeholder: nil))
        #expect(
            Self.detect(Self.colorlessBox(prompt: "> \(hint)", footer: "esc to cancel"))
                == .disabled(AgyInputBoxDetector.working))
    }

    /// A box's rules and marker share one palette: grey rules around a
    /// plain `>` or a bold `!`, plain rules around a blue `>` or a bold
    /// blue `!`, or one rule of each, are no box.
    @Test func aBoxOfMixedPalettesIsNoBox() {
        let plainBang = "\(SGR.reset)\(SGR.bold)!\(SGR.reset)"
        let blueBang = "\(SGR.reset)\(SGR.bold)\u{1B}[38;5;4m!\(SGR.reset)"
        let boxes = [
            [Self.rule(62), ">", Self.plainRule(62)],
            [Self.plainRule(62), ">", Self.rule(62)],
            [Self.rule(62), ">", Self.rule(62)],
            [Self.rule(62), plainBang, Self.rule(62)],
            [Self.plainRule(62), Self.blue + ">" + SGR.reset, Self.plainRule(62)],
            [Self.plainRule(62), Self.blue + ">" + SGR.reset, Self.rule(62)],
            [Self.plainRule(62), blueBang, Self.plainRule(62)],
        ]
        for box in boxes {
            let state = Self.detect(ScreenFixture.synthetic(box + ["? for shortcuts"]))

            guard case .unknown = state else {
                Issue.record("read \(box) as the box: \(state)")
                continue
            }
        }
        // Each palette alone is a box.
        let colorless = ScreenFixture.synthetic([Self.plainRule(62), ">", Self.plainRule(62), "? for shortcuts"])
        #expect(Self.detect(colorless) == .empty(placeholder: nil))
        let bash = ScreenFixture.synthetic([Self.plainRule(62), plainBang, Self.plainRule(62), "? for shortcuts"])
        #expect(Self.detect(bash) == .shellMode(""))
    }

    /// A past prompt is bold without colors too, so a bold `>` is never
    /// the marker, under its short rule or between full-width ones.
    @Test(arguments: [40, 45, 62, 92])
    func aColorlessPastPromptIsNotTheBox(columns: Int) {
        for width in [min(60, columns - 3), columns] {
            let screen = ScreenFixture.synthetic([
                Self.plainRule(width), Self.boldPrompt, Self.plainRule(width), String(repeating: " ", count: columns),
            ])

            guard case .unknown = Self.detect(screen) else {
                Issue.record("read a past prompt as the box at \(columns) columns under a rule \(width) wide")
                continue
            }
        }
    }

    /// Without colors a dialog's selected row draws `> 1. ` plain, as the
    /// prompt's marker and a draft are drawn. Under its title's rule it
    /// reads as a dialog, and even between two full-width rules it never
    /// reads as an empty box.
    @Test func aColorlessSelectedRowUnderARuleIsNotAnEmptyBox() {
        let options = ["> 1. Yes, accept this change", "  2. No, reject this change"]
        let hint = "  \(SGR.bold)↑/↓\(SGR.reset) Navigate · \(SGR.bold)f\(SGR.reset) full diff"
        let dialog = ScreenFixture.synthetic(
            ["\(SGR.bold)Pending edit\(SGR.reset)", Self.plainRule(62), ""] + options + ["", hint, "esc to cancel"])
        let boxed = ScreenFixture.synthetic([Self.plainRule(62)] + options + [Self.plainRule(62), "? for shortcuts"])

        #expect(Self.detect(dialog) == .dialog(title: nil))
        #expect(!Self.detect(boxed).isSendable)
    }

    // MARK: Synthetic screens

    private static let grey = "\u{1B}[0m\u{1B}[38;5;8m"
    private static let blue = "\u{1B}[0m\u{1B}[38;5;12m"

    private static func rule(_ width: Int) -> String {
        Self.grey + String(repeating: "─", count: width) + SGR.reset
    }

    /// An empty box at `columns`, a past prompt and the rows `over` above
    /// it, `under` it, and `footer`.
    private static func box(
        columns: Int = 62, footer: String, over: [String] = [], under: [String] = []
    ) -> ANSIScreen {
        ScreenFixture.synthetic(
            [
                Self.rule(min(60, columns - 3)),
                "\u{1B}[0m\u{1B}[1m\u{1B}[38;5;4m> Reply with only the word pear.\u{1B}[0m",
                "",
            ] + over + [
                Self.rule(columns),
                Self.blue + ">" + SGR.reset,
                Self.rule(columns),
            ] + under + [Self.grey + footer + SGR.reset])
    }

    private static func detect(_ screen: ANSIScreen) -> InputBoxState {
        InputBoxStateDetector.detect(screen, program: .agy)
    }

    /// A footer Chat doesn't know holds: code search mode's and the
    /// background prompt, spelled as in agy 1.5.3's strings and drawn where
    /// the footer's hint goes, which no capture shows, and Vim mode's
    /// Insert and Visual badges, drawn before `? for shortcuts` on the
    /// footer's row (captured 2026-11-08). Vim's Normal mode draws no
    /// badge, so its box reads as idle and takes the send.
    @Test(arguments: [
        "activated code search mode", "-- INSERT -- ? for shortcuts", "-- VISUAL -- ? for shortcuts",
        "press ctrl+b again to send command to background",
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

    /// A command agy sent to the background keeps its panel under the box
    /// after the turn ends; the footer under the panel decides.
    @Test func theTaskPanelUnderTheBoxDoesNotHold() {
        let panel = ["   ● [00:10:32]  sleep 30; echo probe-two  running", Self.rule(62)]

        #expect(Self.detect(Self.box(footer: "? for shortcuts", under: panel)) == .empty(placeholder: nil))
        #expect(Self.detect(Self.box(footer: "esc to cancel", under: panel)) == .disabled(AgyInputBoxDetector.working))
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
