import Foundation
import Testing

@testable import Heeler

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

    @Test func cachedSecretStoreAvoidsRepeatReadsAndInvalidatesOnWriteAndRemove() throws {
        let counting = CountingSecretStore()
        let cached = CachedSecretStore(base: counting)
        let cachedKeys = NotificationKeyStore(secrets: cached, mirror: nil)
        let missingHost = UUID()

        // First lookup of an absent Host hits the backing store once, then caches nil.
        #expect(try cachedKeys.record(forHost: missingHost) == nil)
        #expect(try cachedKeys.record(forHost: missingHost) == nil)
        #expect(counting.readCalls == 1)

        // Saving updates the cache without requiring another read.
        let saved = NotificationKeyRecord(
            hostID: missingHost, hostName: "amux", key: NotificationKeyStore.generateKey())
        try cachedKeys.save(saved)
        #expect(try cachedKeys.record(forHost: missingHost) == saved)
        #expect(try cachedKeys.record(forHost: missingHost) == saved)
        #expect(counting.readCalls == 1)

        // readAll populates complete cache, after which even unseen accounts skip backing reads.
        #expect(try cachedKeys.allRecords() == [saved])
        #expect(try cachedKeys.allRecords() == [saved])
        #expect(counting.readAllCalls == 1)
        #expect(try cachedKeys.record(forHost: UUID()) == nil)
        #expect(counting.readCalls == 1)

        // Removing clears the cached entry immediately.
        try cachedKeys.removeRecord(forHost: missingHost)
        #expect(try cachedKeys.record(forHost: missingHost) == nil)
        #expect(try cachedKeys.allRecords().isEmpty)
        #expect(counting.readCalls == 1)
        #expect(counting.readAllCalls == 1)
    }

    @Test func concurrentRefreshMirrorDoesNotClobberConcurrentSave() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("heeler-mirror-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mirror = NotificationKeyMirror(containerURL: dir)
        let gated = FirstReadAllDelaySecretStore()
        let cached = CachedSecretStore(base: gated)
        let store = NotificationKeyStore(secrets: cached, mirror: mirror)

        let existing = NotificationKeyRecord(
            hostID: UUID(), hostName: "alpha", key: NotificationKeyStore.generateKey())
        try gated.seed(existing)

        let bgRefresh = Task.detached(priority: .utility) {
            store.refreshMirror()
        }
        await gated.waitUntilEnteredFirstReadAll()

        let added = NotificationKeyRecord(
            hostID: UUID(), hostName: "beta", key: NotificationKeyStore.generateKey())
        let writer = Task.detached(priority: .userInitiated) {
            try store.save(added)
        }
        // Let writer queue on mirrorLock (or run after refreshMirror finishes) while
        // the background readAll completes.
        try await Task.sleep(for: .milliseconds(20))
        gated.releaseFirstReadAll()

        _ = await bgRefresh.value
        try await writer.value

        let mirrored = mirror.read().sorted { $0.hostName < $1.hostName }
        #expect(mirrored == [existing, added])
    }
}

private final class FirstReadAllDelaySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var storage: [String: Data] = [:]
    private var delayedOnce = false

    func seed(_ record: NotificationKeyRecord) throws {
        struct Payload: Codable { let v: Int; let name: String; let key: String }
        let data = try JSONEncoder().encode(
            Payload(v: 1, name: record.hostName, key: record.key.base64URLEncodedString()))
        lock.withLock { storage[record.hostID.uuidString] = data }
    }

    func waitUntilEnteredFirstReadAll() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }

    func releaseFirstReadAll() {
        release.signal()
    }

    func read(account: String) throws -> Data? {
        lock.withLock { storage[account] }
    }

    func readAll() throws -> [String: Data] {
        let shouldDelay = lock.withLock { () -> Bool in
            guard !delayedOnce else { return false }
            delayedOnce = true
            return true
        }
        if shouldDelay {
            entered.signal()
            release.wait()
        }
        return lock.withLock { storage }
    }

    func write(_ secret: Data, account: String) throws {
        lock.withLock { storage[account] = secret }
    }

    func removeSecret(account: String) throws {
        lock.withLock { storage[account] = nil }
    }
}

private final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private(set) var readCalls = 0
    private(set) var readAllCalls = 0

    func read(account: String) throws -> Data? {
        lock.withLock {
            readCalls += 1
            return storage[account]
        }
    }

    func readAll() throws -> [String: Data] {
        lock.withLock {
            readAllCalls += 1
            return storage
        }
    }

    func write(_ secret: Data, account: String) throws {
        lock.withLock { storage[account] = secret }
    }

    func removeSecret(account: String) throws {
        lock.withLock { storage[account] = nil }
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
