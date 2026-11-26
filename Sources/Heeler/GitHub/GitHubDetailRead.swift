import Foundation

/// The detail read: one `gh api graphql` request for one pull request or
/// issue by its node id, with the fields its list row has and what the
/// detail and its actions add (ADR 0065). A node costs one point of the
/// GraphQL limit.
enum GitHubDetailRead {
    static func request(for item: GitHubItem) -> GitHubCLIRequest {
        .graphQL(
            """
            query($id: ID!) {
              viewer { login }
              node(id: $id) {
                __typename
                ... on PullRequest {
                  ...pullRequest
                  repository {
                    defaultBranchRef { name }
                    squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed viewerDefaultMergeMethod deleteBranchOnMerge
                  }
                  body bodyHTML headRefName baseRefName changedFiles viewerDidAuthor isCrossRepository
                  headRepositoryOwner { login } mergeable mergeStateStatus
                  headRefOid headRef { id } mergedBy { login } mergeCommit { parents(first: 2) { totalCount } }
                  reviewRequests(first: 20) { nodes { requestedReviewer { ...reviewer } } }
                  viewerLatestReviewRequest { requestedReviewer { ...reviewer } }
                  latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
                }
                ... on Issue {
                  ...issue
                  repository { defaultBranchRef { name } }
                  body bodyHTML assignees(first: 10) { nodes { login } }
                }
              }
            }
            fragment reviewer on RequestedReviewer {
              __typename ... on User { login } ... on Team { name } ... on Bot { login } ... on Mannequin { login }
            }
            \(GitHubGraphQL.pullRequestFragment)
            \(GitHubGraphQL.issueFragment)
            """,
            variables: ["id": item.id])
    }

    /// The item's detail, or why there is none, from what the script reported.
    static func result(
        of outcome: GitHubCLIOutcome, for item: GitHubItem, at now: Date
    ) -> Result<GitHubItemDetail, GitHubReadFailure> {
        GitHubGraphQL.payload(Payload.self, of: outcome, at: now).flatMap { payload in
            guard let node = payload.node else {
                return .failure(.failed(
                    item.kind == .pullRequest
                        ? String(localized: "GitHub no longer shows this pull request to your account.")
                        : String(localized: "GitHub no longer shows this issue to your account.")))
            }
            return .success(node.detail(viewer: payload.viewer.login, kind: item.kind, readAt: now))
        }
    }

    private struct Payload: Decodable {
        let viewer: GitHubGraphQL.Viewer
        /// Null when the item is gone or hidden from the account.
        let node: Node?
    }

    private struct Reviewer: Decodable {
        let login: String?
        /// A team's name.
        let name: String?

        var who: String? { login ?? name }
    }

    private struct ReviewRequest: Decodable {
        let requestedReviewer: Reviewer?
    }

    private struct Review: Decodable {
        let state: String
        let author: GitHubGraphQL.Login?
    }

    private struct MergeCommit: Decodable {
        let parents: GitHubGraphQL.Count?
    }

    /// What the detail adds of the repository: its default branch, nil for
    /// an empty repository, and for a pull request its merge settings. Its
    /// `nameWithOwner` is the list row's, in the same object.
    private struct Repository: Decodable {
        struct Ref: Decodable { let name: String }
        let defaultBranchRef: Ref?
        let squashMergeAllowed: Bool?
        let mergeCommitAllowed: Bool?
        let rebaseMergeAllowed: Bool?
        let viewerDefaultMergeMethod: String?
        let deleteBranchOnMerge: Bool?

        var settings: GitHubMergeSettings {
            let allowed = GitHubMergeMethod.allCases.filter { method in
                switch method {
                case .squash: squashMergeAllowed == true
                case .merge: mergeCommitAllowed == true
                case .rebase: rebaseMergeAllowed == true
                }
            }
            return GitHubMergeSettings(
                allowed: allowed, preferred: viewerDefaultMergeMethod.flatMap(GitHubMergeMethod.init(graphQL:)),
                deletesBranch: deleteBranchOnMerge == true)
        }
    }

    private struct Node: Decodable {
        let item: GitHubGraphQL.ItemNode
        let repository: Repository?
        let body: String?
        /// The body as GitHub renders it, read only for its pictures and
        /// videos' addresses.
        let bodyHTML: String?
        let headRefName: String?
        let baseRefName: String?
        let changedFiles: Int?
        let viewerDidAuthor: Bool?
        let isCrossRepository: Bool?
        let headRepositoryOwner: GitHubGraphQL.Login?
        let mergeable: String?
        let mergeStateStatus: String?
        let headRefOid: String?
        /// Present while the head branch is on GitHub.
        let headRef: HeadRef?
        let mergedBy: GitHubGraphQL.Login?
        let mergeCommit: MergeCommit?
        let reviewRequests: GitHubGraphQL.Nodes<ReviewRequest>?
        let viewerLatestReviewRequest: ReviewRequest?
        let latestOpinionatedReviews: GitHubGraphQL.Nodes<Review>?
        let assignees: GitHubGraphQL.Nodes<GitHubGraphQL.Login>?

        struct HeadRef: Decodable {
            let id: String
        }

        enum CodingKeys: String, CodingKey {
            case repository, body, bodyHTML, headRefName, baseRefName, changedFiles, viewerDidAuthor, isCrossRepository
            case headRepositoryOwner, mergeable, mergeStateStatus, headRefOid, headRef, mergedBy, mergeCommit
            case reviewRequests, viewerLatestReviewRequest, latestOpinionatedReviews, assignees
        }

        init(from decoder: any Decoder) throws {
            item = try GitHubGraphQL.ItemNode(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            repository = try? container.decodeIfPresent(Repository.self, forKey: .repository)
            body = try container.decodeIfPresent(String.self, forKey: .body)
            bodyHTML = try container.decodeIfPresent(String.self, forKey: .bodyHTML)
            headRefName = try container.decodeIfPresent(String.self, forKey: .headRefName)
            baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
            changedFiles = try container.decodeIfPresent(Int.self, forKey: .changedFiles)
            viewerDidAuthor = try container.decodeIfPresent(Bool.self, forKey: .viewerDidAuthor)
            isCrossRepository = try container.decodeIfPresent(Bool.self, forKey: .isCrossRepository)
            headRepositoryOwner = try container.decodeIfPresent(GitHubGraphQL.Login.self, forKey: .headRepositoryOwner)
            mergeable = try container.decodeIfPresent(String.self, forKey: .mergeable)
            mergeStateStatus = try container.decodeIfPresent(String.self, forKey: .mergeStateStatus)
            headRefOid = try container.decodeIfPresent(String.self, forKey: .headRefOid)
            headRef = try container.decodeIfPresent(HeadRef.self, forKey: .headRef)
            mergedBy = try container.decodeIfPresent(GitHubGraphQL.Login.self, forKey: .mergedBy)
            mergeCommit = try container.decodeIfPresent(MergeCommit.self, forKey: .mergeCommit)
            reviewRequests = try container.decodeIfPresent(
                GitHubGraphQL.Nodes<ReviewRequest>.self, forKey: .reviewRequests)
            viewerLatestReviewRequest = try container.decodeIfPresent(
                ReviewRequest.self, forKey: .viewerLatestReviewRequest)
            latestOpinionatedReviews = try container.decodeIfPresent(
                GitHubGraphQL.Nodes<Review>.self, forKey: .latestOpinionatedReviews)
            assignees = try container.decodeIfPresent(GitHubGraphQL.Nodes<GitHubGraphQL.Login>.self, forKey: .assignees)
        }

        func detail(viewer: String, kind: GitHubItem.Kind, readAt: Date) -> GitHubItemDetail {
            var item = item.item(kind: kind)
            var pullRequest: GitHubPullRequestDetail?
            if kind == .pullRequest {
                let review = review(viewer: viewer)
                // The list row says so; this read is the newer word.
                item.asksViewerToReview = review == .requestedOfViewer
                pullRequest = GitHubPullRequestDetail(
                    headBranch: headRefName ?? "",
                    baseBranch: baseRefName ?? "",
                    changedFiles: changedFiles ?? 0,
                    isViewers: viewerDidAuthor ?? (item.author == viewer),
                    isCrossRepository: isCrossRepository ?? false,
                    headOwner: headRepositoryOwner?.login,
                    review: review,
                    mergeable: mergeable,
                    mergeState: mergeStateStatus,
                    headCommit: headRefOid,
                    headBranchExists: headRef != nil,
                    mergedBy: mergedBy?.login,
                    mergeCommitParents: mergeCommit?.parents?.totalCount,
                    mergeSettings: repository?.settings
                        ?? GitHubMergeSettings(allowed: [], preferred: nil, deletesBranch: false))
            }
            return GitHubItemDetail(
                item: item, viewer: viewer, body: body ?? "", media: GitHubMedia.media(inHTML: bodyHTML ?? ""),
                pullRequest: pullRequest,
                assignees: (assignees?.values ?? []).map(\.login),
                defaultBranch: repository?.defaultBranchRef?.name, readAt: readAt)
        }

        /// The account's own request first: it is what the account can act
        /// on. Then what reviewers said, then who is still asked.
        private func review(viewer: String) -> GitHubReviewState {
            let pending = (reviewRequests?.values ?? []).compactMap { $0.requestedReviewer?.who }
            // A request of a team the account is in names the team.
            let viewerRequest = viewerLatestReviewRequest?.requestedReviewer?.who
            if GitHubGraphQL.asksViewer(pending: pending, viewerRequest: viewerRequest, viewer: viewer) {
                return .requestedOfViewer
            }
            let reviews = latestOpinionatedReviews?.values ?? []
            let changes = reviews.filter { $0.state == "CHANGES_REQUESTED" }.compactMap(\.author?.login)
            if !changes.isEmpty { return .changesRequested(by: changes) }
            let approvals = reviews.filter { $0.state == "APPROVED" }.compactMap(\.author?.login)
            if !approvals.isEmpty { return .approved(by: approvals) }
            if !pending.isEmpty { return .requested(of: pending) }
            return .notRequested
        }
    }
}
