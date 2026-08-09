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
struct NotificationRegistrationCeremony: Sendable {
    let keys: NotificationKeyStore

    init(keys: NotificationKeyStore = NotificationKeyStore()) {
        self.keys = keys
    }

    /// Registers this device for Agent Notifications from one Host. The
    /// Notification Key is saved locally before the remote write: a write
    /// that fails after that leaves a key the retry reuses, whereas the
    /// reverse order could put a key on the Host that this device can no
    /// longer decrypt with. Re-registration with the same token is
    /// idempotent — the file keeps one entry per device token.
    @discardableResult
    func register(
        hostID: UUID,
        hostName: String,
        deviceToken: APNSDeviceToken,
        notify: NotificationTriggerPreferences = NotificationTriggerPreferences(),
        relayBaseURL: URL? = nil,
        over transport: any Transport
    ) async throws -> NotificationKeyRecord {
        let record = try hostRecord(hostID: hostID, hostName: hostName)
        try keys.save(record)
        let file = try NotificationRegistrationFile.decode(
            try await transport.readNotificationRegistration())
        let entry = NotificationDeviceEntry(
            token: deviceToken, key: record.key, notify: notify)
        try await transport.replaceNotificationRegistration(
            try file.upserting(entry).encoded())
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

    /// Revokes this device on one Host: its entry leaves the registration
    /// file, then the local Notification Key record is dropped — in that
    /// order, so a failed remote removal keeps the key that still-armed
    /// pushes need. Removing a device that was never registered is a no-op.
    func remove(
        hostID: UUID,
        deviceToken: APNSDeviceToken,
        over transport: any Transport
    ) async throws {
        if let data = try await transport.readNotificationRegistration() {
            let file = try NotificationRegistrationFile.decode(data)
            if file.containsDevice(token: deviceToken.hex) {
                try await transport.replaceNotificationRegistration(
                    try file.removing(token: deviceToken.hex).encoded())
            }
        }
        try keys.removeRecord(forHost: hostID)
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
