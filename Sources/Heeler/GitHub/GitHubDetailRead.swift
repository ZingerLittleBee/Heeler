import Foundation

/// The detail read: one `gh api graphql` request for one pull request or
/// issue by its node id, with the fields its list row has and what the
/// detail adds (ADR 0064). A node costs one point of the GraphQL limit.
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
                  repository { defaultBranchRef { name } }
                  body headRefName baseRefName changedFiles viewerDidAuthor isCrossRepository
                  headRepositoryOwner { login } mergeable mergeStateStatus
                  reviewRequests(first: 20) { nodes { requestedReviewer { ...reviewer } } }
                  viewerLatestReviewRequest { requestedReviewer { ...reviewer } }
                  latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
                }
                ... on Issue {
                  ...issue
                  repository { defaultBranchRef { name } }
                  body assignees(first: 10) { nodes { login } }
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

    /// The repository's default branch; nil for an empty repository.
    private struct Repository: Decodable {
        struct Ref: Decodable { let name: String }
        let defaultBranchRef: Ref?
    }

    private struct Node: Decodable {
        let item: GitHubGraphQL.ItemNode
        let repository: Repository?
        let body: String?
        let headRefName: String?
        let baseRefName: String?
        let changedFiles: Int?
        let viewerDidAuthor: Bool?
        let isCrossRepository: Bool?
        let headRepositoryOwner: GitHubGraphQL.Login?
        let mergeable: String?
        let mergeStateStatus: String?
        let reviewRequests: GitHubGraphQL.Nodes<ReviewRequest>?
        let viewerLatestReviewRequest: ReviewRequest?
        let latestOpinionatedReviews: GitHubGraphQL.Nodes<Review>?
        let assignees: GitHubGraphQL.Nodes<GitHubGraphQL.Login>?

        enum CodingKeys: String, CodingKey {
            case repository, body, headRefName, baseRefName, changedFiles, viewerDidAuthor, isCrossRepository
            case headRepositoryOwner, mergeable, mergeStateStatus, reviewRequests, viewerLatestReviewRequest
            case latestOpinionatedReviews, assignees
        }

        init(from decoder: any Decoder) throws {
            item = try GitHubGraphQL.ItemNode(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            repository = try? container.decodeIfPresent(Repository.self, forKey: .repository)
            body = try container.decodeIfPresent(String.self, forKey: .body)
            headRefName = try container.decodeIfPresent(String.self, forKey: .headRefName)
            baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
            changedFiles = try container.decodeIfPresent(Int.self, forKey: .changedFiles)
            viewerDidAuthor = try container.decodeIfPresent(Bool.self, forKey: .viewerDidAuthor)
            isCrossRepository = try container.decodeIfPresent(Bool.self, forKey: .isCrossRepository)
            headRepositoryOwner = try container.decodeIfPresent(GitHubGraphQL.Login.self, forKey: .headRepositoryOwner)
            mergeable = try container.decodeIfPresent(String.self, forKey: .mergeable)
            mergeStateStatus = try container.decodeIfPresent(String.self, forKey: .mergeStateStatus)
            reviewRequests = try container.decodeIfPresent(
                GitHubGraphQL.Nodes<ReviewRequest>.self, forKey: .reviewRequests)
            viewerLatestReviewRequest = try container.decodeIfPresent(
                ReviewRequest.self, forKey: .viewerLatestReviewRequest)
            latestOpinionatedReviews = try container.decodeIfPresent(
                GitHubGraphQL.Nodes<Review>.self, forKey: .latestOpinionatedReviews)
            assignees = try container.decodeIfPresent(GitHubGraphQL.Nodes<GitHubGraphQL.Login>.self, forKey: .assignees)
        }

        func detail(viewer: String, kind: GitHubItem.Kind, readAt: Date) -> GitHubItemDetail {
            let item = item.item(kind: kind)
            var pullRequest: GitHubPullRequestDetail?
            if kind == .pullRequest {
                pullRequest = GitHubPullRequestDetail(
                    headBranch: headRefName ?? "",
                    baseBranch: baseRefName ?? "",
                    changedFiles: changedFiles ?? 0,
                    isViewers: viewerDidAuthor ?? (item.author == viewer),
                    isCrossRepository: isCrossRepository ?? false,
                    headOwner: headRepositoryOwner?.login,
                    review: review(viewer: viewer),
                    mergeable: mergeable,
                    mergeState: mergeStateStatus)
            }
            return GitHubItemDetail(
                item: item, viewer: viewer, body: body ?? "", pullRequest: pullRequest,
                assignees: (assignees?.values ?? []).map(\.login),
                defaultBranch: repository?.defaultBranchRef?.name, readAt: readAt)
        }

        /// The account's own request first: it is what the account can act
        /// on. Then what reviewers said, then who is still asked.
        private func review(viewer: String) -> GitHubReviewState {
            let pending = (reviewRequests?.values ?? []).compactMap { $0.requestedReviewer?.who }
            // A request of a team the account is in names the team.
            let viewerRequest = viewerLatestReviewRequest?.requestedReviewer?.who
            if pending.contains(viewer) || viewerRequest.map(pending.contains) == true {
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
