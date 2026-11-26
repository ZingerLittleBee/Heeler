import Foundation
import Testing

@testable import Heeler

@Suite("Host file cache")
struct HostFileCacheTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_791_266_400)

        var now: Date { lock.withLock { date } }

        func advance(_ interval: TimeInterval) {
            lock.withLock { date = date.addingTimeInterval(interval) }
        }
    }

    private static func makeCache(
        policy: HostFileCache.Policy = .init(), clock: Clock = Clock()
    ) -> (HostFileCache, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "HostFileCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (
            HostFileCache(root: root, policy: policy, now: { clock.now }),
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    private static func key(_ host: UUID, _ path: String = "/home/dev/demo.mp4", size: UInt64 = 4, time: UInt32 = 100)
        -> HostFileCache.Key
    {
        guard let key = HostFileCache.Key(hostID: host, path: path, size: size, modificationTime: time) else {
            preconditionFailure("a key with a modification time")
        }
        return key
    }

    @Test func opensTheVersionItKeptAndOnlyTheNewestOfAPath() async throws {
        let (cache, cleanup) = Self.makeCache()
        defer { cleanup() }
        let host = UUID()
        let first = Self.key(host)
        #expect(HostFileCache.Key(hostID: host, path: first.path, size: 4, modificationTime: nil) == nil)

        let download = try await cache.newDownload(named: "demo.mp4")
        try Data("abcd".utf8).write(to: download)
        let kept = try #require(await cache.keep(download, for: first))
        #expect(kept.lastPathComponent == "demo.mp4")
        #expect(!FileManager.default.fileExists(atPath: download.deletingLastPathComponent().path))
        let opened = try #require(await cache.file(for: first))
        #expect(try Data(contentsOf: opened) == Data("abcd".utf8))

        // Written again on the Host: the kept copy is not that file.
        let rewritten = Self.key(host, size: 5, time: 101)
        #expect(await cache.file(for: rewritten) == nil)
        let newer = try #require(await cache.keep(Data("abcde".utf8), named: "demo.mp4", for: rewritten))
        #expect(try Data(contentsOf: newer) == Data("abcde".utf8))
        #expect(await cache.file(for: first) == nil)
        #expect(await cache.diskUsage() == 5)
    }

    @Test func dropsARemovedHostsCopiesAndRefusesItsLaterOnes() async throws {
        let (cache, cleanup) = Self.makeCache()
        defer { cleanup() }
        let kept = UUID()
        let removed = UUID()
        _ = try #require(await cache.keep(Data("abcd".utf8), named: "a.png", for: Self.key(kept)))
        _ = try #require(await cache.keep(Data("abcd".utf8), named: "a.png", for: Self.key(removed)))

        await cache.retainHosts([kept])

        #expect(await cache.file(for: Self.key(kept)) != nil)
        #expect(await cache.file(for: Self.key(removed)) == nil)
        #expect(await cache.keep(Data("abcd".utf8), named: "a.png", for: Self.key(removed)) == nil)
    }

    @Test func removesCopiesUnopenedPastTheAgeLimitThenTheLeastRecentlyOpened() async throws {
        let clock = Clock()
        let (cache, cleanup) = Self.makeCache(
            policy: .init(totalBudget: 10, lowWater: 8, maxAge: 100), clock: clock)
        defer { cleanup() }
        let host = UUID()
        let stale = Self.key(host, "/stale.pdf")
        let older = Self.key(host, "/older.pdf")
        let opened = Self.key(host, "/opened.pdf")
        _ = try #require(await cache.keep(Data("abcd".utf8), named: "stale.pdf", for: stale))
        clock.advance(60)
        _ = try #require(await cache.keep(Data("abcd".utf8), named: "older.pdf", for: older))
        _ = try #require(await cache.keep(Data("abcd".utf8), named: "opened.pdf", for: opened))
        clock.advance(50)
        // Opening a copy counts as using it.
        #expect(await cache.file(for: opened) != nil)

        // Past 100 seconds unopened, then over 10 bytes until at most 8.
        _ = try #require(await cache.keep(Data("abcd".utf8), named: "new.pdf", for: Self.key(host, "/new.pdf")))

        #expect(await cache.file(for: stale) == nil)
        #expect(await cache.file(for: older) == nil)
        #expect(await cache.file(for: opened) != nil)
        #expect(await cache.diskUsage() == 8)
    }
}
