import Foundation

/// A change the GitHub tab makes on GitHub (ADR 0065): one gh porcelain
/// command in one exec, naming the item by its URL, never sent twice.
enum GitHubWrite: Sendable, Equatable {
    /// `gh pr comment` or `gh issue comment`.
    case comment(String)
    /// `gh pr review --approve`, with the user's words when there are any.
    case approve(String)
    /// `gh pr merge`, only while the head is the commit the user saw.
    case merge(GitHubMergeMethod, deleteBranch: Bool, headCommit: String)
    /// `gh pr close`, or `gh issue close` with a reason.
    case close(GitHubCloseReason?)

    enum Action: Hashable, Sendable {
        case comment
        case approve
        case merge
        case close
    }

    var action: Action {
        switch self {
        case .comment: .comment
        case .approve: .approve
        case .merge: .merge
        case .close: .close
        }
    }

    /// What the user wrote, for a comment or an approval.
    var typed: String? {
        switch self {
        case .comment(let text), .approve(let text): text
        case .merge, .close: nil
        }
    }

    /// The command as the sheets name it: "gh pr merge".
    static func command(_ action: Action, for kind: GitHubItem.Kind) -> String {
        let noun = kind == .pullRequest ? "pr" : "issue"
        return switch action {
        case .comment: "gh \(noun) comment"
        case .approve: "gh pr review"
        case .merge: "gh pr merge"
        case .close: "gh \(noun) close"
        }
    }

    /// What the detail's "⋯" offers for an item as a detail read found it:
    /// a comment on anything, an approval of an open pull request someone
    /// else opened, a merge of an open pull request that is not a draft, and
    /// closing anything open.
    static func actions(for detail: GitHubItemDetail) -> [Action] {
        let item = detail.item
        let isOpen = item.state == .open || item.state == .draft
        var actions: [Action] = [.comment]
        if item.kind == .pullRequest, isOpen, !detail.isViewers { actions.append(.approve) }
        if item.kind == .pullRequest, item.state == .open { actions.append(.merge) }
        if isOpen { actions.append(.close) }
        return actions
    }

    /// gh's command line. The item goes by its URL, which names its
    /// repository, so gh needs no checkout around it.
    func request(for item: GitHubItem) -> GitHubCLIRequest {
        let noun = item.kind == .pullRequest ? "pr" : "issue"
        switch self {
        case .comment(let body):
            return GitHubCLIRequest(arguments: [noun, "comment", item.url], isMutation: true, body: body)
        case .approve(let body):
            return GitHubCLIRequest(
                arguments: ["pr", "review", item.url, "--approve"], isMutation: true,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body)
        case .merge(let method, let deleteBranch, let headCommit):
            var arguments = ["pr", "merge", item.url, method.flag, "--match-head-commit", headCommit]
            if deleteBranch { arguments.append("--delete-branch") }
            return GitHubCLIRequest(arguments: arguments, isMutation: true)
        case .close(let reason):
            var arguments = [noun, "close", item.url]
            if item.kind == .issue, let reason { arguments += ["--reason", reason.argument] }
            return GitHubCLIRequest(arguments: arguments, isMutation: true)
        }
    }

    /// Why the item, as it was just read again, no longer takes this write;
    /// nil when it does.
    func refusal(by detail: GitHubItemDetail) -> String? {
        let item = detail.item
        if !Self.actions(for: detail).contains(action) {
            switch (item.kind, item.state) {
            case (.pullRequest, .merged):
                return String(localized: "GitHub now shows this pull request as merged, so Heeler ran nothing.")
            case (.pullRequest, .closed):
                return String(localized: "GitHub now shows this pull request as closed, so Heeler ran nothing.")
            case (.issue, .closed):
                return String(localized: "GitHub now shows this issue as closed, so Heeler ran nothing.")
            case (.pullRequest, .draft):
                return String(localized: "This pull request is a draft again, so Heeler ran nothing.")
            default:
                return String(localized: "GitHub no longer offers this here, so Heeler ran nothing.")
            }
        }
        if case .merge(_, _, let headCommit) = self, detail.pullRequest?.headCommit != headCommit {
            return String(
                localized: "New commits were pushed to this pull request after you opened it, so Heeler did not merge. Look at them, then merge again.")
        }
        return nil
    }
}

/// Why an issue is closed.
enum GitHubCloseReason: Sendable, Equatable {
    case completed
    case notPlanned

    /// gh's `--reason` value.
    var argument: String {
        switch self {
        case .completed: "completed"
        case .notPlanned: "not planned"
        }
    }
}

/// What one write came to, before the read after it.
enum GitHubWriteOutcome: Sendable, Equatable {
    /// Nothing was run on GitHub; why, in a sentence.
    case notRun(String)
    /// gh finished with this status. `printed` is its error output, where gh
    /// writes what it did or why not, then its output, as it printed them.
    case finished(exitStatus: Int32, printed: String)
    /// The exec ended without gh's status, so the write may have run; why,
    /// in a sentence. It is not sent again.
    case unknown(String)

    /// What the script reported of one write.
    init(_ outcome: GitHubCLIOutcome) {
        guard let run = outcome.run else {
            self = .notRun(GitHubBannerText.message(for: .notInstalled(isMac: outcome.isMac)))
            return
        }
        switch run.route {
        case .desktopUnavailable:
            self = .notRun(GitHubBannerText.message(for: .notSignedIn))
        case .failed:
            self = .notRun(String(localized: "The Host could not make a private temporary folder for gh."))
        case .desktopTimedOut:
            self = .unknown(String(localized: "gh did not finish in the Mac's desktop session in time."))
        case .ran:
            guard let status = run.exitStatus else {
                self = .unknown(String(localized: "gh did not say how it ended."))
                return
            }
            // gh with no token could change nothing.
            if GitHubCLIScript.writeHadNoToken(exitStatus: status, errorOutput: run.errorOutput) {
                self = .notRun(GitHubBannerText.message(for: .notSignedIn))
                return
            }
            let printed = [run.errorOutput, String(decoding: run.output, as: UTF8.self)]
                .map { $0.trimmingCharacters(in: .newlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            self = .finished(exitStatus: status, printed: printed)
        }
    }
}

/// One write and the item as read after it.
struct GitHubWriteResult: Sendable, Equatable {
    let write: GitHubWrite
    /// The item the write was for, as the detail showed it.
    let item: GitHubItem
    let outcome: GitHubWriteOutcome
    /// The item as read after gh ran, or as read before when nothing ran;
    /// nil when that read failed.
    let detail: GitHubItemDetail?
    /// Why the read after failed.
    let readFailure: GitHubReadFailure?

    /// Nothing to say beyond what the detail and its row show: a comment or
    /// approval gh finished without an error, a merge it finished that the
    /// read after shows merged, and a close the read after shows closed
    /// unless gh stopped with an error.
    var isPlainSuccess: Bool {
        let state = detail?.item.state
        switch (write.action, outcome) {
        case (.comment, .finished(exitStatus: 0, _)), (.approve, .finished(exitStatus: 0, _)):
            return true
        case (.merge, .finished(exitStatus: 0, _)):
            return state == .merged
        case (.close, .finished(exitStatus: 0, _)), (.close, .unknown):
            return state == .closed || state == .merged
        default:
            return false
        }
    }
}

/// A write's result that came after the screen it began on had gone, for
/// the tab to show once (ADR 0065).
struct GitHubWriteReport: Identifiable, Equatable {
    let id = UUID()
    let host: GitHubHost
    let result: GitHubWriteResult
}

/// What `GitHubStore.write` came to, for the screen that asked.
enum GitHubWriteDelivery: Equatable {
    /// Nothing ran: a write on the item was already running, or GitHub is
    /// off.
    case ranNothing
    /// What the write came to, for the screen that asked, still on screen.
    case result(GitHubWriteResult)
    /// The write ended after its screen had gone. Whatever ran is done: a
    /// result that is not a plain success waits in `GitHubStore.reports`,
    /// and a screen still up closes rather than offer its form again.
    case screenGone
}
