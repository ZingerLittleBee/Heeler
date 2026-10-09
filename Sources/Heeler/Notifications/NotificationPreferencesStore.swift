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
}

/// Per-Host Agent Notification preferences (#75): the on/off registration
/// toggle and the separate Done flag, persisted in the Host's registration
/// file and filtered at the source by the plugin (the service extension
/// cannot silently drop a push).
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
        /// The Host's truth is unknown: unreachable, plugin missing, or push
        /// bootstrap incomplete. No toggle can act until a refresh succeeds.
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

    /// Aligns with the Host catalog; a removed Host drops its state.
    func setHosts(_ hosts: [Host]) {
        self.hosts = hosts
        let known = Set(hosts.map(\.id))
        states = states.filter { known.contains($0.key) }
    }

    /// Re-reads every Host's registration file so the toggles reflect what
    /// each Host actually holds.
    func refresh() async {
        await withTaskGroup { group in
            for host in hosts {
                group.addTask { await self.load(host) }
            }
        }
    }

    /// The per-Host on/off (registration add/remove). Enabling registers
    /// this device with both triggers on; disabling removes its entry and
    /// drops the local Notification Key.
    func setNotificationsEnabled(_ enabled: Bool, for host: Host) async {
        guard let settings = confirmedSettings(for: host.id),
            settings.isRegistered != enabled
        else { return }
        let relay = relayBaseURL()
        await write(for: host, from: settings, registers: enabled) { ceremony, token, transport in
            if enabled {
                let notify = NotificationTriggerPreferences()
                try await ceremony.register(
                    host: host, deviceToken: token, notify: notify, relayBaseURL: relay,
                    over: transport)
                return HostSettings(isRegistered: true, notify: notify)
            } else {
                try await ceremony.remove(host: host, deviceToken: token, over: transport)
                return HostSettings(
                    isRegistered: false, notify: NotificationTriggerPreferences())
            }
        }
    }

    /// The separate Done flag (User Story 9): rewrites this device's entry
    /// over SSH so the plugin stops (or resumes) sending Done pushes at the
    /// source. Ignored while unregistered — there is no entry to update.
    func setDoneEnabled(_ enabled: Bool, for host: Host) async {
        guard let settings = confirmedSettings(for: host.id),
            settings.isRegistered, settings.notify.done != enabled
        else { return }
        let notify = NotificationTriggerPreferences(
            blocked: settings.notify.blocked, done: enabled)
        let relay = relayBaseURL()
        await write(for: host, from: settings, registers: true) { ceremony, token, transport in
            // Re-registration is the flag update: it rewrites this Host's
            // entry reusing the stored Notification Key (#72 idempotence).
            try await ceremony.register(
                host: host, deviceToken: token, notify: notify, relayBaseURL: relay,
                over: transport)
            return HostSettings(isRegistered: true, notify: notify)
        }
    }

    private func load(_ host: Host) async {
        if case .updating = states[host.id] { return }
        guard let token = deviceToken() else {
            states[host.id] = .unavailable(
                message: "Waiting for push registration on this device.")
            return
        }
        states[host.id] = .loading
        do {
            var file = try await readFile(for: host.id)
            // Only an entry carrying this Host's Notification Key is its own;
            // another Host of the same remote user shares this file (#412).
            let owner = try ceremony.registrationOwner(for: host, deviceToken: token)
            if let owner, file.normalized(for: owner) != file {
                file = await migrate(host, token: token) ?? file
            }
            let preferences = owner.flatMap { file.preferences(for: $0) }
            states[host.id] = .idle(
                HostSettings(
                    isRegistered: preferences != nil,
                    notify: preferences ?? NotificationTriggerPreferences()))
        } catch {
            states[host.id] = .unavailable(message: Self.message(for: error))
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
        return try? await transports.withNotificationTransport(for: host.id) { transport in
            try await ceremony.migrate(host: host, deviceToken: token, over: transport)
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
            NotificationRegistrationCeremony, APNSDeviceToken, any Transport
        ) async throws -> HostSettings
    ) async {
        guard let token = deviceToken() else {
            states[host.id] = .unavailable(
                message: "Waiting for push registration on this device.")
            return
        }
        states[host.id] = .updating(settings)
        do {
            let ceremony = ceremony
            let confirmed = try await transports.withNotificationTransport(
                for: host.id
            ) { transport in
                try await operation(ceremony, token, transport)
            }
            states[host.id] = .idle(confirmed)
            if registers {
                onRegistered?(host.id)
                await reloadRegisteredHosts(except: host.id)
            }
        } catch {
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

    private func readFile(for hostID: Host.ID) async throws -> NotificationRegistrationFile {
        try NotificationRegistrationFile.decode(
            try await transports.withNotificationTransport(for: hostID) { transport in
                try await transport.readNotificationRegistration()
            })
    }

    /// The gate the in-app banner reads (#77): the Host's confirmed notify
    /// flags, or nil when this device is not registered or the Host's truth
    /// is unknown (unreachable, still loading, never refreshed) — in which
    /// case the banner fails closed, matching the plugin's semantics.
    func confirmedTriggers(for hostID: Host.ID) -> NotificationTriggerPreferences? {
        guard let settings = confirmedSettings(for: hostID), settings.isRegistered
        else { return nil }
        return settings.notify
    }

    private func confirmedSettings(for hostID: Host.ID) -> HostSettings? {
        switch states[hostID] {
        case .idle(let settings), .failed(_, let settings):
            settings
        case .loading, .unavailable, .updating, nil:
            nil
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case NotificationRegistrationError.pluginNotInstalled:
            "Install the Heeler plugin on this Host, then check again."
        case NotificationRegistrationError.pluginProbeFailed:
            "Could not check the Heeler plugin on this Host. "
                + "Check the connection and try again."
        case NotificationRegistrationError.readFailed:
            "Could not read notification settings from this Host. "
                + "Check the connection and try again."
        case NotificationRegistrationError.writeFailed:
            "Could not update notification settings on this Host. "
                + "Check the connection and try again."
        case NotificationRegistrationError.unsupportedFileVersion:
            "This Host was registered by a newer app version. Update the app."
        case NotificationRegistrationError.deviceNotRegistered:
            "Register this device for notifications on this Host first."
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case TransportError.herdrBinaryNotFound:
            TransportError.herdrBinaryNotFound.presentation.message
        case TransportError.herdrLauncherNotFound(let path):
            TransportError.herdrLauncherNotFound(path: path).presentation.message
        case is TransportError:
            "The connection to the Host failed."
        default:
            "Could not update notification settings. Try again."
        }
    }
}
