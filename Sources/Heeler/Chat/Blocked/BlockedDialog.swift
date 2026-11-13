import Foundation

/// Which prompt a parsed dialog is. The kind fixes the anchors the parser
/// matched and the actions a card may plan; a prompt the parsers do not
/// know never gets a kind and falls back to the generic card.
enum BlockedDialogKind: String, Sendable, Hashable, CaseIterable {
    case claudeBash
    case claudeFileEdit
    case claudeFileCreate
    /// Claude's `Read file`: a read outside the project, such as a staged
    /// upload.
    case claudeFileRead
    case claudeFetch
    case claudePlan
    case claudeQuestion
    case claudeQuestionReview
    case claudeWorkspaceTrust
    case codexExec
    case codexPatch
    case codexNetwork
    case codexQuestion
    /// Codex's asynchronous questions folded into `? N questions` above the
    /// composer. Their text is only in the transcript until expanded.
    case codexAsyncCollapsed
    case codexAsyncQuestion
    /// Codex's `Folder access` screen at startup, before its first prompt:
    /// `Trust and continue`, or `Quit`.
    case codexWorkspaceTrust
    /// Oh My Pi's `Allow tool:` panel, answered by ctrl+q or Esc.
    case ompApproval
    /// One page of Oh My Pi's `Ask` panel: a single-select question,
    /// answered with arrow keys and Enter.
    case ompQuestion
    /// The `Review answers` page after several Oh My Pi questions.
    case ompQuestionReview
    /// Grok Build's permission card, answered by a row's digit.
    case grokPermission
    /// A single question Grok Build's agent asks during its turn, with
    /// single-select answers, answered by a row's key.
    case grokQuestion
    /// The panel Ctrl+C opens while Grok Build's subagents run.
    case grokCancelTurn
    /// The worktree question Grok Build's `/fork` asks, answered by a row's
    /// key. Every answer forks.
    case grokFork
    /// OpenCode's `Permission required`, answered in a row of options:
    /// `Allow once`, `Always allow`, `Reject`.
    case openCodePermission
    /// OpenCode's form with a single single-select question, answered by
    /// digit.
    case openCodeQuestion
    /// Antigravity CLI's `Run this command?`, answered by a row's digit.
    case agyCommand
    /// Antigravity CLI's `Accept this file edit?`, which herdr 0.9.5
    /// reports idle.
    case agyFileEdit
    /// Antigravity CLI's `Allow creation of this file?`, which herdr 0.9.5
    /// reports idle.
    case agyFileCreate
    /// One page of Antigravity CLI's questions, single-select or
    /// multi-select, with its `Write-in...` row.
    case agyQuestion
    /// Antigravity CLI's `Accessing workspace:` at start, before its first
    /// prompt: `Yes, I trust this folder`, or `No, exit`.
    case agyWorkspaceTrust

    var program: ChatProgram {
        switch self {
        case .claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFileRead, .claudeFetch, .claudePlan,
            .claudeQuestion, .claudeQuestionReview, .claudeWorkspaceTrust:
            .claude
        case .codexExec, .codexPatch, .codexNetwork, .codexQuestion, .codexAsyncCollapsed,
            .codexAsyncQuestion, .codexWorkspaceTrust:
            .codex
        case .ompApproval, .ompQuestion, .ompQuestionReview:
            .omp
        case .grokPermission, .grokQuestion, .grokCancelTurn, .grokFork:
            .grok
        case .openCodePermission, .openCodeQuestion:
            .opencode
        case .agyCommand, .agyFileEdit, .agyFileCreate, .agyQuestion, .agyWorkspaceTrust:
            .agy
        }
    }
}

/// What choosing an option does, which sets its button style: the first
/// option is primary, a decline uses the danger color, and an option that
/// writes a rule or switches the permission mode is secondary with a
/// warning line.
enum DialogOptionRole: String, Sendable, Hashable {
    /// Allows this one request.
    case approve
    /// Allows it and stores a rule: `don't ask again`, `always allow`,
    /// `for this session`, Codex `(a)` and `(p)`.
    case approvePersistent
    /// Allows it and switches the permission mode, such as auto mode.
    case approveModeSwitch
    /// Declines: Claude's `No…`, Codex's `(esc)` option, and on Codex's
    /// trust screen `Back to Agent Command Center`, which leaves Codex
    /// running.
    case decline
    /// A question's answer.
    case answer
    /// An answer the user types: Claude's `Type something.` and plan
    /// feedback row, Codex's `None of the above` notes and `Other`.
    case otherText
    /// Claude's `Chat about this`, which declines to clarify the questions.
    case chat
    /// The unnumbered `Next` or `Submit` button under a multi-select page.
    case next
    /// `Submit answers` on the review page.
    case submit
    /// `Cancel` on the review page.
    case cancel
    /// Claude's `Yes, I trust this folder`, Codex's `Trust and continue`.
    case trust
    /// Claude's `No, exit` and Codex's `Quit`: the program quits.
    case exitProgram
}

/// An option row that is a text field.
enum InputRowState: Sendable, Hashable {
    /// Empty, showing its hint.
    case placeholder(String)
    /// Holding typed or pasted text.
    case text(String)
}

/// One choice the dialog offers, as the screen shows it.
struct DialogOption: Sendable, Hashable {
    /// The option's 1-based position in `BlockedDialog.options`, unnumbered
    /// rows included. It differs from `number` once an unnumbered row such
    /// as `Next` comes first.
    let ordinal: Int
    /// The digit the program draws, nil for an unnumbered row.
    let number: Int?
    /// The label as printed, wrapped rows joined and residue dropped. A key
    /// hint such as `(y)` or `(shift+tab)` moves to `shortcut`. An input row
    /// keeps the label it shows when empty, so typing does not change it.
    let label: String
    /// The description: inline after ` · `, on the following row, or in
    /// Codex's second column. Narrow screens can cut it short.
    let detail: String?
    /// The key the label names in parentheses, without them: `y`, `esc`.
    let shortcut: String?
    let role: DialogOptionRole
    let isFocused: Bool
    /// For a multi-select option, whether it is checked; nil otherwise.
    let isChecked: Bool?
    /// Set when the row is a text field.
    let input: InputRowState?

    init(
        ordinal: Int, number: Int?, label: String, detail: String? = nil, shortcut: String? = nil,
        role: DialogOptionRole, isFocused: Bool = false, isChecked: Bool? = nil,
        input: InputRowState? = nil
    ) {
        self.ordinal = ordinal
        self.number = number
        self.label = label
        self.detail = detail
        self.shortcut = shortcut
        self.role = role
        self.isFocused = isFocused
        self.isChecked = isChecked
        self.input = input
    }
}

/// The parts of a dialog that move while the user acts on it, kept out of
/// the fingerprint and checked step by step instead.
struct DialogFocusState: Sendable, Hashable {
    /// The focused option's ordinal, nil when no row shows focus.
    var focusedOrdinal: Int?
    /// Ordinals of checked multi-select options.
    var checked: Set<Int>
    /// The text in the focused input row; nil while it shows its
    /// placeholder or when no input row has focus.
    var inputText: String?
    /// Codex: the notes typed for the highlighted answer. Empty while the
    /// notes field is open but blank, nil while it is closed: keys then go
    /// to the field rather than to the options.
    var notesText: String?
    /// Claude: the option whose row Tab turned into a note field.
    var feedbackOrdinal: Int?
    /// Oh My Pi: the prompt below the question holds a draft, so keys go
    /// into the draft rather than to the question.
    var composerDraftGuard: Bool
    /// Grok Build: the footer shows none of the card's hints, so the
    /// scrollback or one of the card's fields has the keyboard, and keys
    /// would miss the options.
    var keysMissOptions: Bool

    init(
        focusedOrdinal: Int? = nil, checked: Set<Int> = [], inputText: String? = nil,
        notesText: String? = nil, feedbackOrdinal: Int? = nil, composerDraftGuard: Bool = false,
        keysMissOptions: Bool = false
    ) {
        self.focusedOrdinal = focusedOrdinal
        self.checked = checked
        self.inputText = inputText
        self.notesText = notesText
        self.feedbackOrdinal = feedbackOrdinal
        self.composerDraftGuard = composerDraftGuard
        self.keysMissOptions = keysMissOptions
    }
}

/// What a dialog asks about, as far as the screen shows it: the fields a
/// transcript matcher compares with pending requests. Narrow screens and
/// tall dialogs can cut any of them short; the transcript has the full text.
struct DialogSubject: Sendable, Hashable {
    /// Oh My Pi approval: the tool its title names, `bash`. OpenCode
    /// permission: the action its title starts with, `Read`, or `Shell` for
    /// a command.
    var toolName: String?
    /// Claude Bash and Codex exec: the command, rows joined with spaces.
    /// Oh My Pi approval: the `Command:` row, its cut-off mark dropped.
    var command: String?
    /// Claude Bash: the description row above the command.
    var commandDescription: String?
    /// Claude Edit/Write: the file as the dialog names it. Codex patch: the
    /// first `Destination:`.
    var filePath: String?
    /// Codex patch: every `Destination:`.
    var destinations: [String] = []
    /// Claude WebFetch: the URL.
    var url: String?
    /// Claude WebFetch and Codex network access: the host.
    var host: String?
    /// Claude WebFetch: the prompt.
    var prompt: String?
    /// Codex and Oh My Pi: the `Reason:` text.
    var reason: String?
    /// Codex: the `Environment:` value.
    var environment: String?
    /// Questions: the question text shown on this page.
    var question: String?
    /// Claude's question headers in tab order (`Colors`, `Size`), without
    /// the Submit tab. A single question shows its one header chip. Oh My
    /// Pi's tabs likewise, shown only for several questions.
    var questionHeaders: [String] = []
    /// Claude's question review page: question and answer pairs. Oh My
    /// Pi's names each question by its tab.
    var reviewAnswers: [ReviewAnswer] = []
    /// Claude plan: the plan file from the footer (`~/.claude/plans/…`).
    var planFilePath: String?
    /// Workspace trust: the folder.
    var workspacePath: String?
    /// Codex workspace trust: the Git repository root that trusting
    /// applies to, for a folder below it.
    var workspaceRoot: String?
    /// OpenCode permission: the lines under the action, wrapped rows
    /// joined (`Path: .env`, `$ ls -la`). OpenCode swaps them for what the
    /// rule would allow while `Always allow` has focus, so the fingerprint
    /// carries them apart from the body (`DialogFingerprint.matches`).
    var notes: [String] = []
    /// Antigravity CLI permission: the screen cut the command (it ends in
    /// `…`) or the file's path (it reaches the dialog's right edge), so the
    /// call it asks about only starts with it.
    var isRequestCut = false
    /// Antigravity CLI file permission: the changed lines, by their place
    /// among them, that reach the dialog's right edge, where agy cuts a
    /// line without a mark.
    var cutChanges: Set<Int> = []
    /// Antigravity CLI file permission: the screen cut a changed line.
    var changesAreCut: Bool { !cutChanges.isEmpty }

    struct ReviewAnswer: Sendable, Hashable {
        var question: String
        var answer: String
    }
}

/// A dialog the parsers recognized, ready for a native card.
struct BlockedDialog: Sendable, Hashable {
    var program: ChatProgram { kind.program }
    let kind: BlockedDialogKind
    /// The heading as printed: `Bash command`, `Ready to code?`, a
    /// question's text, `Would you like to run the following command?`.
    let title: String
    /// Who asked, from Claude's title suffix: `from the general-purpose
    /// agent`.
    let sourceSuffix: String?
    /// The queue position when several dialogs wait: Claude's `1 of N`,
    /// Codex's `1 of 2` over async questions.
    let positionLabel: String?
    /// Rows between the heading and the options, wrapped rows joined: the
    /// command, file, URL, plan, reason and question rows. Tips are left
    /// out.
    let body: [String]
    /// Where a multi-page dialog stands: Claude's active question tab or
    /// `Review your answers`, Codex's `Question 2/2` or async question title,
    /// Oh My Pi's active question tab or `Review answers`.
    let progress: String?
    let options: [DialogOption]
    /// The zero-based screen rows the dialog covers.
    let rows: Range<Int>
    let fingerprint: DialogFingerprint
    let focus: DialogFocusState
    let subject: DialogSubject
    /// Heeler's own line under the options, about a choice the card leaves
    /// to the terminal: Grok Build's lasting rule cut short to fit.
    var note: String? = nil

    /// The option at a 1-based ordinal.
    func option(_ ordinal: Int) -> DialogOption? {
        options.indices.contains(ordinal - 1) ? options[ordinal - 1] : nil
    }

    /// An Oh My Pi question under a draft in its prompt (`Finish or clear
    /// the current prompt to answer`) takes no answer, only Stop.
    var answersHeldByDraft: Bool {
        [.ompQuestion, .ompQuestionReview].contains(kind) && focus.composerDraftGuard
    }

    /// A multi-select question's page: Claude's, with a `Next` or `Submit`
    /// button under its answers, and Antigravity CLI's, whose answers have
    /// check boxes.
    var isMultiSelect: Bool {
        switch kind {
        case .claudeQuestion: options.contains { $0.role == .next }
        case .agyQuestion: options.contains { $0.isChecked != nil }
        default: false
        }
    }

    /// Codex's and Antigravity CLI's `Question i/n`, as numbers.
    var questionPage: (index: Int, count: Int)? {
        guard let progress, let match = progress.wholeMatch(of: /Question (\d+)\/(\d+)/),
            let index = Int(match.1), let count = Int(match.2)
        else { return nil }
        return (index, count)
    }

    /// A Grok Build permission titled with the card's own question, as
    /// before a subagent starts, whether Grok showed it whole or cut it
    /// at the card's edge with `…`. The Agent wrote the words, so the
    /// card's header shows all of them Grok drew, with no line limit, and
    /// its content doesn't repeat them.
    var asksInTitle: Bool {
        guard kind == .grokPermission, let description = body.first else { return false }
        return description == title || description == "\(title)?"
    }
}

/// A screen with something dialog-like the parsers could not name or trust.
/// The generic card shows these rows verbatim with a button per numbered
/// option.
struct GenericDialogExcerpt: Sendable, Hashable {
    let rows: [ScreenRow]
    /// Numbered options, number to label: rows drawn like options (Claude's
    /// colored numbers, the block above Codex's footer), so a numbered line
    /// in a plan or reply never gets a button.
    let numbered: [Int: String]
    /// Why the screen did not parse as a known dialog.
    let reason: String
    /// Covers the excerpt's text without focus markers, for the same
    /// "screen unchanged" check a parsed dialog gets.
    let fingerprint: DialogFingerprint
    /// What the card shows in place of `rows`, when the parser can read
    /// the dialog's frame better than the phone can draw it: Oh My Pi's
    /// panel without its borders, which wrap at a phone's width, and with
    /// its nerd-font glyphs mapped or dropped. `ruleLine` marks a rule.
    var displayLines: [String]? = nil

    static let ruleLine = "───"
}

enum DialogParseResult: Sendable, Hashable {
    case dialog(BlockedDialog)
    case unrecognized(GenericDialogExcerpt)
    /// Nothing on screen looks like a dialog.
    case none

    var dialog: BlockedDialog? {
        if case .dialog(let dialog) = self { return dialog }
        return nil
    }

    var excerpt: GenericDialogExcerpt? {
        if case .unrecognized(let excerpt) = self { return excerpt }
        return nil
    }

    /// The fingerprint of whatever the screen shows, nil when nothing
    /// looks like a dialog.
    var fingerprint: DialogFingerprint? {
        switch self {
        case .dialog(let dialog): dialog.fingerprint
        case .unrecognized(let excerpt): excerpt.fingerprint
        case .none: nil
        }
    }
}

/// The parser for an Agent's program.
enum BlockedDialogParser {
    static func parse(_ screen: ANSIScreen, program: ChatProgram) -> DialogParseResult {
        switch program {
        case .claude: ClaudeDialogParser.parse(screen)
        case .codex: CodexDialogParser.parse(screen)
        case .omp: OMPDialogParser.parse(screen)
        case .grok: GrokDialogParser.parse(screen)
        case .opencode: OpenCodeDialogParser.parse(screen)
        case .agy: AgyDialogParser.parse(screen)
        // Pi has no dialog parser yet.
        case .pi: .none
        }
    }
}
