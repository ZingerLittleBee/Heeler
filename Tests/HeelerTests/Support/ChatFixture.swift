import Foundation

@testable import Heeler

/// Files under `Tests/HeelerTests/ChatFixtures/`: captured transcripts and
/// screens (see the README there for provenance and scrubbing).
///
/// The test bundle carries the directory as a folder reference. When the
/// bundle lacks it (a test run outside the app's test target), the loader
/// falls back to the source tree next to this file. A missing file throws,
/// so it fails only the test that asked for it.
enum ChatFixture {
    struct Missing: Error, CustomStringConvertible {
        let path: String
        var description: String { "Chat fixture \(path) is missing" }
    }

    static func url(_ relativePath: String) throws -> URL {
        for root in roots {
            let url = root.appending(path: relativePath)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
        }
        throw Missing(path: relativePath)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    static func text(_ relativePath: String) throws -> String {
        String(decoding: try data(relativePath), as: UTF8.self)
    }

    /// The fixture's complete lines with their true offsets.
    static func lines(_ relativePath: String) throws -> [ChatLine] {
        JSONLLineFramer.lines(in: try data(relativePath))
    }

    /// Splits `data` at the given offsets, as a series of reads would.
    static func chunks(_ data: Data, splitAt offsets: [Int]) -> [Data] {
        var chunks: [Data] = []
        var start = 0
        for offset in offsets.sorted() where offset > start && offset < data.count {
            chunks.append(data.subdata(in: start..<offset))
            start = offset
        }
        chunks.append(data.subdata(in: start..<data.count))
        return chunks
    }

    /// Splits `data` into reads of `size` bytes.
    static func chunks(_ data: Data, size: Int) -> [Data] {
        stride(from: 0, to: data.count, by: max(1, size)).map {
            data.subdata(in: $0..<min(data.count, $0 + max(1, size)))
        }
    }

    private static let roots: [URL] = {
        var roots: [URL] = []
        if let bundled = Bundle(for: Locator.self).url(forResource: "ChatFixtures", withExtension: nil) {
            roots.append(bundled)
        }
        let source = URL(filePath: #filePath).resolvingSymlinksInPath()
        roots.append(
            source.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "ChatFixtures", directoryHint: .isDirectory))
        return roots
    }()

    private final class Locator {}
}
