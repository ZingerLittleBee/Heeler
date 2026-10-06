import Foundation
import Testing

@testable import Heeler

@Suite("Transcript follower")
struct TranscriptFollowerTests {
    private static let path = "/home/dev/.claude/projects/-k/s.jsonl"

    /// Small limits so a few hundred bytes exercise every boundary.
    private static let limits = TranscriptFollower.Limits(
        tailWindow: 64, readChunk: 16, pollBudget: 1_024, olderPage: 32, maximumOlderPage: 128,
        lineStartSearch: 1_024, anchorLength: 8, headLength: 32, lineCap: 4_096, prefixCap: 16)

    private static func lines(_ range: Range<Int>) -> String {
        range.map { #"{"n":\#($0)}"# + "\n" }.joined()
    }

    private static func texts(_ lines: [ChatLine]) -> [String] {
        lines.map { String(decoding: $0.data, as: UTF8.self) }
    }

    private static func expected(_ range: Range<Int>) -> [String] {
        range.map { #"{"n":\#($0)}"# }
    }

    private static func makeFollower(_ text: String) async throws -> (TranscriptFollower, VirtualHostFiles, [ChatLine]) {
        let files = VirtualHostFiles()
        await files.write(text, at: path)
        var follower = TranscriptFollower(path: path, limits: limits)
        let opened = try #require(try await follower.open(files.hostFiles()))
        return (follower, files, opened)
    }

    @Test func aSmallFileOpensWhole() async throws {
        let (follower, _, opened) = try await Self.makeFollower(Self.lines(0..<4))

        #expect(Self.texts(opened) == Self.expected(0..<4))
        #expect(follower.windowStart == 0)
        #expect(!follower.hasOlder)
    }

    @Test func aLargeFileOpensAtItsTailWithoutTheCutLine() async throws {
        let text = Self.lines(0..<30)
        let (follower, _, opened) = try await Self.makeFollower(text)

        // The window starts mid-line; that fragment is dropped.
        let texts = Self.texts(opened)
        #expect(texts.last == #"{"n":29}"#)
        #expect(Self.expected(0..<30).suffix(texts.count) == ArraySlice(texts))
        #expect(texts.count < 30)
        #expect(follower.hasOlder)
        #expect(follower.windowStart == opened.first?.offset)
    }

    @Test func anUnchangedFileCostsOneStat() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<4))
        await files.clearRecords()

        #expect(try await follower.poll(files.hostFiles()) == .unchanged)
        #expect(await files.reads.isEmpty)
        #expect(await files.statuses == [Self.path])
    }

    @Test func appendedLinesArriveOnceComplete() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<4))

        await files.append(#"{"n":4}"# + "\n" + #"{"n":"#, to: Self.path)
        #expect(try await follower.poll(files.hostFiles()) == .appended([
            ChatLine(offset: 32, data: Data(#"{"n":4}"#.utf8)),
        ]))

        await files.append("5}\n", to: Self.path)
        guard case .appended(let lines) = try await follower.poll(files.hostFiles()) else {
            Issue.record("expected appended lines")
            return
        }
        #expect(Self.texts(lines) == [#"{"n":5}"#])
        #expect(lines.first?.offset == 40)
    }

    @Test func shortReadsGiveTheSameLines() async throws {
        let files = VirtualHostFiles()
        await files.write(Self.lines(0..<30), at: Self.path)
        await files.setReadLimit(5)
        var follower = TranscriptFollower(path: Self.path, limits: Self.limits)
        let opened = try #require(try await follower.open(files.hostFiles()))

        let (_, _, reference) = try await Self.makeFollower(Self.lines(0..<30))
        #expect(opened == reference)

        await files.append(Self.lines(30..<33), to: Self.path)
        #expect(try await follower.poll(files.hostFiles()) == .appended(
            JSONLLineFramer.lines(in: Data(Self.lines(30..<33).utf8), startOffset: UInt64(Self.lines(0..<30).utf8.count))))
    }

    @Test func aTouchWithoutNewBytesChecksTheAnchorOnly() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<4))
        let original = try #require(await files.contents(of: Self.path))
        await files.write(original, at: Self.path)
        await files.clearRecords()

        #expect(try await follower.poll(files.hostFiles()) == .unchanged)
        let reads = await files.reads
        #expect(reads.map(\.offset) == [24])
        #expect(reads.map(\.maxBytes) == [8])
    }

    @Test func headsAgreeOnlyOverSharedBytes() {
        #expect(TranscriptFollower.sameStart(Data("abcd".utf8), Data("ab".utf8)))
        #expect(!TranscriptFollower.sameStart(Data("abcd".utf8), Data("abx".utf8)))
        #expect(!TranscriptFollower.sameStart(Data(), Data("ab".utf8)))
        #expect(!TranscriptFollower.sameStart(nil, Data("ab".utf8)))
    }

    @Test func anInPlaceShrinkReloadsTheTailKeepingIdentity() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<4))
        // Claude rewrites a transcript to drop a record: same head, shorter.
        await files.write(Self.lines(0..<2), at: Self.path)

        #expect(try await follower.poll(files.hostFiles()) == .reset(
            JSONLLineFramer.lines(in: Data(Self.lines(0..<2).utf8)), replaced: false))
    }

    @Test func aDifferentFileUnderTheSameNameIsReplaced() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<4))
        await files.write(Self.lines(100..<108), at: Self.path)

        guard case .reset(let lines, replaced: true) = try await follower.poll(files.hostFiles()) else {
            Issue.record("expected a replaced reset")
            return
        }
        #expect(Self.texts(lines).last == #"{"n":107}"#)
    }

    @Test func aRewriteThatGrowsTheFileFailsTheAnchor() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<8))
        // A dropped record shifts every later byte, the anchor included.
        await files.write(Self.lines(0..<5) + Self.lines(6..<10), at: Self.path)

        guard case .reset(let lines, replaced: false) = try await follower.poll(files.hostFiles()) else {
            Issue.record("expected an in-place reset")
            return
        }
        #expect(Self.texts(lines).last == #"{"n":9}"#)
        #expect(!Self.texts(lines).contains(#"{"n":5}"#))
    }

    @Test func aSameSizeRewriteWithANewTimeIsCaught() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<8))
        await files.write(Self.lines(0..<7) + #"{"n":9}"# + "\n", at: Self.path)

        guard case .reset(_, replaced: false) = try await follower.poll(files.hostFiles()) else {
            Issue.record("expected an in-place reset")
            return
        }
    }

    @Test func aMissingFileKeepsStateAndResumesWhenItReturns() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<4))
        let original = try #require(await files.contents(of: Self.path))
        await files.remove(Self.path)

        #expect(try await follower.poll(files.hostFiles()) == .missing)

        await files.write(original + Data(Self.lines(4..<5).utf8), at: Self.path)
        #expect(try await follower.poll(files.hostFiles()) == .appended([
            ChatLine(offset: 32, data: Data(#"{"n":4}"#.utf8)),
        ]))
    }

    @Test func aFailedReadKeepsThePosition() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<4))
        await files.append(Self.lines(4..<6), to: Self.path)
        await files.failNext(.read, with: TransportError.hostFileTimedOut)

        await #expect(throws: TransportError.hostFileTimedOut) {
            _ = try await follower.poll(files.hostFiles())
        }
        guard case .appended(let lines) = try await follower.poll(files.hostFiles()) else {
            Issue.record("expected appended lines")
            return
        }
        #expect(Self.texts(lines) == Self.expected(4..<6))
    }

    @Test func pagingBackwardsReachesTheHeadWithEveryLineOnce() async throws {
        let text = Self.lines(0..<40)
        var (follower, files, opened) = try await Self.makeFollower(text)
        var all = opened
        var pages = 0
        while follower.hasOlder {
            guard case .lines(let older) = try await follower.loadOlder(files.hostFiles()) else {
                Issue.record("expected an older page")
                return
            }
            all = older + all
            pages += 1
        }

        #expect(pages > 1)
        #expect(all == JSONLLineFramer.lines(in: Data(text.utf8)))
        #expect(try await follower.loadOlder(files.hostFiles()) == .headReached)
    }

    @Test func aLineLongerThanTheLargestPageArrivesTruncated() async throws {
        let long = #"{"blob":""# + String(repeating: "z", count: 300) + #""}"#
        let text = Self.lines(0..<2) + long + "\n" + Self.lines(2..<4)
        var (follower, files, opened) = try await Self.makeFollower(text)
        #expect(Self.texts(opened) == Self.expected(2..<4))

        guard case .lines(let page) = try await follower.loadOlder(files.hostFiles()) else {
            Issue.record("expected the long line")
            return
        }
        let line = try #require(page.first)
        #expect(page.count == 1)
        #expect(line.offset == 16)
        #expect(line.length == long.utf8.count)
        #expect(line.isTruncated)
        #expect(line.data == Data(long.utf8.prefix(16)))

        guard case .lines(let head) = try await follower.loadOlder(files.hostFiles()) else {
            Issue.record("expected the head")
            return
        }
        #expect(Self.texts(head) == Self.expected(0..<2))
        #expect(!follower.hasOlder)
    }

    @Test func pagingNoticesBytesChangedBeforeTheWindow() async throws {
        var (follower, files, _) = try await Self.makeFollower(Self.lines(0..<30))
        let start = try #require(follower.windowStart)
        var bytes = try #require(await files.contents(of: Self.path))
        bytes[Int(start) - 1] = UInt8(ascii: "x")
        await files.replaceKeepingTime(bytes, at: Self.path)

        #expect(try await follower.loadOlder(files.hostFiles()) == .rewritten)
    }
}
