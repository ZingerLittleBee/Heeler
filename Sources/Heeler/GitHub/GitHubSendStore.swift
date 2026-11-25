import Foundation
import Observation

/// What Send to Agent asks the Agent to do with a pull request or an issue.
enum GitHubSendMode: String, Identifiable, Sendable {
    case review
    case fixChecks
    case addressReview
    case work
    case investigate
    case read

    var id: Self { self }

    var title: String {
        switch self {
        case .review: String(localized: "Review It")
        case .fixChecks: String(localized: "Fix the Failing Checks")
        case .addressReview: String(localized: "Address the Review Comments")
        case .work: String(localized: "Work on It")
        case .investigate: String(localized: "Investigate First")
        case .read: String(localized: "Just Read It")
        }
    }

    /// The sentence put in the Agent's Composer, then the item's address.
    /// A program reads it, so it is not localized (ADR 0041); the user reads
    /// it too, and can reword it before sending.
    func message(for item: GitHubItem) -> String {
        let sentence =
            switch (self, item.kind) {
            case (.review, _): "Review this pull request and tell me what you find:"
            case (.fixChecks, _): "Checks are failing on this pull request. Find out why and fix them:"
            case (.addressReview, _): "Address the review comments on this pull request:"
            case (.work, _): "Work on this issue:"
            case (.investigate, _): "Investigate this issue and report what you find before changing anything:"
            case (.read, .pullRequest): "Read this pull request:"
            case (.read, .issue): "Read this issue:"
            }
        return "\(sentence) \(item.url)"
    }

    /// What the sheet offers for an item, as its detail (or, before that
    /// arrives, its row) shows it. Fixing checks is for the account's own
    /// pull request; addressing comments for one with changes requested.
    static func modes(for item: GitHubItem, detail: GitHubItemDetail?, viewer: String?) -> [GitHubSendMode] {
        switch item.kind {
        case .issue:
            return [.work, .investigate, .read]
        case .pullRequest:
            let isViewers = detail?.isViewers ?? (viewer != nil && item.author == viewer)
            let changesRequested: Bool
            if let review = detail?.pullRequest?.review {
                if case .changesRequested = review { changesRequested = true } else { changesRequested = false }
            } else {
                changesRequested = item.review == .changesRequested
            }
            var modes: [GitHubSendMode] = [.review]
            if isViewers, (item.checks?.failing ?? 0) > 0 { modes.append(.fixChecks) }
            if changesRequested { modes.append(.addressReview) }
            modes.append(.read)
            return modes
        }
    }

    /// The account's failing pull request opens on fixing it.
    static func defaultMode(in modes: [GitHubSendMode]) -> GitHubSendMode {
        if modes.contains(.fixChecks) { return .fixChecks }
        return modes.first ?? .read
    }
}

/// Send to Agent for one item, from its detail.
struct GitHubSendRequest: Identifiable, Sendable {
    let id = UUID()
    let host: GitHubHost
    let item: GitHubItem
}

/// An Agent the sheet offers, with how its checkout relates to the item.
struct GitHubSendTarget: Identifiable {
    enum Mark: Equatable {
        /// A checkout of the item's repository on the pull request's branch.
        case onBranch
        /// A checkout of the item's repository.
        case repository
    }

    let agent: ConsoleAgent
    let mark: Mark?

    var id: ConsoleAgent.ID { agent.id }

    /// Agents in a checkout of the item's repository first, those on the
    /// pull request's branch before the rest of them; the others after, in
    /// the order they came.
    static func ordered(
        _ agents: [ConsoleAgent], checkouts: [String: GitHubCheckout], item: GitHubItem, headBranch: String?
    ) -> [GitHubSendTarget] {
        let host = URL(string: item.url)?.host() ?? "github.com"
        let targets = agents.map { agent in
            let checkout = agent.directory.flatMap { checkouts[$0] }
            let mark: Mark? =
                if let checkout, checkout.isCheckout(of: item.repository, host: host) {
                    if let headBranch, !headBranch.isEmpty, checkout.branch == headBranch { .onBranch } else { .repository }
                } else {
                    nil
                }
            return GitHubSendTarget(agent: agent, mark: mark)
        }
        func rank(_ target: GitHubSendTarget) -> Int {
            switch target.mark {
            case .onBranch: 0
            case .repository: 1
            case nil: 2
            }
        }
        return targets.enumerated()
            .sorted { rank($0.element) == rank($1.element) ? $0.offset < $1.offset : rank($0.element) < rank($1.element) }
            .map(\.element)
    }
}

/// One Send to Agent: which Agent gets the item, with what message. Picking
/// one puts the message in its Composer, by Hand Off's rules, and opens it;
/// nothing is sent.
@MainActor
@Observable
final class GitHubSendStore {
    enum State: Equatable {
        case choosing
        case working(ConsoleAgent.ID)
        case failed(String)
        /// The message is in this Agent's Composer.
        case sent(ConsoleAgent.ID)
    }

    let request: GitHubSendRequest
    /// The mode the user picked; nil until they pick one.
    var chosenMode: GitHubSendMode?
    private(set) var checkouts: [String: GitHubCheckout] = [:]
    private(set) var isReadingCheckouts = false
    private(set) var state = State.choosing

    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private let readCheckouts: ([String]) async -> [String: GitHubCheckout]
    @ObservationIgnored private let deliver: (String, ConsoleAgent.ID) async throws -> Void

    /// - Parameters:
    ///   - readCheckouts: The checkouts among directories on the item's Host
    ///     (`GitHubStore.readCheckouts`).
    ///   - deliver: Puts a message in an Agent's Composer (`ConsoleStore.deliverDraft`).
    init(
        request: GitHubSendRequest,
        readCheckouts: @escaping ([String]) async -> [String: GitHubCheckout],
        deliver: @escaping (String, ConsoleAgent.ID) async throws -> Void
    ) {
        self.request = request
        self.readCheckouts = readCheckouts
        self.deliver = deliver
    }

    var isWorking: Bool {
        if case .working = state { true } else { false }
    }

    /// The picked mode while the sheet still offers it, else the default.
    func mode(in modes: [GitHubSendMode]) -> GitHubSendMode {
        chosenMode.flatMap { modes.contains($0) ? $0 : nil } ?? GitHubSendMode.defaultMode(in: modes)
    }

    /// Reads the directories not read yet. The Agents show unmarked until
    /// it answers, and stay so if it does not.
    func readCheckouts(of directories: [String]) async {
        let unread = directories.filter { checkouts[$0] == nil }
        guard !unread.isEmpty else { return }
        isReadingCheckouts = true
        let found = await readCheckouts(unread)
        checkouts.merge(found) { _, new in new }
        isReadingCheckouts = false
    }

    func send(_ message: String, to id: ConsoleAgent.ID) async {
        guard !isWorking, !isSent else { return }
        state = .working(id)
        let task = Task { [self] in
            do {
                try await deliver(message, id)
                state = .sent(id)
            } catch {
                state = Task.isCancelled ? .choosing : .failed(Self.message(for: error))
            }
        }
        work = task
        await task.value
    }

    /// The sheet is closing: nothing is put in a Composer after this.
    func cancel() {
        work?.cancel()
    }

    private var isSent: Bool {
        if case .sent = state { true } else { false }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as HandOffError:
            error.message
        case TransportError.sshUnreachable:
            String(localized: "The Host is not connected.")
        default:
            String(localized: "The message could not be put in that Agent's Composer: \(String(describing: error))")
        }
    }
}
