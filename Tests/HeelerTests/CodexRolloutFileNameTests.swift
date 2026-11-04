import Foundation
import Testing

@testable import Heeler

@Suite("Codex rollout file name")
struct CodexRolloutFileNameTests {
    private static let thread = "01a10f87-e025-7fb1-8974-8dd09937767a"
    private static let revert = "01a2b3c4-0000-7000-8000-000000000001"

    @Test func parsesARootSegment() throws {
        let name = try #require(
            CodexRolloutFileName(fileName: "rollout-2026-10-06T12-45-25-\(Self.thread).jsonl"))
        #expect(name.timestampKey == "2026-10-06T12-45-25")
        #expect(name.threadID == Self.thread)
        #expect(name.rolloutID == Self.thread)
        #expect(!name.isCompressed)
    }

    @Test func splitsARevertSegmentAtTheFirstUnderscore() throws {
        let name = try #require(
            CodexRolloutFileName(
                fileName: "rollout-2026-10-09T10-00-00-\(Self.thread)_\(Self.revert).jsonl.zst"))
        #expect(name.threadID == Self.thread)
        #expect(name.rolloutID == Self.revert)
        #expect(name.isCompressed)
    }

    @Test(arguments: [
        "session.jsonl",
        "rollout-2026.jsonl",
        "rollout-2026-10-06T12-45-25-.jsonl",
        "rollout-2026-10-06T12-45-25_\(thread).jsonl",
        "rollout-2026-10-06T12-45-25-\(thread).json",
        "rollout-2026-10-06T12-45-25-\(thread)_.jsonl",
    ])
    func rejectsOtherNames(fileName: String) {
        #expect(CodexRolloutFileName(fileName: fileName) == nil)
    }

    @Test func ordersByTimeThenRolloutWithPlainCopiesLast() throws {
        func name(_ text: String) throws -> CodexRolloutFileName {
            try #require(CodexRolloutFileName(fileName: text))
        }
        let root = try name("rollout-2026-10-06T12-45-25-\(Self.thread).jsonl")
        let laterCompressed = try name("rollout-2026-10-09T10-00-00-\(Self.thread)_\(Self.revert).jsonl.zst")
        let laterPlain = try name("rollout-2026-10-09T10-00-00-\(Self.thread)_\(Self.revert).jsonl")
        let sorted = [laterPlain, root, laterCompressed].sorted(by: CodexRolloutFileName.isOrderedBefore)
        #expect(sorted == [root, laterCompressed, laterPlain])
    }

    @Test func versionSevenIDsCarryTheirCreationTime() throws {
        let date = try #require(CodexThreadID.creationDate(of: Self.thread))
        #expect(date.timeIntervalSince1970 == 1_791_261_925.413)
        #expect(CodexThreadID.creationDate(of: "e951205e-24af-4a5e-baa7-3ccbebd2de2c") == nil)
        #expect(CodexThreadID.creationDate(of: "not-a-uuid") == nil)
    }

    @Test func searchesTheDaysAroundCreationAndToday() {
        let now = Date(timeIntervalSince1970: 1_791_500_400)  // 2026-10-08T23:00:00Z
        #expect(
            CodexTranscriptLocator.dateDirectories(threadID: Self.thread, now: now)
                == ["2026/10/05", "2026/10/06", "2026/10/07", "2026/10/08", "2026/10/09"])
        #expect(
            CodexTranscriptLocator.dateDirectories(
                threadID: "e951205e-24af-4a5e-baa7-3ccbebd2de2c", now: now)
                == ["2026/10/07", "2026/10/08", "2026/10/09"])
    }
}
