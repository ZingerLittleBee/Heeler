import Foundation
import Observation

/// Scoped borrow of a Host's live connection for Notification Registration
/// work (#75). The Console already keeps one SSH connection per Host;
/// preference reads and writes ride it instead of dialing a second one. An
/// unreachable Host throws `TransportError` — never a silent no-op.
protocol NotificationTransportProvider: Sendable {
    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value

    /// Borrows a Host's notification and Usage files, whose root follows its
    /// Server Kind: the plugin's directories on Herdr TUI, the Host Helper's on
    /// herdr-core (ADR 0033).
    func withNotificationFiles<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any HostNotificationFiles) async throws -> Value
    ) async throws -> Value
}

extension NotificationTransportProvider {
    /// A provider of Herdr TUI Hosts only has the plugin's files to offer.
    func withNotificationFiles<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any HostNotificationFiles) async throws -> Value
    ) async throws -> Value {
        try await withNotificationTransport(for: hostID) { transport in
            try await operation(transport)
        }
    }
}

/// Per-Host Agent Notification preferences (#75): the on/off registration
/// toggle and the separate Done flag, persisted in the Host's registration
/// file and filtered at the source by the plugin, or on a herdr-core Host by its
/// Host Helper (the service extension cannot silently drop a push).
///
/// The displayed value is always the last state the Host confirmed: a toggle
/// never flips optimistically, a failed write surfaces its error and snaps
/// back, and `refresh` re-reads the file so the screen shows the Host's
/// truth, not a local mirror.
@MainActor
@Observable
final class NotificationPreferencesStore {
    /// One Host's confirmed registration state, as its file last reported it.
    struct HostSettings: Equatable, Sendable {
        /// Whether this device has an entry in the Host's registration file.
        var isRegistered: Bool
        /// The entry's notify flags; meaningful only while registered.
        var notify: NotificationTriggerPreferences
    }

    enum HostState: Equatable, Sendable {
        /// The registration file read is in flight.
        case loading
        /// The Host's truth is unknown: unreachable, plugin or Host Helper
        /// missing, or push bootstrap incomplete. No toggle can act until a
        /// refresh succeeds.
        case unavailable(message: String)
        /// The Host answered; the toggles reflect `settings`.
        case idle(HostSettings)
        /// A preference write is in flight; `settings` stays the last
        /// confirmed truth until the Host acknowledges.
        case updating(HostSettings)
        /// A write failed; `settings` is still the Host's truth (the replace
        /// is atomic), and the message says why the toggle did not move.
        case failed(message: String, settings: HostSettings)
    }

    private(set) var hosts: [Host] = []
    private(set) var states: [Host.ID: HostState] = [:]
    /// What a core Host's Helper needs, from its last read.
    private var helperRequirements: [Host.ID: String] = [:]
    /// Whether a core Host's Helper can drive a Live Activity, from its last read.
    /// Nil on a read that failed, and on any other Host.
    private var helperDrivesLiveActivity: [Host.ID: Bool] = [:]
    /// How a core Host's Helper reads on its Host page, from its last read. Nil
    /// on a read that failed, and on any other Host.
    private var helperPresentations: [Host.ID: HostHelperPresentation] = [:]
    /// What a core Host last confirmed, held for its banner gate while it is read
    /// again. Reads repeat with the connection and a Helper's takes seconds; Herdr
    /// TUI's gate still fails closed for its read.
    private var settingsDuringReRead: [Host.ID: HostSettings] = [:]
    /// What each Host last settled on, shown while it is read again so Settings
    /// keeps its rows steady. Display only: no gate reads it.
    private var settledBeforeReRead: [Host.ID: HostState] = [:]
    /// A catalog edit/removal invalidates every result captured for that Host.
    private var operations: [Host.ID: UUID] = [:]
    /// Seen marks waiting for a core Host's registration to be known, or for the
    /// write before them. Each holds every mark, so a newer one replaces an older.
    private var pendingSeenMarks: [Host.ID: PendingSeenMarks] = [:]
    private var seenMarkWrites: [Host.ID: Task<Void, Never>] = [:]
    /// Every mark this device holds on a core Host, for a registration that has
    /// no file of them yet.
    @ObservationIgnored private var heldSeenMarks: @MainActor (Host.ID) -> PendingSeenMarks? = { _ in nil }

    private let transports: any NotificationTransportProvider
    private let deviceToken: @MainActor () -> APNSDeviceToken?
    /// The app-side custom Push Relay base URL, read at write time so a change
    /// in Settings lands on the next Host the user registers. `nil` — the
    /// empty/default setting — leaves each Host's `notify.json` untouched (#76).
    private let relayBaseURL: @MainActor () -> URL?
    private let ceremony: NotificationRegistrationCeremony
    /// Fires after a registration write the Host confirmed, so Live
    /// Activity writes that failed for want of an entry can retry.
    @ObservationIgnored var onRegistered: (@MainActor (Host.ID) -> Void)?

    init(
        transports: any NotificationTransportProvider,
        deviceToken: @escaping @MainActor () -> APNSDeviceToken?,
        relayBaseURL: @escaping @MainActor () -> URL? = { nil },
        ceremony: NotificationRegistrationCeremony = NotificationRegistrationCeremony()
    ) {
        self.transports = transports
        self.deviceToken = deviceToken
        self.relayBaseURL = relayBaseURL
        self.ceremony = ceremony
    }

    /// Only unchanged Hosts keep confirmed state and in-flight operations. A
    /// Host waiting for its Server Kind has no notifications to offer yet, nor
    /// has one of a kind without a plugin or a Host Helper.
    func setHosts(_ catalogHosts: [Host]) {
        let hosts = catalogHosts.filter(\.serverKind.hasHostIntegrations)
        let unchanged = Set(
            hosts.filter { incoming in
                self.hosts.contains { Self.isSameNotificationHost($0, incoming) }
            }.map(\.id))
        self.hosts = hosts
        states = states.filter { unchanged.contains($0.key) }
        helperRequirements = helperRequirements.filter { unchanged.contains($0.key) }
        helperDrivesLiveActivity = helperDrivesLiveActivity.filter { unchanged.contains($0.key) }
        helperPresentations = helperPresentations.filter { unchanged.contains($0.key) }
        settingsDuringReRead = settingsDuringReRead.filter { unchanged.contains($0.key) }
        settledBeforeReRead = settledBeforeReRead.filter { unchanged.contains($0.key) }
        operations = operations.filter { unchanged.contains($0.key) }
        pendingSeenMarks = pendingSeenMarks.filter { unchanged.contains($0.key) }
    }

    private func isCurrent(_ operation: UUID, for host: Host) -> Bool {
        operations[host.id] == operation && hosts.contains { Self.isSameNotificationHost($0, host) }
    }

    /// A tmux Host's stored paths move as a connection resolves them, without
    /// making it another Host.
    private static func isSameNotificationHost(_ lhs: Host, _ rhs: Host) -> Bool {
        var a = lhs
        var b = rhs
        a.tmuxPaths = nil
        b.tmuxPaths = nil
        return a == b
    }

    /// A note beside a core Host's toggles: what its Helper still needs while they
    /// work without it. With no toggles to show, the unavailable state says it.
    /// Like the toggles, it stays as last read while the Host is read again.
    func helperRequirement(for hostID: Host.ID) -> String? {
        switch shownState(for: hostID) {
        case .idle, .updating, .failed: helperRequirements[hostID]
        case .loading, .unavailable, nil: nil
        }
    }

    /// A core Host's Helper as its Host page shows it, kept while the Host is
    /// read again. Nil on any other Host, and after a read that failed.
    func helperPresentation(for hostID: Host.ID) -> HostHelperPresentation? {
        helperPresentations[hostID]
    }

    /// Re-reads every Host's registration file so the toggles reflect what
    /// each Host actually holds.
    func refresh() async {
        await refresh(hosts.map(\.id))
    }

    /// Re-reads only these Hosts', as their connections change.
    func refresh(_ hostIDs: some Collection<Host.ID>) async {
        let ids = Set(hostIDs)
        await withTaskGroup { group in
            for host in hosts where ids.contains(host.id) {
                group.addTask { await self.load(host) }
            }
        }
    }

    /// What Settings shows for a Host: its state, or while it is read again what
    /// it last settled on. Nil until a first read settles.
    func shownState(for hostID: Host.ID) -> HostState? {
        let state = states[hostID]
        guard state == .loading else { return state }
        return settledBeforeReRead[hostID]
    }

    /// Whether a Host is being read, so its switches cannot act yet.
    func isReading(_ hostID: Host.ID) -> Bool {
        states[hostID] == .loading
    }

    /// The per-Host on/off (registration add/remove). Enabling registers
    /// this device with both triggers on; disabling removes its entry and
    /// drops the local Notification Key.
    func setNotificationsEnabled(_ enabled: Bool, for host: Host) async {
        guard let settings = confirmedSettings(for: host.id),
            settings.isRegistered != enabled
        else { return }
        let relay = relayBaseURL()
        await write(for: host, from: settings, registers: enabled) { ceremony, token, files in
            if enabled {
                // The Helper may have gone since this screen last read it.
                if let standing = try await files.readHostHelper()?.notificationStanding, !standing.canRegister {
                    throw HostHelperRequirementError(message: standing.requirement ?? "")
                }
                let notify = NotificationTriggerPreferences()
                try await ceremony.register(
                    host: host, deviceToken: token, notify: notify, relayBaseURL: relay,
                    over: files)
                return HostSettings(isRegistered: true, notify: notify)
            } else {
                try await ceremony.remove(host: host, deviceToken: token, over: files)
                return HostSettings(
                    isRegistered: false, notify: NotificationTriggerPreferences())
            }
        }
    }

    /// The separate Done flag (User Story 9): rewrites this device's entry
    /// over SSH so the plugin or Host Helper stops (or resumes) sending Done
    /// pushes at the source. Ignored while unregistered — there is no entry to
    /// update.
    func setDoneEnabled(_ enabled: Bool, for host: Host) async {
        guard let settings = confirmedSettings(for: host.id),
            settings.isRegistered, settings.notify.done != enabled
        else { return }
        let notify = NotificationTriggerPreferences(
            blocked: settings.notify.blocked, done: enabled)
        let relay = relayBaseURL()
        await write(for: host, from: settings, registers: true) { ceremony, token, files in
            // Re-registration is the flag update: it rewrites this Host's
            // entry reusing the stored Notification Key (#72 idempotence).
            try await ceremony.register(
                host: host, deviceToken: token, notify: notify, relayBaseURL: relay,
                over: files)
            return HostSettings(isRegistered: true, notify: notify)
        }
    }

    // MARK: Host removal (#414)

    /// Whether this device holds a Notification Key for the Host, i.e.
    /// removing the Host deletes one. A Keychain that cannot be read counts
    /// as holding one: the removal will try to delete it.
    func hasNotificationKey(for hostID: Host.ID) -> Bool {
        do {
            return try ceremony.keys.record(forHost: hostID) != nil
        } catch {
            return true
        }
    }

    /// Best effort, before a Host is removed: drops this device's own entries
    /// from the Host's registration file so its plugin or Host Helper stops
    /// pushing here, with its seen marks on a Host Helper, keeping the
    /// Notification Key (`forgetNotificationKey` deletes it).
    /// Entries are matched by the key alone, so no device token is needed.
    /// Only a Host that can be reached (`isConnected`) with a stored key is
    /// asked; anything else touches no network. The whole revoke, gate wait included, is
    /// abandoned after `timeout`: a dead link waits out its own request
    /// deadline and redial, and removal must not. Failures are swallowed;
    /// the removal goes ahead either way. A revoke the Host confirmed reads
    /// unregistered at once, so a removal that then fails keeps the Host
    /// with notifications off.
    func revokeRegistration(
        for host: Host, isConnected: Bool, timeout: Duration = .seconds(6)
    ) async {
        guard isConnected, (try? ceremony.keys.record(forHost: host.id)) != nil else { return }
        let operation = UUID()
        operations[host.id] = operation
        let ceremony = ceremony
        let transports = transports
        do {
            try await AsyncDeadline.run(for: timeout) {
                try await transports.withNotificationFiles(for: host.id) { files in
                    try await ceremony.revoke(host: host, over: files)
                }
            }
        } catch {
            return
        }
        guard isCurrent(operation, for: host) else { return }
        markUnregistered(host.id)
    }

    /// Deletes the Host's Notification Key record (Keychain and app-group
    /// mirror) as part of its removal. Without a key no entry on the Host is
    /// this device's own, so a confirmed state now reads unregistered: a
    /// removal that fails after this keeps the Host with notifications off.
    func forgetNotificationKey(for hostID: Host.ID) throws {
        try ceremony.keys.removeRecord(forHost: hostID)
        markUnregistered(hostID)
    }

    /// Settles a confirmed state on unregistered; one still loading or
    /// updating is left for its own read or write to settle.
    private func markUnregistered(_ hostID: Host.ID) {
        settingsDuringReRead[hostID] = nil
        settledBeforeReRead[hostID] = nil
        guard confirmedSettings(for: hostID) != nil else { return }
        states[hostID] = .idle(
            HostSettings(isRegistered: false, notify: NotificationTriggerPreferences()))
    }

    private func load(_ host: Host) async {
        guard hosts.contains(host) else { return }
        if case .updating = states[host.id] { return }
        guard let token = deviceToken() else {
            states[host.id] = .unavailable(
                message: String(localized: "Waiting for push registration on this device."))
            return
        }
        let operation = UUID()
        operations[host.id] = operation
        if states[host.id] != .loading {
            settingsDuringReRead[host.id] =
                (host.serverKind == .herdrCore || host.serverKind == .tmux)
                ? confirmedSettings(for: host.id) : nil
            settledBeforeReRead[host.id] = states[host.id]
        }
        states[host.id] = .loading
        defer { writeSeenMarks(for: host.id) }
        do {
            let read = try await readRegistration(for: host.id)
            guard isCurrent(operation, for: host) else { return }
            var file = try NotificationRegistrationFile.decode(read.registration)
            helperRequirements[host.id] = read.standing?.requirement
            helperDrivesLiveActivity[host.id] = read.standing?.drivesLiveActivity
            helperPresentations[host.id] = read.helper
            // Only an entry carrying this Host's Notification Key is its own;
            // another Host of the same remote user shares this file (#412).
            let owner = try ceremony.registrationOwner(for: host, deviceToken: token)
            if let owner, file.normalized(for: owner) != file {
                file = await migrate(host, token: token) ?? file
                guard isCurrent(operation, for: host) else { return }
            }
            let preferences = owner.flatMap { file.preferences(for: $0) }
            // A Helper that can take no registration still lets this device leave.
            if let standing = read.standing, !standing.canRegister, preferences == nil {
                states[host.id] = .unavailable(message: standing.requirement ?? "")
                return
            }
            states[host.id] = .idle(
                HostSettings(
                    isRegistered: preferences != nil,
                    notify: preferences ?? NotificationTriggerPreferences()))
        } catch {
            guard isCurrent(operation, for: host) else { return }
            helperDrivesLiveActivity[host.id] = nil
            helperPresentations[host.id] = nil
            states[host.id] = .unavailable(message: Self.message(for: error))
        }
    }

    /// The Host's registration file, and on a core Host what its Helper stands
    /// as, over one connection. A Host with nothing of the Helper's has no
    /// directory to read a file from.
    private func readRegistration(for hostID: Host.ID) async throws -> RegistrationRead {
        try await transports.withNotificationFiles(for: hostID) { files in
            guard let reading = try await files.readHostHelper() else {
                return RegistrationRead(
                    registration: try await files.readNotificationRegistration(), standing: nil, helper: nil)
            }
            return RegistrationRead(
                registration: reading.offersRemoval ? try await files.readNotificationRegistration() : nil,
                standing: reading.notificationStanding, helper: reading.presentation)
        }
    }

    /// Moves this Host's entry to its current herdr session (an entry an
    /// older app wrote, or one from before a session edit). Best-effort: a
    /// failed write leaves the state derived from the plain read, and the
    /// next refresh retries.
    private func migrate(
        _ host: Host, token: APNSDeviceToken
    ) async -> NotificationRegistrationFile? {
        let ceremony = ceremony
        return try? await transports.withNotificationFiles(for: host.id) { files in
            try await ceremony.migrate(host: host, deviceToken: token, over: files)
        }
    }

    /// Shared write choreography: hold the confirmed settings while the
    /// ceremony runs, publish the new truth on success, snap back with the
    /// error on failure (fail loudly — never a silently divergent toggle).
    private func write(
        for host: Host,
        from settings: HostSettings,
        registers: Bool,
        _ operation: @escaping @Sendable (
            NotificationRegistrationCeremony, APNSDeviceToken, any HostNotificationFiles
        ) async throws -> HostSettings
    ) async {
        guard hosts.contains(host) else { return }
        guard let token = deviceToken() else {
            states[host.id] = .unavailable(
                message: String(localized: "Waiting for push registration on this device."))
            return
        }
        let operationID = UUID()
        operations[host.id] = operationID
        states[host.id] = .updating(settings)
        defer { writeSeenMarks(for: host.id) }
        do {
            let ceremony = ceremony
            let confirmed = try await transports.withNotificationFiles(
                for: host.id
            ) { files in
                try await operation(ceremony, token, files)
            }
            guard isCurrent(operationID, for: host) else { return }
            states[host.id] = .idle(confirmed)
            // A new key has no file yet, and the projection only reports changes.
            if registers, !settings.isRegistered, pendingSeenMarks[host.id] == nil {
                pendingSeenMarks[host.id] = heldSeenMarks(host.id)
            }
            if registers {
                onRegistered?(host.id)
                await reloadRegisteredHosts(except: host.id)
            }
        } catch {
            guard isCurrent(operationID, for: host) else { return }
            states[host.id] = .failed(message: Self.message(for: error), settings: settings)
        }
    }

    /// A registration takes over its herdr session's entry, so another Host
    /// of the same remote user on that session may have just lost its own
    /// (#412). Only Hosts that read registered can be affected.
    private func reloadRegisteredHosts(except hostID: Host.ID) async {
        let affected = hosts.filter { host in
            host.id != hostID && confirmedSettings(for: host.id)?.isRegistered == true
        }
        await withTaskGroup { group in
            for host in affected {
                group.addTask { await self.load(host) }
            }
        }
    }

    /// The gate the in-app banner reads (#77): the Host's confirmed notify
    /// flags, or nil when this device is not registered or the Host's truth
    /// is unknown (unreachable, still loading, never refreshed) — in which
    /// case the banner fails closed, matching the plugin's semantics. A core
    /// Host being read again keeps what it last confirmed until the read settles.
    func confirmedTriggers(for hostID: Host.ID) -> NotificationTriggerPreferences? {
        let held = states[hostID] == .loading ? settingsDuringReRead[hostID] : nil
        guard let settings = confirmedSettings(for: hostID) ?? held, settings.isRegistered else { return nil }
        return settings.notify
    }

    /// Whether a core Host may show a Live Activity: this device's confirmed
    /// registration, with a Helper that can drive the activity once the app
    /// suspends. A read that failed says nothing about either, so it is unknown.
    func liveActivityGate(forCoreHost hostID: Host.ID) -> LiveActivityGate {
        switch states[hostID] {
        case .idle(let settings), .failed(_, let settings):
            settings.isRegistered && helperDrivesLiveActivity[hostID] == true ? .open : .closed
        case .unavailable:
            helperDrivesLiveActivity[hostID] == false ? .closed : .unknown
        case .loading, .updating, nil:
            .unknown
        }
    }

    /// Each core or tmux Host's gate, for whoever follows them changing.
    var coreLiveActivityGates: [Host.ID: LiveActivityGate] {
        var gates: [Host.ID: LiveActivityGate] = [:]
        for host in hosts where host.serverKind == .herdrCore || host.serverKind == .tmux {
            gates[host.id] = liveActivityGate(forCoreHost: host.id)
        }
        return gates
    }

    /// Whether Settings offers a Host's Live Activity switch. Herdr TUI's has its
    /// own note about what the plugin lacks.
    func offersLiveActivity(for host: Host) -> Bool {
        host.serverKind == .herdrTUI || helperDrivesLiveActivity[host.id] == true
    }

    private func confirmedSettings(for hostID: Host.ID) -> HostSettings? {
        guard hosts.contains(where: { $0.id == hostID }) else { return nil }
        return switch states[hostID] {
        case .idle(let settings), .failed(_, let settings):
            settings
        case .loading, .unavailable, .updating, nil:
            nil
        }
    }

    // MARK: Seen marks (ADR 0033)

    /// Hears what this device sees on `console`'s core Hosts.
    func followSeenMarks(of console: ConsoleStore) {
        console.onCoreSeenMarksChanged = { [weak self] hostID, core, marks in
            self?.noteSeenMarks(core: core, marks: marks, for: hostID)
        }
        heldSeenMarks = { [weak console] hostID in
            guard let held = console?.coreSeenMarks(on: hostID), !held.marks.isEmpty else { return nil }
            return PendingSeenMarks(core: held.core, marks: held.marks)
        }
    }

    /// What this device has seen on a core Host changed, in full. It goes into
    /// the Helper's directory while the Helper holds this device's registration,
    /// and never otherwise. A write that fails leaves those Agents counted as Done
    /// there, and the next change's write carries these marks too.
    func noteSeenMarks(
        core: String, marks: [String: HerdrCoreTurnState.Mark], for hostID: Host.ID
    ) {
        guard hosts.contains(where: {
            $0.id == hostID && ($0.serverKind == .herdrCore || $0.serverKind == .tmux)
        }) else { return }
        pendingSeenMarks[hostID] = PendingSeenMarks(core: core, marks: marks)
        writeSeenMarks(for: hostID)
    }

    private func writeSeenMarks(for hostID: Host.ID) {
        guard seenMarkWrites[hostID] == nil, pendingSeenMarks[hostID] != nil else { return }
        seenMarkWrites[hostID] = Task { [weak self] in
            await self?.drainSeenMarks(for: hostID)
            self?.seenMarkWrites[hostID] = nil
        }
    }

    private func drainSeenMarks(for hostID: Host.ID) async {
        let ceremony = ceremony
        while let pending = pendingSeenMarks[hostID] {
            let keyID: String
            switch seenMarkDevice(for: hostID) {
            case .unknownYet:
                return  // What settles the registration comes back here.
            case .unregistered:
                pendingSeenMarks[hostID] = nil
                return
            case .registered(let id):
                keyID = id
            }
            pendingSeenMarks[hostID] = nil
            let file = HerdrCoreSeenMarkFile(device: keyID, core: pending.core, marks: pending.marks)
            guard let contents = try? file.encoded() else { continue }
            let wrote = try? await transports.withNotificationFiles(for: hostID) { [weak self] files in
                try await ceremony.writeSeenMarks(contents, keyID: keyID, over: files) {
                    if case .registered(let current)? = self?.seenMarkDevice(for: hostID) {
                        return current == keyID
                    }
                    return false
                }
            }
            if wrote == false, pendingSeenMarks[hostID] == nil {
                // The registration moved while this waited its turn.
                pendingSeenMarks[hostID] = pending
            }
        }
    }

    private func seenMarkDevice(for hostID: Host.ID) -> SeenMarkDevice {
        switch states[hostID] {
        case nil, .loading, .updating:
            return .unknownYet
        case .unavailable:
            return .unregistered
        case .idle(let settings), .failed(_, let settings):
            guard settings.isRegistered, let record = try? ceremony.keys.record(forHost: hostID) else {
                return .unregistered
            }
            return .registered(keyID: record.keyID)
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let error as HostHelperRequirementError:
            error.message
        case let error as HostHelperError:
            error.message
        case NotificationRegistrationError.pluginNotInstalled:
            String(localized: "The Heeler plugin is missing or turned off on this Host. See this Host's page in Hosts, then check again.")
        case NotificationRegistrationError.pluginProbeFailed:
            String(localized: "Could not check the Heeler plugin on this Host. Check the connection and try again.")
        case NotificationRegistrationError.readFailed:
            String(localized: "Could not read notification settings from this Host. Check the connection and try again.")
        case NotificationRegistrationError.writeFailed:
            String(localized: "Could not update notification settings on this Host. Check the connection and try again.")
        case NotificationRegistrationError.unsupportedFileVersion:
            String(localized: "This Host was registered by a newer app version. Update the app.")
        case NotificationRegistrationError.deviceNotRegistered:
            String(localized: "Register this device for notifications on this Host first.")
        case TransportError.sshUnreachable:
            String(localized: "The Host is not connected.")
        case TransportError.timedOut:
            String(localized: "The Host did not answer in time.")
        case TransportError.herdrBinaryNotFound:
            TransportError.herdrBinaryNotFound.presentation.message
        case TransportError.herdrLauncherNotFound(let path):
            TransportError.herdrLauncherNotFound(path: path).presentation.message
        case is TransportError:
            String(localized: "The connection to the Host failed.")
        default:
            String(localized: "Could not update notification settings. Try again.")
        }
    }
}

/// One read of a Host's notification state.
private struct RegistrationRead: Sendable {
    let registration: Data?
    /// Nil on a Host whose notifications come from the plugin.
    let standing: HostHelperNotificationStanding?
    let helper: HostHelperPresentation?
}

private struct PendingSeenMarks: Sendable {
    let core: String
    let marks: [String: HerdrCoreTurnState.Mark]
}

private enum SeenMarkDevice: Sendable {
    /// The Host's truth is still being read or written.
    case unknownYet
    case unregistered
    case registered(keyID: String)
}

/// A core Host's Helper stands in the way of registering, in words for the user.
private struct HostHelperRequirementError: Error {
    let message: String
}
