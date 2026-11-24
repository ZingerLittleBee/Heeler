import Foundation

/// The list read: one `gh api graphql` request for the account's login and
/// four searches of open items across repositories (ADR 0064). GitHub counts
/// a GraphQL search against the GraphQL rate limit, two points for all four.
enum GitHubListRead {
    /// Rows per section; the header gives GitHub's full count.
    static let pageSize = 30

    static let searches: [(GitHubListSection.Kind, String)] = [
        (.reviewRequested, "is:pr is:open archived:false review-requested:@me sort:updated-desc"),
        (.authored, "is:pr is:open archived:false author:@me sort:updated-desc"),
        (.assigned, "is:issue is:open archived:false assignee:@me sort:updated-desc"),
        // Issues already under Assigned to You stay there.
        (.created, "is:issue is:open archived:false author:@me -assignee:@me sort:updated-desc"),
    ]

    static var request: GitHubCLIRequest {
        let fields = searches.map { kind, query in
            let fragment = kind.itemKind == .pullRequest ? "pullRequest" : "issue"
            return """
                \(kind.rawValue): search(type: ISSUE, first: \(pageSize), query: "\(query)") {
                  issueCount nodes { ...\(fragment) }
                }
                """
        }
        return .graphQL("""
            query {
              viewer { login }
              \(fields.joined(separator: "\n"))
            }
            \(GitHubGraphQL.pullRequestFragment)
            \(GitHubGraphQL.issueFragment)
            """)
    }

    /// The lists, or why there are none, from what the script reported.
    static func result(of outcome: GitHubCLIOutcome, at now: Date) -> Result<GitHubList, GitHubReadFailure> {
        GitHubGraphQL.payload(Payload.self, of: outcome, at: now).map { $0.list(readAt: now) }
    }

    private struct Payload: Decodable {
        let viewer: GitHubGraphQL.Viewer
        let reviewRequested: Search
        let authored: Search
        let assigned: Search
        let created: Search

        func list(readAt: Date) -> GitHubList {
            let sections = GitHubListRead.searches.map { kind, _ in
                let search =
                    switch kind {
                    case .reviewRequested: reviewRequested
                    case .authored: authored
                    case .assigned: assigned
                    case .created: created
                    }
                let items = search.nodes.compactMap { $0.value?.item(kind: kind.itemKind) }
                return GitHubListSection(kind: kind, totalCount: max(search.issueCount, items.count), items: items)
            }
            return GitHubList(login: viewer.login, sections: sections, readAt: readAt)
        }
    }

    private struct Search: Decodable {
        let issueCount: Int
        let nodes: [GitHubGraphQL.Lossy<GitHubGraphQL.ItemNode>]
    }
}
