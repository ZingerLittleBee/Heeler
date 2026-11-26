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
    /// Who it is assigned to, as the list read them; nil where a read did
    /// not ask, as a pull request's detail does not.
    var assignees: [String]? = nil
    /// Whether an organization owns the repository, which GitHub's search
    /// names with `org:` rather than `user:`; nil where a read did not ask.
    var ownerIsOrganization: Bool? = nil
    /// A GitHub App's bot opened it, which no person filter can name; nil
    /// where a read did not ask.
    var authorIsApp: Bool? = nil
    /// A pull request asks the account for its review, of it or of a team
    /// it is in; nil for an issue and where a read did not ask.
    var asksViewerToReview: Bool? = nil

    /// The repository's name without its owner.
    var repositoryName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    /// The login that owns the repository.
    var repositoryOwner: String {
        repository.split(separator: "/").first.map(String.init) ?? repository
    }

    /// This item as another read found it, keeping what only the list read
    /// asks for where that read did not.
    func updated(to newer: GitHubItem) -> GitHubItem {
        var item = newer
        item.assignees = newer.assignees ?? assignees
        item.ownerIsOrganization = newer.ownerIsOrganization ?? ownerIsOrganization
        item.authorIsApp = newer.authorIsApp ?? authorIsApp
        item.asksViewerToReview = newer.asksViewerToReview ?? asksViewerToReview
        return item
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

/// One page of one GitHub search, newest first.
struct GitHubSearchPage: Sendable, Equatable {
    /// GitHub's count of everything the search matches.
    let totalCount: Int
    /// Where the next page starts.
    let endCursor: String?
    let hasNextPage: Bool
    let items: [GitHubItem]
}

/// A segment's list as GitHub's searches answered it, read a page at a time
/// (ADR 0065): the items shown, newest first, and what each search holds
/// beyond them. With two searches, which never share an item, the list
/// shows the newest of both, so an item waits until every search that could
/// hold a newer one has been read that far.
struct GitHubItemList: Codable, Sendable, Equatable {
    struct Search: Codable, Sendable, Equatable {
        /// GitHub's search query, which reads its later pages.
        let query: String
        var totalCount: Int
        var endCursor: String?
        var hasNextPage: Bool
        /// Read and not shown yet, newest first.
        var waiting: [GitHubItem]
    }

    /// Which list a later page belongs to: a read of the first pages makes
    /// a new one.
    let id: UUID
    private(set) var items: [GitHubItem]
    private(set) var searches: [Search]

    /// The first page of each search, `count` items shown.
    init(firstPages: [(query: String, page: GitHubSearchPage)], showing count: Int = GitHubListRead.pageSize) {
        id = UUID()
        items = []
        searches = firstPages.map { query, page in
            Search(
                query: query, totalCount: page.totalCount, endCursor: page.endCursor,
                hasNextPage: page.hasNextPage, waiting: [])
        }
        for (index, entry) in firstPages.enumerated() { add(entry.page.items, to: index) }
        show(count)
    }

    /// GitHub's count across the searches, never less than what is shown.
    var totalCount: Int {
        max(items.count, searches.reduce(0) { $0 + $1.totalCount })
    }

    /// Something is left to show, read or not.
    var hasMore: Bool {
        searches.contains { !$0.waiting.isEmpty || $0.hasNextPage }
    }

    /// The searches whose next page must be read before `count` more items
    /// can be shown in order.
    func searchesToRead(for count: Int = GitHubListRead.pageSize) -> [Int] {
        searches.indices.filter { searches[$0].hasNextPage && searches[$0].waiting.count < count }
    }

    /// Takes in the next page of the search at `index`.
    mutating func add(_ page: GitHubSearchPage, to index: Int) {
        guard searches.indices.contains(index) else { return }
        searches[index].totalCount = page.totalCount
        searches[index].endCursor = page.endCursor
        searches[index].hasNextPage = page.hasNextPage
        add(page.items, to: index)
    }

    /// Shows up to `count` more items, newest first, stopping where a
    /// search that has run out of read items has more on GitHub.
    mutating func show(_ count: Int = GitHubListRead.pageSize) {
        var shown = 0
        while shown < count {
            if searches.contains(where: { $0.waiting.isEmpty && $0.hasNextPage }) { return }
            var newest: Int?
            for index in searches.indices {
                guard let head = searches[index].waiting.first else { continue }
                if let current = newest, let best = searches[current].waiting.first,
                    head.updatedAt <= best.updatedAt
                {
                    continue
                }
                newest = index
            }
            guard let newest else { return }
            let item = searches[newest].waiting.removeFirst()
            // An item updated between two pages can come back on the later one.
            guard !items.contains(where: { $0.id == item.id }) else { continue }
            items.append(item)
            shown += 1
        }
    }

    /// Replaces every copy of an item that was read again.
    mutating func replace(_ item: GitHubItem) {
        for index in items.indices where items[index].id == item.id {
            items[index] = items[index].updated(to: item)
        }
        for search in searches.indices {
            for index in searches[search].waiting.indices where searches[search].waiting[index].id == item.id {
                searches[search].waiting[index] = searches[search].waiting[index].updated(to: item)
            }
        }
    }

    private mutating func add(_ items: [GitHubItem], to index: Int) {
        let known = Set(self.items.map(\.id)).union(searches[index].waiting.map(\.id))
        searches[index].waiting += items.filter { !known.contains($0.id) }
    }
}

/// One read of the lists on one Host at the filters' defaults: what
/// involves the account gh is signed in to there. The device keeps it.
struct GitHubList: Codable, Sendable, Equatable {
    let login: String
    var pullRequests: GitHubItemList
    var issues: GitHubItemList
    let readAt: Date

    subscript(kind: GitHubItem.Kind) -> GitHubItemList {
        get {
            switch kind {
            case .pullRequest: pullRequests
            case .issue: issues
            }
        }
        set {
            switch kind {
            case .pullRequest: pullRequests = newValue
            case .issue: issues = newValue
            }
        }
    }

    /// Replaces every copy of an item that was read again.
    mutating func replace(_ item: GitHubItem) {
        pullRequests.replace(item)
        issues.replace(item)
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
    /// The pictures and videos GitHub shows in the body, in reading order,
    /// at the addresses this read gave (`GitHubMedia`).
    let media: [GitHubMedia]
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
