import Foundation

/// The per-Host Notification Registration ceremony (#72, ADR 0008): mint or
/// reuse the Host's Notification Key, then write this device's entry into
/// the registration file the Host's notify hook reads. The Transport owns
/// where that file lives and how it is replaced atomically; this type owns
/// the read-merge-write and the custody split (key in the device Keychain and
/// Host registration file, token only in the Host registration file).
///
/// Every failure is surfaced: a thrown `NotificationRegistrationError` or
/// `TransportError` means notifications are not armed, never silently broken.
///
/// Several Hosts can share one registration file (Hosts on several herdr
/// sessions of one remote user), so every read-modify-write of it runs under
/// `gate` when one is given: the app shares one gate between the preference
/// toggles and the Live Activity writes so neither loses the other's entry.
/// The gate covers only the `notifications.json` read and replace, taken
/// inside the borrowed transport's operation (it is not reentrant: callers
/// never hold it around a ceremony call).
struct NotificationRegistrationCeremony: Sendable {
    let keys: NotificationKeyStore
    private let gate: GitExecGate?
    /// The herdr session (see `Host.notificationSession`) of a Host the
    /// Live Activity writes know only by id; nil once the Host left the
    /// catalog. Writes that receive the Host itself ignore it.
    private let hostSession: @MainActor @Sendable (Host.ID) -> String?

    init(
        keys: NotificationKeyStore = NotificationKeyStore(),
        gate: GitExecGate? = nil,
        hostSession: @escaping @MainActor @Sendable (Host.ID) -> String? = { _ in nil }
    ) {
        self.keys = keys
        self.gate = gate
        self.hostSession = hostSession
    }

    /// Who this device's entry belongs to on `host`, or nil when no
    /// Notification Key is stored for it — then no entry on the Host can be
    /// its own, and the Host reads as unregistered.
    func registrationOwner(
        for host: Host, deviceToken: APNSDeviceToken
    ) throws -> NotificationRegistrationOwner? {
        guard let key = try keys.record(forHost: host.id)?.key else { return nil }
        return NotificationRegistrationOwner(
            deviceToken: deviceToken.hex, key: key, session: host.notificationSession)
    }

    /// Registers this device for Agent Notifications from one Host. The
    /// Notification Key is saved locally before the remote write: a write
    /// that fails after that leaves a key the retry reuses, whereas the
    /// reverse order could put a key on the Host that this device can no
    /// longer decrypt with. Re-registration is idempotent — the Host keeps
    /// one entry, scoped to the herdr session it targets.
    @discardableResult
    func register(
        host: Host,
        deviceToken: APNSDeviceToken,
        notify: NotificationTriggerPreferences = NotificationTriggerPreferences(),
        relayBaseURL: URL? = nil,
        over transport: any Transport
    ) async throws -> NotificationKeyRecord {
        let record = try hostRecord(hostID: host.id, hostName: host.displayName)
        try keys.save(record)
        let entry = NotificationDeviceEntry(
            token: deviceToken, key: record.key, session: host.notificationSession,
            notify: notify)
        try await exclusively {
            let file = try NotificationRegistrationFile.decode(
                try await transport.readNotificationRegistration())
            try await transport.replaceNotificationRegistration(
                try file.registering(entry).encoded())
        }
        if let resolvedRelayURL = NotificationRelayEndpoint.resolve(
            customBaseURL: relayBaseURL)
        {
            try await applyRelayURL(resolvedRelayURL, over: transport)
        }
        return record
    }

    /// Writes the resolved Push Relay base URL into the Host's `notify.json` so
    /// this Host's notify hook POSTs there (#76). Read-merge-write preserves
    /// the plugin's own knobs (`debounce_ms`, `retry_delay_ms`, and future
    /// fields). The production endpoint is written for the empty/default app
    /// setting; self-builders can still supply an explicit custom URL.
    private func applyRelayURL(_ relayBaseURL: URL, over transport: any Transport) async throws {
        let config = try NotificationConfigFile.decode(
            try await transport.readNotificationConfig())
        let updated = config.settingRelayURL(relayBaseURL.absoluteString)
        guard updated != config else { return }
        try await transport.replaceNotificationConfig(try updated.encoded())
    }

    /// Revokes this device on one Host: the Host's entries (this device
    /// token with the Host's Notification Key) leave the registration file,
    /// then the local Notification Key record is dropped — in that order, so
    /// a failed remote removal keeps the key that still-armed pushes need.
    /// Other Hosts' entries of this device stay. Removing a device that was
    /// never registered is a no-op.
    func remove(
        host: Host,
        deviceToken: APNSDeviceToken,
        over transport: any Transport
    ) async throws {
        let owner = try registrationOwner(for: host, deviceToken: deviceToken)
        try await exclusively {
            guard let data = try await transport.readNotificationRegistration(), let owner
            else { return }
            let file = try NotificationRegistrationFile.decode(data)
            let updated = file.removing(owner)
            if updated != file {
                try await transport.replaceNotificationRegistration(try updated.encoded())
            }
        }
        try keys.removeRecord(forHost: host.id)
    }

    /// Writes the normalized registration file (see
    /// `NotificationRegistrationFile.normalized(for:)`) when the Host's own
    /// entry predates its current session, and returns the file the Host
    /// holds afterwards. Re-reads under the gate, so a write that landed
    /// since the caller's plain read is kept; idempotent.
    func migrate(
        host: Host,
        deviceToken: APNSDeviceToken,
        over transport: any Transport
    ) async throws -> NotificationRegistrationFile {
        let owner = try registrationOwner(for: host, deviceToken: deviceToken)
        return try await exclusively {
            let file = try NotificationRegistrationFile.decode(
                try await transport.readNotificationRegistration())
            guard let owner else { return file }
            let normalized = file.normalized(for: owner)
            if normalized != file {
                try await transport.replaceNotificationRegistration(try normalized.encoded())
            }
            return normalized
        }
    }

    /// Writes this device's Live Activity push token into the Host's own
    /// registration entry, first dropping that token from every other entry.
    /// The Host must already be registered — there is no entry to hang the
    /// token on otherwise, and inventing one would omit the Notification
    /// Key the plugin still needs for alerts.
    func setLiveActivityToken(
        tokenHex: String,
        startedAt: Date,
        hostID: Host.ID,
        deviceToken: APNSDeviceToken,
        pinnedPaneIDs: [String] = [],
        rowLayout: AgentRowLayout? = nil,
        hostName: String? = nil,
        over transport: any Transport,
        diagnose: (@Sendable (String) async -> Void)? = nil
    ) async throws {
        let owner = try await liveActivityOwner(hostID: hostID, deviceToken: deviceToken)
        try await rewrite(
            for: owner, over: transport, diagnose: diagnose,
            prepare: { $0.strippingLiveActivity(token: tokenHex, keepingOwnEntryOf: owner) }
        ) { file in
            guard let owner else { throw NotificationRegistrationError.deviceNotRegistered }
            return try file.settingLiveActivity(
                token: tokenHex, startedAt: startedAt, for: owner,
                pinnedPaneIDs: pinnedPaneIDs, rowLayout: rowLayout, hostName: hostName)
        }
    }

    /// Updates `pinned_pane_ids` (and the row layout, when given) on the
    /// Host's own `live_activity` object. No-op while that field is absent
    /// or the Host has no entry: the next token write carries the current
    /// preferences anyway.
    func setLiveActivityPinnedPaneIDs(
        _ pinnedPaneIDs: [String],
        rowLayout: AgentRowLayout? = nil,
        hostName: String? = nil,
        hostID: Host.ID,
        deviceToken: APNSDeviceToken,
        over transport: any Transport
    ) async throws {
        guard let owner = try await liveActivityOwner(hostID: hostID, deviceToken: deviceToken)
        else { return }
        try await rewrite(for: owner, over: transport) { file in
            var updated = try file.settingLiveActivityPinnedPaneIDs(pinnedPaneIDs, for: owner)
            if let rowLayout {
                updated = try updated.settingLiveActivityRowLayout(
                    rowLayout, hostName: hostName, for: owner)
            }
            return updated
        }
    }

    /// Drops `live_activity` from the Host's own entry, leaving the rest of
    /// the object (alert token, key, notify flags, unknown fields) intact.
    /// `liveActivityToken` is the token last written for this Host, when
    /// known: it limits the own-entry clear to that token, and without an
    /// own entry it finds the stale copy. An unregistered Host is a no-op.
    func clearLiveActivityToken(
        _ liveActivityToken: String?,
        hostID: Host.ID,
        deviceToken: APNSDeviceToken,
        over transport: any Transport
    ) async throws {
        let owner = try await liveActivityOwner(hostID: hostID, deviceToken: deviceToken)
        try await rewrite(for: owner, over: transport) { file in
            file.clearingLiveActivity(token: liveActivityToken, for: owner)
        }
    }

    /// The owner the Live Activity writes act for, resolved by Host id.
    private func liveActivityOwner(
        hostID: Host.ID, deviceToken: APNSDeviceToken
    ) async throws -> NotificationRegistrationOwner? {
        guard let key = try keys.record(forHost: hostID)?.key else { return nil }
        return NotificationRegistrationOwner(
            deviceToken: deviceToken.hex, key: key, session: await hostSession(hostID))
    }

    /// One read-modify-write of the registration file: normalizes the Host's
    /// own entry toward its session, applies `prepare` then `change`, and
    /// replaces the file only when the result differs from what was read. A
    /// `change` that throws still persists the normalized, prepared file
    /// when that differs, then rethrows.
    private func rewrite(
        for owner: NotificationRegistrationOwner?,
        over transport: any Transport,
        diagnose: (@Sendable (String) async -> Void)? = nil,
        prepare: @escaping @Sendable (NotificationRegistrationFile) -> NotificationRegistrationFile = {
            $0
        },
        change: @escaping @Sendable (NotificationRegistrationFile) throws
            -> NotificationRegistrationFile
    ) async throws {
        try await exclusively {
            try await rewriteUnderGate(
                for: owner, over: transport, diagnose: diagnose, prepare: prepare, change: change)
        }
    }

    private func rewriteUnderGate(
        for owner: NotificationRegistrationOwner?,
        over transport: any Transport,
        diagnose: (@Sendable (String) async -> Void)?,
        prepare: (NotificationRegistrationFile) -> NotificationRegistrationFile,
        change: (NotificationRegistrationFile) throws -> NotificationRegistrationFile
    ) async throws {
        try Task.checkCancellation()
        await diagnose?("registration read started")
        let registration = try await transport.readNotificationRegistration()
        await diagnose?("registration read completed")
        try Task.checkCancellation()
        let file = try NotificationRegistrationFile.decode(registration)
        await diagnose?("registration decoded")
        let base = prepare(owner.map { file.normalized(for: $0) } ?? file)
        let updated: NotificationRegistrationFile
        do {
            updated = try change(base)
        } catch {
            if base != file {
                try await transport.replaceNotificationRegistration(try base.encoded())
            }
            throw error
        }
        guard updated != file else { return }
        let contents = try updated.encoded()
        await diagnose?("registration encoded")
        try Task.checkCancellation()
        try await transport.replaceNotificationRegistration(contents)
        await diagnose?("registration replaced")
    }

    /// Runs one registration-file read-modify-write under the shared gate,
    /// or directly when this ceremony has none.
    private func exclusively<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let gate else { return try await operation() }
        return try await gate.run(operation)
    }

    /// The Host's key record: the existing key when one is stored (the
    /// service extension must keep decrypting with the key the Host already
    /// holds), refreshed with the current display name; a fresh key
    /// otherwise.
    private func hostRecord(hostID: UUID, hostName: String) throws -> NotificationKeyRecord {
        let key = try keys.record(forHost: hostID)?.key ?? NotificationKeyStore.generateKey()
        return NotificationKeyRecord(hostID: hostID, hostName: hostName, key: key)
    }
}

extension Host {
    /// The herdr session value a registration entry carries for this Host:
    /// "" for the default session, otherwise the session name. An endpoint
    /// Host carries the session its socket names, as its hooks derive it
    /// (ADR 0021); any other fixed socket path (test fixtures only) counts as
    /// the default session.
    var notificationSession: String {
        if let herdrEndpoint {
            return herdrEndpoint.session
        }
        return switch socketLocation {
        case .defaultSession, .absolutePath: ""
        case .namedSession(let name): name
        }
    }
}
