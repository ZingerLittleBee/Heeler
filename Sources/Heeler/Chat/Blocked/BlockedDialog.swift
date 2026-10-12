import Foundation

/// Which prompt a parsed dialog is. The kind fixes the anchors the parser
/// matched and the actions a card may plan; a prompt the parsers do not
/// know never gets a kind and falls back to the generic card.
enum BlockedDialogKind: String, Sendable, Hashable, CaseIterable {
    case claudeBash
    case claudeFileEdit
    case claudeFileCreate
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

    var program: ChatProgram {
        switch self {
        case .claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFetch, .claudePlan,
            .claudeQuestion, .claudeQuestionReview, .claudeWorkspaceTrust:
            .claude
        case .codexExec, .codexPatch, .codexNetwork, .codexQuestion, .codexAsyncCollapsed,
            .codexAsyncQuestion:
            .codex
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
    /// Declines: Claude's `No…`, Codex's `(esc)` option.
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
    /// `Yes, I trust this folder`.
    case trust
    /// `No, exit`: Claude Code quits.
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

    init(
        focusedOrdinal: Int? = nil, checked: Set<Int> = [], inputText: String? = nil,
        notesText: String? = nil, feedbackOrdinal: Int? = nil
    ) {
        self.focusedOrdinal = focusedOrdinal
        self.checked = checked
        self.inputText = inputText
        self.notesText = notesText
        self.feedbackOrdinal = feedbackOrdinal
    }
}

/// What a dialog asks about, as far as the screen shows it: the fields a
/// transcript matcher compares with pending requests. Narrow screens and
/// tall dialogs can cut any of them short; the transcript has the full text.
struct DialogSubject: Sendable, Hashable {
    /// Claude Bash and Codex exec: the command, rows joined with spaces.
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
    /// Codex: the `Reason:` text.
    var reason: String?
    /// Codex: the `Environment:` value.
    var environment: String?
    /// Questions: the question text shown on this page.
    var question: String?
    /// Claude's question headers in tab order (`Colors`, `Size`), without
    /// the Submit tab. A single question shows its one header chip.
    var questionHeaders: [String] = []
    /// Claude's question review page: question and answer pairs.
    var reviewAnswers: [ReviewAnswer] = []
    /// Claude plan: the plan file from the footer (`~/.claude/plans/…`).
    var planFilePath: String?
    /// Claude workspace trust: the folder.
    var workspacePath: String?

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
    /// `Review your answers`, Codex's `Question 2/2` or async question title.
    let progress: String?
    let options: [DialogOption]
    /// The zero-based screen rows the dialog covers.
    let rows: Range<Int>
    let fingerprint: DialogFingerprint
    let focus: DialogFocusState
    let subject: DialogSubject

    /// The option at a 1-based ordinal.
    func option(_ ordinal: Int) -> DialogOption? {
        options.indices.contains(ordinal - 1) ? options[ordinal - 1] : nil
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
        }
    }
}
