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
            fragment pullRequest on PullRequest {
              id number title url isDraft state updatedAt additions deletions reviewDecision
              author { login } repository { nameWithOwner } comments { totalCount }
              commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 1) {
                checkRunCountsByState { state count } statusContextCountsByState { state count }
              } } } } }
            }
            fragment issue on Issue {
              id number title url state updatedAt
              author { login } repository { nameWithOwner } comments { totalCount }
              labels(first: 10) { nodes { name color } }
            }
            """)
    }

    /// The lists, or why there are none, from what the script reported.
    static func result(of outcome: GitHubCLIOutcome, at now: Date) -> Result<GitHubList, GitHubReadFailure> {
        guard let run = outcome.run else { return .failure(.notInstalled(isMac: outcome.isMac)) }
        switch run.route {
        case .desktopUnavailable: return .failure(.notSignedIn)
        case .desktopTimedOut: return .failure(.timedOut)
        case .failed:
            return .failure(.failed(String(localized: "The Host could not make a private temporary folder for gh.")))
        case .ran: break
        }
        let response = GitHubHTTPResponse(including: run.output)
        let envelope = try? decoder.decode(Envelope.self, from: response.body)
        if let failure = failure(of: run, response: response, envelope: envelope, now: now) {
            return .failure(failure)
        }
        guard let data = envelope?.data else {
            return .failure(.failed(String(localized: "GitHub's answer could not be read.")))
        }
        return .success(data.list(readAt: now))
    }

    private static func failure(
        of run: GitHubCLIOutcome.Run, response: GitHubHTTPResponse, envelope: Envelope?, now: Date
    ) -> GitHubReadFailure? {
        let errors = envelope?.errors ?? []
        let message = errors.compactMap(\.message).first ?? envelope?.message
        if run.exitStatus == 4 || response.status == 401 { return .notSignedIn }
        // A limit on requests with no token says gh sent none.
        if (message ?? run.errorOutput).contains(GitHubCLIScript.unauthenticatedMark) { return .notSignedIn }
        let rateLimited =
            errors.contains { $0.type == "RATE_LIMITED" }
            || (response.headers["x-ratelimit-remaining"] == "0" && (!errors.isEmpty || run.exitStatus != 0))
            || ([403, 429].contains(response.status) && (message ?? run.errorOutput).localizedCaseInsensitiveContains("rate limit"))
        if rateLimited {
            return .rateLimited(retryAt: retryTime(response.headers, now: now))
        }
        guard run.exitStatus != 0 || envelope?.data == nil else { return nil }
        if let message, !message.isEmpty { return .failed(message) }
        let words = run.errorOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "\n")
        if !words.isEmpty { return .failed(words) }
        let status = run.exitStatus.map(String.init) ?? "?"
        return .failed(String(localized: "gh stopped with status \(status) and gave no reason."))
    }

    /// `retry-after` in seconds for a secondary limit, else the primary
    /// limit's reset in epoch seconds.
    static func retryTime(_ headers: [String: String], now: Date) -> Date? {
        if let seconds = headers["retry-after"].flatMap(TimeInterval.init) {
            return now.addingTimeInterval(seconds)
        }
        if let reset = headers["x-ratelimit-reset"].flatMap(TimeInterval.init) {
            return Date(timeIntervalSince1970: reset)
        }
        return nil
    }

    // MARK: GitHub's answer

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct Envelope: Decodable {
        let data: Payload?
        let errors: [GraphQLError]?
        /// A REST-style error body, such as `Bad credentials`.
        let message: String?
    }

    private struct GraphQLError: Decodable {
        let type: String?
        let message: String?
    }

    private struct Payload: Decodable {
        let viewer: Viewer
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

    private struct Viewer: Decodable {
        let login: String
    }

    private struct Search: Decodable {
        let issueCount: Int
        let nodes: [Lossy<Node>]
    }

    /// A node that does not decode, such as one GitHub hid, is left out
    /// rather than failing the read.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct Login: Decodable {
        let login: String
    }

    private struct Repository: Decodable {
        let nameWithOwner: String
    }

    private struct Count: Decodable {
        let totalCount: Int
    }

    private struct Nodes<Value: Decodable>: Decodable {
        let nodes: [Value?]?
    }

    private struct StateCount: Decodable {
        let state: String
        let count: Int
    }

    private struct CommitNode: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable {
                struct Contexts: Decodable {
                    let checkRunCountsByState: [StateCount]?
                    let statusContextCountsByState: [StateCount]?
                }

                let contexts: Contexts?
            }

            let statusCheckRollup: Rollup?
        }

        let commit: Commit?
    }

    private struct LabelNode: Decodable {
        let name: String
        let color: String?
    }

    private struct Node: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: String
        let state: String
        let updatedAt: Date
        let isDraft: Bool?
        let additions: Int?
        let deletions: Int?
        let reviewDecision: String?
        let author: Login?
        let repository: Repository
        let comments: Count?
        let commits: Nodes<CommitNode>?
        let labels: Nodes<LabelNode>?

        func item(kind: GitHubItem.Kind) -> GitHubItem {
            let state: GitHubItem.State =
                switch self.state {
                case "MERGED": .merged
                case "CLOSED": .closed
                default: isDraft == true ? .draft : .open
                }
            return GitHubItem(
                id: id, kind: kind, repository: repository.nameWithOwner, number: number, title: title,
                url: url, author: author?.login, state: state, updatedAt: updatedAt,
                commentCount: comments?.totalCount ?? 0,
                checks: kind == .pullRequest ? checks : nil,
                review: reviewDecision.flatMap(GitHubListRead.review),
                additions: additions, deletions: deletions,
                labels: (labels?.nodes ?? []).compactMap { $0 }.map {
                    GitHubLabel(name: $0.name, color: $0.color ?? "")
                })
        }

        private var checks: GitHubChecks {
            let contexts = commits?.nodes?.last??.commit?.statusCheckRollup?.contexts
            var checks = GitHubChecks(failing: 0, pending: 0, passing: 0)
            for entry in (contexts?.checkRunCountsByState ?? []) + (contexts?.statusContextCountsByState ?? []) {
                switch entry.state {
                case "FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "CANCELLED":
                    checks.failing += entry.count
                case "PENDING", "EXPECTED", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED":
                    checks.pending += entry.count
                case "SUCCESS", "NEUTRAL", "SKIPPED":
                    checks.passing += entry.count
                default:
                    break
                }
            }
            return checks
        }
    }

    private static func review(_ decision: String) -> GitHubReviewDecision? {
        switch decision {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: nil
        }
    }
}
