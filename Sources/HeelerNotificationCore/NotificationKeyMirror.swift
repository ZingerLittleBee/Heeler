import Foundation

/// A mirror of every Notification Key record in the shared app-group
/// container, maintained by the app whenever the Keychain records change.
///
/// It exists because WidgetKit's lock-screen rendering context cannot reach
/// the Keychain: `SecItemCopyMatching` answers `errSecNotAvailable` (-25291)
/// inside the widget extension while the device is locked (observed on a
/// physical device; the simulator does not model the restriction, and the
/// Notification Service Extension reads the same items fine). Live Activity
/// decryption falls back to this file when the Keychain read fails.
///
/// Protection is equivalent to the Keychain class the records use
/// (`AfterFirstUnlockThisDeviceOnly`): the file is written with
/// complete-until-first-unlock data protection and excluded from backup, so
/// the keys stay device-local and unreadable before first unlock. The
/// Keychain remains the source of truth; the mirror is a best-effort cache
/// and every failure degrades to "no mirrored records", never an error.
struct NotificationKeyMirror: Sendable {
    /// Injectable for tests; the production value is the shared app-group
    /// container.
    var containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: NotificationKeyStore.sharedAccessGroup)

    private var fileURL: URL? {
        containerURL?.appendingPathComponent("notification-keys.json")
    }

    /// Rewrites the mirror to exactly `records`. Best-effort: a failure
    /// leaves the previous mirror in place.
    func write(_ records: [NotificationKeyRecord]) {
        guard var url = fileURL else { return }
        let stored = StoredFile(
            v: 1,
            records: records.map {
                StoredFile.Record(
                    host: $0.hostID.uuidString, name: $0.hostName,
                    key: $0.key.base64URLEncodedString())
            })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        do {
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            // Keychain stays authoritative; a stale or absent mirror only
            // costs the locked-render fallback.
        }
    }

    /// Every mirrored record that still parses; empty on any failure.
    func read() -> [NotificationKeyRecord] {
        guard let url = fileURL,
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(StoredFile.self, from: data),
            stored.v == 1
        else { return [] }
        return stored.records.compactMap { record in
            guard let hostID = UUID(uuidString: record.host),
                let key = Data(base64URLEncoded: record.key), key.count == 32,
                !record.name.isEmpty
            else { return nil }
            return NotificationKeyRecord(hostID: hostID, hostName: record.name, key: key)
        }
    }

    private struct StoredFile: Codable {
        let v: Int
        let records: [Record]

        struct Record: Codable {
            let host: String
            let name: String
            let key: String
        }
    }
}
