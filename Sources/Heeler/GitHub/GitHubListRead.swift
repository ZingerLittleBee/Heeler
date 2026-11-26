import Foundation

/// The list's reads (ADR 0065): one `gh api graphql` request for the
/// account's login and a page of one or more searches across repositories,
/// unarchived and most recently updated first. The list at the filters'
/// defaults reads both segments' searches at once; a filter changed from
/// them reads its segment's; Show More reads the next page of the searches
/// it needs. GitHub counts a GraphQL search against the GraphQL rate limit.
enum GitHubListRead {
    /// Rows a page shows; GitHub gives each search's full count.
    static let pageSize = 30

    /// One search to read: its query and, for a later page, where the last
    /// one ended.
    struct Search: Sendable, Equatable {
        let kind: GitHubItem.Kind
        let query: String
        var after: String? = nil
    }

    /// The account's login and a page of each search read, in order.
    struct Answer: Sendable, Equatable {
        let login: String
        let pages: [GitHubSearchPage]
    }

    // MARK: Queries

    /// GitHub's search queries for a segment under a filter: one, or for
    /// Yours two that never share an item, whose counts add up. GitHub's
    /// advanced search, which could join two roles with `OR` in one query,
    /// is documented for issues only (`ISSUE_ADVANCED`), not for pull
    /// requests or `sort:`. `ownerIsOrganization` picks `org:` or `user:`
    /// for an owner, as GitHub documents each; nil when the filter names
    /// none.
    static func queries(
        for filter: GitHubListFilter, kind: GitHubItem.Kind, ownerIsOrganization: Bool? = nil
    ) -> [String] {
        var terms = [kind == .pullRequest ? "is:pr" : "is:issue"]
        switch (filter.state, kind) {
        case (.open, _): terms.append("is:open")
        case (.draft, _): terms += ["is:open", "draft:true"]
        case (.merged, _): terms.append("is:merged")
        case (.closed, .pullRequest): terms += ["is:closed", "is:unmerged"]
        case (.closed, .issue): terms.append("is:closed")
        case (.all, _): break
        }
        terms.append("archived:false")
        switch filter.repository {
        case .repository(let name): terms.append("repo:\(name)")
        case .owner(let login): terms.append("\(ownerIsOrganization == true ? "org" : "user"):\(login)")
        case nil: break
        }
        if let label = filter.label { terms.append("label:\"\(label)\"") }
        let roles: [[String]] =
            switch (filter.whose, kind) {
            case (.person(let person), _): [[qualifier(for: person)]]
            // Only with a Repository: `whose` reads Anyone without one as Yours.
            case (.anyone, _): [[]]
            case (.yours, .pullRequest): [["author:@me"], ["review-requested:@me", "-author:@me"]]
            case (.yours, .issue): [["assignee:@me"], ["author:@me", "-assignee:@me"]]
            }
        return roles.map { (terms + $0 + ["sort:updated-desc"]).joined(separator: " ") }
    }

    private static func qualifier(for person: GitHubListFilter.Person) -> String {
        let who = person.login ?? "@me"
        return switch person.role {
        case .author: "author:\(who)"
        case .reviewRequested: "review-requested:\(who)"
        case .reviewedBy: "reviewed-by:\(who)"
        case .assignee: "assignee:\(who)"
        case .mentions: "mentions:\(who)"
        }
    }

    /// Both segments' searches at the filters' defaults, pull requests first.
    static var defaultSearches: [Search] {
        [GitHubItem.Kind.pullRequest, .issue].flatMap { kind in
            queries(for: GitHubListFilter(), kind: kind).map { Search(kind: kind, query: $0) }
        }
    }

    // MARK: Requests

    /// One request for the searches, each its own field, with its query
    /// and cursor as variables so nothing the user typed enters the
    /// GraphQL document.
    static func request(_ searches: [Search]) -> GitHubCLIRequest {
        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: String] = [:]
        for (index, search) in searches.enumerated() {
            declarations += ["$q\(index): String!", "$a\(index): String"]
            variables["q\(index)"] = search.query
            if let after = search.after { variables["a\(index)"] = after }
            let spreads = search.kind == .pullRequest ? "...pullRequest ...listPullRequest" : "...issue ...listIssue"
            fields.append("""
                s\(index): search(type: ISSUE, first: \(pageSize), query: $q\(index), after: $a\(index)) {
                  issueCount pageInfo { hasNextPage endCursor } nodes { \(spreads) }
                }
                """)
        }
        // GitHub refuses a fragment the query does not use.
        var fragments: [String] = []
        if searches.contains(where: { $0.kind == .pullRequest }) {
            fragments += [GitHubGraphQL.pullRequestFragment, GitHubGraphQL.listPullRequestFragment]
        }
        if searches.contains(where: { $0.kind == .issue }) {
            fragments += [GitHubGraphQL.issueFragment, GitHubGraphQL.listIssueFragment]
        }
        return .graphQL(
            """
            query(\(declarations.joined(separator: ", "))) {
              viewer { login }
              \(fields.joined(separator: "\n"))
            }
            \(fragments.joined(separator: "\n"))
            """,
            variables: variables)
    }

    /// A page of each search, or why there is none, from what the script
    /// reported.
    static func result(
        of outcome: GitHubCLIOutcome, searches: [Search], at now: Date
    ) -> Result<Answer, GitHubReadFailure> {
        GitHubGraphQL.payload(Payload.self, of: outcome, at: now).flatMap { payload in
            var pages: [GitHubSearchPage] = []
            for (index, search) in searches.enumerated() {
                // A search GitHub would not run, such as one naming an
                // account that does not exist, comes back null beside an
                // error naming it.
                guard let found = payload.searches["s\(index)"] ?? nil else {
                    let message = GitHubGraphQL.errorMessages(in: outcome).first
                    return .failure(.failed(message ?? String(localized: "GitHub did not run this search.")))
                }
                let items = found.nodes.compactMap { $0.value?.item(kind: search.kind, viewer: payload.viewer.login) }
                pages.append(
                    GitHubSearchPage(
                        totalCount: max(found.issueCount, items.count), endCursor: found.pageInfo?.endCursor,
                        hasNextPage: found.pageInfo?.hasNextPage ?? false, items: items))
            }
            return .success(Answer(login: payload.viewer.login, pages: pages))
        }
    }

    /// Both segments' lists from the default searches' answer.
    static func list(from answer: Answer, at now: Date) -> GitHubList {
        let searches = defaultSearches
        func list(_ kind: GitHubItem.Kind) -> GitHubItemList {
            GitHubItemList(
                firstPages: zip(searches, answer.pages).filter { $0.0.kind == kind }.map { ($0.0.query, $0.1) })
        }
        return GitHubList(login: answer.login, pullRequests: list(.pullRequest), issues: list(.issue), readAt: now)
    }

    /// Whether `login` is an organization, for a Repository filter naming an
    /// owner the lists have not shown: GitHub's search names an
    /// organization's repositories with `org:` and a user's with `user:`.
    static func ownerRequest(_ login: String) -> GitHubCLIRequest {
        .graphQL(
            """
            query($login: String!) {
              viewer { login }
              repositoryOwner(login: $login) { __typename }
            }
            """,
            variables: ["login": login])
    }

    /// True for an organization, false for a user, nil when GitHub knows no
    /// such account.
    static func ownerResult(of outcome: GitHubCLIOutcome, at now: Date) -> Result<Bool?, GitHubReadFailure> {
        GitHubGraphQL.payload(OwnerPayload.self, of: outcome, at: now).map { payload in
            payload.repositoryOwner.map { $0.typename == "Organization" }
        }
    }

    // MARK: GitHub's answer

    private struct Payload: Decodable {
        let viewer: GitHubGraphQL.Viewer
        let searches: [String: SearchNode?]

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            viewer = try container.decode(GitHubGraphQL.Viewer.self, forKey: Key(stringValue: "viewer"))
            var searches: [String: SearchNode?] = [:]
            for key in container.allKeys where key.stringValue != "viewer" {
                searches[key.stringValue] = try container.decodeIfPresent(SearchNode.self, forKey: key)
            }
            self.searches = searches
        }
    }

    private struct SearchNode: Decodable {
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }

        let issueCount: Int
        let pageInfo: PageInfo?
        let nodes: [GitHubGraphQL.Lossy<GitHubGraphQL.ItemNode>]
    }

    private struct OwnerPayload: Decodable {
        let repositoryOwner: GitHubGraphQL.Typename?
    }
}
