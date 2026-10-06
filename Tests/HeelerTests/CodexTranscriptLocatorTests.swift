import Foundation
import Testing

@testable import Heeler

@Suite("Codex transcript locator")
struct CodexTranscriptLocatorTests {
    private static let thread = "01a10f87-e025-7fb1-8974-8dd09937767a"
    private static let revert = "01a2b3c4-0000-7000-8000-000000000001"
    private static let sessions = "/home/dev/.codex/sessions"
    /// 2026-10-06T06:00:00Z, the day the fixture thread started.
    private static let sameDay = Date(timeIntervalSince1970: 1_791_266_400)

    private static func rolloutName(_ time: String, rollout: String? = nil, suffix: String = ".jsonl") -> String {
        "rollout-\(time)-\(thread)\(rollout.map { "_\($0)" } ?? "")\(suffix)"
    }

    private static func meta(id: String, padding: Int = 0) -> String {
        #"{"timestamp":"2026-10-06T04:45:58.783Z","type":"session_meta","payload":{"id":"\#(id)","base_instructions":"\#(String(repeating: "x", count: padding))"}}"#
            + "\n"
    }

    private static func locate(
        _ files: VirtualHostFiles, now: Date = sameDay, thread: String = thread
    ) async throws -> Result<CodexTranscriptLocation, CodexTranscriptUnavailable> {
        try await CodexTranscriptLocator(files: files.hostFiles(), now: { now })
            .locate(threadID: thread)
    }

    @Test func findsTheRolloutUnderItsCreationDate() async throws {
        let files = VirtualHostFiles()
        let path = "\(Self.sessions)/2026/10/06/\(Self.rolloutName("2026-10-06T12-45-25"))"
        await files.write(try ChatFixture.data("codex/probe1-rollout.jsonl"), at: path)

        let location = try await Self.locate(files).get()

        #expect(location.segments.map(\.path) == [path])
        let listing = try #require(await files.listings.first)
        #expect(listing.nameContains == Self.thread)
        #expect(listing.nameSuffixes == [".jsonl", ".jsonl.zst"])
    }

    @Test func aHostAheadOfUTCFilesItUnderTheNextDay() async throws {
        let files = VirtualHostFiles()
        let path = "\(Self.sessions)/2026/10/07/\(Self.rolloutName("2026-10-07T00-45-25"))"
        await files.write(Self.meta(id: Self.thread), at: path)

        #expect(try await Self.locate(files).get().live?.path == path)
    }

    @Test func aRevertSegmentFromAnotherDayBecomesTheLiveOne() async throws {
        let files = VirtualHostFiles()
        let base = "\(Self.sessions)/2026/10/06/\(Self.rolloutName("2026-10-06T12-45-25"))"
        let child = "\(Self.sessions)/2026/10/09/\(Self.rolloutName("2026-10-09T10-00-00", rollout: Self.revert))"
        await files.write(Self.meta(id: Self.thread), at: base)
        await files.write(Self.meta(id: Self.thread), at: child)

        let location = try await Self.locate(files, now: Date(timeIntervalSince1970: 1_791_540_000)).get()

        #expect(location.segments.map(\.path) == [base, child])
        #expect(location.live?.name.rolloutID == Self.revert)
    }

    @Test func archivedRolloutsAreFoundWhenTheDatesHoldNone() async throws {
        let files = VirtualHostFiles()
        let path = "/home/dev/.codex/archived_sessions/\(Self.rolloutName("2026-10-06T12-45-25"))"
        await files.write(Self.meta(id: Self.thread), at: path)

        #expect(try await Self.locate(files).get().live?.path == path)
    }

    @Test func aCompressedNewestSegmentIsUnreadable() async throws {
        let files = VirtualHostFiles()
        await files.write(
            Data([0x28, 0xB5, 0x2F, 0xFD]),
            at: "\(Self.sessions)/2026/10/06/\(Self.rolloutName("2026-10-06T12-45-25", suffix: ".jsonl.zst"))")

        #expect(try await Self.locate(files) == .failure(.compressed))
    }

    @Test func aPlainCopyShadowsItsCompressedTwin() async throws {
        let files = VirtualHostFiles()
        let directory = "\(Self.sessions)/2026/10/06"
        await files.write(Data([0x28]), at: "\(directory)/\(Self.rolloutName("2026-10-06T12-45-25", suffix: ".jsonl.zst"))")
        let plain = "\(directory)/\(Self.rolloutName("2026-10-06T12-45-25"))"
        await files.write(Self.meta(id: Self.thread), at: plain)

        #expect(try await Self.locate(files).get().segments.map(\.path) == [plain])
    }

    @Test func aRolloutWhoseMetaNamesAnotherThreadIsRejected() async throws {
        let files = VirtualHostFiles()
        await files.write(
            Self.meta(id: Self.revert),
            at: "\(Self.sessions)/2026/10/06/\(Self.rolloutName("2026-10-06T12-45-25"))")

        #expect(try await Self.locate(files) == .failure(.mismatched))
    }

    @Test func aLongSessionMetaLineIsReadInGrowingPieces() async throws {
        let files = VirtualHostFiles()
        let path = "\(Self.sessions)/2026/10/06/\(Self.rolloutName("2026-10-06T12-45-25"))"
        await files.write(Self.meta(id: Self.thread, padding: 300_000), at: path)

        #expect(try await Self.locate(files).get().live?.path == path)
        let headReads = await files.reads.filter { $0.path == path }
        #expect(headReads.map(\.offset).first == 0)
        #expect(headReads.reduce(0) { $0 + $1.maxBytes } >= 300_000)
    }

    @Test func aSymlinkedRolloutIsFollowed() async throws {
        let files = VirtualHostFiles()
        let target = "/home/dev/elsewhere/rollout.jsonl"
        await files.write(Self.meta(id: Self.thread), at: target)
        let link = "\(Self.sessions)/2026/10/06/\(Self.rolloutName("2026-10-06T12-45-25"))"
        await files.symlink(link, to: target)

        #expect(try await Self.locate(files).get().live?.path == link)
    }

    @Test func nothingWrittenYetIsNotFound() async throws {
        #expect(try await Self.locate(VirtualHostFiles()) == .failure(.notFound))
    }

    @Test func otherThreadsInTheSameDirectoryAreIgnored() async throws {
        let files = VirtualHostFiles()
        let directory = "\(Self.sessions)/2026/10/06"
        await files.write(Self.meta(id: Self.revert), at: "\(directory)/rollout-2026-10-06T12-00-00-\(Self.revert).jsonl")

        #expect(try await Self.locate(files) == .failure(.notFound))
    }
}
