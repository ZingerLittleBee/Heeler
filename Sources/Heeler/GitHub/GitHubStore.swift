import Foundation
import Observation

/// A Host as the GitHub tab lists it: one machine, whichever of its Servers
/// is connected. gh is the machine's, not a Server's (ADR 0064).
struct GitHubHost: Identifiable, Hashable, Sendable {
    /// The machine's first catalog record, which keys its saved list and
    /// the tab's choice of Host.
    let id: Host.ID
    let name: String
    /// The records of its Servers that are on, in catalog order.
    let records: [Host.ID]
    /// Each record's Server label, as New Agent's Server picker names it
    /// (`tmux`, `herdr-core`, ADR 0047), for Send to Agent's rows when more
    /// than one Server's Agents are listed.
    var serverLabels: [Host.ID: String] = [:]
}

/// What the GitHub tab needs of the Console's connections.
@MainActor
protocol GitHubHostAccess: AnyObject {
    /// Whether a Server of the Host is connected now.
    func isConnected(_ recordID: Host.ID) -> Bool
    /// Whether the record is known to be a native Windows Host.
    func isNativeWindows(_ recordID: Host.ID) -> Bool
    /// Runs one gh request on the record's connection, by the route that
    /// connection last needed.
    func runGitHub(_ request: GitHubCLIRequest, on recordID: Host.ID) async throws -> GitHubCLIOutcome
    /// Runs a script of Heeler's own through the same bounded exec as gh,
    /// such as the checkout read behind Send to Agent.
    func runGitHubSeamScript(_ script: Data, on recordID: Host.ID) async throws -> GitExecResult
    /// Forgets which route the Host's connections needed, so the next run
    /// tries the exec first again.
    func forgetGitHubRoutes(_ recordIDs: [Host.ID])
}

/// The GitHub tab's lists, one per Host (ADR 0064). A list read from disk
/// shows at once; a read runs when the tab opens on a stale list, on
/// pull-to-refresh and on Check Again, never in the background.
@MainActor
@Observable
final class GitHubStore {
    struct HostState: Equatable {
        /// The last list read, from this launch or saved on the device.
        var list: GitHubList?
        var isReading = false
        /// Why the last read failed; nil after one that worked.
        var failure: GitHubReadFailure?
    }

    /// One pull request's or issue's detail on one Host, in memory only.
    struct DetailState: Equatable {
        var detail: GitHubItemDetail?
        var isReading = false
        /// Why the last read failed; nil after one that worked.
        var failure: GitHubReadFailure?
    }

    struct DetailKey: Hashable {
        let host: Host.ID
        let item: GitHubItem.ID
    }

    /// A detail read that answered, and the Server it answered on.
    private struct DetailAnswer: Sendable {
        let detail: GitHubItemDetail
        let record: Host.ID
    }

    /// A list or detail older than this is read again when it opens.
    static let staleAfter: TimeInterval = 120
    /// How long Send to Agent waits for the checkout read before it leaves
    /// the Agents unmarked.
    static let checkoutReadLimit: Duration = .seconds(8)

    let settings: GitHubSettings
    /// The Hosts the menu offers, in catalog order.
    private(set) var hosts: [GitHubHost] = []
    private(set) var states: [Host.ID: HostState] = [:]
    private(set) var details: [DetailKey: DetailState] = [:]
    /// Items with a write running, one write per item at a time.
    private(set) var writing: Set<DetailKey> = []

    @ObservationIgnored weak var access: (any GitHubHostAccess)?
    @ObservationIgnored private let cache: any GitHubListCache
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var machines: [GitHubHost] = []
    /// Hosts that answered that they cannot run gh this way.
    @ObservationIgnored private var unsupported: Set<Host.ID> = []
    @ObservationIgnored private var loadedCaches: Set<Host.ID> = []
    @ObservationIgnored private var reads: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var detailReads: [DetailKey: Task<Result<DetailAnswer, GitHubReadFailure>, Never>] = [:]
    /// Bumped when the switch goes off, so a read already running keeps
    /// nothing it finds.
    @ObservationIgnored private var generation = 0

    init(
        settings: GitHubSettings = GitHubSettings(),
        cache: any GitHubListCache = VolatileGitHubListCache(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.cache = cache
        self.now = now
    }

    var isEnabled: Bool { settings.isEnabled }

    /// The Host the tab shows: the one chosen, or the first.
    var selectedHost: GitHubHost? {
        hosts.first { $0.id == settings.selectedHostID } ?? hosts.first
    }

    func state(of host: GitHubHost) -> HostState {
        states[host.id] ?? HostState()
    }

    func isConnected(_ host: GitHubHost) -> Bool {
        host.records.contains { access?.isConnected($0) == true }
    }

    // MARK: Hosts

    /// Follows the catalog. `hostsOutOfSight` is `HostStore.hostsOutOfSight`;
    /// nil says the catalog could not be read, so no saved list is swept.
    func setCatalog(_ catalogHosts: [Host], hostsOutOfSight: Set<Host.ID>?) {
        let previous = machines
        machines = HostMachine.grouped(catalogHosts).compactMap { machine in
            let records = machine.servers.map(\.id)
            guard let first = machine.members.first, !records.isEmpty else { return nil }
            let labels = machine.servers.map { ($0.id, LaunchHostChoice.serverLabel(for: $0)) }
            return GitHubHost(
                id: first.id, name: machine.name, records: records,
                serverLabels: Dictionary(labels) { first, _ in first })
        }
        let ids = Set(machines.map(\.id))
        let moves = Self.moves(from: previous, to: machines)
        for move in moves {
            if var state = states[move.from] {
                state.isReading = false
                states[move.to] = state
            }
            if settings.selectedHostID == move.from { settings.selectHost(move.to) }
        }
        states = states.filter { ids.contains($0.key) }
        details = details.filter { ids.contains($0.key.host) }
        for (key, task) in detailReads where !ids.contains(key.host) {
            task.cancel()
            detailReads[key] = nil
        }
        loadedCaches.formIntersection(ids)
        unsupported.formIntersection(ids)
        for (id, task) in reads where !ids.contains(id) {
            task.cancel()
            reads[id] = nil
        }
        let retained = hostsOutOfSight?.union(catalogHosts.map(\.id))
        if isEnabled, retained != nil || !moves.isEmpty {
            Task { [cache] in
                for move in moves {
                    if let list = await cache.load(move.from) { await cache.save(list, for: move.to) }
                }
                if let retained { await cache.retainHosts(retained) }
            }
        }
        refreshHosts()
    }

    /// A Host is keyed by its first record. When that record goes, as turning
    /// its Server off removes it, the Host is still there under the first
    /// record of the machine that holds one of its others, and its choice in
    /// the menu and its saved list go with it.
    private static func moves(
        from previous: [GitHubHost], to current: [GitHubHost]
    ) -> [(from: Host.ID, to: Host.ID)] {
        let previousIDs = Set(previous.map(\.id))
        let currentIDs = Set(current.map(\.id))
        return previous.compactMap { old in
            guard !currentIDs.contains(old.id),
                let new = current.first(where: { machine in
                    !previousIDs.contains(machine.id) && machine.records.contains(where: old.records.contains)
                })
            else { return nil }
            return (from: old.id, to: new.id)
        }
    }

    /// Hides Hosts known to be native Windows, which the Console learns
    /// after it connects.
    func refreshHosts() {
        let shown = machines.filter { machine in
            !unsupported.contains(machine.id)
                && !machine.records.contains { access?.isNativeWindows($0) == true }
        }
        if shown != hosts { hosts = shown }
    }

    /// Shows another Host; the tab reads it as it does on opening.
    func select(_ host: GitHubHost) {
        settings.selectHost(host.id)
    }

    // MARK: Reading

    /// The tab is showing: show what the device saved for every Host, then
    /// read the shown Host's lists again when they are stale.
    func appear() async {
        guard isEnabled else { return }
        await loadSavedLists()
        guard let host = selectedHost else { return }
        let state = state(of: host)
        guard !state.isReading else { return }
        if let list = state.list, state.failure == nil,
            now().timeIntervalSince(list.readAt) < Self.staleAfter
        {
            return
        }
        await read(host)
    }

    /// Pull-to-refresh: reads the shown Host's lists and returns when done.
    func refresh() async {
        guard isEnabled, let host = selectedHost else { return }
        await read(host)
    }

    /// Check Again, after the user installed gh or signed in on the Host:
    /// the next run tries the exec first, then reads.
    func checkAgain() async {
        guard isEnabled, let host = selectedHost else { return }
        access?.forgetGitHubRoutes(host.records)
        await read(host)
    }

    /// The switch went off: stops reading and forgets every list, here and
    /// on disk.
    func reset() {
        generation += 1
        for task in reads.values { task.cancel() }
        for task in detailReads.values { task.cancel() }
        reads = [:]
        detailReads = [:]
        states = [:]
        details = [:]
        loadedCaches = []
        unsupported = []
        Task { [cache] in await cache.removeAll() }
    }

    private func loadSavedLists() async {
        for host in machines where !loadedCaches.contains(host.id) {
            loadedCaches.insert(host.id)
            let generation = generation
            guard let list = await cache.load(host.id), generation == self.generation else { continue }
            if states[host.id]?.list == nil {
                states[host.id, default: HostState()].list = list
            }
        }
    }

    /// One read per Host at a time; a second caller waits for the first.
    private func read(_ host: GitHubHost) async {
        if let running = reads[host.id] {
            await running.value
            return
        }
        let task = Task { await performRead(host) }
        reads[host.id] = task
        await task.value
        if reads[host.id] == task { reads[host.id] = nil }
    }

    private func performRead(_ host: GitHubHost) async {
        let generation = generation
        states[host.id, default: HostState()].isReading = true
        let failure: GitHubReadFailure?
        var list: GitHubList?
        switch await run(GitHubListRead.request, on: host) {
        case .success(let outcome):
            switch GitHubListRead.result(of: outcome, at: now()) {
            case .success(let read):
                list = read
                failure = nil
            case .failure(let readFailure):
                failure = readFailure
            }
        case .failure(let runFailure):
            failure = runFailure
        }
        guard generation == self.generation, machines.contains(where: { $0.id == host.id }) else { return }
        var state = states[host.id] ?? HostState()
        state.isReading = false
        state.failure = failure
        if let list {
            state.list = list
            Task { [cache] in await cache.save(list, for: host.id) }
        }
        states[host.id] = state
        if failure == .unsupported {
            unsupported.insert(host.id)
            refreshHosts()
        }
    }

    // MARK: An item's detail

    func detailState(of item: GitHubItem, on host: GitHubHost) -> DetailState {
        details[DetailKey(host: host.id, item: item.id)] ?? DetailState()
    }

    /// The item as the Host's list last showed it, if it still does.
    func listItem(_ id: GitHubItem.ID, on host: GitHubHost) -> GitHubItem? {
        state(of: host).list?.sections.lazy.flatMap(\.items).first { $0.id == id }
    }

    /// The detail opened: its row shows at once, and the rest is read
    /// unless a read from the last two minutes is in memory.
    func openDetail(_ item: GitHubItem, on host: GitHubHost) async {
        guard isEnabled else { return }
        let state = detailState(of: item, on: host)
        if let detail = state.detail, state.failure == nil,
            now().timeIntervalSince(detail.readAt) < Self.staleAfter
        {
            return
        }
        await reread(item, on: host)
    }

    /// Reads one item again, as a pull of its detail does and as an action
    /// does before and after it acts. Its detail and its list row both take
    /// what came back. One read per item at a time; a second caller waits
    /// for the first and gets its answer.
    @discardableResult
    func reread(_ item: GitHubItem, on host: GitHubHost) async -> Result<GitHubItemDetail, GitHubReadFailure> {
        await answer(item, on: host).map(\.detail)
    }

    private func answer(_ item: GitHubItem, on host: GitHubHost) async -> Result<DetailAnswer, GitHubReadFailure> {
        let key = DetailKey(host: host.id, item: item.id)
        if let running = detailReads[key] { return await running.value }
        let task = Task { await performDetailRead(item, on: host) }
        detailReads[key] = task
        let result = await task.value
        if detailReads[key] == task { detailReads[key] = nil }
        return result
    }

    /// A read that starts now: one already running may have begun before
    /// what the caller needs to see.
    private func freshAnswer(_ item: GitHubItem, on host: GitHubHost) async -> Result<DetailAnswer, GitHubReadFailure> {
        if let running = detailReads[DetailKey(host: host.id, item: item.id)] { _ = await running.value }
        return await answer(item, on: host)
    }

    private func performDetailRead(
        _ item: GitHubItem, on host: GitHubHost
    ) async -> Result<DetailAnswer, GitHubReadFailure> {
        let generation = generation
        let key = DetailKey(host: host.id, item: item.id)
        details[key, default: DetailState()].isReading = true
        let result = await onHost(host) { access, record in
            try await access.runGitHub(GitHubDetailRead.request(for: item), on: record)
        }.flatMap { ran in
            GitHubDetailRead.result(of: ran.value, for: item, at: now())
                .map { DetailAnswer(detail: $0, record: ran.record) }
        }
        guard generation == self.generation, machines.contains(where: { $0.id == host.id }) else { return result }
        var state = details[key] ?? DetailState()
        state.isReading = false
        switch result {
        case .success(let answer):
            let detail = answer.detail
            state.detail = detail
            state.failure = nil
            if var list = states[host.id]?.list {
                list.replace(detail.item)
                if list != states[host.id]?.list {
                    states[host.id]?.list = list
                    Task { [cache] in await cache.save(list, for: host.id) }
                }
            }
        case .failure(let failure):
            state.failure = failure
        }
        details[key] = state
        return result
    }

    // MARK: Writes

    func isWriting(_ item: GitHubItem, on host: GitHubHost) -> Bool {
        writing.contains(DetailKey(host: host.id, item: item.id))
    }

    /// Comment, Approve, Merge or Close (ADR 0064). Reads the item again and
    /// runs nothing if it no longer takes the write; otherwise runs gh once,
    /// on the Server whose read just answered and on no other, then reads
    /// the item again so the detail, its list row and the saved list follow.
    /// Nil when a write on the item is already running. The write outlives
    /// the caller: a sheet closing under it does not stop it.
    func write(_ write: GitHubWrite, on item: GitHubItem, host: GitHubHost) async -> GitHubWriteResult? {
        let key = DetailKey(host: host.id, item: item.id)
        guard isEnabled, !writing.contains(key) else { return nil }
        writing.insert(key)
        let task = Task {
            let result = await performWrite(write, on: item, host: host)
            writing.remove(key)
            return result
        }
        return await task.value
    }

    private func performWrite(_ write: GitHubWrite, on item: GitHubItem, host: GitHubHost) async -> GitHubWriteResult {
        func result(_ outcome: GitHubWriteOutcome, _ detail: GitHubItemDetail?, _ failure: GitHubReadFailure? = nil)
            -> GitHubWriteResult
        {
            GitHubWriteResult(write: write, item: item, outcome: outcome, detail: detail, readFailure: failure)
        }
        let before: DetailAnswer
        switch await freshAnswer(item, on: host) {
        case .success(let answer):
            before = answer
        case .failure(let failure):
            let reason = GitHubBannerText.message(for: failure)
            return result(.notRun(String(localized: "Heeler could not read it again first, so it ran nothing. \(reason)")), nil, failure)
        }
        if let refusal = write.refusal(by: before.detail) {
            return result(.notRun(refusal), before.detail)
        }
        guard let access, access.isConnected(before.record) else {
            return result(.notRun(GitHubBannerText.message(for: .offline)), before.detail)
        }
        let outcome: GitHubWriteOutcome
        do {
            outcome = GitHubWriteOutcome(try await access.runGitHub(write.request(for: before.detail.item), on: before.record))
        } catch TransportError.hostFeatureUnavailable {
            outcome = .notRun(GitHubBannerText.message(for: .unsupported))
        } catch TransportError.sshUnreachable {
            // Thrown before the exec reached SSH; once there, a failure is
            // `coreMutationOutcomeUnknown`.
            outcome = .notRun(GitHubBannerText.message(for: .offline))
        } catch {
            outcome = .unknown(Self.unknownReason(error))
        }
        if case .notRun = outcome { return result(outcome, before.detail) }
        switch await freshAnswer(item, on: host) {
        case .success(let after): return result(outcome, after.detail)
        case .failure(let failure): return result(outcome, nil, failure)
        }
    }

    private static func unknownReason(_ error: any Error) -> String {
        switch error {
        case GitHubCLIError.unreadableOutput:
            String(localized: "Heeler could not read what gh printed on the Host.")
        case TransportError.hostFileTimedOut, TransportError.timedOut:
            String(localized: "gh did not answer in time.")
        default:
            String(localized: "The connection ended before gh said how it went.")
        }
    }

    // MARK: Checkouts

    /// Which of `directories` on the Host are checkouts, of what and on which
    /// branch, for Send to Agent's marks. Empty when no Server answers in
    /// `checkoutReadLimit`: the marks are a help, never a wait.
    func readCheckouts(_ directories: [String], on host: GitHubHost) async -> [String: GitHubCheckout] {
        guard isEnabled, !directories.isEmpty else { return [:] }
        let nonce = GitProbe.makeNonce()
        let script = GitHubCheckoutRead.script(for: directories, nonce: nonce)
        let read = Task {
            await onHost(host) { access, record in try await access.runGitHubSeamScript(script, on: record) }
                .map { $0.value }
        }
        let first = FirstAnswer<Result<GitExecResult, GitHubReadFailure>>()
        let result = await withCheckedContinuation { continuation in
            first.continuation = continuation
            Task { first.answer(await read.value) }
            Task {
                try? await Task.sleep(for: Self.checkoutReadLimit)
                read.cancel()
                first.answer(.failure(.timedOut))
            }
        }
        guard case .success(let output) = result else { return [:] }
        return GitHubCheckoutRead.checkouts(in: output, directories: directories, nonce: nonce)
    }

    /// The commit a New Agent's Worktree for an item starts from, fetched in
    /// `start`'s checkout on the Server the Agent starts on. Throws
    /// `GitHubWorktreeStartFailure`.
    func worktreeStart(_ start: GitHubWorktreeStart, on record: Host.ID) async throws -> String {
        guard let access else { throw GitHubWorktreeStartFailure.unreachable(String(localized: "The Host is not connected.")) }
        let nonce = GitProbe.makeNonce()
        let output: GitExecResult
        do {
            output = try await access.runGitHubSeamScript(start.script(nonce: nonce), on: record)
        } catch {
            let reason =
                switch Self.failure(error) {
                case .offline: String(localized: "The Host is not connected.")
                case .timedOut: String(localized: "The Host took too long to fetch the worktree's starting commit.")
                case .failed(let message): message
                default: String(describing: error)
                }
            throw GitHubWorktreeStartFailure.unreachable(reason)
        }
        return try start.result(of: output, nonce: nonce).get()
    }

    /// Runs on the first connected Server of the Host that can run gh.
    private func run(
        _ request: GitHubCLIRequest, on host: GitHubHost
    ) async -> Result<GitHubCLIOutcome, GitHubReadFailure> {
        await onHost(host) { access, record in try await access.runGitHub(request, on: record) }.map { $0.value }
    }

    /// A read on the Host's connected Servers in order, until one runs it,
    /// and which one did. A write never comes through here.
    private func onHost<Value>(
        _ host: GitHubHost, _ body: @MainActor (any GitHubHostAccess, Host.ID) async throws -> Value
    ) async -> Result<(value: Value, record: Host.ID), GitHubReadFailure> {
        guard let access else { return .failure(.offline) }
        let connected = host.records.filter { access.isConnected($0) }
        guard !connected.isEmpty else { return .failure(.offline) }
        var failure = GitHubReadFailure.unsupported
        for record in connected {
            do {
                return .success((try await body(access, record), record))
            } catch TransportError.hostFeatureUnavailable {
                continue
            } catch {
                failure = Self.failure(error)
                break
            }
        }
        return .failure(failure)
    }

    private static func failure(_ error: any Error) -> GitHubReadFailure {
        switch error {
        case TransportError.hostFileTimedOut, TransportError.timedOut, TransportError.gitTimedOut:
            return .timedOut
        case TransportError.cancelled, is CancellationError:
            return .failed(String(localized: "The read was cancelled."))
        case GitHubCLIError.unreadableOutput:
            return .failed(String(localized: "Heeler could not read what gh printed on the Host."))
        case let error as TransportError where error.isRetryable:
            return .offline
        case let error as TransportError:
            return .failed(error.presentation.explanation)
        default:
            return .failed(error.localizedDescription)
        }
    }
}

/// The gh script's output did not hold all of its frames.
enum GitHubCLIError: Error, Equatable {
    case unreadableOutput
}

/// Resumes a continuation with whichever of several answers comes first.
@MainActor
private final class FirstAnswer<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Never>?

    func answer(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
