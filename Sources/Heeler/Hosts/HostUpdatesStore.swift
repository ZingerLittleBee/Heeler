import Foundation
import Observation

/// Which of the Hosts' Plugins and Helpers this app carries a newer version
/// of, and the updates that bring them up (ADR 0048).
///
/// What a Host holds is read once as each of its Servers connects, over the
/// Console's connection, and kept until the next read. An update runs over a
/// connection of its own, as the Server's page runs it: Hosts side by side,
/// one Host's updates in turn. One that fails stops no other, and is never
/// tried again unasked.
@MainActor
@Observable
final class HostUpdatesStore {
    /// What a Helper update left behind.
    struct HelperOutcome: Sendable, Equatable {
        /// The Helper as read after the action, nil when it could not be.
        var readBack: HostHelperReading?
        /// Why the action did not finish.
        var failure: String?
        /// The action may have run and the Helper could not be read back.
        var isUncertain = false
    }

    /// How the store reaches the Hosts.
    struct Work: Sendable {
        /// One read of a Herdr TUI Server's plugin over the Console's
        /// connection.
        var readPlugin: @Sendable (Host.ID) async -> HeelerPluginStatus = { _ in .unavailable }
        /// One read of a Host's Helper through one of its herdr-core or tmux
        /// Servers, nil when it could not be read.
        var readHelper: @Sendable (Host.ID) async -> HostHelperReading? = { _ in nil }
        var updatePlugin: @Sendable (Host) async -> HeelerPluginActionRunner.Outcome = { _ in .init() }
        var updateHelper: @MainActor @Sendable (Host, _ repairing: Bool) async -> HelperOutcome = { _, _ in
            HelperOutcome()
        }
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    }

    /// How long the prompt waits for the first Hosts to connect and be read,
    /// and how long after that a Host still counts as there at launch.
    struct PromptTiming: Sendable {
        var grace = Duration.seconds(3)
        var window = Duration.seconds(30)
        var poll = Duration.milliseconds(500)
    }

    /// The prompt is due: Hosts read since launch hold versions older than
    /// the ones this app carries, which no prompt has been shown for yet.
    private(set) var isPromptDue = false

    private var plugins: [Host.ID: HeelerPluginStatus] = [:]
    private var helpers: [HostMachine.ID: HostHelperReading] = [:]
    /// What an update is doing, or did, to an item since its last reading.
    private var progress: [HostUpdateItem.ID: HostUpdateItem.State] = [:]
    private var run = HostUpdatesSnapshot.Run.idle

    private struct Job {
        let id: HostUpdateItem.ID
        let repairing: Bool
    }

    @ObservationIgnored private var queues: [HostMachine.ID: [Job]] = [:]
    @ObservationIgnored private var workers: [HostMachine.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var readsInFlight = 0
    @ObservationIgnored private var openPages = 0
    @ObservationIgnored private var promptDecided = false

    @ObservationIgnored private let hosts: @MainActor () -> [Host]
    @ObservationIgnored private let isReachable: @MainActor (Host.ID) -> Bool
    @ObservationIgnored private let work: Work
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bundledPlugin: PluginVersion
    @ObservationIgnored private let bundledHelper: PluginVersion
    @ObservationIgnored private let promptTiming: PromptTiming

    /// How long a finished run reads All Up to Date before the card goes.
    static let finishedLinger = Duration.seconds(2.4)
    /// The pause before a Host that ended an update without an answer is read
    /// again.
    static let readBackDelay = Duration.seconds(3)
    private static let promptedVersionsKey = "host-updates.prompted-versions"

    init(
        hosts: @escaping @MainActor () -> [Host],
        isReachable: @escaping @MainActor (Host.ID) -> Bool = { _ in true },
        work: Work = Work(),
        defaults: UserDefaults = .standard,
        bundledPlugin: PluginVersion = HeelerPluginCompatibility.bundled,
        bundledHelper: PluginVersion = HostHelperCompatibility.bundled,
        promptTiming: PromptTiming = PromptTiming()
    ) {
        self.hosts = hosts
        self.isReachable = isReachable
        self.work = work
        self.defaults = defaults
        self.bundledPlugin = bundledPlugin
        self.bundledHelper = bundledHelper
        self.promptTiming = promptTiming
    }

    // MARK: Reading

    var snapshot: HostUpdatesSnapshot {
        let groups = HostMachine.grouped(hosts()).compactMap { machine -> HostUpdatesSnapshot.Group? in
            let items = baseItems(of: machine).map { overlaid($0) }
            return items.isEmpty ? nil : HostUpdatesSnapshot.Group(id: machine.id, name: machine.name, items: items)
        }
        return HostUpdatesSnapshot(groups: groups, run: run)
    }

    /// The Host's items as its last readings alone say them.
    private func baseItems(of machine: HostMachine) -> [HostUpdateItem] {
        var items = machine.servers.filter { $0.serverKind == .herdrTUI }.compactMap { record in
            HostUpdateItem.plugin(plugins[record.id], on: record, bundled: bundledPlugin)
        }
        if let helper = helperItem(of: machine) { items.append(helper) }
        return items
    }

    private func helperItem(of machine: HostMachine) -> HostUpdateItem? {
        let records = machine.servers.filter(\.serverKind.usesHostHelper)
        guard let record = records.first(where: { isReachable($0.id) }) ?? records.first else { return nil }
        var kinds: [String] = []
        for kind in records.map(\.serverKind.displayName) where !kinds.contains(kind) { kinds.append(kind) }
        return HostUpdateItem.helper(
            helpers[machine.id], on: machine.id, through: record, scope: kinds.joined(separator: ", "))
    }

    /// An update's mark holds only while the reading under it still fits:
    /// a failure goes once the Host reads current, whoever updated it.
    private func overlaid(_ item: HostUpdateItem) -> HostUpdateItem {
        guard let state = progress[item.id] else { return item }
        var item = item
        switch state {
        case .waiting, .updating, .readingBack:
            item.state = state
        case .updated:
            if item.state == .current { item.state = .updated }
        case .failed:
            if item.state != .current { item.state = state }
        case .damaged:
            if item.offersRepair { item.state = state }
        case .current, .other, .updateAvailable:
            break
        }
        return item
    }

    /// These Servers' connections came up: each is asked once what it holds.
    func hostsDidConnect(_ ids: [Host.ID]) async {
        let ids = Set(ids)
        await read(hosts().filter { ids.contains($0.id) })
    }

    /// Asks every Host in reach again.
    func refresh() async {
        await read(hosts().filter { isReachable($0.id) })
    }

    /// A Helper changed from its Server's page, which shares none of its
    /// readings.
    func helpersDidChange() {
        Task { await read(hosts().filter { $0.serverKind.usesHostHelper && isReachable($0.id) }) }
    }

    /// A plugin as its Server's page read it, or changed it. A read that
    /// could not say leaves the last one in place.
    func notePlugin(_ status: HeelerPluginStatus, for id: Host.ID) {
        switch status {
        case .installed, .notInstalled, .unsupportedPlatform:
            guard hosts().contains(where: { $0.id == id }) else { return }
            plugins[id] = status
        case .checking, .unsupportedServerKind, .unavailable:
            break
        }
    }

    /// The catalog changed: what was read of a Host that is gone, or reached
    /// another way now, goes with it.
    func catalogDidChange() {
        let hosts = hosts()
        let records = Set(hosts.map(\.id))
        let machines = Set(hosts.map(HostMachine.Connection.init))
        plugins = plugins.filter { records.contains($0.key) }
        helpers = helpers.filter { machines.contains($0.key) }
        progress = progress.filter { entry in
            switch entry.key {
            case .plugin(let id): records.contains(id)
            case .helper(let machine): machines.contains(machine)
            }
        }
    }

    private enum Read: Sendable {
        case plugin(Host.ID, HeelerPluginStatus)
        case helper(HostMachine.ID, HostHelperReading?)
    }

    private func read(_ records: [Host]) async {
        let pluginRecords = records.filter { $0.serverKind == .herdrTUI }
        // One read answers for a Host, whichever of its Servers carries it.
        var helperRecords: [HostMachine.ID: Host] = [:]
        for record in records where record.serverKind.usesHostHelper {
            let machine = HostMachine.Connection(record)
            if helperRecords[machine] == nil { helperRecords[machine] = record }
        }
        guard !pluginRecords.isEmpty || !helperRecords.isEmpty else { return }
        readsInFlight += 1
        defer { readsInFlight -= 1 }
        let work = work
        await withTaskGroup(of: Read.self) { group in
            for record in pluginRecords {
                group.addTask { .plugin(record.id, await work.readPlugin(record.id)) }
            }
            for (machine, record) in helperRecords {
                group.addTask { .helper(machine, await work.readHelper(record.id)) }
            }
            for await read in group {
                switch read {
                case .plugin(let id, let status):
                    notePlugin(status, for: id)
                case .helper(let machine, let reading):
                    if let reading, hosts().contains(where: { HostMachine.Connection($0) == machine }) {
                        helpers[machine] = reading
                    }
                }
            }
        }
    }

    // MARK: Updating

    /// Starts every update, retry and repair that can start.
    func updateAll() {
        start { _, _ in true }
    }

    func updateAll(on machine: HostMachine.ID) {
        start { group, _ in group.id == machine }
    }

    /// One row's Update, Retry or Repair.
    func update(_ id: HostUpdateItem.ID) {
        start { _, item in item.id == id }
    }

    private func start(_ picks: (HostUpdatesSnapshot.Group, HostUpdateItem) -> Bool) {
        var started = 0
        for group in snapshot.groups {
            for item in group.items where item.state.isReady && picks(group, item) {
                let repairing = if case .damaged = item.state { true } else { false }
                queues[group.id, default: []].append(Job(id: item.id, repairing: repairing))
                progress[item.id] = .waiting
                started += 1
            }
        }
        guard started > 0 else { return }
        if case .running(let done, let total) = run {
            run = .running(done: done, total: total + started)
        } else {
            run = .running(done: 0, total: started)
        }
        for machine in queues.keys where workers[machine] == nil {
            workers[machine] = Task { await drain(machine) }
        }
    }

    /// One Host's updates, in turn.
    private func drain(_ machine: HostMachine.ID) async {
        while let job = queues[machine]?.first {
            queues[machine]?.removeFirst()
            await perform(job, on: machine)
            if case .running(let done, let total) = run { run = .running(done: done + 1, total: total) }
        }
        queues[machine] = nil
        workers[machine] = nil
        settle()
    }

    private func perform(_ job: Job, on machine: HostMachine.ID) async {
        guard let item = snapshot.item(job.id)?.item, let record = hosts().first(where: { $0.id == item.record })
        else {
            // Its Host left the catalog while it waited.
            progress[job.id] = nil
            return
        }
        progress[job.id] = .updating
        switch job.id {
        case .plugin(let id):
            let outcome = await work.updatePlugin(record)
            if let status = outcome.readBack { notePlugin(status, for: id) }
            var wasRead = true
            if outcome.isUncertain {
                progress[job.id] = .readingBack
                await work.sleep(Self.readBackDelay)
                let status = await work.readPlugin(id)
                notePlugin(status, for: id)
                switch status {
                case .installed, .notInstalled: break
                case .checking, .unsupportedPlatform, .unsupportedServerKind, .unavailable: wasRead = false
                }
            }
            let base = hosts().first { $0.id == id }.flatMap {
                HostUpdateItem.plugin(plugins[id], on: $0, bundled: bundledPlugin)
            }
            progress[job.id] = conclusion(
                for: item, base: base,
                failure: outcome.failure.map { HostUpdateFailure(message: $0.message, detail: $0.detail) },
                isUncertain: outcome.isUncertain, wasRead: wasRead)
        case .helper:
            let outcome = await work.updateHelper(record, job.repairing)
            if let reading = outcome.readBack { helpers[machine] = reading }
            var wasRead = true
            if outcome.isUncertain {
                progress[job.id] = .readingBack
                await work.sleep(Self.readBackDelay)
                if let reading = await work.readHelper(record.id) {
                    helpers[machine] = reading
                } else {
                    wasRead = false
                }
            }
            let reading = helpers[machine]
            if wasRead, let reading, reading.installAction == .repair {
                // The update put something there that does not stand.
                let said = reading.presentation
                progress[job.id] = .damaged(
                    HostUpdateFailure(
                        message: String(localized: "\(said.value.asSentence) \(said.detail)"),
                        detail: outcome.failure))
                return
            }
            let base = HostUpdateItem.helper(reading, on: machine, through: record, scope: item.scope)
            // An update that ended without an answer is worded here, so what
            // the connection said goes under it.
            progress[job.id] = conclusion(
                for: item, base: base,
                failure: outcome.failure.map {
                    HostUpdateFailure(message: $0, detail: outcome.isUncertain ? $0 : nil)
                },
                isUncertain: outcome.isUncertain, wasRead: wasRead)
        }
    }

    /// What an update came to, from what the Host reads now. The reading has
    /// the last word: an update that reported a failure and left the Host
    /// current took.
    private func conclusion(
        for item: HostUpdateItem, base: HostUpdateItem?, failure: HostUpdateFailure?, isUncertain: Bool,
        wasRead: Bool
    ) -> HostUpdateItem.State? {
        if wasRead, base?.state == .current { return .updated }
        let name = item.component.name
        if isUncertain {
            // The step's own failure says to run the Server's checks again,
            // which this already did.
            guard wasRead, let base else {
                return .failed(
                    HostUpdateFailure(
                        message: String(localized: "The connection ended or the Host took too long, and Heeler could not read what is installed there now. Try again once the Host is connected."),
                        detail: failure?.detail))
            }
            return .failed(
                HostUpdateFailure(
                    message: String(
                        localized: "The connection ended or the Host took too long, and it still has \(name) \(base.installed). The update may still finish there, so check again in a minute.",
                        comment: "Arguments: Heeler Plugin or Host Helper, then the version the Host holds."),
                    detail: failure?.detail))
        }
        if let failure { return .failed(failure) }
        // Nothing failed and the Host is not current: its reading says why,
        // on the Server's page.
        return base?.state == .updateAvailable
            ? .failed(
                HostUpdateFailure(
                    message: String(
                        localized: "\(name) was not updated.", comment: "Argument: Heeler Plugin or Host Helper.")))
            : nil
    }

    /// Every Host has finished its turn.
    private func settle() {
        guard workers.isEmpty else { return }
        guard snapshot.outstanding.isEmpty else {
            run = .idle
            return
        }
        run = .finished
        let sleep = work.sleep
        Task {
            await sleep(Self.finishedLinger)
            guard run == .finished else { return }
            run = .idle
            if openPages == 0 { forgetUpdated() }
        }
    }

    /// An Updates page is showing: what updated keeps its check mark while
    /// the page stays up.
    func pageDidOpen() {
        openPages += 1
    }

    func pageDidClose() {
        openPages = max(0, openPages - 1)
        if openPages == 0, run == .idle { forgetUpdated() }
    }

    private func forgetUpdated() {
        progress = progress.filter { $0.value != .updated }
    }

    // MARK: Prompt

    private var bundledVersions: String { "plugin \(bundledPlugin), helper \(bundledHelper)" }

    /// Decides, once for this launch, whether the prompt is due. It waits for
    /// the first Hosts to connect and be read, then looks for a short while
    /// longer. A Host that connects after that reaches the card and the badge
    /// only, and a launch that found nothing older leaves the question to the
    /// next.
    func decidePrompt() async {
        guard !promptDecided else { return }
        promptDecided = true
        guard defaults.string(forKey: Self.promptedVersionsKey) != bundledVersions else { return }
        await work.sleep(promptTiming.grace)
        var waited = Duration.zero
        while waited < promptTiming.window {
            if readsInFlight == 0, snapshot.items.contains(where: { $0.state == .updateAvailable }) {
                isPromptDue = true
                return
            }
            await work.sleep(promptTiming.poll)
            waited += promptTiming.poll
        }
    }

    /// A window put the prompt up. It is not shown again for the versions
    /// this app carries.
    func promptDidShow() {
        isPromptDue = false
        defaults.set(bundledVersions, forKey: Self.promptedVersionsKey)
    }
}

extension HostUpdatesStore.Work {
    /// The app's: reads borrow the Console's connection to the Server, and
    /// each update dials for itself with the catalog's credentials, declining
    /// a key that still needs trusting. `helperDidChange` runs after a Helper
    /// update has been read back, for what else follows the Helper.
    @MainActor
    static func app(
        console: ConsoleStore,
        dialing: HostOnboardingDependencies = HostOnboardingDependencies(),
        helperDidChange: @escaping @MainActor @Sendable () -> Void = {}
    ) -> Self {
        Self(
            readPlugin: { [weak console] id in
                guard let console else { return .unavailable }
                do {
                    let plugin = try await console.withNotificationTransport(for: id) {
                        try await $0.readHeelerPlugin()
                    }
                    return HeelerPluginStatus(.success(plugin))
                } catch {
                    return HeelerPluginStatus(.failure(error))
                }
            },
            readHelper: { [weak console] id in
                try? await console?.withNotificationFiles(for: id) { try await $0.readHostHelper() }
            },
            updatePlugin: { host in
                await HeelerPluginActionRunner(
                    host: host, connector: dialing.connector, knownHosts: dialing.knownHosts,
                    credentials: dialing.credentials
                ).update()
            },
            updateHelper: { host, repairing in
                let store = HostHelperStore.dialing(host, dependencies: dialing)
                await store.updateInstalled(repairing: repairing)
                helperDidChange()
                switch store.reading {
                case .read(let reading):
                    return HostUpdatesStore.HelperOutcome(readBack: reading, failure: store.failure)
                case .checking:
                    // It never reached the Host.
                    return HostUpdatesStore.HelperOutcome(failure: store.failure)
                case .unavailable(let message):
                    return HostUpdatesStore.HelperOutcome(failure: store.failure ?? message, isUncertain: true)
                }
            })
    }
}

extension HostHelperStore {
    /// A Helper's store for an action with no Server's page behind it: it
    /// dials `host` as that page would once its checks had settled the Host
    /// key, so a key that still needs trusting is declined.
    static func dialing(
        _ host: Host, dependencies: HostOnboardingDependencies, overlays: OverlayNetworkRuntime = .shared
    ) -> HostHelperStore {
        let connector = dependencies.connector
        let knownHosts = dependencies.knownHosts
        let credentials = dependencies.credentials
        return HostHelperStore(
            connect: {
                let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
                let settings = SSHTransportSettings(
                    host: host, credentials: try credentials.credentials(for: host),
                    hostKeyPolicy: policy, overlays: overlays)
                if host.serverKind == .tmux {
                    return try await connector.connectTmux(settings: settings)
                }
                return try await connector.connectCore(settings: settings)
            },
            tmuxPaths: { host.storedTmuxPaths })
    }
}
