import Foundation
import Testing

@testable import Heeler

/// Oh My Pi 18.11.1's panels as captured live: the tool approval is a known
/// dialog, other titled panels hold sending as excerpts, and tool renderings
/// are not dialogs.
@Suite("OMP dialog parser")
struct OMPDialogParserTests {
    private func parse(_ stem: String) throws -> DialogParseResult {
        BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: .omp)
    }

    private func dialog(_ stem: String) throws -> BlockedDialog {
        let result = try parse(stem)
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    @Test(arguments: [
        ("omp-24-approval-a-dialog", "echo approved-2", 33),
        ("omp-23-approval-a-ctrlq-early", "echo approved-1", 24),
    ])
    func approvalBashIsParsedWithCommandAndTwoOptions(stem: String, command: String, top: Int) throws {
        let dialog = try dialog(stem)
        #expect(dialog.kind == .ompApproval)
        #expect(dialog.program == .omp)
        #expect(dialog.title == "Allow tool: bash")
        #expect(dialog.subject.toolName == "bash")
        #expect(dialog.subject.command == command)
        #expect(dialog.subject.reason == nil)
        #expect(dialog.body == ["Command: \(command)"])
        #expect(dialog.rows == top..<(top + 5))
        #expect(dialog.options.map(\.label) == ["Approve", "Deny"])
        #expect(dialog.options.map(\.shortcut) == ["ctrl+q", "esc"])
        #expect(dialog.options.map(\.role) == [.approve, .decline])
        #expect(dialog.options.allSatisfy { $0.number == nil })
    }

    /// Oh My Pi 18.12.1 lists the approval's choices under the details,
    /// the pointer on the focused one. The list becomes the card's options,
    /// its session row included, and stays out of the body.
    @Test func approvalChoiceListBecomesTheOptions() throws {
        let dialog = try dialog("omp-36-approval-edit-18-12")
        #expect(dialog.kind == .ompApproval)
        #expect(dialog.title == "Allow tool: edit")
        #expect(dialog.subject.toolName == "edit")
        #expect(dialog.body == ["File: notes.txt"])
        #expect(dialog.rows == 30..<38)
        #expect(dialog.options.map(\.label) == ["Approve", "Approve edit for this session", "Deny"])
        #expect(dialog.options.map(\.shortcut) == ["ctrl+q", nil, "esc"])
        #expect(dialog.options.map(\.role) == [.approve, .approvePersistent, .decline])
        #expect(dialog.options.map(\.ordinal) == [1, 2, 3])
        #expect(dialog.options.allSatisfy { $0.number == nil })
        #expect(dialog.focus.focusedOrdinal == 1)
        #expect(!dialog.focus.composerDraftGuard)
        #expect(
            dialog.option(2)?.persistenceNote(program: .omp) == "Oh My Pi won't ask again for edit in this session.")
    }

    /// ↓ moves the pointer to the session row; the dialog keeps its
    /// fingerprint, as a focus check needs.
    @Test func approvalFocusFollowsThePointer() throws {
        let moved = try dialog("omp-37-approval-session-a-after-down")
        #expect(moved.focus.focusedOrdinal == 2)
        #expect(moved.options.map(\.label) == ["Approve", "Approve edit for this session", "Deny"])
        #expect(moved.body == ["File: notes.txt"])
        #expect(moved.fingerprint == (try dialog("omp-36-approval-edit-18-12")).fingerprint)
    }

    /// With a draft in the prompt below, Oh My Pi draws the pointer on
    /// `Deny and send message` whatever the list's focus, the footer drops
    /// `choose`, and arrow keys edit the draft. The list still stays out of
    /// the body, Deny keeps its label, and no focus is read.
    @Test func approvalUnderADraftReadsNoFocus() throws {
        let dialog = try dialog("omp-37-approval-session-b-draft")
        #expect(dialog.body == ["File: notes.txt"])
        #expect(dialog.options.map(\.label) == ["Approve", "Approve edit for this session", "Deny"])
        #expect(dialog.focus.focusedOrdinal == nil)
        #expect(dialog.focus.composerDraftGuard)
        #expect(dialog.fingerprint == (try self.dialog("omp-37-approval-session-a-after-down")).fingerprint)
    }

    /// Typing during an approval goes to the prompt below and turns the
    /// footer's `type to steer instead` into `deny and send`.
    @Test func fingerprintIgnoresDraftFooterAndCountdown() throws {
        let clean = try dialog("omp-24-approval-a-dialog")
        let drafted = try dialog("omp-24-approval-d-typed-abc")
        #expect(clean.fingerprint == drafted.fingerprint)
        #expect(clean.fingerprint != (try dialog("omp-23-approval-a-ctrlq-early")).fingerprint)

        let counting = BlockedDialogParser.parse(
            Self.panel(title: "Allow tool: bash (30s)", details: ["Command: echo approved-2"]), program: .omp)
        #expect(counting.dialog?.title == "Allow tool: bash")
        #expect(counting.dialog?.fingerprint == clean.fingerprint)
    }

    @Test func aCutOffCommandAndAReasonAreRead() throws {
        let screen = Self.panel(
            title: "Allow tool: bash", details: ["Command: rm -rf build && make…", "Reason: Cleans the build"])
        let dialog = try #require(BlockedDialogParser.parse(screen, program: .omp).dialog)
        #expect(dialog.subject.command == "rm -rf build && make")
        #expect(dialog.subject.reason == "Cleans the build")
    }

    @Test func anApprovalWithoutItsKeysIsUnrecognized() throws {
        let screen = Self.panel(title: "Allow tool: bash", details: ["Command: ls"], footer: "↑/↓ scroll")
        #expect(BlockedDialogParser.parse(screen, program: .omp).excerpt != nil)
    }

    @Test func planReviewIsUnrecognized() throws {
        let excerpt = try #require(try parse("omp-31-plan-review").excerpt)
        #expect(excerpt.reason == "Heeler does not know Oh My Pi's \u{201C}Plan Review\u{201D} panel.")
        #expect(excerpt.numbered.isEmpty)
        #expect(excerpt.rows.first?.trimmedText.hasPrefix("╭─ Plan Review ─") == true)
    }

    // MARK: Ask

    @Test func askSingleQuestionFocusStartsOnFirst() throws {
        let ask = try dialog("omp-27-ask-a-dialog")
        #expect(ask.kind == .ompQuestion)
        #expect(ask.program == .omp)
        #expect(ask.title == "Pick a fruit")
        #expect(ask.subject.question == "Pick a fruit")
        #expect(ask.subject.questionHeaders.isEmpty)
        #expect(ask.progress == nil)
        #expect(ask.body == ["Pick a fruit"])
        #expect(ask.rows == 28..<40)
        #expect(ask.options.map(\.label) == ["apple", "pear", "plum", "Other (type your own)"])
        #expect(ask.options.map(\.role) == [.answer, .answer, .answer, .otherText])
        #expect(ask.options.allSatisfy { $0.number == nil && $0.input == nil })
        #expect(ask.focus == DialogFocusState(focusedOrdinal: 1))
    }

    @Test func askFocusMovesWithDown() throws {
        let first = try dialog("omp-27-ask-a-dialog")
        let moved = try dialog("omp-27-ask-c-after-down")
        #expect(moved.focus.focusedOrdinal == 2)
        #expect(moved.fingerprint == first.fingerprint)
    }

    /// OMP binds no digits to its options: `2` leaves the panel as it was.
    @Test func digitDoesNotChangeTheDialog() throws {
        let first = try dialog("omp-27-ask-a-dialog")
        let afterDigit = try dialog("omp-27-ask-b-after-digit2")
        #expect(afterDigit.fingerprint == first.fingerprint)
        #expect(afterDigit.focus == first.focus)
    }

    /// Two questions add a tab row; Enter on the first turns to the second.
    @Test func askTabsAndSecondPage() throws {
        let fruit = try dialog("omp-28-ask2-a-dialog")
        #expect(fruit.kind == .ompQuestion)
        #expect(fruit.subject.questionHeaders == ["fruit", "size"])
        #expect(fruit.progress == "fruit")
        #expect(fruit.subject.question == "Pick a fruit")
        #expect(fruit.options.map(\.label) == ["apple", "pear", "Other (type your own)"])
        #expect(fruit.focus.focusedOrdinal == 1)

        let size = try dialog("omp-28-ask2-b-after-enter-q1")
        #expect(size.kind == .ompQuestion)
        #expect(size.progress == "size")
        #expect(size.subject.question == "Pick a size")
        #expect(size.options.map(\.label) == ["small", "large", "Other (type your own)"])
        #expect(size.focus.focusedOrdinal == 1)
        #expect(size.fingerprint != fruit.fingerprint)
    }

    @Test func submitPageIsReview() throws {
        let review = try dialog("omp-28-ask2-c-submit-page")
        #expect(review.kind == .ompQuestionReview)
        #expect(review.title == "Review answers")
        #expect(review.progress == "Review answers")
        #expect(review.subject.questionHeaders == ["fruit", "size"])
        #expect(
            review.subject.reviewAnswers == [
                .init(question: "fruit", answer: "apple"), .init(question: "size", answer: "small"),
            ])
        #expect(review.options.map(\.label) == ["Submit"])
        #expect(review.options.map(\.role) == [.submit])
        #expect(review.focus.focusedOrdinal == 1)
    }

    /// A draft in the prompt below turns the hints into `Finish or clear the
    /// current prompt to answer`; Enter in the terminal queues the draft
    /// and the same question takes keys again.
    @Test func draftGuardSetsGuardWithoutChangingFingerprint() throws {
        let guarded = try dialog("omp-29-guard-b-ask-with-draft")
        let free = try dialog("omp-29-guard-c-after-enter")
        #expect(guarded.kind == .ompQuestion)
        #expect(guarded.title == "Pick a color")
        #expect(guarded.rows == 26..<38)
        #expect(guarded.focus.composerDraftGuard)
        #expect(!free.focus.composerDraftGuard)
        // The card holds every answer but Stop until the draft goes.
        #expect(guarded.answersHeldByDraft)
        #expect(!free.answersHeldByDraft)
        #expect(guarded.focus.focusedOrdinal == free.focus.focusedOrdinal)
        #expect(guarded.fingerprint == free.fingerprint)
    }

    @Test func aRecommendedOptionLosesItsMark() {
        let screen = Self.ask(["Pick a fruit"], options: ["\u{F054} \u{F10C} apple (Recommended)", "  \u{F10C} pear"])
        let ask = BlockedDialogParser.parse(screen, program: .omp).dialog
        #expect(ask?.options.map(\.label) == ["apple", "pear"])
    }

    /// Only the radio seen live is read: a multi-select question's rows, an
    /// option's description or any other row leaves the question to the
    /// terminal.
    @Test(arguments: [
        ["\u{F054} \u{F096} apple", "  \u{F096} pear"],
        ["\u{F054} \u{F10C} apple", "    A round fruit", "  \u{F10C} pear"],
        ["\u{F054}\u{F10C} apple"],
    ])
    func optionRowsHeelerDoesNotKnowAreUnrecognized(options: [String]) throws {
        // A multi-select page has its own footer.
        let footer = options.contains { $0.contains("\u{F096}") } ? Self.multiSelectFooter : Self.selectFooter
        let screen = Self.ask(["Pick a fruit"], options: options, footer: footer)
        let excerpt = try #require(BlockedDialogParser.parse(screen, program: .omp).excerpt)
        #expect(excerpt.numbered.isEmpty)
        #expect(excerpt.reason.contains("single-select"))
    }

    /// omp 18.11.1 at 62 columns: a multi-select page's footer reads
    /// `toggle · submit`, with no `select`, yet the card still says why
    /// Heeler leaves it to the terminal.
    @Test func aCapturedMultiSelectQuestionNamesSingleSelect() throws {
        let excerpt = try #require(try parse("omp-34-ask-multi-62").excerpt)
        #expect(excerpt.numbered.isEmpty)
        #expect(excerpt.reason == "Heeler answers only Oh My Pi's single-select questions. Answer this one in the terminal.")
    }

    /// The phone wraps the 62-column panel's borders and has no nerd font,
    /// so the card shows the panel's text with the borders gone and the
    /// glyphs mapped or dropped. The fingerprint still reads the rows.
    @Test func aCapturedMultiSelectQuestionShowsWithoutBordersOrNerdGlyphs() throws {
        let excerpt = try #require(try parse("omp-34-ask-multi-62").excerpt)
        let lines = try #require(excerpt.displayLines)
        let text = lines.joined(separator: "\n")
        #expect(!text.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) || $0.value >= 0xF0000 })
        #expect(!text.contains("│") && !text.contains("╭") && !text.contains("╰"))
        #expect(
            lines == [
                "Ask", " colors    Submit", "请选择颜色（可多选）", GenericDialogExcerpt.ruleLine, "❯ ☐ red", "  ☐ green",
                "  ☐ blue", "  ☐ Other (type your own)", GenericDialogExcerpt.ruleLine,
                "toggle · submit · ↑/↓ move · /←/→ question · cance…",
            ])
        #expect(excerpt.fingerprint.value == "038f64a1e20da36752fdc2c5f4fa044f4553a1f6a2a30989a11ec37bcc059fcc")
    }

    @Test func aCheckedBoxAndRadiosShowAsUnicodeSymbols() throws {
        let screen = Self.ask(
            ["Pick fruits"], options: ["\u{F054} \u{F14A} apple", "  \u{F096} pear", "  \u{F192} plum", "  \u{F10C} fig"],
            footer: Self.multiSelectFooter)
        let lines = try #require(BlockedDialogParser.parse(screen, program: .omp).excerpt?.displayLines)
        #expect(lines.contains("❯ ☑ apple"))
        #expect(lines.contains("  ☐ pear"))
        #expect(lines.contains("  ◉ plum"))
        #expect(lines.contains("  ○ fig"))
        #expect(lines.last == "toggle · submit · ↑/↓ move · cancel")
    }

    @Test func aDrawnMultiSelectQuestionIsUnrecognized() async throws {
        let tui = FakeQuestionTUI(
            .omp, [.init(header: "fruit", text: "Pick fruits", options: ["apple", "pear"], isMultiSelect: true)])
        let excerpt = try #require(BlockedDialogParser.parse(await tui.read(), program: .omp).excerpt)
        #expect(excerpt.reason == "Heeler answers only Oh My Pi's single-select questions. Answer this one in the terminal.")
    }

    /// The drawn program reads like the captures, page by page.
    @Test func theDrawnAskReadsLikeTheCaptures() async throws {
        let tui = FakeQuestionTUI(
            .omp, [
                .init(header: "fruit", text: "Pick a fruit", options: ["apple", "pear"]),
                .init(header: "size", text: "Pick a size", options: ["small", "large"]),
            ])
        for (stem, keys) in [
            ("omp-28-ask2-a-dialog", [String]()), ("omp-28-ask2-b-after-enter-q1", ["enter"]),
            ("omp-28-ask2-c-submit-page", ["enter"]),
        ] {
            if !keys.isEmpty { await tui.send(keys) }
            let drawn = try #require(BlockedDialogParser.parse(await tui.read(), program: .omp).dialog, "\(stem)")
            let captured = try dialog(stem)
            #expect(drawn.fingerprint == captured.fingerprint, "\(stem)")
            #expect(drawn.focus == captured.focus, "\(stem)")
            #expect(drawn.subject == captured.subject, "\(stem)")
        }
    }

    /// Idle and working screens with tool renderings in the history, and
    /// the screen after a denial.
    @Test(arguments: [
        "omp-26-approval-b-idle", "omp-27-ask-e-idle", "omp-24-approval-e-enter-deny-and-send",
        "omp-09-tool-working-3s", "omp-08-empty-120-after-first", "omp-14-slash-popup", "omp-33-after-exit-2",
    ])
    func toolRenderBoxesAreNotDialogs(stem: String) throws {
        #expect(try parse(stem) == .none)
    }

    /// Tool renderings drawn right on the band still are not dialogs.
    @Test func untitledAndRuledPanelsOnTheBandAreNotDialogs() {
        for border in ["╭" + String(repeating: "─", count: 30) + "╮", "╭─── Ask 1 questions ─────────╮", "╭───  Ask ────╮"] {
            let screen = Self.panel(border: border, details: ["$ echo hi"])
            #expect(BlockedDialogParser.parse(screen, program: .omp) == .none, "\(border)")
        }
    }

    @Test func piNeverParses() throws {
        for stem in ["omp-24-approval-a-dialog", "omp-31-plan-review", "omp-27-ask-a-dialog"] {
            #expect(BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: .pi) == .none)
        }
    }

    // MARK: Helpers

    /// An `Ask` panel with these question and option rows, ending the
    /// screen.
    private static let selectFooter = "\u{F0311} select · ↑/↓ move · \u{F12B7} cancel"
    private static let multiSelectFooter = "\u{F1050} toggle · \u{F0311} submit · ↑/↓ move · \u{F12B7} cancel"

    private static func ask(_ question: [String], options: [String], footer: String = selectFooter) -> ANSIScreen {
        let rule = "├" + String(repeating: "─", count: 30) + "┤"
        let rows =
            ["Asking…", "╭─ Ask " + String(repeating: "─", count: 24) + "╮"] + question.map { "│ \($0) │" } + [rule]
            + options.map { "│ \($0) │" } + [rule, "│ \(footer) │"]
            + ["╰" + String(repeating: "─", count: 30) + "╯"]
        return ScreenFixture.synthetic(rows)
    }

    private static let band =
        "\u{1B}[48;2;15;18;22m \u{2839} 1m  project \u{1B}[0m──3%────272K─"

    private static func panel(
        title: String, details: [String], footer: String = "ctrl+q approve · esc deny · type to steer instead"
    ) -> ANSIScreen {
        panel(border: "╭─ \(title) " + String(repeating: "─", count: 20) + "╮", details: details, footer: footer)
    }

    /// A panel resting on the working band, the prompt below it.
    private static func panel(border: String, details: [String], footer: String? = nil) -> ANSIScreen {
        var rows = ["Working…", border] + details.map { "│ \($0) │" }
        if let footer { rows += ["├" + String(repeating: "─", count: 30) + "┤", "│ \(footer) │"] }
        rows += ["╰" + String(repeating: "─", count: 30) + "╯", band, "╰─ "]
        return ScreenFixture.synthetic(rows)
    }
}
