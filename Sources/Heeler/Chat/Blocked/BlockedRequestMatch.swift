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

    private static func matches(_ request: ChatPendingRequest, _ dialog: BlockedDialog) -> Bool {
        let subject = dialog.subject
        switch dialog.kind {
        case .claudeBash:
            return ["Bash", "PowerShell"].contains(request.toolName) && begins(request.summary, with: subject.command)
        case .claudeFileEdit, .claudeFileCreate:
            return ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(request.toolName)
                && sameFile(request.summary, subject.filePath)
        case .claudeFetch:
            return request.toolName == "WebFetch" && begins(request.summary, with: subject.url)
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
        case .claudeWorkspaceTrust, .codexNetwork:
            return false
        }
    }

    /// The screen's text is the request's, or its start where the dialog
    /// was cut off. Wrapping moves spaces, so they do not count.
    private static func begins(_ full: String, with shown: String?) -> Bool {
        let start = DialogRowScanner.comparable(shown ?? "")
        return !start.isEmpty && DialogRowScanner.comparable(full).hasPrefix(start)
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

    private static func asks(_ request: ChatPendingRequest, _ question: String) -> Bool {
        let shown = DialogRowScanner.comparable(question)
        guard !shown.isEmpty else { return false }
        let asked = request.questions.map(\.text) + [request.summary]
        return asked.contains { DialogRowScanner.comparable($0) == shown }
    }
}
