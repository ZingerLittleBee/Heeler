import Foundation

/// One pull request or issue, as a GitHub list row shows it. `id` is
/// GitHub's node id; `repository` and `number` name it for gh.
struct GitHubItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case pullRequest
        case issue
    }

    enum State: String, Codable, Sendable {
        case open
        case draft
        case merged
        case closed
    }

    /// Why a closed issue was closed, as GitHub says it.
    enum ClosedReason: String, Codable, Sendable {
        case completed
        /// Not planned, or a duplicate.
        case notPlanned
    }

    let id: String
    let kind: Kind
    /// `owner/name`.
    let repository: String
    let number: Int
    var title: String
    var url: String
    var author: String?
    var state: State
    var updatedAt: Date
    var commentCount: Int
    /// A pull request's checks on its last commit; nil for an issue.
    var checks: GitHubChecks?
    var review: GitHubReviewDecision?
    var additions: Int?
    var deletions: Int?
    var labels: [GitHubLabel]
    /// A closed issue's reason; nil for anything else, and when GitHub or a
    /// list saved before Heeler read it gave none.
    var closedReason: ClosedReason? = nil

    /// The repository's name without its owner.
    var repositoryName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
}

/// How a pull request's checks stand, by count.
struct GitHubChecks: Codable, Sendable, Equatable, Hashable {
    var failing: Int
    var pending: Int
    var passing: Int

    enum Summary: Equatable {
        case failing(Int)
        case running
        case passing
        case none
    }

    var summary: Summary {
        if failing > 0 { return .failing(failing) }
        if pending > 0 { return .running }
        if passing > 0 { return .passing }
        return .none
    }
}

enum GitHubReviewDecision: String, Codable, Sendable {
    case approved
    case changesRequested
    case reviewRequired
}

struct GitHubLabel: Codable, Sendable, Equatable, Hashable {
    let name: String
    /// Six hex digits, as GitHub gives it.
    let color: String
}

/// The four lists that involve the account: what each holds of GitHub's
/// open items, and how many GitHub counted.
struct GitHubListSection: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// Pull requests whose review was requested of the account.
        case reviewRequested
        /// Pull requests the account opened.
        case authored
        /// Issues assigned to the account.
        case assigned
        /// Issues the account opened that are not assigned to it.
        case created

        var itemKind: GitHubItem.Kind {
            switch self {
            case .reviewRequested, .authored: .pullRequest
            case .assigned, .created: .issue
            }
        }

        var title: String {
            switch self {
            case .reviewRequested: String(localized: "Needs Your Review")
            case .authored: String(localized: "Your Pull Requests")
            case .assigned: String(localized: "Assigned to You")
            case .created: String(localized: "Created by You")
            }
        }
    }

    let kind: Kind
    /// GitHub's count, which can be more than `items` holds.
    let totalCount: Int
    var items: [GitHubItem]

    var id: Kind { kind }
}

/// One read of the lists on one Host: what involves the account gh is
/// signed in to there.
struct GitHubList: Codable, Sendable, Equatable {
    let login: String
    var sections: [GitHubListSection]
    let readAt: Date

    func sections(of kind: GitHubItem.Kind) -> [GitHubListSection] {
        sections.filter { $0.kind.itemKind == kind }
    }

    /// Replaces every copy of an item that was read again.
    mutating func replace(_ item: GitHubItem) {
        for index in sections.indices {
            for itemIndex in sections[index].items.indices where sections[index].items[itemIndex].id == item.id {
                sections[index].items[itemIndex] = item
            }
        }
    }
}

/// What a pull request's or an issue's detail shows beyond its list row: a
/// second read of the one item, made when the detail opens and kept in
/// memory only.
struct GitHubItemDetail: Sendable, Equatable {
    /// The row as this read found it, which replaces the list's copy.
    let item: GitHubItem
    /// The account gh is signed in to, which "You" stands for.
    let viewer: String
    /// Markdown, as its author wrote it.
    let body: String
    /// Nil for an issue.
    let pullRequest: GitHubPullRequestDetail?
    /// Who an issue is assigned to; empty for a pull request.
    let assignees: [String]
    /// The repository's default branch, which a worktree for an issue
    /// starts from; nil for an empty repository.
    let defaultBranch: String?
    let readAt: Date

    /// The account opened it.
    var isViewers: Bool {
        pullRequest?.isViewers ?? (item.author == viewer)
    }
}

struct GitHubPullRequestDetail: Sendable, Equatable {
    let headBranch: String
    let baseBranch: String
    let changedFiles: Int
    let isViewers: Bool
    /// The head branch is in a fork, owned by `headOwner`.
    let isCrossRepository: Bool
    let headOwner: String?
    let review: GitHubReviewState
    /// GitHub's `mergeable` (MERGEABLE, CONFLICTING, UNKNOWN), for merging.
    let mergeable: String?
    /// GitHub's `mergeStateStatus` (CLEAN, BLOCKED, BEHIND, DIRTY, ...).
    let mergeState: String?
    /// The head commit's id. A merge names it, so a commit pushed after the
    /// user looked is not merged with it.
    let headCommit: String?
    /// The head branch is still on GitHub.
    let headBranchExists: Bool
    /// Who merged it, once merged.
    let mergedBy: String?
    /// How many parents its merge commit has, once merged: two for a merge
    /// commit, one for a squash or a rebase.
    let mergeCommitParents: Int?
    let mergeSettings: GitHubMergeSettings
}

/// How a pull request's repository lets it be merged.
struct GitHubMergeSettings: Sendable, Equatable {
    /// The methods the repository allows, in the order the sheet lists them.
    let allowed: [GitHubMergeMethod]
    /// GitHub's choice for the account in this repository: the method it
    /// last used there, or the repository's default.
    let preferred: GitHubMergeMethod?
    /// GitHub deletes a merged pull request's branch itself.
    let deletesBranch: Bool

    /// The method the sheet starts on.
    var initial: GitHubMergeMethod? {
        preferred.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed.first
    }
}

enum GitHubMergeMethod: String, CaseIterable, Sendable, Identifiable {
    case squash
    case merge
    case rebase

    var id: Self { self }

    /// GitHub's `PullRequestMergeMethod`.
    init?(graphQL value: String) {
        switch value {
        case "SQUASH": self = .squash
        case "MERGE": self = .merge
        case "REBASE": self = .rebase
        default: return nil
        }
    }

    /// gh's flag for it.
    var flag: String {
        switch self {
        case .squash: "--squash"
        case .merge: "--merge"
        case .rebase: "--rebase"
        }
    }

    var title: String {
        switch self {
        case .squash: String(localized: "Squash and Merge")
        case .merge: String(localized: "Create a Merge Commit")
        case .rebase: String(localized: "Rebase and Merge")
        }
    }
}

/// Where a pull request's review stands, and with whom.
enum GitHubReviewState: Sendable, Equatable {
    /// The account's review is asked for, of it or of a team it is in.
    case requestedOfViewer
    case changesRequested(by: [String])
    case approved(by: [String])
    /// Asked of someone else, who has not answered yet.
    case requested(of: [String])
    case notRequested
}

/// Why a Host's lists could not be read.
enum GitHubReadFailure: Error, Sendable, Equatable {
    /// gh is not on the Host's PATH. `isMac` picks the install command.
    case notInstalled(isMac: Bool)
    /// gh has no usable token on the Host, in the exec and, on a Mac, in the
    /// desktop session too.
    case notSignedIn
    /// GitHub refused for a rate limit; nil when it said no end.
    case rateLimited(retryAt: Date?)
    /// No Server of the Host is connected.
    case offline
    /// The Host cannot run gh this way, such as native Windows.
    case unsupported
    /// The read did not finish in its time.
    case timedOut
    /// gh's own words, or a sentence of Heeler's when it gave none.
    case failed(String)
}
