import Foundation
import Testing

@testable import Heeler

/// The shared seen-mark vectors (ADR 0033): the app writes each file byte for byte,
/// and the Helper's tests parse the same ones.
@Suite("Herdr core seen mark file")
struct HerdrCoreSeenMarkFileTests {
    private struct Vectors: Decodable {
        struct File: Decodable {
            struct Mark: Decodable {
                let terminal: String
                let turn: Int
                let word: String?
            }

            let name: String
            let key: String
            let keyId: String
            let fileName: String
            let core: String
            let marks: [Mark]
            let contents: String
        }

        let files: [File]
    }

    private static func vectors() throws -> [Vectors.File] {
        let url = try #require(
            Bundle(for: BundleLocator.self).url(forResource: "herdr-core-seen-mark-v1", withExtension: "json"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).files
    }

    private final class BundleLocator {}

    @Test func writesEachSharedVectorByteForByte() throws {
        let vectors = try Self.vectors()
        #expect(!vectors.isEmpty)
        for vector in vectors {
            let file = HerdrCoreSeenMarkFile(
                device: vector.keyId, core: vector.core,
                marks: Dictionary(
                    uniqueKeysWithValues: vector.marks.map {
                        ($0.terminal, HerdrCoreTurnState.Mark(turn: $0.turn, word: $0.word))
                    }))
            #expect(String(decoding: try file.encoded(), as: UTF8.self) == vector.contents, "\(vector.name)")
        }
    }

    /// The name comes from the Notification Key, through the same id its envelopes
    /// carry, and never from a Terminal's address.
    @Test func namesEachSharedVectorFromItsNotificationKey() throws {
        for vector in try Self.vectors() {
            let key = try #require(Data(base64URLEncoded: vector.key))
            #expect(NotificationEnvelope.keyID(for: key) == vector.keyId, "\(vector.name)")
            #expect(HerdrCoreSeenMarkFile.fileName(keyID: vector.keyId) == vector.fileName, "\(vector.name)")
        }
    }
}
