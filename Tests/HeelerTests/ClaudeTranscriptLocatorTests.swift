import Foundation
import Testing

@testable import Heeler

@Suite("Claude transcript locator")
struct ClaudeTranscriptLocatorTests {
    private static let sessionID = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let cwd = "/private/tmp/heeler-tmp-chat2/probe-claude"
    private static let projects = "/home/dev/.claude/projects"

    private static func transcriptPath(key: String) -> String {
        "\(projects)/\(key)/\(sessionID).jsonl"
    }

    private static func locate(
        _ files: VirtualHostFiles, directories: [String] = [cwd], statBudget: Int = 200
    ) async throws -> Result<ClaudeTranscriptLocation, ClaudeTranscriptUnavailable> {
        var locator = ClaudeTranscriptLocator(files: files.hostFiles())
        locator.statBudget = statBudget
        return try await locator.locate(sessionID: sessionID, directories: directories)
    }

    @Test func findsTheTranscriptUnderTheWorkingDirectoryKey() async throws {
        let files = VirtualHostFiles()
        let path = Self.transcriptPath(key: "-private-tmp-heeler-tmp-chat2-probe-claude")
        await files.write(try ChatFixture.data("claude/probe2-transcript.jsonl"), at: path)

        let result = try await Self.locate(files)

        #expect(
            result == .success(
                ClaudeTranscriptLocation(
                    projectDirectory: "\(Self.projects)/-private-tmp-heeler-tmp-chat2-probe-claude",
                    transcriptPath: path, sessionID: Self.sessionID)))
        // One stat, one head read; no listing.
        #expect(await files.listings.isEmpty)
        #expect(await files.statuses == [path])
    }

    @Test func triesTheLaunchDirectoryAfterTheCurrentOne() async throws {
        let files = VirtualHostFiles()
        let path = Self.transcriptPath(key: "-private-tmp-heeler-tmp-chat2-probe-claude")
        await files.write(try ChatFixture.data("claude/probe2-transcript.jsonl"), at: path)

        let result = try await Self.locate(files, directories: ["/home/dev/elsewhere", Self.cwd])

        #expect(try result.get().transcriptPath == path)
        #expect(await files.listings.isEmpty)
    }

    @Test func aRelocatedSessionIsFoundByScanningProjectsClosestNameFirst() async throws {
        let files = VirtualHostFiles()
        for name in ["-home-dev-a", "-private-tmp-heeler-tmp-chat2-zzz", "-var-x"] {
            await files.makeDirectory("\(Self.projects)/\(name)")
        }
        let moved = Self.transcriptPath(key: "-var-x")
        await files.write(try ChatFixture.data("claude/probe2-transcript.jsonl"), at: moved)

        let result = try await Self.locate(files)

        #expect(try result.get().transcriptPath == moved)
        let statuses = await files.statuses
        // The exact key first, then listed names by shared prefix.
        #expect(statuses.first == Self.transcriptPath(key: "-private-tmp-heeler-tmp-chat2-probe-claude"))
        #expect(statuses.dropFirst().first == Self.transcriptPath(key: "-private-tmp-heeler-tmp-chat2-zzz"))
    }

    @Test func emptyFilesAreNotTranscriptsYet() async throws {
        let files = VirtualHostFiles()
        await files.write(Data(), at: Self.transcriptPath(key: "-private-tmp-heeler-tmp-chat2-probe-claude"))

        #expect(try await Self.locate(files) == .failure(.notFound(searchedAll: true)))
    }

    @Test func aSubagentTranscriptUnderTheSessionNameIsRejected() async throws {
        let files = VirtualHostFiles()
        await files.write(
            try ChatFixture.data("claude/probe2-subagent.jsonl"),
            at: Self.transcriptPath(key: "-private-tmp-heeler-tmp-chat2-probe-claude"))

        #expect(try await Self.locate(files) == .failure(.mismatched))
    }

    @Test func aFileNamingAnotherSessionIsRejected() async throws {
        let files = VirtualHostFiles()
        await files.write(
            try ChatFixture.data("claude/probe1-transcript.jsonl"),
            at: Self.transcriptPath(key: "-private-tmp-heeler-tmp-chat2-probe-claude"))

        #expect(try await Self.locate(files) == .failure(.mismatched))
    }

    @Test func aLongKeyIsFoundByItsPrefixWhateverItsHash() async throws {
        let directory = "/home/dev/" + String(repeating: "a", count: 250)
        let prefix = try #require(ClaudeProjectKey.longKeyPrefix(forDirectory: directory))
        let files = VirtualHostFiles()
        let path = Self.transcriptPath(key: prefix + "bunhash1")
        await files.write(try ChatFixture.data("claude/probe2-transcript.jsonl"), at: path)

        let result = try await Self.locate(files, directories: [directory])

        #expect(try result.get().transcriptPath == path)
        #expect(await files.listings.first?.namePrefix == prefix)
    }

    @Test func theStatBudgetEndsTheScanWithoutClaimingAbsence() async throws {
        let files = VirtualHostFiles()
        for index in 0..<6 {
            await files.makeDirectory("\(Self.projects)/-p\(index)")
        }
        await files.write(
            try ChatFixture.data("claude/probe2-transcript.jsonl"), at: Self.transcriptPath(key: "-p5"))

        #expect(try await Self.locate(files, statBudget: 3) == .failure(.notFound(searchedAll: false)))
        #expect(try await Self.locate(files, statBudget: 20).get().transcriptPath == Self.transcriptPath(key: "-p5"))
    }

    @Test func noProjectsDirectoryMeansNothingWasWritten() async throws {
        #expect(try await Self.locate(VirtualHostFiles()) == .failure(.notFound(searchedAll: true)))
    }

    @Test func subagentPathsStayInsideTheSessionDirectory() {
        let location = ClaudeTranscriptLocation(
            projectDirectory: "\(Self.projects)/-k", transcriptPath: "\(Self.projects)/-k/s.jsonl",
            sessionID: Self.sessionID)
        #expect(
            location.subagentTranscriptPath(agentID: "a9985bf0a8b4ebbe3")
                == "\(Self.projects)/-k/\(Self.sessionID)/subagents/agent-a9985bf0a8b4ebbe3.jsonl")
        #expect(location.subagentTranscriptPath(agentID: "../x") == nil)
        #expect(location.subagentTranscriptPath(agentID: "") == nil)
    }

    @Test func workflowJournalsSitInsideTheSessionDirectory() {
        let transcript = "\(Self.projects)/-k/\(Self.sessionID).jsonl"
        #expect(
            ClaudeTranscriptLocation.workflowJournalPath(transcriptPath: transcript, runID: "wf_2d6c7df2-dc3")
                == "\(Self.projects)/-k/\(Self.sessionID)/subagents/workflows/wf_2d6c7df2-dc3/journal.jsonl")
        #expect(ClaudeTranscriptLocation.workflowJournalPath(transcriptPath: transcript, runID: "wf_../x") == nil)
        #expect(ClaudeTranscriptLocation.workflowJournalPath(transcriptPath: transcript, runID: "wf_a\u{0}b") == nil)
        #expect(ClaudeTranscriptLocation.workflowJournalPath(transcriptPath: "relative/s.jsonl", runID: "wf_1") == nil)
        #expect(ClaudeTranscriptLocation.workflowJournalPath(transcriptPath: "/x/s.json", runID: "wf_1") == nil)
    }
}
