import Foundation

/// Finds the transcript's request behind a dialog on screen. The screen
/// decides what a card offers; the request fills in what a narrow or tall
/// dialog cuts short, and gives a Claude card the call whose result
/// confirms an answer. Ties go to the oldest request, since dialogs follow
/// call order.
enum BlockedRequestMatch {
    static func request(for dialog: BlockedDialog, in requests: [ChatPendingRequest]) -> ChatPendingRequest? {
        requests.first { matches($0, dialog) }
    }

    /// Every request the dialog could be asking about, oldest first: those
    /// it matches, and on a Grok Build subagent's card, which names neither
    /// a command nor a file, the spawns its title names. A start of one of
    /// these shows a Grok Build answer took (`BlockedCardStore`).
    static func requests(answering dialog: BlockedDialog, in requests: [ChatPendingRequest]) -> [ChatPendingRequest] {
        requests.filter { matches($0, dialog) || asksToStart($0, dialog) }
    }

    private static func matches(_ request: ChatPendingRequest, _ dialog: BlockedDialog) -> Bool {
        let subject = dialog.subject
        switch dialog.kind {
        case .claudeBash:
            return ["Bash", "PowerShell"].contains(request.toolName) && begins(request.summary, with: subject.command)
        case .claudeFileEdit, .claudeFileCreate:
            return ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(request.toolName)
                && sameFile(request.summary, subject.filePath)
        case .claudeFileRead:
            return request.toolName == "Read" && samePath(request.summary, subject.filePath)
        case .claudeFetch:
            return request.toolName == "WebFetch" && sameURL(request.summary, subject.url)
        case .claudePlan:
            return request.toolName == "ExitPlanMode"
        case .claudeQuestion:
            return request.toolName == "AskUserQuestion" && asks(request, subject.question ?? dialog.title)
        case .claudeQuestionReview:
            return request.toolName == "AskUserQuestion"
        case .codexExec:
            return request.kind == .command && overlaps(request.summary, subject.command)
        case .codexPatch:
            return request.kind == .fileEdit || request.kind == .fileWrite
        case .codexQuestion:
            return request.toolName == "request_user_input" && asks(request, subject.question ?? dialog.title)
        case .codexAsyncCollapsed:
            return request.toolName == "request_user_input_async"
        case .codexAsyncQuestion:
            return request.toolName == "request_user_input_async" && asks(request, dialog.title)
        case .ompApproval:
            // A tool without a `Command:` row matches by its name alone.
            guard request.toolName == subject.toolName else { return false }
            return subject.command == nil || begins(request.summary, with: subject.command)
        case .ompQuestion:
            return request.toolName == "ask" && asks(request, subject.question ?? dialog.title)
        case .ompQuestionReview:
            return request.toolName == "ask"
        case .grokPermission:
            // A command by its start; an edit or a new file by its name.
            if let command = subject.command {
                return request.toolName == "run_terminal_command" && begins(request.summary, with: command)
            }
            return ["search_replace", "write"].contains(request.toolName) && sameFile(request.summary, subject.filePath)
        case .grokQuestion:
            return request.toolName == "ask_user_question" && asks(request, subject.question ?? dialog.title)
        case .openCodePermission:
            return openCodePermission(request, subject)
        case .openCodeQuestion:
            return request.kind == .question && asks(request, subject.question ?? dialog.title)
        case .agyCommand:
            return request.toolName == "run_command" && agyShows(request.summary, subject.command, subject)
        case .agyFileEdit:
            // A write over a file may ask as an edit.
            let tools = AgyToolCall.editTools.union(AgyToolCall.writeTools)
            return tools.contains(request.toolName) && agyShows(request.summary, subject.filePath, subject)
        case .agyFileCreate:
            return AgyToolCall.writeTools.contains(request.toolName)
                && agyShows(request.summary, subject.filePath, subject)
        case .agyQuestion:
            return request.toolName == "ask_question" && asks(request, subject.question ?? dialog.title)
        case .claudeWorkspaceTrust, .codexWorkspaceTrust, .codexNetwork, .grokCancelTurn, .grokFork,
            .agyWorkspaceTrust:
            return false
        }
    }

    /// Before a subagent starts, Grok Build's card asks `Allow
    /// <description>?` and takes that question as its title, whole or as
    /// far as the card's edge, where Grok cut it with `…`. A cut title
    /// names every spawn whose question it starts. Runs of whitespace count
    /// as one space.
    private static func asksToStart(_ request: ChatPendingRequest, _ dialog: BlockedDialog) -> Bool {
        guard request.kind == .agent, dialog.asksInTitle, dialog.subject.command == nil,
            dialog.subject.filePath == nil
        else { return false }
        let asked = words("Allow " + request.summary)
        let title = words(dialog.title)
        guard title.hasSuffix("…") else { return asked == title }
        return asked.hasPrefix(words(String(title.dropLast())))
    }

    /// `text` with each run of whitespace as one space, trimmed.
    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The action on OpenCode's permission names the call's kind, and its
    /// target is the call's file, command or URL. Other actions match no
    /// call, so the card won't reject them.
    private static func openCodePermission(_ request: ChatPendingRequest, _ subject: DialogSubject) -> Bool {
        switch subject.toolName {
        case "Read":
            request.kind == .fileRead && samePath(request.summary, subject.filePath)
        case "Edit", "Write", "Patch":
            [.fileEdit, .fileWrite].contains(request.kind) && samePath(request.summary, subject.filePath)
        case "Shell", "Bash":
            request.kind == .command && begins(request.summary, with: subject.command)
        case "WebFetch":
            request.kind == .web && begins(request.summary, with: subject.url)
        default:
            false
        }
    }

    /// The plan a Claude card shows: the call's Markdown when it agrees
    /// with the plan rows on screen, else those rows. Claude Code 2.1.301
    /// records `input.plan` from the plan file as it stood before a Write
    /// sent in the same message, so the call can hold the previous plan
    /// while the dialog asks about the new one. Rows compare by letters and
    /// digits only, so Markdown, wrapping and bullets don't count; a table
    /// row compares cell by cell, since a wrapped table puts pieces of
    /// several cells on one line, and a list item without its number, since
    /// the terminal renumbers a list.
    static func claudePlanText(call: String?, shownRows: [String]) -> String {
        let shown = shownRows.joined(separator: "\n")
        guard let call, !call.isEmpty else { return shown }
        let recorded = lettersAndDigits(call)
        let disagrees = shownRows.contains { row in
            row.split(whereSeparator: { "│|┃".contains($0) }).contains { cell in
                let text = lettersAndDigits(String(droppingListNumber(String(cell))))
                return text.count >= 8 && !recorded.contains(text)
            }
        }
        return disagrees ? shown : call
    }

    /// The command or path an Antigravity CLI permission card shows: the
    /// screen's, or where the screen cut it, the matched call's, which
    /// starts with it.
    static func agyRequest(on dialog: BlockedDialog, call: ChatPendingRequest?) -> String {
        let shown = dialog.subject.command ?? dialog.subject.filePath ?? ""
        guard dialog.subject.isRequestCut else { return shown }
        return call?.summary ?? dialog.body.first ?? shown
    }

    /// The changed lines an Antigravity CLI file card shows: the screen's,
    /// unless the screen cut one at its edge and the matched call records
    /// the change, whose rows then stand in (`agyChangeRows`).
    static func agyChanges(on dialog: BlockedDialog, call: ChatPendingRequest?) -> [String] {
        let shown = Array(dialog.body.dropFirst())
        guard dialog.subject.changesAreCut, let changes = call?.fileChanges else { return shown }
        let rows = agyChangeRows(changes)
        return rows.isEmpty ? shown : rows
    }

    /// A file call's change in the row format of Antigravity CLI's dialog,
    /// for a card whose screen cut a changed line: the line's number, its
    /// mark and its text, `N  -  old` and `N  +  new`; a context line has
    /// no mark. The rows come from a line diff of the call's target and
    /// replacement, numbered from the line the call names or else 1, so
    /// they can differ from the dialog's: for `cherry` becoming `cherry`
    /// and `date`, agy draws `1  -  cherry`, `1  +  cherry`, `2  +  date`
    /// and the diff `1     cherry`, `2  +  date`.
    static func agyChangeRows(_ changes: ChatFileChanges) -> [String] {
        var rows: [String] = []
        for hunk in changes.files.flatMap(\.hunks) {
            var old = hunk.oldStart
            var new = hunk.newStart
            for line in hunk.lines where !ChatDiffHunk.isNewlineMarker(line) {
                let text = line.dropFirst()
                switch line.first {
                case "-":
                    rows.append("\(old)  -  \(text)")
                    old += 1
                case "+":
                    rows.append("\(new)  +  \(text)")
                    new += 1
                default:
                    rows.append("\(new)     \(text)")
                    old += 1
                    new += 1
                }
            }
        }
        return rows
    }

    /// `text` without a leading `12.` or `12)`.
    private static func droppingListNumber(_ text: String) -> Substring {
        let trimmed = text.drop(while: \.isWhitespace)
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, let marker = trimmed.dropFirst(digits.count).first, marker == "." || marker == ")" else {
            return trimmed
        }
        return trimmed.dropFirst(digits.count + 1)
    }

    private static func lettersAndDigits(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// An Antigravity CLI dialog shows the call's whole command or path,
    /// or its start where the screen cut it. Another call that only starts
    /// the same way, `rm -rf build/tmp` for `rm -rf build`, is another
    /// call. Wrapping moves spaces, so they do not count.
    private static func agyShows(_ full: String, _ shown: String?, _ subject: DialogSubject) -> Bool {
        guard !subject.isRequestCut else { return begins(full, with: shown) }
        let screen = DialogRowScanner.comparable(shown ?? "")
        return !screen.isEmpty && DialogRowScanner.comparable(full) == screen
    }

    /// The screen's text is the request's, or its start where the dialog
    /// was cut off. Wrapping moves spaces, so they do not count.
    private static func begins(_ full: String, with shown: String?) -> Bool {
        let start = DialogRowScanner.comparable(shown ?? "")
        return !start.isEmpty && DialogRowScanner.comparable(full).hasPrefix(start)
    }

    /// The dialog shows the URL Claude Code normalized, which ends a bare
    /// host with `/` (`https://example.com/` for `https://example.com`). A
    /// URL the dialog cut off matches the call it starts, but once the
    /// screen shows where the host ends, the call's host must be the same:
    /// `https://example.com/` never matches `https://example.com.au`.
    private static func sameURL(_ full: String, _ shown: String?) -> Bool {
        let screen = DialogRowScanner.comparable(shown ?? "")
        let call = DialogRowScanner.comparable(full)
        guard !screen.isEmpty else { return false }
        if let screenHost = host(of: screen, complete: true), host(of: call, complete: false) != screenHost {
            return false
        }
        func trimmed(_ url: String) -> String { url.hasSuffix("/") ? String(url.dropLast()) : url }
        return trimmed(call).hasPrefix(trimmed(screen))
    }

    /// The scheme and host of `url`, up to the first `/`, `?` or `#` after
    /// `://`. With `complete`, nil when the text ends before one.
    private static func host(of url: String, complete: Bool) -> Substring? {
        guard let scheme = url.range(of: "://") else { return nil }
        guard let end = url[scheme.upperBound...].firstIndex(where: { "/?#".contains($0) }) else {
            return complete ? nil : url[...]
        }
        return url[..<end]
    }

    /// Codex code mode runs a command inside a script, so either text may
    /// hold the other.
    private static func overlaps(_ full: String, _ shown: String?) -> Bool {
        let screen = DialogRowScanner.comparable(shown ?? "")
        let call = DialogRowScanner.comparable(full)
        return !screen.isEmpty && !call.isEmpty && (call.contains(screen) || screen.contains(call))
    }

    /// Dialogs name a file relative to the project; calls use full paths.
    private static func sameFile(_ path: String, _ shown: String?) -> Bool {
        guard let shown else { return false }
        let name = (shown as NSString).lastPathComponent
        return !name.isEmpty && name == (path as NSString).lastPathComponent
    }

    /// A Read dialog shows the whole path (wrapped), relative to the project
    /// for a file inside it. Every staged image is `image.<ext>` in its own
    /// folder, so the folders must agree too.
    private static func samePath(_ path: String, _ shown: String?) -> Bool {
        let screen = DialogRowScanner.comparable(shown ?? "")
        let call = DialogRowScanner.comparable(path)
        guard !screen.isEmpty else { return false }
        if screen.hasPrefix("~/") { return call.hasSuffix(screen.dropFirst()) }
        return call == screen || call.hasSuffix("/" + screen)
    }

    private static func asks(_ request: ChatPendingRequest, _ question: String) -> Bool {
        let shown = DialogRowScanner.comparable(question)
        guard !shown.isEmpty else { return false }
        let asked = request.questions.map(\.text) + [request.summary]
        return asked.contains { DialogRowScanner.comparable($0) == shown }
    }
}
