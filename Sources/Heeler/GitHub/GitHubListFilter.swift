import Foundation

/// What one segment of the GitHub list shows: the filter row's four choices
/// (ADR 0065). Each segment keeps its own on the device; at the default it
/// is what involves the account, open and in any repository.
struct GitHubListFilter: Codable, Sendable, Hashable {
    enum State: String, Codable, Sendable, CaseIterable {
        /// Open, drafts included.
        case open
        /// Open and a draft; pull requests only.
        case draft
        /// Pull requests only.
        case merged
        /// A pull request closed without merging, or an issue closed as
        /// completed or not planned.
        case closed
        case all
    }

    /// How a person stands to an item.
    enum Role: String, Codable, Sendable, CaseIterable {
        case author
        /// Pull requests only.
        case reviewRequested
        /// Pull requests only.
        case reviewedBy
        case assignee
        case mentions
    }

    struct Person: Codable, Sendable, Hashable {
        var role: Role
        /// A GitHub login; nil for the account gh is signed in to.
        var login: String?

        var isViewer: Bool { login == nil }
    }

    enum Repository: Codable, Sendable, Hashable {
        /// `owner/name`.
        case repository(String)
        /// Every repository the account with this login owns, a user's or
        /// an organization's.
        case owner(String)

        /// The account that owns what it covers.
        var owner: String {
            switch self {
            case .repository(let name): String(name.split(separator: "/").first ?? Substring(name))
            case .owner(let login): login
            }
        }
    }

    var state: State = .open
    /// Nil is All: what involves the account, as the list showed before
    /// there were filters.
    var person: Person?
    var repository: Repository?
    var label: String?

    var isDefault: Bool { self == GitHubListFilter() }

    /// The states a segment offers, in the menu's order.
    static func states(for kind: GitHubItem.Kind) -> [State] {
        switch kind {
        case .pullRequest: [.open, .draft, .merged, .closed, .all]
        case .issue: [.open, .closed, .all]
        }
    }

    /// The roles a segment offers, in the menu's order.
    static func roles(for kind: GitHubItem.Kind) -> [Role] {
        switch kind {
        case .pullRequest: [.author, .reviewRequested, .reviewedBy, .assignee, .mentions]
        case .issue: [.author, .assignee, .mentions]
        }
    }

    /// This filter as `kind`'s segment can hold it: a choice that segment
    /// does not offer goes back to its default.
    func valid(for kind: GitHubItem.Kind) -> GitHubListFilter {
        var filter = self
        if !Self.states(for: kind).contains(filter.state) { filter.state = .open }
        if let person, !Self.roles(for: kind).contains(person.role) { filter.person = nil }
        return filter
    }
}

// MARK: - What the row of chips and its menus say

extension GitHubListFilter.State {
    func title(for kind: GitHubItem.Kind) -> String {
        switch self {
        case .open: String(localized: "GitHub state Open", defaultValue: "Open")
        case .draft: String(localized: "Draft")
        case .merged: String(localized: "Merged")
        case .closed: String(localized: "GitHub state Closed", defaultValue: "Closed")
        case .all: String(localized: "All States")
        }
    }

    /// The line under the option in the State menu, where one helps.
    func subtitle(for kind: GitHubItem.Kind) -> String? {
        switch (self, kind) {
        case (.open, .pullRequest): String(localized: "Drafts included")
        case (.closed, .pullRequest): String(localized: "Closed without merging")
        case (.closed, .issue): String(localized: "Completed or not planned")
        default: nil
        }
    }
}

extension GitHubListFilter.Role {
    /// "Created by You", for the account gh is signed in to.
    var viewerTitle: String {
        switch self {
        case .author: String(localized: "Created by You")
        case .reviewRequested: String(localized: "Needs Your Review")
        case .reviewedBy: String(localized: "Reviewed by You")
        case .assignee: String(localized: "Assigned to You")
        case .mentions: String(localized: "Mentioning You")
        }
    }

    /// "Created by sam-okafor", for someone else.
    func title(for login: String) -> String {
        switch self {
        case .author:
            String(localized: "Created by \(login)", comment: "A GitHub person filter. The argument is a GitHub login.")
        case .reviewRequested:
            String(localized: "Needs \(login)'s Review", comment: "A GitHub person filter. The argument is a GitHub login.")
        case .reviewedBy:
            String(localized: "Reviewed by \(login)", comment: "A GitHub person filter. The argument is a GitHub login.")
        case .assignee:
            String(localized: "Assigned to \(login)", comment: "A GitHub person filter. The argument is a GitHub login.")
        case .mentions:
            String(localized: "Mentioning \(login)", comment: "A GitHub person filter. The argument is a GitHub login.")
        }
    }

    /// "Created by Them", in the Someone Else sheet before a name is typed.
    var someoneTitle: String {
        switch self {
        case .author: String(localized: "Created by Them")
        case .reviewRequested: String(localized: "Needs Their Review")
        case .reviewedBy: String(localized: "Reviewed by Them")
        case .assignee: String(localized: "Assigned to Them")
        case .mentions: String(localized: "Mentioning Them")
        }
    }
}

extension GitHubListFilter.Person {
    var title: String {
        login.map(role.title(for:)) ?? role.viewerTitle
    }
}

extension GitHubListFilter {
    /// The State chip's words.
    func stateTitle(for kind: GitHubItem.Kind) -> String { state.title(for: kind) }

    /// The Person chip's words: "All" at the default.
    var personTitle: String {
        person?.title ?? String(localized: "All")
    }

    /// The Repository chip's words: the repository's name, "All of acme"
    /// for an owner, "Repository" at the default.
    var repositoryTitle: String {
        switch repository {
        case .repository(let name):
            String(name.split(separator: "/").last ?? Substring(name))
        case .owner(let login):
            String(localized: "All of \(login)", comment: "A GitHub Repository filter: every repository an account owns.")
        case nil:
            String(localized: "Repository")
        }
    }

    /// The Label chip's words: the label, "Label" at the default.
    var labelTitle: String {
        label ?? String(localized: "Label", comment: "The GitHub Label filter's chip at its default.")
    }
}

/// What a person types in the filter sheets, as GitHub names it.
enum GitHubFilterInput {
    /// A login: letters, digits and hyphens, at most 39.
    static func login(_ text: String) -> String? {
        let login = trimmed(text)
        guard !login.isEmpty, login.count <= 39,
            login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return login
    }

    /// `owner/name` or an owner alone.
    static func repository(_ text: String) -> GitHubListFilter.Repository? {
        let text = trimmed(text)
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return login(text).map(GitHubListFilter.Repository.owner)
        case 2:
            let name = parts[1]
            guard let owner = login(String(parts[0])), !name.isEmpty, name.count <= 100,
                name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
            else { return nil }
            return .repository("\(owner)/\(name)")
        default:
            return nil
        }
    }

    /// A label's name. A double quote cannot be searched for, since the
    /// name goes between double quotes.
    static func label(_ text: String) -> String? {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 100, !label.contains("\""), !label.contains(where: \.isNewline) else {
            return nil
        }
        return label
    }

    private static func trimmed(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("@") { text.removeFirst() }
        return text
    }
}
