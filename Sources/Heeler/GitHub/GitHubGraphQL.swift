import Foundation

/// What every `gh api graphql -i` read shares (ADR 0064): the fields a list
/// row needs, the decoding of GitHub's answer, and how a failed run reads.
enum GitHubGraphQL {
    /// A pull request's fields as a list row shows them.
    static let pullRequestFragment = """
        fragment pullRequest on PullRequest {
          id number title url isDraft state updatedAt additions deletions reviewDecision
          author { login } repository { nameWithOwner } comments { totalCount }
          commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 1) {
            checkRunCountsByState { state count } statusContextCountsByState { state count }
          } } } } }
        }
        """

    /// An issue's fields as a list row shows them.
    static let issueFragment = """
        fragment issue on Issue {
          id number title url state updatedAt
          author { login } repository { nameWithOwner } comments { totalCount }
          labels(first: 10) { nodes { name color } }
        }
        """

    /// GitHub's `data`, or why there is none, from what the script reported.
    static func payload<Payload: Decodable>(
        _ type: Payload.Type, of outcome: GitHubCLIOutcome, at now: Date
    ) -> Result<Payload, GitHubReadFailure> {
        guard let run = outcome.run else { return .failure(.notInstalled(isMac: outcome.isMac)) }
        switch run.route {
        case .desktopUnavailable: return .failure(.notSignedIn)
        case .desktopTimedOut: return .failure(.timedOut)
        case .failed:
            return .failure(.failed(String(localized: "The Host could not make a private temporary folder for gh.")))
        case .ran: break
        }
        let response = GitHubHTTPResponse(including: run.output)
        let envelope = try? decoder.decode(Envelope<Payload>.self, from: response.body)
        if let failure = failure(of: run, response: response, errors: envelope?.errors, message: envelope?.message,
            hasData: envelope?.data != nil, now: now)
        {
            return .failure(failure)
        }
        guard let data = envelope?.data else {
            return .failure(.failed(String(localized: "GitHub's answer could not be read.")))
        }
        return .success(data)
    }

    private static func failure(
        of run: GitHubCLIOutcome.Run, response: GitHubHTTPResponse, errors: [GraphQLError]?, message: String?,
        hasData: Bool, now: Date
    ) -> GitHubReadFailure? {
        let errors = errors ?? []
        let message = errors.compactMap(\.message).first ?? message
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
        // gh exits 1 whenever GitHub lists errors, even beside `data`. Errors
        // that each name a field leave the rest answered: the field comes back
        // null, as a node that is gone, hidden or behind SAML does, and the
        // read deals with that.
        if hasData, !errors.isEmpty, errors.allSatisfy(\.namesField) { return nil }
        guard run.exitStatus != 0 || !hasData else { return nil }
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

    private struct Envelope<Payload: Decodable>: Decodable {
        let data: Payload?
        let errors: [GraphQLError]?
        /// A REST-style error body, such as `Bad credentials`.
        let message: String?
    }

    private struct GraphQLError: Decodable {
        let type: String?
        let message: String?
        /// Whether the error names the field it is about (`path`), as a
        /// field error does and a request error does not.
        let namesField: Bool

        private enum CodingKeys: String, CodingKey { case type, message, path }

        /// A `path` entry: a field name or a list index.
        private struct PathEntry: Decodable {
            init(from decoder: any Decoder) throws {
                let value = try decoder.singleValueContainer()
                if (try? value.decode(String.self)) == nil { _ = try value.decode(Int.self) }
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            let path = (try? container.decodeIfPresent([PathEntry].self, forKey: .path)) ?? nil
            namesField = !(path ?? []).isEmpty
        }
    }

    struct Viewer: Decodable {
        let login: String
    }

    /// A node that does not decode, such as one GitHub hid, is left out
    /// rather than failing the read.
    struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    struct Login: Decodable {
        let login: String
    }

    struct Repository: Decodable {
        let nameWithOwner: String
    }

    struct Count: Decodable {
        let totalCount: Int
    }

    struct Nodes<Value: Decodable>: Decodable {
        let nodes: [Value?]?

        var values: [Value] { (nodes ?? []).compactMap { $0 } }
    }

    struct StateCount: Decodable {
        let state: String
        let count: Int
    }

    struct CommitNode: Decodable {
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

    struct LabelNode: Decodable {
        let name: String
        let color: String?
    }

    /// A pull request or issue with the fragments' fields.
    struct ItemNode: Decodable {
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
                review: reviewDecision.flatMap(GitHubGraphQL.review),
                additions: additions, deletions: deletions,
                labels: (labels?.values ?? []).map { GitHubLabel(name: $0.name, color: $0.color ?? "") })
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
