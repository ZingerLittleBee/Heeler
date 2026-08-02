import Foundation
import Testing

@testable import HerdrMobile

@Suite("Notification key store")
struct NotificationKeyStoreTests {
    private let secrets = InMemorySecretStore()
    private var store: NotificationKeyStore { NotificationKeyStore(secrets: secrets) }

    @Test func savedRecordRoundTripsByHost() throws {
        let record = NotificationKeyRecord(
            hostID: UUID(), hostName: "mac-studio", key: NotificationKeyStore.generateKey())

        try store.save(record)

        #expect(try store.record(forHost: record.hostID) == record)
    }

    @Test func generatedKeysAreDistinct32ByteSecrets() {
        let first = NotificationKeyStore.generateKey()
        let second = NotificationKeyStore.generateKey()

        #expect(first.count == 32)
        #expect(second.count == 32)
        #expect(first != second)
    }

    @Test func keyIDMatchesTheEnvelopeDerivation() {
        let key = NotificationKeyStore.generateKey()
        let record = NotificationKeyRecord(hostID: UUID(), hostName: "vps", key: key)

        #expect(record.keyID == NotificationEnvelope.keyID(for: key))
    }

    @Test func allRecordsListsEveryRegisteredHost() throws {
        let first = NotificationKeyRecord(
            hostID: UUID(), hostName: "mac-studio", key: NotificationKeyStore.generateKey())
        let second = NotificationKeyRecord(
            hostID: UUID(), hostName: "vps-1", key: NotificationKeyStore.generateKey())
        try store.save(first)
        try store.save(second)

        let records = try store.allRecords()

        #expect(records.count == 2)
        #expect(records.contains(first))
        #expect(records.contains(second))
    }

    @Test func savingTheSameHostReplacesItsRecord() throws {
        let hostID = UUID()
        try store.save(
            NotificationKeyRecord(
                hostID: hostID, hostName: "old", key: NotificationKeyStore.generateKey()))
        let replacement = NotificationKeyRecord(
            hostID: hostID, hostName: "new", key: NotificationKeyStore.generateKey())

        try store.save(replacement)

        #expect(try store.record(forHost: hostID) == replacement)
        #expect(try store.allRecords().count == 1)
    }

    @Test func removeRevokesTheHost() throws {
        let record = NotificationKeyRecord(
            hostID: UUID(), hostName: "mac-studio", key: NotificationKeyStore.generateKey())
        try store.save(record)

        try store.removeRecord(forHost: record.hostID)

        #expect(try store.record(forHost: record.hostID) == nil)
        #expect(try store.allRecords().isEmpty)
    }

    @Test func missingHostReadsAsNil() throws {
        #expect(try store.record(forHost: UUID()) == nil)
    }

    /// The service extension reads this store on every push; a corrupted
    /// entry must vanish from the listing instead of taking every other
    /// Host's notifications down with it.
    @Test func corruptEntriesAreSkippedNotFatal() throws {
        let good = NotificationKeyRecord(
            hostID: UUID(), hostName: "mac-studio", key: NotificationKeyStore.generateKey())
        try store.save(good)
        try secrets.write(Data("not json".utf8), account: UUID().uuidString)
        try secrets.write(Data(#"{"v":1,"name":"short","key":"AAEC"}"#.utf8), account: UUID().uuidString)

        #expect(try store.allRecords() == [good])
    }

    @Test func saveRejectsAKeyThatIsNot32Bytes() {
        let record = NotificationKeyRecord(
            hostID: UUID(), hostName: "mac-studio", key: Data([1, 2, 3]))

        #expect(throws: NotificationKeyStoreError.invalidRecord) {
            try store.save(record)
        }
    }

    @Test func saveRejectsABlankHostName() {
        let record = NotificationKeyRecord(
            hostID: UUID(), hostName: "  ", key: NotificationKeyStore.generateKey())

        #expect(throws: NotificationKeyStoreError.invalidRecord) {
            try store.save(record)
        }
    }
}

/// The store's production backing is the shared-access-group Keychain that
/// the Notification Service Extension reads too. Exercise that wiring for
/// real on the simulator instead of trusting the in-memory stand-in.
@Suite("Notification key store on the shared Keychain", .serialized)
struct SharedKeychainNotificationKeyStoreTests {
    @Test func roundTripsThroughTheSharedAccessGroup() throws {
        let secrets = KeychainSecretStore(
            service: "dev.bybee.heeler.tests.notifications",
            accessGroup: NotificationKeyStore.sharedAccessGroup)
        let store = NotificationKeyStore(secrets: secrets)
        let record = NotificationKeyRecord(
            hostID: UUID(), hostName: "mac-studio", key: NotificationKeyStore.generateKey())
        defer { try? store.removeRecord(forHost: record.hostID) }

        try store.save(record)

        #expect(try store.record(forHost: record.hostID) == record)
        #expect(try store.allRecords().contains(record))
    }
}
