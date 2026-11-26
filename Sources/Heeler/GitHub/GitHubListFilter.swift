import Foundation

/// What one segment of the GitHub list shows: the filter row's four choices
/// (ADR 0065). Each segment keeps its own on the device; at the default it
/// is what involves the account, open and in any repository, and with a
/// Repository chosen it is everyone's there.
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

    /// Whose items a segment shows.
    enum People: Sendable, Hashable {
        /// What involves the account: two searches, by role (ADR 0065).
        case yours
        /// Anyone's, in the repositories the filter names. Without one it
        /// would search all of GitHub, so it needs a Repository.
        case anyone
        /// One role of one person.
        case person(Person)
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
    /// Nil is the default for the Repository chosen: Yours across
    /// repositories, Anyone in a repository or an owner's.
    var people: People?
    var repository: Repository?
    var label: String?

    var isDefault: Bool { self == GitHubListFilter() }

    /// Whose items the filter shows, its default resolved. Anyone with no
    /// Repository reads as Yours, never as all of GitHub.
    var whose: People {
        switch people {
        case .anyone? where repository == nil, nil: repository == nil ? .yours : .anyone
        case let people?: people
        }
    }

    /// The person a role names, when the filter shows one.
    var person: Person? {
        if case .person(let person) = whose { person } else { nil }
    }

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
        if let person, !Self.roles(for: kind).contains(person.role) { filter.people = nil }
        // Anyone is the default in a Repository and needs one; Yours is the
        // default without one. Kept as nil, the default follows the
        // Repository, and the defaults compare equal.
        switch filter.people {
        case .anyone?: filter.people = nil
        case .yours? where filter.repository == nil: filter.people = nil
        default: break
        }
        return filter
    }

    // MARK: Kept on the device

    private enum CodingKeys: String, CodingKey {
        /// A role of a person's, as 0.1.24 kept it.
        case person
        /// Yours or Anyone, chosen over the Repository's default.
        case people
        case state, repository, label
    }

    private enum Choice: String, Codable {
        case yours, anyone
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .open
        repository = try container.decodeIfPresent(Repository.self, forKey: .repository)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        if let person = try container.decodeIfPresent(Person.self, forKey: .person) {
            people = .person(person)
        } else {
            people = switch try container.decodeIfPresent(Choice.self, forKey: .people) {
            case .yours?: .yours
            case .anyone?: .anyone
            case nil: nil
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(repository, forKey: .repository)
        try container.encodeIfPresent(label, forKey: .label)
        switch people {
        case .person(let person)?: try container.encode(person, forKey: .person)
        case .yours?: try container.encode(Choice.yours, forKey: .people)
        case .anyone?: try container.encode(Choice.anyone, forKey: .people)
        case nil: break
        }
    }

    init() {}
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

    /// The Person chip's words: Yours, Anyone, or the role.
    var personTitle: String {
        switch whose {
        case .yours:
            String(localized: "GitHub person Yours", defaultValue: "Yours", comment: "A GitHub Person filter: what involves you.")
        case .anyone:
            String(
                localized: "GitHub person Anyone", defaultValue: "Anyone",
                comment: "A GitHub Person filter: everyone's, in the repositories chosen.")
        case .person(let person): person.title
        }
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
