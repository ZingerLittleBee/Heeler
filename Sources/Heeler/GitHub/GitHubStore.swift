import Foundation
import Observation

/// A Host as the GitHub tab lists it: one machine, whichever of its Servers
/// is connected. gh is the machine's, not a Server's (ADR 0064).
struct GitHubHost: Identifiable, Equatable, Sendable {
    /// The machine's first catalog record, which keys its saved list and
    /// the tab's choice of Host.
    let id: Host.ID
    let name: String
    /// The records of its Servers that are on, in catalog order.
    let records: [Host.ID]
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

    /// A list older than this is read again when the tab opens on it.
    static let staleAfter: TimeInterval = 120

    let settings: GitHubSettings
    /// The Hosts the menu offers, in catalog order.
    private(set) var hosts: [GitHubHost] = []
    private(set) var states: [Host.ID: HostState] = [:]

    @ObservationIgnored weak var access: (any GitHubHostAccess)?
    @ObservationIgnored private let cache: any GitHubListCache
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var machines: [GitHubHost] = []
    /// Hosts that answered that they cannot run gh this way.
    @ObservationIgnored private var unsupported: Set<Host.ID> = []
    @ObservationIgnored private var loadedCaches: Set<Host.ID> = []
    @ObservationIgnored private var reads: [Host.ID: Task<Void, Never>] = [:]
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
        machines = HostMachine.grouped(catalogHosts).compactMap { machine in
            let records = machine.servers.map(\.id)
            guard let first = machine.members.first, !records.isEmpty else { return nil }
            return GitHubHost(id: first.id, name: machine.name, records: records)
        }
        let ids = Set(machines.map(\.id))
        states = states.filter { ids.contains($0.key) }
        loadedCaches.formIntersection(ids)
        unsupported.formIntersection(ids)
        for (id, task) in reads where !ids.contains(id) {
            task.cancel()
            reads[id] = nil
        }
        if let hostsOutOfSight, isEnabled {
            let retained = hostsOutOfSight.union(catalogHosts.map(\.id))
            Task { [cache] in await cache.retainHosts(retained) }
        }
        refreshHosts()
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
        reads = [:]
        states = [:]
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

    /// Runs on the first connected Server of the Host that can run gh.
    private func run(
        _ request: GitHubCLIRequest, on host: GitHubHost
    ) async -> Result<GitHubCLIOutcome, GitHubReadFailure> {
        guard let access else { return .failure(.offline) }
        let connected = host.records.filter { access.isConnected($0) }
        guard !connected.isEmpty else { return .failure(.offline) }
        var failure = GitHubReadFailure.unsupported
        for record in connected {
            do {
                return .success(try await access.runGitHub(request, on: record))
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
