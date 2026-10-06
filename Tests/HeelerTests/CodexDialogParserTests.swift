import Foundation
import Testing

@testable import Heeler

@Suite("Codex dialog parser")
struct CodexDialogParserTests {
    private func dialog(_ stem: String) throws -> BlockedDialog {
        let result = CodexDialogParser.parse(try ScreenFixture.screen(stem))
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    @Test("A command approval")
    func exec() throws {
        let dialog = try dialog("codex-01-x1-exec")
        #expect(dialog.kind == .codexExec)
        #expect(dialog.program == .codex)
        #expect(dialog.title == "Would you like to run the following command?")
        #expect(dialog.body == ["Environment: local", "Reason: 允许在当前目录创建 x1.txt 吗？", "$ touch x1.txt"])
        #expect(
            dialog.options.map(\.label) == [
                "Yes, proceed", "Yes, and don't ask again for commands that start with `touch x1.txt`",
                "No, and tell Codex what to do differently",
            ])
        #expect(dialog.options.map(\.number) == [1, 2, 3])
        #expect(dialog.options.map(\.shortcut) == ["y", "p", "esc"])
        #expect(dialog.options.map(\.role) == [.approve, .approvePersistent, .decline])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.subject.command == "touch x1.txt")
        #expect(dialog.subject.reason == "允许在当前目录创建 x1.txt 吗？")
        #expect(dialog.subject.environment == "local")
        #expect(dialog.rows == 26..<40)
    }

    @Test(
        "Command approvals at 40 columns join wrapped rows",
        arguments: ["codex-12-x5-narrow-exec", "codex-13-par-first", "codex-14-par-second"])
    func narrowExec(stem: String) throws {
        let files = [
            "codex-12-x5-narrow-exec": "x5-narrow-probe-file.txt", "codex-13-par-first": "par-c.txt",
            "codex-14-par-second": "par-d.txt",
        ]
        let file = try #require(files[stem])
        let dialog = try dialog(stem)
        #expect(dialog.kind == .codexExec)
        // The title wraps at 40 columns.
        #expect(dialog.title == "Would you like to run the following command?")
        #expect(dialog.subject.command == "touch \(file)")
        #expect(dialog.subject.reason == "允许在当前目录创建 \(file) 吗？")
        // `touch x5-` + `narrow-probe-file.txt` joins without a space.
        #expect(
            dialog.options.map(\.label) == [
                "Yes, proceed", "Yes, and don't ask again for commands that start with `touch \(file)`",
                "No, and tell Codex what to do differently",
            ])
        #expect(dialog.options.map(\.shortcut) == ["y", "p", "esc"])
        #expect(dialog.rows == 10..<30)
    }

    @Test("A patch approval names its destination")
    func patch() throws {
        let path = "/private/tmp/heeler-tmp-chat2/probe-codex/patch.txt"
        let dialog = try dialog("codex-02-x2-patch")
        #expect(dialog.kind == .codexPatch)
        #expect(dialog.title == "Would you like to make the following edits?")
        #expect(dialog.body == ["Description: Apply proposed file edits", "Destination: \(path)"])
        #expect(
            dialog.options.map(\.label) == [
                "Yes, proceed", "Yes, and don't ask again for these files", "No, and tell Codex what to do differently",
            ])
        #expect(dialog.options.map(\.shortcut) == ["y", "a", "esc"])
        #expect(dialog.options.map(\.role) == [.approve, .approvePersistent, .decline])
        #expect(dialog.subject.destinations == [path])
        #expect(dialog.subject.filePath == path)
    }

    @Test("A request_user_input question")
    func question() throws {
        let dialog = try dialog("codex-04-x3-q1")
        #expect(dialog.kind == .codexQuestion)
        #expect(dialog.title == "Pick a color")
        #expect(dialog.progress == "Question 1/2")
        #expect(dialog.body.isEmpty)
        #expect(dialog.subject.question == "Pick a color")
        #expect(dialog.options.map(\.label) == ["Red", "Green", "None of the above"])
        #expect(
            dialog.options.map(\.detail) == ["Choose red.", "Choose green.", "Optionally, add details in notes (tab)"])
        #expect(dialog.options.map(\.role) == [.answer, .answer, .otherText])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.rows == 31..<39)
    }

    @Test("The next question, with focus moved and then notes typed")
    func questionNotes() throws {
        let first = try dialog("codex-04-x3-q1")
        let second = try dialog("codex-05-x3-q2")
        #expect(second.title == "Pick a size")
        #expect(second.progress == "Question 2/2")
        #expect(second.options.map(\.label) == ["Small", "Large", "None of the above"])
        #expect(second.fingerprint != first.fingerprint)

        let moved = try dialog("codex-06-x3-q2-up")
        #expect(moved.focus == DialogFocusState(focusedOrdinal: 3))
        let noted = try dialog("codex-07-x3-q2-pasted")
        #expect(noted.focus == DialogFocusState(focusedOrdinal: 3, notesText: "Medium please"))
        #expect(noted.rows == 29..<39)
        #expect(moved.fingerprint == second.fingerprint)
        #expect(noted.fingerprint == second.fingerprint)
    }

    @Test("Asynchronous questions folded above the composer")
    func collapsedQuestions() throws {
        let dialog = try dialog("codex-08-x4-async-collapsed")
        #expect(dialog.kind == .codexAsyncCollapsed)
        #expect(dialog.title == "2 questions")
        #expect(dialog.options.isEmpty)
        #expect(dialog.focus == DialogFocusState())
        #expect(dialog.rows == 31..<34)
    }

    @Test("An expanded asynchronous question, then the next one")
    func expandedQuestions() throws {
        let first = try dialog("codex-09-x4-expanded")
        #expect(first.kind == .codexAsyncQuestion)
        #expect(first.title == "Pick a fruit")
        #expect(first.positionLabel == "1 of 2")
        #expect(first.progress == "Pick a fruit")
        #expect(first.options.map(\.label) == ["Apple", "Banana", "Other"])
        #expect(first.options.map(\.role) == [.answer, .answer, .otherText])
        #expect(first.focus == DialogFocusState(focusedOrdinal: 1))

        let next = try dialog("codex-10-x4-after-digit")
        #expect(next.title == "Pick a drink")
        #expect(next.positionLabel == nil)
        #expect(next.options.map(\.label) == ["Tea", "Coffee", "Other"])
        #expect(next.fingerprint != first.fingerprint)
    }

    @Test("The queued-messages notice lists answered asynchronous questions")
    func queuedNotice() throws {
        let answered = try ScreenFixture.screen("codex-10-x4-after-digit")
        #expect(CodexQueuedNotice.shows(answerTo: "Pick a fruit", in: answered))
        #expect(CodexQueuedNotice.shows(answerTo: "Pick  a fruit", in: answered))
        #expect(!CodexQueuedNotice.shows(answerTo: "Pick a drink", in: answered))
        #expect(CodexQueuedNotice.shows(answerTo: "Pick a fruit", in: try ScreenFixture.screen("codex-11-x4-after-skip")))
        #expect(!CodexQueuedNotice.shows(answerTo: "Pick a fruit", in: try ScreenFixture.screen("codex-09-x4-expanded")))
    }

    @Test(
        "Screens with the composer show no dialog",
        arguments: ["codex-00-ready", "codex-03-x2-after-esc", "codex-11-x4-after-skip"])
    func composerScreens(stem: String) throws {
        #expect(CodexDialogParser.parse(try ScreenFixture.screen(stem)) == DialogParseResult.none)
    }

    // MARK: Synthetic screens

    @Test("An approval Heeler does not know goes to the generic card (synthetic)")
    func unknownApproval() throws {
        let screen = ScreenFixture.synthetic(
            [
                "  " + SGR.bold + "Allow the tool to read the file?" + SGR.reset,
                "",
                "  Reason: " + SGR.italic + "Testing" + SGR.reset,
                "",
            ] + CodexRows.approvalOptions + ["", CodexRows.approvalFooter])
        let excerpt = try #require(CodexDialogParser.parse(screen).excerpt)
        #expect(excerpt.reason == "Heeler does not know the approval \u{201C}Allow the tool to read the file?\u{201D}.")
        #expect(excerpt.numbered == [1: "Yes, proceed (y)", 2: "No, and tell Codex what to do differently (esc)"])
        #expect(excerpt.rows.first?.trimmedText == "Allow the tool to read the file?")
    }

    @Test("Numbered history above an approval whose title scrolled away gets no button (synthetic)")
    func numberedHistory() throws {
        let screen = ScreenFixture.synthetic(
            ["  3. A numbered line in a reply", ""] + CodexRows.approvalOptions + ["", CodexRows.approvalFooter])
        let excerpt = try #require(CodexDialogParser.parse(screen).excerpt)
        #expect(excerpt.reason == "The top of the approval is off screen.")
        #expect(excerpt.numbered == [1: "Yes, proceed (y)", 2: "No, and tell Codex what to do differently (esc)"])
    }

    @Test("Open notes read as empty until typed into, and wrap (synthetic)")
    func openNotes() throws {
        let blank = try #require(CodexDialogParser.parse(CodexRows.question(notes: [CodexRows.notesPlaceholder])).dialog)
        #expect(blank.focus == DialogFocusState(focusedOrdinal: 2, notesText: ""))

        let wrapped = try #require(
            CodexDialogParser.parse(
                CodexRows.question(notes: [
                    "  " + SGR.bold + "›" + SGR.reset + " Medium, but only if the larger one is",
                    "    out of stock",
                ])
            ).dialog)
        #expect(wrapped.focus.notesText == "Medium, but only if the larger one is out of stock")
        #expect(wrapped.fingerprint == blank.fingerprint)
    }

    @Test("A pointed list without a composer goes to the generic card (synthetic)")
    func unknownList() throws {
        let screen = ScreenFixture.synthetic([
            "  " + SGR.bold + "Select a model" + SGR.reset,
            "",
            SGR.bold + SGR.reverse + "› 1. gpt-5" + SGR.reset,
            "  2. gpt-5-mini",
            "",
            "  " + SGR.dim + "Press enter to select" + SGR.reset,
        ])
        let excerpt = try #require(CodexDialogParser.parse(screen).excerpt)
        #expect(excerpt.reason == "Heeler does not know this list.")
        #expect(excerpt.numbered == [1: "gpt-5", 2: "gpt-5-mini"])
    }
}

/// Synthetic Codex rows styled like the captures.
enum CodexRows {
    static let approvalOptions = [
        SGR.bold + SGR.reverse + "› 1. Yes, proceed (y)" + String(repeating: " ", count: 30) + SGR.reset,
        "  2. No, and tell Codex what to do differently (" + SGR.bold + "esc" + SGR.reset + ")",
    ]

    static let approvalFooter =
        "  " + SGR.dim + "Press " + SGR.reset + SGR.bold + "enter" + SGR.reset + SGR.dim + " to confirm or "
        + SGR.reset + SGR.bold + "esc" + SGR.reset + SGR.dim + " to cancel" + SGR.reset

    static let notesPlaceholder = "  " + SGR.bold + "›" + SGR.reset + " " + SGR.dim + "Add notes" + SGR.reset

    /// The last of one question, focus on `None of the above`, with notes
    /// open.
    static func question(notes: [String]) -> ANSIScreen {
        ScreenFixture.synthetic(
            [
                "  " + SGR.dim + "Question 1/1" + SGR.reset,
                "  " + SGR.fg(99, 168, 248) + "Pick a size" + SGR.reset,
                "",
                "    1. Small              " + SGR.dim + "Choose small." + SGR.reset,
                "  " + SGR.bold + SGR.reverse + "› 2. None of the above  " + SGR.reset + SGR.reverse
                    + "Optionally, add details in notes (tab)" + SGR.reset,
                "",
            ] + notes + [
                "",
                "  " + SGR.bold + "tab" + SGR.reset + SGR.dim + " or " + SGR.reset + SGR.bold + "esc" + SGR.reset
                    + SGR.dim + " to clear notes | " + SGR.reset + SGR.bold + "enter" + SGR.reset + " to submit all",
            ])
    }
}
