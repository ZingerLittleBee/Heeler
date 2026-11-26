import Foundation
import Observation

/// A Host as the GitHub tab lists it: one machine, whichever of its Servers
/// is connected. gh is the machine's, not a Server's (ADR 0065).
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
    /// connection last needed, or one git request, the exec first.
    func runGitHub(_ request: GitHubCLIRequest, on recordID: Host.ID) async throws -> GitHubCLIOutcome
    /// Runs a script of Heeler's own through the same bounded exec as gh,
    /// such as the checkout read behind Send to Agent.
    func runGitHubSeamScript(_ script: Data, on recordID: Host.ID) async throws -> GitExecResult
    /// Forgets which route the Host's connections needed, so the next run
    /// tries the exec first again.
    func forgetGitHubRoutes(_ recordIDs: [Host.ID])
}

/// The GitHub tab's lists, one per Host (ADR 0065). The list at the
/// filters' defaults, read from disk, shows at once; a read runs when the
/// tab opens on a stale list, when a filter changes, on pull-to-refresh and
/// on Check Again, never in the background.
@MainActor
@Observable
final class GitHubStore {
    struct HostState: Equatable {
        /// The last list read at the filters' defaults, from this launch or
        /// saved on the device.
        var list: GitHubList?
        /// That list is being read.
        var isReading = false
        /// Why the Host's last read failed, of either list; nil after one
        /// that worked.
        var failure: GitHubReadFailure?
        /// What a segment's filter changed from the default found, never
        /// saved: only the list at the defaults is shown offline.
        var results: [GitHubItem.Kind: Results] = [:]
        /// Segments whose next page is being read.
        var readingMore: Set<GitHubItem.Kind> = []
        /// Why a segment's last read of a next page failed, which its row
        /// says in Show More's place.
        var moreFailures: [GitHubItem.Kind: MoreFailure] = [:]
    }

    /// A next page's read that failed, and the list it was read for.
    struct MoreFailure: Equatable {
        let list: UUID
        let failure: GitHubReadFailure
    }

    /// A segment's list under a filter changed from the default.
    struct Results: Equatable {
        let filter: GitHubListFilter
        var list: GitHubItemList?
        /// The account the read answered for.
        var login: String?
        var readAt: Date?
        var isReading = false
        /// Why its last read failed; nil after one that worked.
        var failure: GitHubReadFailure?
    }

    /// What a segment's list area shows of what was read.
    struct Shown: Equatable {
        let list: GitHubItemList
        let login: String
        let readAt: Date
        /// A read is on its way over it.
        let isReading: Bool
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

    private struct ResultsKey: Hashable {
        let host: Host.ID
        let kind: GitHubItem.Kind
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
    /// There are Hosts, and none can run gh, as native Windows cannot.
    private(set) var hasHiddenHostsOnly = false
    private(set) var states: [Host.ID: HostState] = [:]
    private(set) var details: [DetailKey: DetailState] = [:]
    /// Items with a write running, one write per item at a time.
    private(set) var writing: Set<DetailKey> = []
    /// Results that are not plain successes and came after their screen had
    /// gone, oldest first, until the tab shows them.
    private(set) var reports: [GitHubWriteReport] = []

    @ObservationIgnored weak var access: (any GitHubHostAccess)?
    @ObservationIgnored private let cache: any GitHubListCache
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var machines: [GitHubHost] = []
    /// Hosts that answered that they cannot run gh this way.
    @ObservationIgnored private var unsupported: Set<Host.ID> = []
    @ObservationIgnored private var loadedCaches: Set<Host.ID> = []
    @ObservationIgnored private var reads: [Host.ID: Task<Void, Never>] = [:]
    /// Filtered reads, one per segment of a Host, with the filter each reads.
    @ObservationIgnored private var resultsReads: [ResultsKey: (filter: GitHubListFilter, task: Task<Void, Never>)] = [:]
    /// Which owners GitHub said are organizations, by lowercased login.
    @ObservationIgnored private var ownerKinds: [String: Bool] = [:]
    @ObservationIgnored private var detailReads: [DetailKey: Task<Result<DetailAnswer, GitHubReadFailure>, Never>] = [:]
    /// Bumped when the switch goes off, so a read already running keeps
    /// nothing it finds.
    @ObservationIgnored private var generation = 0
    /// The screens that can show a write's result, while they are on screen.
    @ObservationIgnored private var presenters: Set<UUID> = []

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
                state.readingMore = []
                for kind in state.results.keys { state.results[kind]?.isReading = false }
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
        for (key, read) in resultsReads where !ids.contains(key.host) {
            read.task.cancel()
            resultsReads[key] = nil
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
        if hasHiddenHostsOnly != (shown.isEmpty && !machines.isEmpty) { hasHiddenHostsOnly.toggle() }
    }

    /// Shows another Host; the tab reads it as it does on opening.
    func select(_ host: GitHubHost) {
        settings.selectHost(host.id)
    }

    // MARK: Filters

    /// What the filter row shows on a segment.
    func filter(for kind: GitHubItem.Kind) -> GitHubListFilter {
        settings.filter(for: kind)
    }

    /// The user picked a filter; the screen showing it reads.
    func setFilter(_ filter: GitHubListFilter, for kind: GitHubItem.Kind) {
        settings.setFilter(filter, for: kind)
    }

    /// What a segment's list area shows: the list at the defaults, or what
    /// its filter found. Nil while nothing has been read for it, and for a
    /// filter while the Host is offline, since only the list at the
    /// defaults is kept.
    func shown(_ kind: GitHubItem.Kind, on host: GitHubHost) -> Shown? {
        let state = state(of: host)
        let filter = filter(for: kind)
        if filter.isDefault {
            return state.list.map { Shown(list: $0[kind], login: $0.login, readAt: $0.readAt, isReading: state.isReading) }
        }
        guard let results = state.results[kind], results.filter == filter, let list = results.list,
            let login = results.login, let readAt = results.readAt
        else { return nil }
        return Shown(list: list, login: login, readAt: readAt, isReading: results.isReading)
    }

    /// The segment's filtered read, while its filter is changed from the
    /// default.
    func results(_ kind: GitHubItem.Kind, on host: GitHubHost) -> Results? {
        let filter = filter(for: kind)
        guard !filter.isDefault, let results = state(of: host).results[kind], results.filter == filter else {
            return nil
        }
        return results
    }

    /// Why the last read of the next page of what the segment shows failed;
    /// nil once it is read again, or when the list was read anew.
    func moreFailure(_ kind: GitHubItem.Kind, on host: GitHubHost) -> GitHubReadFailure? {
        guard let failure = state(of: host).moreFailures[kind], failure.list == shown(kind, on: host)?.list.id else {
            return nil
        }
        return failure.failure
    }

    // MARK: Reading

    /// The tab is showing `kind`: show what the device saved for every
    /// Host, then read what the segment shows when it is stale or its
    /// filter changed.
    func appear(showing kind: GitHubItem.Kind) async {
        guard isEnabled else { return }
        await loadSavedLists()
        guard let host = selectedHost else { return }
        let state = state(of: host)
        let filter = filter(for: kind)
        if filter.isDefault {
            guard !state.isReading else { return }
            // Until a rate limit ends, only a pull or Check Again asks again.
            if case .rateLimited(let retryAt?) = state.failure, now() < retryAt { return }
            if let list = state.list, state.failure == nil,
                now().timeIntervalSince(list.readAt) < Self.staleAfter
            {
                return
            }
            await read(host)
            return
        }
        // Offline, a filter has nothing to show until the Host connects.
        guard isConnected(host) else { return }
        if let results = state.results[kind], results.filter == filter {
            if results.isReading { return }
            if case .rateLimited(let retryAt?) = state.failure, now() < retryAt { return }
            if results.failure == nil, let readAt = results.readAt, now().timeIntervalSince(readAt) < Self.staleAfter {
                return
            }
        }
        await readResults(kind, filter: filter, on: host)
    }

    /// Pull-to-refresh: reads what the segment shows and returns when done.
    func refresh(showing kind: GitHubItem.Kind) async {
        guard isEnabled, let host = selectedHost else { return }
        let filter = filter(for: kind)
        if filter.isDefault {
            await read(host)
        } else {
            await readResults(kind, filter: filter, on: host)
        }
    }

    /// Check Again, after the user installed gh or signed in on the Host:
    /// the next run tries the exec first, then reads what the segment shows.
    func checkAgain(showing kind: GitHubItem.Kind) async {
        guard isEnabled, let host = selectedHost else { return }
        access?.forgetGitHubRoutes(host.records)
        await refresh(showing: kind)
    }

    /// Show More: the next page of what the segment shows, read from the
    /// searches that need it.
    func showMore(_ kind: GitHubItem.Kind) async {
        guard isEnabled, let host = selectedHost, isConnected(host) else { return }
        let filter = filter(for: kind)
        guard !state(of: host).readingMore.contains(kind), let shown = shown(kind, on: host), shown.list.hasMore
        else { return }
        var list = shown.list
        states[host.id]?.moreFailures[kind] = nil
        let toRead = list.searchesToRead()
        if !toRead.isEmpty {
            let generation = generation
            states[host.id, default: HostState()].readingMore.insert(kind)
            let searches = toRead.map { index in
                GitHubListRead.Search(kind: kind, query: list.searches[index].query, after: list.searches[index].endCursor)
            }
            let answer = await run(GitHubListRead.request(searches), on: host).flatMap {
                GitHubListRead.result(of: $0, searches: searches, at: now())
            }
            guard generation == self.generation, machines.contains(where: { $0.id == host.id }) else { return }
            states[host.id]?.readingMore.remove(kind)
            switch answer {
            case .success(let answer):
                // A read of the first pages may have replaced the list.
                guard let current = self.shown(kind, on: host)?.list, current.id == list.id,
                    self.filter(for: kind) == filter
                else { return }
                list = current
                for (index, page) in zip(toRead, answer.pages) { list.add(page, to: index) }
            case .failure(let failure):
                switch failure {
                case .rateLimited, .timedOut, .failed:
                    // The rows shown stay, and the title bar keeps the
                    // status of the list's own read.
                    states[host.id]?.moreFailures[kind] = MoreFailure(list: list.id, failure: failure)
                case .offline, .notInstalled, .notSignedIn, .unsupported:
                    // The Host or its gh, not the page: the tab says so as
                    // it does for any read.
                    states[host.id]?.failure = failure
                }
                return
            }
        }
        list.show()
        keep(list, of: kind, filter: filter, on: host)
    }

    /// Puts a segment's list back where it came from, saving the list at
    /// the defaults.
    private func keep(_ list: GitHubItemList, of kind: GitHubItem.Kind, filter: GitHubListFilter, on host: GitHubHost) {
        if filter.isDefault {
            guard var saved = states[host.id]?.list else { return }
            saved[kind] = list
            states[host.id]?.list = saved
            Task { [cache] in await cache.save(saved, for: host.id) }
        } else if states[host.id]?.results[kind]?.filter == filter {
            states[host.id]?.results[kind]?.list = list
        }
    }

    /// The switch went off: stops reading and forgets every list, here and
    /// on disk.
    func reset() {
        generation += 1
        for task in reads.values { task.cancel() }
        for read in resultsReads.values { read.task.cancel() }
        for task in detailReads.values { task.cancel() }
        reads = [:]
        resultsReads = [:]
        detailReads = [:]
        states = [:]
        details = [:]
        reports = []
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
        let started = now()
        states[host.id, default: HostState()].isReading = true
        let searches = GitHubListRead.defaultSearches
        let answer = await run(GitHubListRead.request(searches), on: host).flatMap {
            GitHubListRead.result(of: $0, searches: searches, at: now())
        }
        guard generation == self.generation, machines.contains(where: { $0.id == host.id }) else { return }
        var state = states[host.id] ?? HostState()
        state.isReading = false
        switch answer {
        case .success(let answer):
            var list = GitHubListRead.list(from: answer, at: now())
            replaceNewerDetails(in: &list, on: host, since: started)
            state.list = list
            state.failure = nil
            Task { [cache] in await cache.save(list, for: host.id) }
        case .failure(let failure):
            state.failure = failure
        }
        states[host.id] = state
        noteUnsupported(state.failure, on: host)
    }

    /// An item read on its own since a list read began, as a write's read
    /// after it is, is newer than its row there.
    private func replaceNewerDetails(in list: inout GitHubList, on host: GitHubHost, since started: Date) {
        for (key, detailState) in details where key.host == host.id {
            if let detail = detailState.detail, detail.readAt > started { list.replace(detail.item) }
        }
    }

    private func noteUnsupported(_ failure: GitHubReadFailure?, on host: GitHubHost) {
        guard failure == .unsupported else { return }
        unsupported.insert(host.id)
        refreshHosts()
    }

    /// One filtered read per segment of a Host: a second caller for the same
    /// filter waits for the first, and a new filter cancels the old one's.
    private func readResults(_ kind: GitHubItem.Kind, filter: GitHubListFilter, on host: GitHubHost) async {
        let key = ResultsKey(host: host.id, kind: kind)
        if let running = resultsReads[key] {
            if running.filter == filter {
                await running.task.value
                return
            }
            running.task.cancel()
        }
        let task = Task { await performResultsRead(kind, filter: filter, on: host) }
        resultsReads[key] = (filter, task)
        await task.value
        if resultsReads[key]?.task == task { resultsReads[key] = nil }
    }

    private func performResultsRead(_ kind: GitHubItem.Kind, filter: GitHubListFilter, on host: GitHubHost) async {
        let generation = generation
        let started = now()
        var results = states[host.id]?.results[kind]
        if results?.filter != filter { results = Results(filter: filter) }
        results?.isReading = true
        states[host.id, default: HostState()].results[kind] = results
        let answer = await searchResults(kind, filter: filter, on: host)
        // The switch went off, the Host went, or the filter changed on.
        guard generation == self.generation, machines.contains(where: { $0.id == host.id }), !Task.isCancelled,
            var landed = states[host.id]?.results[kind], landed.filter == filter
        else { return }
        landed.isReading = false
        switch answer {
        case .success(let answer):
            var list = answer.list
            for (detailKey, detailState) in details where detailKey.host == host.id {
                if let detail = detailState.detail, detail.readAt > started { list.replace(detail.item) }
            }
            landed.list = list
            landed.login = answer.login
            landed.readAt = now()
            landed.failure = nil
            states[host.id]?.failure = nil
        case .failure(let failure):
            landed.failure = failure
            states[host.id]?.failure = failure
        }
        states[host.id]?.results[kind] = landed
        noteUnsupported(landed.failure, on: host)
    }

    /// The first pages of a filter's searches, learning first whether an
    /// owner the lists have not shown is an organization.
    private func searchResults(
        _ kind: GitHubItem.Kind, filter: GitHubListFilter, on host: GitHubHost
    ) async -> Result<(list: GitHubItemList, login: String), GitHubReadFailure> {
        var isOrganization: Bool?
        if case .owner(let login) = filter.repository {
            if let known = ownerIsOrganization(login, on: host) {
                isOrganization = known
            } else {
                let found = await run(GitHubListRead.ownerRequest(login), on: host).flatMap {
                    GitHubListRead.ownerResult(of: $0, at: now())
                }
                switch found {
                case .success(let found?):
                    ownerKinds[login.lowercased()] = found
                    isOrganization = found
                case .success(nil):
                    // No such account: nothing on GitHub matches.
                    let empty = GitHubItemList(firstPages: [])
                    return .success((empty, state(of: host).list?.login ?? ""))
                case .failure(let failure):
                    return .failure(failure)
                }
            }
        }
        let searches = GitHubListRead.queries(for: filter, kind: kind, ownerIsOrganization: isOrganization)
            .map { GitHubListRead.Search(kind: kind, query: $0) }
        return await run(GitHubListRead.request(searches), on: host)
            .flatMap { GitHubListRead.result(of: $0, searches: searches, at: now()) }
            .map { answer in
                (GitHubItemList(firstPages: zip(searches, answer.pages).map { ($0.0.query, $0.1) }), answer.login)
            }
    }

    /// Whether GitHub said the owner is an organization: the account itself
    /// is a person, and a repository read in a list says so of its owner.
    private func ownerIsOrganization(_ login: String, on host: GitHubHost) -> Bool? {
        let key = login.lowercased()
        if let known = ownerKinds[key] { return known }
        let state = state(of: host)
        if let viewer = state.list?.login, viewer.lowercased() == key { return false }
        let lists = [state.list?.pullRequests, state.list?.issues].compactMap(\.self)
            + state.results.values.compactMap(\.list)
        return lists.lazy.flatMap(\.items)
            .first { $0.repositoryOwner.lowercased() == key && $0.ownerIsOrganization != nil }?
            .ownerIsOrganization
    }

    // MARK: An item's detail

    func detailState(of item: GitHubItem, on host: GitHubHost) -> DetailState {
        details[DetailKey(host: host.id, item: item.id)] ?? DetailState()
    }

    /// The item as one of the Host's lists last showed it, if one still does.
    func listItem(_ id: GitHubItem.ID, on host: GitHubHost) -> GitHubItem? {
        let state = state(of: host)
        let lists = [state.list?.pullRequests, state.list?.issues].compactMap(\.self)
            + state.results.values.compactMap(\.list)
        return lists.lazy.flatMap(\.items).first { $0.id == id }
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

    /// An address that loads one of the item's pictures or videos now
    /// (ADR 0065): the last read's while its signature lasts, else the one
    /// a new read gives. `refresh` reads again after a signed address
    /// failed. Nil when a new read cannot give one.
    func mediaURL(_ media: GitHubMedia, refresh: Bool, of item: GitHubItem, on host: GitHubHost) async -> URL? {
        let current = detailState(of: item, on: host).detail?.media.first { $0.id == media.id } ?? media
        if !refresh, current.isFresh(at: now()) { return current.url }
        guard current.expiresAt != nil, case .success(let detail) = await reread(item, on: host) else { return nil }
        return detail.media.first { $0.id == media.id }?.url
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
            for kind in states[host.id]?.results.keys.map(\.self) ?? [] {
                states[host.id]?.results[kind]?.list?.replace(detail.item)
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

    /// Comment, Approve, Merge or Close (ADR 0065). Reads the item again and
    /// runs nothing if it no longer takes the write; otherwise runs gh once,
    /// on the Server whose read just answered and on no other, then reads
    /// the item again so the detail, its list row and the saved list follow.
    /// Runs nothing when a write on the item is already running. The write
    /// outlives the caller: a sheet closing under it does not stop it. When
    /// `presenter` is nil or has left the screen by the end, a result that
    /// is not a plain success waits in `reports` for the tab.
    @discardableResult
    func write(
        _ write: GitHubWrite, on item: GitHubItem, host: GitHubHost, shownBy presenter: UUID?
    ) async -> GitHubWriteDelivery {
        let key = DetailKey(host: host.id, item: item.id)
        guard isEnabled, !writing.contains(key) else { return .ranNothing }
        writing.insert(key)
        let task = Task {
            let result = await performWrite(write, on: item, host: host)
            writing.remove(key)
            return result
        }
        let result = await task.value
        guard let presenter, presenters.contains(presenter) else {
            if isEnabled, !result.isPlainSuccess { reports.append(GitHubWriteReport(host: host, result: result)) }
            return .screenGone
        }
        return .result(result)
    }

    /// A screen that can show a write's result came on screen.
    func present(_ presenter: UUID) {
        presenters.insert(presenter)
    }

    /// That screen left; a result that comes now goes to `reports`.
    func leave(_ presenter: UUID) {
        presenters.remove(presenter)
    }

    /// The oldest result the tab has not shown, which it now shows.
    func takeReport() -> GitHubWriteReport? {
        reports.isEmpty ? nil : reports.removeFirst()
    }

    private func performWrite(_ write: GitHubWrite, on item: GitHubItem, host: GitHubHost) async -> GitHubWriteResult {
        func result(_ outcome: GitHubWriteOutcome, _ detail: GitHubItemDetail?, _ failure: GitHubReadFailure? = nil)
            -> GitHubWriteResult
        {
            GitHubWriteResult(write: write, item: item, outcome: outcome, detail: detail, readFailure: failure)
        }
        let generation = generation
        let before: DetailAnswer
        switch await freshAnswer(item, on: host) {
        case .success(let answer):
            before = answer
        case .failure(let failure):
            let reason = GitHubBannerText.message(for: failure)
            return result(.notRun(String(localized: "Heeler could not read it again first, so it ran nothing. \(reason)")), nil, failure)
        }
        // The switch went off while the read before ran.
        guard generation == self.generation, isEnabled else {
            return result(.notRun(String(localized: "GitHub was turned off, so Heeler ran nothing.")), before.detail)
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
    /// `start`'s checkout on the Server the Agent starts on: the fetch
    /// through the gh seam, so a Mac runs it in the desktop session when it
    /// fails over SSH, then the branch's rules in an exec of their own.
    /// Throws `GitHubWorktreeStartFailure`.
    func worktreeStart(_ start: GitHubWorktreeStart, on record: Host.ID) async throws -> String {
        guard let access else { throw GitHubWorktreeStartFailure.unreachable(String(localized: "The Host is not connected.")) }
        let nonce = GitProbe.makeNonce()
        let fetchedInto = GitHubWorktreeStart.privateRef(at: Self.epoch(), nonce: nonce)
        do {
            let fetched = try await access.runGitHub(start.fetchRequest(into: fetchedInto), on: record)
            if let failure = start.fetchFailure(fetched) { throw failure }
            let output = try await access.runGitHubSeamScript(
                start.script(nonce: nonce, fetchedInto: fetchedInto, now: Self.epoch()), on: record)
            return try start.result(of: output, nonce: nonce).get()
        } catch let failure as GitHubWorktreeStartFailure {
            throw failure
        } catch GitHubCLIError.unreadableOutput {
            throw GitHubWorktreeStartFailure.incomplete
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
    }

    /// Seconds since 1970 by the device's clock, which names a Worktree
    /// start's private ref and decides when a later start removes it.
    private static func epoch() -> Int { Int(Date().timeIntervalSince1970) }

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
                // A link that failed leaves the Host's next Server to answer;
                // after a timeout, trying on would double the wait.
                if failure == .offline { continue }
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
