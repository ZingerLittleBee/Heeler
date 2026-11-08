import Foundation
import Testing

@testable import Heeler

/// Antigravity CLI's dialogs, read from agy 1.5.3 captures at 190, 120, 62
/// and 40 columns, from captures of agy under `NO_COLOR` at 93 and 92
/// columns (`nocolor`, herdr 0.9.5), and from synthetic screens laid out
/// the way agy draws, for states no capture shows.
@Suite("Antigravity CLI dialog parser")
struct AgyDialogParserTests {
    private static func dialog(_ stem: String) throws -> BlockedDialog {
        let result = AgyDialogParser.parse(try ScreenFixture.screen(stem))
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    private static let runCommand = "Yes, run command"
    private static let cancel = "No, cancel"

    /// Every capture that shows a dialog, by the kind it reads as.
    private static let dialogs: [String: BlockedDialogKind] = [
        "agy-00-trust-prompt-191x49": .agyWorkspaceTrust,
        "agy-10-trust-prompt-no-selected-190x49": .agyWorkspaceTrust,
        "agy-11-trust-prompt-no-selected-62x41": .agyWorkspaceTrust,
        "agy-12-trust-prompt-no-selected-40x30": .agyWorkspaceTrust,
        "agy-30-perm-run-command-default-120x40": .agyCommand,
        "agy-31-perm-run-command-default-40x30": .agyCommand,
        "agy-31-perm-run-command-default-62x20": .agyCommand,
        "agy-31-perm-run-command-default-62x41": .agyCommand,
        "agy-41-ask-question-single-120x40": .agyQuestion,
        "agy-42-ask-question-single-40x30": .agyQuestion,
        "agy-42-ask-question-single-62x20": .agyQuestion,
        "agy-42-ask-question-single-62x41": .agyQuestion,
        "agy-44-ask-question-multi-120x40": .agyQuestion,
        "agy-45-ask-question-multi-q2-120x40": .agyQuestion,
        "agy-47-perm-file-edit-default-120x40": .agyFileEdit,
        "agy-48-perm-file-edit-default-40x30": .agyFileEdit,
        "agy-48-perm-file-edit-default-62x20": .agyFileEdit,
        "agy-48-perm-file-edit-default-62x41": .agyFileEdit,
        "agy-52-perm-run-command-amend-120x40": .agyCommand,
        "agy-55-perm-run-command-190x49": .agyCommand,
        "agy-69-working-draft-entered-then-perm-dialog-62x41": .agyCommand,
        "agy-77-accept-edits-run-command-120x40": .agyCommand,
        "agy-82-plan-approved-result-120x40": .agyFileEdit,
        "agy-99-perm-file-create-default-120x40": .agyFileCreate,
        "agy-99-perm-file-create-default-40x30": .agyFileCreate,
        "agy-99-perm-file-create-default-62x41": .agyFileCreate,
        "agy-100-ask-question-multiselect-62x41": .agyQuestion,
        "agy-101-ask-question-multiselect-after-digit2-62x41": .agyQuestion,
        "agy-102-ask-question-multiselect-after-3-2-62x41": .agyQuestion,
        "agy-104-ask-question-writein-after-digit-62x41": .agyQuestion,
        "agy-105-ask-question-writein-typed-62x41": .agyQuestion,
        "agy-106-ask-question-multi-q1-after-esc-62x41": .agyQuestion,
        "agy-108-perm-run-command-62x41": .agyCommand,
        "agy-109-perm-run-command-amend-62x41": .agyCommand,
        "agy-110-perm-run-command-amend-typed-62x41": .agyCommand,
        "agy-111-perm-run-command-tab-on-no-62x41": .agyCommand,
        "agy-113-ask-question-multiselect-q1-of-2-62x41": .agyQuestion,
        "agy-114-ask-question-multiselect-q1-after-enter-62x41": .agyQuestion,
        "agy-135-nocolor-perm-run-command-92x47": .agyCommand,
        "agy-139-nocolor-perm-file-create-92x47": .agyFileCreate,
        "agy-141-nocolor-perm-file-edit-92x47": .agyFileEdit,
        "agy-142-nocolor-perm-file-edit-no-selected-92x47": .agyFileEdit,
        "agy-144-nocolor-ask-question-multi-q1-92x47": .agyQuestion,
        "agy-145-nocolor-ask-question-multi-q1-down-92x47": .agyQuestion,
        "agy-146-nocolor-ask-question-multi-q2-92x47": .agyQuestion,
        "agy-148-nocolor-ask-question-multiselect-92x47": .agyQuestion,
        "agy-149-nocolor-ask-question-multiselect-toggled-92x47": .agyQuestion,
        "agy-152-nocolor-trust-prompt-92x47": .agyWorkspaceTrust,
        "agy-153-nocolor-trust-prompt-no-selected-93x45": .agyWorkspaceTrust,
    ]

    @Test(arguments: ScreenFixture.agy)
    func everyCaptureReadsAsItsDialogOrNone(_ stem: String) throws {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: .agy)
        if let kind = Self.dialogs[stem] {
            #expect(result.dialog?.kind == kind, "\(stem) parsed as \(result)")
            #expect(result.dialog?.program == .agy)
        } else {
            // Idle, working, popups, help, the model picker, the artifact
            // review, bash mode and an exited agy show no dialog.
            #expect(result == .none, "\(stem) parsed as \(result)")
        }
    }

    // MARK: Command

    /// agy-30: the request, the question and four options, the first
    /// selected. `No` ends the turn.
    @Test func readsTheCommandPermission() throws {
        let dialog = try Self.dialog("agy-30-perm-run-command-default-120x40")

        #expect(dialog.title == "Run this command?")
        #expect(dialog.subject.command == "sleep 40; echo probe-done")
        #expect(dialog.body == ["sleep 40; echo probe-done"])
        #expect(
            dialog.options.map(\.label) == [
                Self.runCommand,
                "Yes, and always allow in this conversation for commands that start with 'sleep'",
                "Yes, and always allow for commands that start with 'sleep' (Persist to settings.json)",
                Self.cancel,
            ])
        #expect(dialog.options.map(\.number) == [1, 2, 3, 4])
        #expect(dialog.options.map(\.role) == [.approve, .approvePersistent, .approvePersistent, .decline])
        #expect(dialog.options.map(\.detail) == [nil, nil, nil, "Ends the turn"])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.rows == 24..<37)
        #expect(
            dialog.options[1].persistenceNote(program: .agy)
                == "Antigravity CLI won't ask again in this conversation for commands that start this way.")
        #expect(
            dialog.options[2].persistenceNote(program: .agy)
                == "Saves a rule in Antigravity CLI's settings, so commands that start this way aren't asked about "
                + "again.")
    }

    /// At the phone's grids and 40 columns a long option continues at
    /// column 0, and the dialog reads the same, fingerprint included.
    @Test(arguments: [
        "agy-31-perm-run-command-default-40x30", "agy-31-perm-run-command-default-62x20",
        "agy-31-perm-run-command-default-62x41",
    ])
    func readsTheCommandAtEveryGrid(_ stem: String) throws {
        let wide = try Self.dialog("agy-30-perm-run-command-default-120x40")
        let dialog = try Self.dialog(stem)

        #expect(dialog.options == wide.options)
        #expect(dialog.subject == wide.subject)
        #expect(dialog.fingerprint == wide.fingerprint)
    }

    /// agy-109 and agy-110: Tab turned `Yes, run command` into a note
    /// field, empty and then holding text. herdr reports it done. The row
    /// keeps its label and the dialog its fingerprint, so a card's step
    /// into the field checks against the dialog it saw.
    @Test func readsTheAmendFieldAsTheSameDialog() throws {
        let dialog = try Self.dialog("agy-108-perm-run-command-62x41")
        let amend = try Self.dialog("agy-109-perm-run-command-amend-62x41")
        let typed = try Self.dialog("agy-110-perm-run-command-amend-typed-62x41")

        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(amend.focus == DialogFocusState(focusedOrdinal: 1, feedbackOrdinal: 1))
        #expect(
            typed.focus
                == DialogFocusState(focusedOrdinal: 1, inputText: "then also reply with the word kiwi", feedbackOrdinal: 1))
        #expect(amend.options.first?.label == Self.runCommand)
        #expect(amend.fingerprint == dialog.fingerprint)
        #expect(typed.fingerprint == dialog.fingerprint)
        #expect(typed.hasTypedText)
        #expect(!amend.hasTypedText)

        let wide = try Self.dialog("agy-52-perm-run-command-amend-120x40")
        #expect(wide.subject.command == "echo probe-amend")
        #expect(wide.focus == DialogFocusState(focusedOrdinal: 1, feedbackOrdinal: 1))
    }

    /// agy-111: Tab on `No, cancel` gives it the field.
    @Test func readsTheDeclinesNoteField() throws {
        let dialog = try Self.dialog("agy-111-perm-run-command-tab-on-no-62x41")

        #expect(dialog.options.map(\.label).last == Self.cancel)
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 4, feedbackOrdinal: 4))
    }

    // MARK: Files

    /// agy-47: the file, its changed lines, and the shift+tab mode hint
    /// left out.
    @Test func readsTheFileEdit() throws {
        let dialog = try Self.dialog("agy-47-perm-file-edit-default-120x40")

        #expect(dialog.title == "Accept this file edit?")
        #expect(dialog.subject.filePath == "/Users/developer/projects/fruits/fruits.txt")
        #expect(
            dialog.body == [
                "/Users/developer/projects/fruits/fruits.txt", "1  -  cherry", "1  +  cherry", "2  +  date",
            ])
        #expect(dialog.options.map(\.label) == ["Yes, accept this change", "No, reject this change"])
        #expect(dialog.options.map(\.role) == [.approve, .decline])
        #expect(dialog.options.map(\.number) == [1, 2])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
    }

    @Test(arguments: [
        "agy-48-perm-file-edit-default-40x30", "agy-48-perm-file-edit-default-62x20",
        "agy-48-perm-file-edit-default-62x41",
    ])
    func readsTheFileEditAtEveryGrid(_ stem: String) throws {
        let dialog = try Self.dialog(stem)

        #expect(dialog.subject.filePath == "/Users/developer/projects/fruits/fruits.txt")
        #expect(dialog.options.map(\.label) == ["Yes, accept this change", "No, reject this change"])
        #expect(dialog.body.dropFirst().map { $0.prefix(5) } == ["1  - ", "1  + ", "2  + "])
    }

    /// agy-82: a plan's edit adds `ctrl+r Review` to the hint row.
    @Test func readsAPlansFileEdit() throws {
        let dialog = try Self.dialog("agy-82-plan-approved-result-120x40")

        #expect(dialog.subject.filePath == "/Users/developer/projects/fruits/calc.py")
        #expect(dialog.body.count == 8)
        #expect(dialog.options.map(\.role) == [.approve, .decline])
    }

    /// agy-99: a new file's lines, all added, with no mode hint. agy cuts
    /// the path at the screen's edge, and herdr reports the dialog done.
    @Test(arguments: [
        ("agy-99-perm-file-create-default-120x40", "/Users/developer/projects/fruits2/a3note.txt"),
        ("agy-99-perm-file-create-default-62x41", "/Users/developer/projects/fruits2/a3note.txt"),
        ("agy-99-perm-file-create-default-40x30", "/Users/developer/projects/fruits2/a3note"),
    ])
    func readsTheFileCreation(_ stem: String, path: String) throws {
        let dialog = try Self.dialog(stem)

        #expect(dialog.title == "Allow creation of this file?")
        #expect(dialog.subject.filePath == path)
        #expect(dialog.body == [path, "1  +  hello a3"])
        #expect(dialog.options.map(\.label) == ["Yes, allow creation", "No, deny creation"])
        #expect(dialog.options.map(\.role) == [.approve, .decline])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
    }

    // MARK: Questions

    /// agy-41: the recommended answer's marker becomes its detail, and
    /// `Write-in...` is a text answer.
    @Test func readsASingleQuestion() throws {
        let dialog = try Self.dialog("agy-41-ask-question-single-120x40")

        #expect(dialog.title == "Which fruit do you prefer?")
        #expect(dialog.subject.question == "Which fruit do you prefer?")
        #expect(dialog.progress == "Question 1/1")
        #expect(dialog.options.map(\.label) == ["Apple", "Banana", "Write-in..."])
        #expect(dialog.options.map(\.detail) == ["Recommended", nil, nil])
        #expect(dialog.options.map(\.role) == [.answer, .answer, .otherText])
        #expect(dialog.options.map(\.number) == [1, 2, 3])
        #expect(dialog.options.map(\.isChecked) == [nil, nil, nil])
        #expect(dialog.options.last?.input == .placeholder("Write-in..."))
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(!dialog.isMultiSelect)
        #expect(dialog.questionPage?.index == 1)
        #expect(dialog.questionPage?.count == 1)
    }

    @Test(arguments: [
        "agy-42-ask-question-single-40x30", "agy-42-ask-question-single-62x20", "agy-42-ask-question-single-62x41",
    ])
    func readsTheQuestionAtEveryGrid(_ stem: String) throws {
        let wide = try Self.dialog("agy-41-ask-question-single-120x40")
        let dialog = try Self.dialog(stem)

        #expect(dialog.options == wide.options)
        #expect(dialog.fingerprint == wide.fingerprint)
    }

    /// agy-44 and agy-45: two questions, one page each.
    @Test func readsEachPageOfTwoQuestions() throws {
        let first = try Self.dialog("agy-44-ask-question-multi-120x40")
        let second = try Self.dialog("agy-45-ask-question-multi-q2-120x40")

        #expect(first.progress == "Question 1/2")
        #expect(first.title == "What is your favorite color?")
        #expect(first.options.map(\.label) == ["Red", "Blue", "Write-in..."])
        #expect(second.progress == "Question 2/2")
        #expect(second.title == "What is your favorite season?")
        #expect(first.fingerprint != second.fingerprint)
    }

    /// agy-100 to agy-102: a multi-select question's check boxes. A digit
    /// moves the selection to its answer and toggles it; neither the
    /// selection nor the checks change the fingerprint.
    @Test func readsAMultiSelectQuestion() throws {
        let fresh = try Self.dialog("agy-100-ask-question-multiselect-62x41")
        let green = try Self.dialog("agy-101-ask-question-multiselect-after-digit2-62x41")
        let blue = try Self.dialog("agy-102-ask-question-multiselect-after-3-2-62x41")

        #expect(fresh.options.map(\.label) == ["red", "green", "blue", "Write-in..."])
        #expect(fresh.options.map(\.isChecked) == [false, false, false, nil])
        #expect(fresh.isMultiSelect)
        #expect(fresh.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(green.focus == DialogFocusState(focusedOrdinal: 2, checked: [2]))
        #expect(blue.focus == DialogFocusState(focusedOrdinal: 2, checked: [3]))
        #expect(green.fingerprint == fresh.fingerprint)
        #expect(blue.fingerprint == fresh.fingerprint)
    }

    /// agy-113: the first of two questions is multi-select. Its hint row,
    /// cut at 62 columns, loses `esc Skip`, so herdr reports it done.
    @Test func readsAMultiSelectPageOfTwo() throws {
        let dialog = try Self.dialog("agy-113-ask-question-multiselect-q1-of-2-62x41")

        #expect(dialog.progress == "Question 1/2")
        #expect(dialog.isMultiSelect)
        #expect(dialog.options.map(\.label) == ["apple", "pear", "plum", "Write-in..."])
    }

    /// agy-104 and agy-105: the Write-in row's digit opens `Your answer:`;
    /// what is typed there is the field's text.
    @Test func readsTheWriteInField() throws {
        let question = try Self.dialog("agy-104-ask-question-writein-after-digit-62x41")
        let typed = try Self.dialog("agy-105-ask-question-writein-typed-62x41")

        #expect(question.options.map(\.label) == ["cat", "dog", "Write-in..."])
        #expect(question.focus == DialogFocusState(focusedOrdinal: 3, feedbackOrdinal: 3))
        #expect(typed.focus == DialogFocusState(focusedOrdinal: 3, inputText: "a small hamster", feedbackOrdinal: 3))
        #expect(typed.fingerprint == question.fingerprint)
        #expect(typed.hasTypedText)
    }

    // MARK: Trust

    /// agy-00: the folder, the question and agy's note, then two options
    /// without numbers, trusting selected.
    @Test func readsTheTrustPrompt() throws {
        let dialog = try Self.dialog("agy-00-trust-prompt-191x49")

        #expect(dialog.title == "Accessing workspace:")
        #expect(dialog.subject.workspacePath == "/Users/developer/projects/fruits")
        #expect(
            dialog.body == [
                "/Users/developer/projects/fruits", "Do you trust the contents of this project?",
                "Antigravity CLI requires permission to read, edit, and execute files here.",
            ])
        #expect(dialog.options.map(\.label) == ["Yes, I trust this folder", "No, exit"])
        #expect(dialog.options.map(\.number) == [nil, nil])
        #expect(dialog.options.map(\.role) == [.trust, .exitProgram])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
        #expect(dialog.rows.lowerBound == 0)
    }

    /// agy-10 to agy-12: `No, exit` selected, and at 40 columns the
    /// question and note wrapped, where herdr reports the prompt idle.
    @Test(arguments: [
        "agy-10-trust-prompt-no-selected-190x49", "agy-11-trust-prompt-no-selected-62x41",
        "agy-12-trust-prompt-no-selected-40x30",
    ])
    func readsTheTrustPromptWithExitSelected(_ stem: String) throws {
        let dialog = try Self.dialog(stem)

        #expect(dialog.subject.workspacePath == "/Users/developer/projects/fruits3")
        #expect(dialog.body.dropFirst().first == "Do you trust the contents of this project?")
        #expect(dialog.options.map(\.role) == [.trust, .exitProgram])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 2))
    }

    // MARK: Scrollback

    /// A declined call leaves its dialog's title in the scrollback, bold
    /// blue over `⎿  User declined the tool call`. The parser reads the
    /// live dialog under it, framed from its own bold yellow title.
    @Test(arguments: [
        ("agy-69-working-draft-entered-then-perm-dialog-62x41", 25),
        ("agy-113-ask-question-multiselect-q1-of-2-62x41", 29),
    ])
    func aDeclinedTitleInTheScrollbackIsNoDialog(_ stem: String, liveTitle: Int) throws {
        let text = try ScreenFixture.text(stem)
        #expect(text.contains(Self.declined))
        let dialog = try Self.dialog(stem)
        #expect(dialog.rows.lowerBound == liveTitle)

        // With the live title blue too, no title frames a dialog: the
        // declined one above is not read as one.
        let live = "\(SGR.bold)\u{1B}[38;5;3m\(dialog.kind == .agyCommand ? "Command" : "Question")"
        try #require(text.components(separatedBy: live).count == 2)
        let blue = text.replacingOccurrences(of: live, with: live.replacingOccurrences(of: "38;5;3m", with: "38;5;4m"))
        let result = AgyDialogParser.parse(ANSIScreenDecoder.decode(blue))
        #expect(result.dialog == nil)
        #expect(result.excerpt?.reason == "Heeler can't find the top of Antigravity CLI's dialog.")
    }

    /// agy 1.5.3's declined title: bold, blue 4.
    private static let declined = "\(SGR.bold)\u{1B}[38;5;4mCommand"

    // MARK: Without colors

    /// The start of the folder agy ran in under `NO_COLOR`, where the file
    /// dialogs cut it at 92 columns.
    private static let colorlessFile =
        "/Users/developer/projects/heeler-acceptance/mac-core-2026-11-08/no-color-captures-agy-153-he"

    /// agy-135: a command under `NO_COLOR` reads as agy-77 does in agy's
    /// colors, whose command also starts with `echo`.
    @Test func readsTheColorlessCommand() throws {
        let dialog = try Self.dialog("agy-135-nocolor-perm-run-command-92x47")
        let colored = try Self.dialog("agy-77-accept-edits-run-command-120x40")

        #expect(dialog.title == colored.title)
        #expect(dialog.subject.command == "echo nc-check")
        #expect(dialog.subject.isRequestCut == colored.subject.isRequestCut)
        #expect(dialog.body == ["echo nc-check"])
        #expect(dialog.options == colored.options)
        #expect(dialog.focus == colored.focus)
        #expect(dialog.rows == 17..<30)
    }

    /// agy-139: a new file under `NO_COLOR`, its path cut at the screen's
    /// edge, reads as agy-99 does at 40 columns, where agy cut it too.
    @Test func readsTheColorlessFileCreation() throws {
        let dialog = try Self.dialog("agy-139-nocolor-perm-file-create-92x47")
        let colored = try Self.dialog("agy-99-perm-file-create-default-40x30")

        #expect(dialog.title == colored.title)
        #expect(dialog.subject.filePath == Self.colorlessFile)
        #expect(dialog.subject.isRequestCut)
        #expect(dialog.subject.isRequestCut == colored.subject.isRequestCut)
        #expect(dialog.subject.changesAreCut == colored.subject.changesAreCut)
        #expect(dialog.body == [Self.colorlessFile, "1  +  one"])
        #expect(dialog.options == colored.options)
        #expect(dialog.focus == colored.focus)
    }

    /// agy-141 and agy-142: an edit under `NO_COLOR`, with a context row,
    /// reads as agy-47 does; the selection keeps the fingerprint.
    @Test func readsTheColorlessFileEdit() throws {
        let dialog = try Self.dialog("agy-141-nocolor-perm-file-edit-92x47")
        let declining = try Self.dialog("agy-142-nocolor-perm-file-edit-no-selected-92x47")
        let colored = try Self.dialog("agy-47-perm-file-edit-default-120x40")

        #expect(dialog.title == colored.title)
        #expect(dialog.subject.filePath == Self.colorlessFile)
        #expect(dialog.subject.isRequestCut)
        #expect(!dialog.subject.changesAreCut)
        #expect(dialog.body == [Self.colorlessFile, "1     one", "2  +  two"])
        #expect(dialog.options == colored.options)
        #expect(dialog.focus == colored.focus)
        #expect(declining.focus == DialogFocusState(focusedOrdinal: 2))
        #expect(declining.options.map(\.label) == colored.options.map(\.label))
        #expect(declining.fingerprint == dialog.fingerprint)
    }

    /// agy-144 to agy-146: two questions under `NO_COLOR`, each page read
    /// as agy-44 and agy-45 are in agy's colors.
    @Test func readsColorlessQuestions() throws {
        let first = try Self.dialog("agy-144-nocolor-ask-question-multi-q1-92x47")
        let down = try Self.dialog("agy-145-nocolor-ask-question-multi-q1-down-92x47")
        let second = try Self.dialog("agy-146-nocolor-ask-question-multi-q2-92x47")
        let colored = try Self.dialog("agy-44-ask-question-multi-120x40")

        #expect(first.progress == "Question 1/2")
        #expect(first.title == "Which color?")
        #expect(first.subject.question == "Which color?")
        #expect(first.body == ["Which color?"])
        #expect(first.options.map(\.label) == ["red", "green", "blue", "Write-in..."])
        #expect(first.options.map(\.detail) == ["Recommended", nil, nil, nil])
        #expect(first.options.map(\.role) == [.answer, .answer, .answer, .otherText])
        #expect(first.options.map(\.number) == [1, 2, 3, 4])
        #expect(first.options.map(\.isChecked) == [nil, nil, nil, nil])
        #expect(first.options.last?.input == colored.options.last?.input)
        #expect(first.focus == colored.focus)
        #expect(!first.isMultiSelect)
        #expect(down.focus == DialogFocusState(focusedOrdinal: 2))
        #expect(down.fingerprint == first.fingerprint)
        #expect(second.progress == "Question 2/2")
        #expect(second.title == "Which size?")
        #expect(second.options.map(\.label) == ["small", "large", "Write-in..."])
        #expect(second.fingerprint != first.fingerprint)
    }

    /// agy-148 and agy-149: a multi-select question under `NO_COLOR`, its
    /// boxes read as agy-100 and agy-102 are in agy's colors.
    @Test func readsAColorlessMultiSelectQuestion() throws {
        let fresh = try Self.dialog("agy-148-nocolor-ask-question-multiselect-92x47")
        let toggled = try Self.dialog("agy-149-nocolor-ask-question-multiselect-toggled-92x47")
        let colored = try Self.dialog("agy-100-ask-question-multiselect-62x41")

        #expect(fresh.progress == "Question 1/1")
        #expect(fresh.title == "Which fruits do you like?")
        #expect(fresh.options.map(\.label) == ["apple", "banana", "cherry", "Write-in..."])
        #expect(fresh.options.map(\.detail) == ["Recommended", nil, nil, nil])
        #expect(fresh.options.map(\.isChecked) == colored.options.map(\.isChecked))
        #expect(fresh.options.map(\.role) == colored.options.map(\.role))
        #expect(fresh.isMultiSelect)
        #expect(fresh.focus == colored.focus)
        #expect(toggled.focus == DialogFocusState(focusedOrdinal: 3, checked: [1, 3]))
        #expect(toggled.fingerprint == fresh.fingerprint)
    }

    /// agy-152 and agy-153: the trust prompt under `NO_COLOR`, its folder
    /// wrapped over two bold rows, reads as agy-00 and agy-10 do.
    @Test func readsTheColorlessTrustPrompt() throws {
        let dialog = try Self.dialog("agy-152-nocolor-trust-prompt-92x47")
        let exiting = try Self.dialog("agy-153-nocolor-trust-prompt-no-selected-93x45")
        let colored = try Self.dialog("agy-00-trust-prompt-191x49")
        let path =
            "/Users/developer/projects/heeler-acceptance/mac-core-2026-11-08/no-color-captures-agy-153-"
            + "herdr095workspaceprobefolder/nocolor-trust/untrusted"

        #expect(dialog.title == colored.title)
        #expect(dialog.subject.workspacePath == path)
        #expect(dialog.body.first == path)
        #expect(Array(dialog.body.dropFirst()) == Array(colored.body.dropFirst()))
        #expect(dialog.options == colored.options)
        #expect(dialog.focus == colored.focus)
        #expect(dialog.rows.lowerBound == 0)
        #expect(exiting.subject.workspacePath == path)
        #expect(exiting.options == (try Self.dialog("agy-10-trust-prompt-no-selected-190x49")).options)
    }

    /// Without colors a declined title stays bold, as a live one is, but
    /// no rule follows it, nor any past prompt's bold rows: with the live
    /// title's rule gone, nothing frames a dialog.
    @Test(arguments: ["agy-144-nocolor-ask-question-multi-q1-92x47", "agy-148-nocolor-ask-question-multiselect-92x47"])
    func aColorlessDeclinedTitleInTheScrollbackIsNoDialog(_ stem: String) throws {
        let text = try ScreenFixture.text(stem)
        #expect(text.contains("\(SGR.bold)Pending edit\(SGR.reset)"))
        #expect(text.contains("User declined the tool call"))
        let rule = String(repeating: "─", count: 92)
        try #require(text.components(separatedBy: rule).count == 2)

        let result = AgyDialogParser.parse(ANSIScreenDecoder.decode(text.replacingOccurrences(of: rule, with: "")))

        #expect(result.dialog == nil)
        #expect(result.excerpt?.reason == "Heeler can't find the top of Antigravity CLI's dialog.")
    }

    /// A title and its rule share one palette, and without colors the
    /// rule spans the screen: a bold title over a past prompt's short
    /// plain rule, a yellow title over a plain rule and a bold title
    /// without color over a grey rule frame nothing.
    @Test func aTitleNeedsARuleOfItsPalette() {
        let yellow = "\(SGR.reset)\(SGR.bold)\u{1B}[38;5;3mCommand\(SGR.reset)"
        let plain = "\(SGR.reset)\(SGR.bold)Command\(SGR.reset)"
        let grey = "\(SGR.reset)\u{1B}[38;5;8m" + String(repeating: "─", count: 62) + SGR.reset
        func command(_ title: String, _ rule: String) -> DialogParseResult {
            AgyDialogParser.parse(
                ScreenFixture.synthetic([
                    title, rule, "", "\(SGR.bold)Requesting permission for:\(SGR.reset)", "   ls", "",
                    "\(SGR.bold)Run this command?\(SGR.reset)", "> 1. Yes, run command", "  2. No, cancel", "",
                    "  \(SGR.bold)↑/↓\(SGR.reset) Navigate · \(SGR.bold)tab\(SGR.reset) Amend",
                    "esc to cancel" + String(repeating: " ", count: 49),
                ]))
        }

        #expect(command(plain, String(repeating: "─", count: 62)).dialog?.kind == .agyCommand)
        #expect(command(yellow, grey).dialog?.kind == .agyCommand)
        let short = String(repeating: "─", count: 59)
        let wide = String(repeating: "─", count: 62)
        for (title, rule) in [(plain, short), (yellow, wide), (plain, grey)] {
            let result = command(title, rule)
            #expect(result.dialog == nil)
            #expect(result.excerpt?.reason == "Heeler can't find the top of Antigravity CLI's dialog.")
        }
    }

    // MARK: Unknown

    /// A dialog agy draws with a title Heeler doesn't know holds sending as
    /// an excerpt without numbers.
    @Test func anUnknownDialogIsAnExcerpt() {
        let screen = ScreenFixture.synthetic([
            "\(SGR.reset)\(SGR.bold)\u{1B}[38;5;3mSubagent\(SGR.reset)",
            "\(SGR.reset)\u{1B}[38;5;8m" + String(repeating: "─", count: 62) + SGR.reset,
            "",
            "\(SGR.bold)Allow this subagent to start?\(SGR.reset)",
            "\(SGR.reset)\u{1B}[38;5;12m> 1. Yes\(SGR.reset)",
            "  2. No",
            "",
            "  \(SGR.bold)\u{1B}[38;5;12m↑/↓\(SGR.reset)\u{1B}[38;5;8m Navigate\(SGR.reset)",
            "\(SGR.reset)\u{1B}[38;5;8mesc to cancel\(SGR.reset)",
        ])

        let result = AgyDialogParser.parse(screen)

        guard case .unrecognized(let excerpt) = result else {
            Issue.record("Expected an excerpt, got \(result)")
            return
        }
        #expect(excerpt.numbered.isEmpty)
        #expect(excerpt.rows.count == 8)
        #expect(excerpt.reason.contains("Heeler doesn't know this Antigravity CLI dialog"))
    }

    /// A known dialog with an option agy wasn't seen to draw stays generic
    /// rather than guessing what the option does.
    @Test func aCommandWithAnUnknownOptionIsAnExcerpt() {
        let screen = ScreenFixture.synthetic([
            "\(SGR.reset)\(SGR.bold)\u{1B}[38;5;3mCommand\(SGR.reset)",
            "\(SGR.reset)\u{1B}[38;5;8m" + String(repeating: "─", count: 62) + SGR.reset,
            "",
            "\(SGR.reset)\(SGR.bold)\u{1B}[38;5;7mRequesting permission for:\(SGR.reset)",
            "\(SGR.reset)\u{1B}[38;5;7m   ls\(SGR.reset)",
            "",
            "\(SGR.bold)Run this command?\(SGR.reset)",
            "\(SGR.reset)\u{1B}[38;5;12m> 1. Yes, run command\(SGR.reset)",
            "  2. Run it in a sandbox",
            "  3. No, cancel",
            "",
            "  \(SGR.bold)\u{1B}[38;5;12m↑/↓\(SGR.reset)\u{1B}[38;5;8m Navigate · \(SGR.reset)\(SGR.bold)\u{1B}[38;5;12mtab"
                + "\(SGR.reset)\u{1B}[38;5;8m Amend\(SGR.reset)",
            "\(SGR.reset)\u{1B}[38;5;8mesc to cancel\(SGR.reset)",
        ])

        #expect(AgyDialogParser.parse(screen).excerpt != nil)
    }
}
