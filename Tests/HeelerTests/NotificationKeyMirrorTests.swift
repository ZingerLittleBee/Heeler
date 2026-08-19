import Foundation
import Testing

@testable import Heeler

/// The app-group Notification Key mirror: the Live Activity widget's
/// fallback when the Keychain is unreachable in its locked rendering
/// context (-25291 on device).
@Suite("Notification key mirror")
struct NotificationKeyMirrorTests {
    private let record = NotificationKeyRecord(
        hostID: UUID(uuidString: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E")!,
        hostName: "mbp",
        key: Data(0..<32))

    private func temporaryMirror() throws -> NotificationKeyMirror {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return NotificationKeyMirror(containerURL: container)
    }

    @Test func roundTripsRecords() throws {
        let mirror = try temporaryMirror()

        mirror.write([record])

        #expect(mirror.read() == [record])
    }

    @Test func readIsEmptyWithoutAFile() throws {
        #expect(try temporaryMirror().read() == [])
    }

    @Test func rewriteReplacesTheWholeSet() throws {
        let mirror = try temporaryMirror()
        mirror.write([record])

        mirror.write([])

        #expect(mirror.read() == [])
    }

    @Test func skipsRecordsWithInvalidKeys() throws {
        let mirror = try temporaryMirror()
        let short = NotificationKeyRecord(
            hostID: UUID(), hostName: "other", key: Data(0..<16))

        mirror.write([record, short])

        #expect(mirror.read() == [record])
    }

    @Test func storeMutationsRefreshTheMirror() throws {
        let mirror = try temporaryMirror()
        let store = NotificationKeyStore(secrets: VolatileSecretStore(), mirror: mirror)

        try store.save(record)
        #expect(mirror.read() == [record])

        try store.removeRecord(forHost: record.hostID)
        #expect(mirror.read() == [])
    }

    @Test func mirroredRecordsDecryptTheSharedVectors() throws {
        // The widget's locked-render fallback selects a mirrored record by
        // kid and opens the envelope with it; prove a mirror round trip
        // preserves exactly that ability.
        let vector = LiveActivityVectorFile.shared.valid[0]
        let key = try #require(Data(base64URLEncoded: vector.key))
        let mirror = try temporaryMirror()
        mirror.write([NotificationKeyRecord(hostID: UUID(), hostName: "mbp", key: key)])

        let record = try #require(
            mirror.read().first { $0.keyID == vector.keyId })
        let details = try AgentActivityEnvelope.open(
            Data(vector.envelope.utf8), using: record.key)

        #expect(details.agents.map(\.paneID) == vector.payload.agents.map(\.pane))
    }
}
