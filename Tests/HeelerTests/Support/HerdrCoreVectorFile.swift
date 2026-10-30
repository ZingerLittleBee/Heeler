import Foundation

@testable import Heeler

/// The shared herdr-core frame vectors from `plugin/test-vectors/`, bundled
/// into the test target as a resource. Captured from a fixture core; every case
/// names its capture.
struct HerdrCoreVectorFile: Decodable, Sendable {
    let provisional: Bool
    let coreVersion: String
    let coreCommit: String
    let hello: Hello
    let frames: [FrameCase]
    let exchanges: [Exchange]
    let errors: [ErrorCase]
    let events: [EventCase]
    let eventFrames: [EventFrames]

    struct Hello: Decodable, Sendable {
        let name: String
        let source: String
        let reply: String
    }

    struct FrameCase: Decodable, Sendable {
        let name: String
        let source: String
        let bytes: String
    }

    struct Exchange: Decodable, Sendable {
        let name: String
        let source: String
        let method: String
        let params: JSONValue
        let result: JSONValue
        let requestFrame: String
        let replyFrame: String
    }

    struct ErrorCase: Decodable, Sendable {
        let name: String
        let source: String
        let kind: String
        let line: String
    }

    struct EventCase: Decodable, Sendable {
        let name: String
        let source: String
        let line: String
    }

    struct EventFrames: Decodable, Sendable {
        let name: String
        let source: String
        let bytes: String
        let lines: Int
    }

    /// Every case's name and source, across the file's sections.
    var allCases: [(name: String, source: String)] {
        [(hello.name, hello.source)]
            + frames.map { ($0.name, $0.source) }
            + exchanges.map { ($0.name, $0.source) }
            + errors.map { ($0.name, $0.source) }
            + events.map { ($0.name, $0.source) }
            + eventFrames.map { ($0.name, $0.source) }
    }

    func exchange(_ name: String) throws -> Exchange {
        guard let exchange = exchanges.first(where: { $0.name == name }) else {
            throw CocoaError(.coderValueNotFound, userInfo: [NSDebugDescriptionErrorKey: name])
        }
        return exchange
    }

    func event(_ name: String) throws -> Data {
        guard let event = events.first(where: { $0.name == name }) else {
            throw CocoaError(.coderValueNotFound, userInfo: [NSDebugDescriptionErrorKey: name])
        }
        return Data(event.line.utf8)
    }

    func error(_ name: String) throws -> ErrorCase {
        guard let error = errors.first(where: { $0.name == name }) else {
            throw CocoaError(.coderValueNotFound, userInfo: [NSDebugDescriptionErrorKey: name])
        }
        return error
    }

    static let shared: HerdrCoreVectorFile = {
        do {
            return try JSONDecoder().decode(HerdrCoreVectorFile.self, from: fileData())
        } catch {
            fatalError("shared herdr-core vectors failed to load: \(error)")
        }
    }()

    static func fileData() throws -> Data {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "herdr-core-frames-v1", withExtension: "json")
        else {
            throw CocoaError(
                .fileNoSuchFile, userInfo: [NSFilePathErrorKey: "herdr-core-frames-v1.json"])
        }
        return try Data(contentsOf: url)
    }

    /// Exact bytes from a vector's hex string.
    static func bytes(hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                fatalError("invalid hex in a herdr-core vector: \(hex[index..<next])")
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private final class BundleLocator {}
}
