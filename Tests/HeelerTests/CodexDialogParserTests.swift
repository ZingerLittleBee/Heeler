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

    @Test("At phone width the pointed option's wrapped description stays its detail")
    func pointedQuestionAtPhoneWidth() throws {
        let pointed = try dialog("codex-16-x7-phone-question-pointed")
        #expect(pointed.kind == .codexQuestion)
        #expect(pointed.title == "Pick a size")
        #expect(pointed.options.map(\.label) == ["Small", "Large", "None of the above"])
        #expect(
            pointed.options.map(\.detail)
                == ["Choose the small size.", "Choose the large size.", "Optionally, add details in notes (tab)"])
        #expect(pointed.options.map(\.role) == [.answer, .answer, .otherText])
        #expect(pointed.focus == DialogFocusState(focusedOrdinal: 3))

        let noted = try dialog("codex-17-x7-phone-question-notes")
        #expect(noted.options.map(\.label) == pointed.options.map(\.label))
        #expect(noted.focus == DialogFocusState(focusedOrdinal: 3, notesText: "Medium please"))
        #expect(noted.fingerprint == pointed.fingerprint)
    }

    /// codex-16 with the pointer on option 1, as Codex draws it before a
    /// move, and option 3's description as given.
    private static func phoneQuestion(thirdDetail: (String, String) = ("Optionally, add details in notes", "(tab)"))
        throws -> ANSIScreen
    {
        var rows = try ScreenFixture.text("codex-16-x7-phone-question-pointed").components(separatedBy: "\n")
        rows[33] =
            "  " + SGR.reset + SGR.bold + SGR.reverse + "› 1. Small              " + SGR.reset + SGR.reverse
            + "Choose the small size." + SGR.reset + SGR.bold + SGR.reverse + "          " + SGR.reset
        rows[35] = "    3. None of the above  " + SGR.reset + SGR.dim + thirdDetail.0 + SGR.reset
        rows[36] = "                          " + SGR.reset + SGR.dim + thirdDetail.1 + SGR.reset
        return ANSIScreenDecoder.decode(rows.joined(separator: "\n"))
    }

    @Test("At phone width moving the pointer down the options keeps the fingerprint (synthetic)")
    func phoneQuestionPointerOnFirst() throws {
        let first = try #require(CodexDialogParser.parse(try Self.phoneQuestion()).dialog)
        let pointed = try dialog("codex-16-x7-phone-question-pointed")
        #expect(first.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(first.options.map(\.label) == pointed.options.map(\.label))
        #expect(first.options.map(\.detail) == pointed.options.map(\.detail))
        #expect(first.fingerprint == pointed.fingerprint)
    }

    @Test("A wrapped Chinese description joins without a space (synthetic)")
    func wrappedChineseDetail() throws {
        let dialog = try #require(
            CodexDialogParser.parse(try Self.phoneQuestion(thirdDetail: ("可以在备注里补充", "细节。"))).dialog)
        #expect(dialog.options.last?.detail == "可以在备注里补充细节。")
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

    @Test("A countdown on the folded questions keeps their title and fingerprint")
    func collapsedQuestionsCountdown() throws {
        let ticking = try dialog("codex-18-x7-phone-async-countdown")
        #expect(ticking.kind == .codexAsyncCollapsed)
        #expect(ticking.title == "2 questions")
        #expect(ticking.fingerprint == (try dialog("codex-08-x4-async-collapsed")).fingerprint)
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

    @Test("The folder trust screen in a Git repository's subdirectory")
    func workspaceTrust() throws {
        let dialog = try dialog("codex-20-x8-trust")
        #expect(dialog.kind == .codexWorkspaceTrust)
        #expect(dialog.program == .codex)
        #expect(dialog.title == "Folder access")
        #expect(dialog.subject.workspacePath == Self.trustFolder)
        #expect(dialog.subject.workspaceRoot == Self.trustRoot)
        #expect(dialog.body == Self.trustBody)
        #expect(dialog.options.map(\.label) == ["Trust and continue", "Quit"])
        #expect(dialog.options.map(\.number) == [1, 2])
        #expect(dialog.options.map(\.role) == [.trust, .exitProgram])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.rows == 1..<15)
    }

    @Test("At phone width the trust screen's wrapped paths join, and it keeps its fingerprint")
    func workspaceTrustAtPhoneWidth() throws {
        let wide = try dialog("codex-20-x8-trust")
        for stem in ["codex-21-x8-phone-trust", "codex-22-x8-phone-trust-focus-quit"] {
            let phone = try dialog(stem)
            #expect(phone.kind == .codexWorkspaceTrust, "\(stem)")
            #expect(phone.subject.workspacePath == Self.trustFolder, "\(stem)")
            #expect(phone.subject.workspaceRoot == Self.trustRoot, "\(stem)")
            #expect(phone.body == Self.trustBody, "\(stem)")
            #expect(phone.fingerprint == wide.fingerprint, "\(stem)")
            #expect(phone.rows == 1..<20, "\(stem)")
        }
        #expect(try dialog("codex-22-x8-phone-trust-focus-quit").focus == DialogFocusState(focusedOrdinal: 2))
    }

    @Test("Without --no-daemon the trust screen goes back to the Agent Command Center")
    func workspaceTrustCommandCenter() throws {
        let dialog = try dialog("codex-23-x8-trust-command-center")
        #expect(dialog.kind == .codexWorkspaceTrust)
        #expect(dialog.subject.workspacePath == "/private/tmp/hct/daemon-repo")
        #expect(dialog.subject.workspaceRoot == nil)
        #expect(dialog.body.count == 2)
        #expect(dialog.options.map(\.label) == ["Trust and continue", "Back to Agent Command Center"])
        #expect(dialog.options.map(\.role) == [.trust, .decline])
    }

    @Test("A trust screen offering an option Heeler does not know goes to the generic card (synthetic)")
    func workspaceTrustUnknownOption() throws {
        let text = try ScreenFixture.text("codex-20-x8-trust").replacingOccurrences(of: "2. Quit", with: "2. Leave")
        let excerpt = try #require(CodexDialogParser.parse(ANSIScreenDecoder.decode(text)).excerpt)
        #expect(excerpt.reason.contains("Leave"))
        #expect(excerpt.rows.first?.trimmedText == "Folder access")
    }

    private static let trustRoot = "/private/tmp/hct/scratch-repository-for-heeler-trust-probe"
    private static let trustFolder = trustRoot + "/nested/worktree-sync-fix"
    private static let trustBody = [
        trustFolder,
        "Note: You\u{2019}re in a subdirectory of a Git project. Trusting will apply to the repository root:",
        trustRoot,
        "Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. Folder "
            + "settings can run code automatically, even without a model request. Continue only if you trust these "
            + "files. Your trust decision will be saved.",
    ]

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

    @Test("An MCP tool approval at 41 columns goes generic with its question in the excerpt")
    func mcpToolListAtPhoneWidth() throws {
        let result = CodexDialogParser.parse(try ScreenFixture.screen("codex-15-x6-mcp-tool-list"))
        let excerpt = try #require(result.excerpt, "parsed as \(result)")
        #expect(excerpt.reason == "Heeler does not know this list.")
        let texts = excerpt.rows.map(\.trimmedText)
        #expect(texts.first == "Field 1/1")
        #expect(texts.contains("Allow the probe MCP server to run"))
        #expect(!texts.contains("+ Show details"))
        #expect(excerpt.numbered.keys.sorted() == [1, 2, 3, 4])
    }

    @Test("An MCP tool approval's generic buttons keep the label column, wrapped label rows joined")
    func mcpToolListLabels() throws {
        let excerpt = try #require(CodexDialogParser.parse(try ScreenFixture.screen("codex-15-x6-mcp-tool-list")).excerpt)
        #expect(
            excerpt.numbered == [1: "Allow", 2: "Allow for this session", 3: "Always allow", 4: "Cancel"])
    }

    @Test("A two-column row cuts at the gap and joins only rows at its label column (synthetic)")
    func twoColumnLabels() throws {
        let screen = ScreenFixture.synthetic([
            "  " + SGR.bold + "Allow the probe MCP server to run tool \"echo\"?" + SGR.reset,
            "",
            SGR.bold + SGR.reverse + "› 1. Allow once" + SGR.reset + "      " + SGR.reverse + "Run it" + SGR.reset,
            "                     " + SGR.reverse + "now" + SGR.reset,
            "  2. Allow for the" + "   " + SGR.dim + "Remember" + SGR.reset,
            "     whole session" + "   " + SGR.dim + "it" + SGR.reset,
            "  3. Deny  me" + "      " + SGR.dim + "Stop" + SGR.reset,
            "",
            "  " + SGR.dim + "enter to submit | esc to cancel" + SGR.reset,
        ])
        let excerpt = try #require(CodexDialogParser.parse(screen).excerpt, "parsed as \(CodexDialogParser.parse(screen))")
        #expect(excerpt.numbered == [1: "Allow once", 2: "Allow for the whole session", 3: "Deny  me"])
    }

    /// Codex 0.162.1 puts the description two blanks past the widest label
    /// (`selection_popup_common.rs` `desc_col = max_name_width + 2`), so on a
    /// pane wide enough for the label not to wrap that row has only a
    /// two-blank gap; the description's dim style marks it.
    @Test("A wide two-column list cuts the widest label at its two-blank gap (synthetic, codex-19 rows)")
    func twoBlankGapLabels() throws {
        let screen = ScreenFixture.synthetic([
            "  " + SGR.bold + "Implement this plan?" + SGR.reset,
            "",
            SGR.bold + SGR.reverse + "› 1. Yes, implement this plan          " + SGR.reset + SGR.reverse
                + "Switch to Default and start coding" + SGR.reset,
            "  2. Yes, clear context and implement  " + SGR.reset + SGR.dim
                + "Start a fresh thread (current context: 4% used)" + SGR.reset,
            "  3. No, stay in Plan mode             " + SGR.reset + SGR.dim + "Continue planning with the model"
                + SGR.reset,
            "",
            "  " + SGR.dim + "enter to submit | esc to cancel" + SGR.reset,
        ])
        let excerpt = try #require(CodexDialogParser.parse(screen).excerpt, "parsed as \(CodexDialogParser.parse(screen))")
        #expect(
            excerpt.numbered == [
                1: "Yes, implement this plan", 2: "Yes, clear context and implement", 3: "No, stay in Plan mode",
            ])
    }

    @Test("A list whose wrapped details put the pointed option far above the footer still goes generic (synthetic)")
    func tallWrappedList() throws {
        let details = (1...18).map { "       detail line \($0)" }
        let screen = ScreenFixture.synthetic(
            ["  " + SGR.bold + "Allow the probe MCP server to run" + SGR.reset, "", ""]
                + [SGR.bold + SGR.reverse + "› 1. Allow" + SGR.reset] + details
                + ["  2. Deny", "", "  " + SGR.dim + "enter to submit | esc to cancel" + SGR.reset])
        let excerpt = try #require(CodexDialogParser.parse(screen).excerpt, "parsed as \(CodexDialogParser.parse(screen))")
        #expect(excerpt.reason == "Heeler does not know this list.")
        #expect(excerpt.numbered.keys.sorted() == [1, 2])
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
