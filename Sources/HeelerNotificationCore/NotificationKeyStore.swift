import CryptoKit
import Foundation
import Security

/// One Host's Notification Key plus what the service extension needs to name
/// that Host in a rewritten alert. The key id is derived, never stored
/// (`kid = SHA-256(key)[0..8]` base64url per the envelope contract), so a
/// record is selectable by the kid of an incoming envelope.
struct NotificationKeyRecord: Sendable, Equatable {
    let hostID: UUID
    /// The Host's display name at registration time, for alert copy.
    let hostName: String
    /// Raw 32-byte Notification Key.
    let key: Data

    var keyID: String {
        NotificationEnvelope.keyID(for: key)
    }
}

enum NotificationKeyStoreError: Error, Equatable {
    /// The record violates the v1 contract: the key is not 32 bytes or the
    /// Host name is blank.
    case invalidRecord
}

/// Where Notification Keys live: one record per registered Host, keyed by
/// host id, in the Keychain access group shared with the Notification
/// Service Extension — the extension must select a key by an envelope's kid
/// while the app is not running. Records that no longer parse are skipped,
/// never fatal: one corrupt entry must not take down every other Host's
/// notifications, and a Notification Key is cheaply re-registered (unlike
/// the Device Key, losing one locks nobody out).
struct NotificationKeyStore: Sendable {
    /// The app-group id doubling as the Keychain access group (iOS accepts
    /// app groups in `kSecAttrAccessGroup` without the team prefix), granted
    /// to the app and the service extension by their entitlements.
    static let sharedAccessGroup = "group.dev.bybee.heeler.shared"

    private static let service = "dev.bybee.heeler.notifications"
    private static let keyBytes = 32

    private let secrets: any SecretStore

    init(
        secrets: any SecretStore = KeychainSecretStore(
            service: NotificationKeyStore.service,
            accessGroup: NotificationKeyStore.sharedAccessGroup)
    ) {
        self.secrets = secrets
    }

    /// A fresh random Notification Key, generated on device per the contract.
    static func generateKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    func save(_ record: NotificationKeyRecord) throws {
        guard record.key.count == Self.keyBytes,
            !record.hostName.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw NotificationKeyStoreError.invalidRecord
        }
        let stored = StoredRecord(
            v: 1, name: record.hostName, key: record.key.base64URLEncodedString())
        try secrets.write(try JSONEncoder().encode(stored), account: record.hostID.uuidString)
    }

    func record(forHost hostID: UUID) throws -> NotificationKeyRecord? {
        guard let data = try secrets.read(account: hostID.uuidString) else { return nil }
        return Self.decode(account: hostID.uuidString, data: data)
    }

    func allRecords() throws -> [NotificationKeyRecord] {
        try secrets.readAll().compactMap(Self.decode)
    }

    func removeRecord(forHost hostID: UUID) throws {
        try secrets.removeSecret(account: hostID.uuidString)
    }

    private static func decode(account: String, data: Data) -> NotificationKeyRecord? {
        guard let hostID = UUID(uuidString: account),
            let stored = try? JSONDecoder().decode(StoredRecord.self, from: data),
            stored.v == 1,
            let key = Data(base64URLEncoded: stored.key), key.count == keyBytes,
            !stored.name.isEmpty
        else { return nil }
        return NotificationKeyRecord(hostID: hostID, hostName: stored.name, key: key)
    }

    /// Keychain item payload. Versioned like every persisted shape here so a
    /// future field change cannot be misread by an older extension binary.
    private struct StoredRecord: Codable {
        let v: Int
        let name: String
        let key: String
    }
}
