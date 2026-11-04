import Foundation
import Testing

@testable import Heeler

@Suite("Grok Build transcript locator")
struct GrokTranscriptLocatorTests {
    private static let sessionID = "01900000-0000-7000-8000-000000000010"
    private static let otherID = "01900000-0000-7000-8000-000000000011"
    /// The ids in `grok/fork-head.jsonl`: the fork, and the session whose
    /// records it copied.
    private static let forkID = "01900000-0000-7000-8000-000000000002"
    private static let parentID = "01900000-0000-7000-8000-000000000001"
    private static let cwd = "/home/dev/proj"
    private static let root = "/home/dev/.grok/sessions"
    private static let group = "%2Fhome%2Fdev%2Fproj"
    /// A directory whose group name would run past 255 bytes: each CJK
    /// character is three UTF-8 bytes, nine once percent-encoded.
    private static let longDirectory = "/home/dev/" + String(repeating: "深层目录/", count: 8) + "My App"

    private static func transcriptPath(group: String = group, sessionID: String = sessionID) -> String {
        "\(root)/\(group)/\(sessionID)/updates.jsonl"
    }

    /// Grok Build's first record, herdr's `session_start` hook: `sessionId`
    /// names the session, and `eventId` the session that first wrote it.
    private static func record(sessionID: String, eventPrefix: String? = nil) -> String {
        #"{"timestamp":1792422477,"method":"_x.ai/session/update","params":{"sessionId":"\#(sessionID)","update":{"sessionUpdate":"hook_execution","event_name":"session_start","runs":[{"name":"global/herdr:session_start[0].hooks[0]","status":{"status":"success","elapsed_ms":41}}]},"_meta":{"eventId":"\#(eventPrefix ?? sessionID)-1","agentTimestampMs":1792421871074}}}"#
            + "\n"
    }

    /// The record as a reader sees it while Grok writes it: cut `count`
    /// bytes into the session id.
    private static func record(cutInsideIDAfter count: Int) throws -> String {
        let record = record(sessionID: sessionID)
        let id = try #require(record.range(of: sessionID))
        return String(record[..<id.lowerBound]) + String(sessionID.prefix(count))
    }

    private static func locate(
        _ files: VirtualHostFiles, sessionID: String = sessionID, directories: [String] = [cwd],
        groupBudget: Int = 200
    ) async throws -> Result<String, GrokTranscriptLocator.Failure> {
        var locator = GrokTranscriptLocator(files: files.hostFiles())
        locator.groupBudget = groupBudget
        return try await locator.locate(sessionID: sessionID, directories: directories)
    }

    // MARK: Groups

    @Test func findsTheSessionInThePaneDirectorysGroup() async throws {
        let files = VirtualHostFiles()
        let path = Self.transcriptPath()
        await files.write(Self.record(sessionID: Self.sessionID), at: path)

        #expect(try await Self.locate(files) == .success(path))
        // The session's folder, then its file; no listing.
        #expect(await files.statuses == ["\(Self.root)/\(Self.group)/\(Self.sessionID)", path])
        #expect(await files.listings.isEmpty)
        #expect(GrokTranscriptLocator.groupDirectory(ofTranscript: path) == "\(Self.root)/\(Self.group)")
    }

    @Test(
        arguments: zip(
            [
                "/home/dev/My Project", "/home/dev/café", "/home/dev/a-b_c.d~e", "/srv/x+y:z%",
                "/" + String(repeating: "a", count: 252), "/" + String(repeating: "a", count: 253),
            ],
            [
                "%2Fhome%2Fdev%2FMy%20Project", "%2Fhome%2Fdev%2Fcaf%C3%A9", "%2Fhome%2Fdev%2Fa-b_c.d~e",
                "%2Fsrv%2Fx%2By%3Az%25", "%2F" + String(repeating: "a", count: 252), nil,
            ]))
    func encodesGroupNamesLikeGrok(directory: String, expected: String?) {
        // Every byte outside A-Z a-z 0-9 - _ . ~ as uppercase %XX, at most
        // 255 bytes in all.
        #expect(GrokTranscriptLocator.groupName(forDirectory: directory) == expected)
    }

    @Test func triesTheForegroundDirectoryFirst() async throws {
        let files = VirtualHostFiles()
        let path = Self.transcriptPath()
        await files.write(Self.record(sessionID: Self.sessionID), at: path)

        let result = try await Self.locate(files, directories: ["/home/dev/proj/web", Self.cwd])

        #expect(result == .success(path))
        #expect(
            await files.statuses == [
                "\(Self.root)/%2Fhome%2Fdev%2Fproj%2Fweb/\(Self.sessionID)",
                "\(Self.root)/\(Self.group)/\(Self.sessionID)", path,
            ])
        #expect(await files.listings.isEmpty)
    }

    // MARK: Long directories

    @Test func findsALongDirectoryByItsSlugAndCwdFile() async throws {
        let files = VirtualHostFiles()
        let group = "my-app-0123456789abcdef"
        await files.write(Self.longDirectory, at: "\(Self.root)/\(group)/.cwd")
        // Named like the slug, but not `<slug>-<16 hex>`: never read.
        await files.write(Self.longDirectory, at: "\(Self.root)/my-app-0000/.cwd")
        let path = Self.transcriptPath(group: group)
        await files.write(Self.record(sessionID: Self.sessionID), at: path)

        let result = try await Self.locate(files, directories: [Self.longDirectory])

        #expect(GrokTranscriptLocator.groupName(forDirectory: Self.longDirectory) == nil)
        #expect(result == .success(path))
        let listings = await files.listings
        #expect(listings.map(\.namePrefix) == ["my-app-"])
        #expect(listings.first?.kinds == [.directory])
        #expect(await files.reads.allSatisfy { $0.path != "\(Self.root)/my-app-0000/.cwd" })
    }

    @Test(
        arguments: zip(
            [
                "My App", "__init__", "深层目录", "Café Ünïcode", String(repeating: "a", count: 39) + " bcdef",
                "v2.0-RC1",
            ],
            ["my-app", "init", "workspace", "caf-n-code", String(repeating: "a", count: 39) + "-", "v2-0-rc1"]))
    func slugsLikeGrok(name: String, expected: String) {
        // Lowercased; each run of anything but ASCII letters and digits one
        // `-`; trimmed of `-`, then cut to 40, so a cut can end on `-`.
        #expect(GrokTranscriptLocator.slug(forDirectory: "/home/dev/" + name) == expected)
    }

    @Test func skipsASlugGroupWhoseCwdFileNamesAnotherDirectory() async throws {
        let files = VirtualHostFiles()
        let other = "/home/dev/" + String(repeating: "其他目录/", count: 8) + "My App"
        let otherGroup = "my-app-0000000000000001"
        await files.write(other, at: "\(Self.root)/\(otherGroup)/.cwd")
        await files.makeDirectory("\(Self.root)/\(otherGroup)/\(Self.otherID)")
        let group = "my-app-fedcba9876543210"
        await files.write(Self.longDirectory, at: "\(Self.root)/\(group)/.cwd")
        let path = Self.transcriptPath(group: group)
        await files.write(Self.record(sessionID: Self.sessionID), at: path)

        let result = try await Self.locate(files, directories: [Self.longDirectory])

        #expect(result == .success(path))
        // Listed first and read, but nothing in it was looked at.
        #expect(await files.reads.contains { $0.path == "\(Self.root)/\(otherGroup)/.cwd" })
        #expect(await files.statuses.allSatisfy { !$0.hasPrefix("\(Self.root)/\(otherGroup)/") })
    }

    // MARK: Other groups

    @Test func searchesWorktreeGroupsBeforeTheRest() async throws {
        let files = VirtualHostFiles()
        let worktree = "%2Fhome%2Fdev%2F.grok%2Fworktrees%2Fproj%2F2026-10-19-8f50828d"
        for group in ["%2Fapp", Self.group, worktree, "%2Fsrv%2Fdata"] {
            await files.makeDirectory("\(Self.root)/\(group)")
        }
        let path = Self.transcriptPath(group: worktree)
        await files.write(Self.record(sessionID: Self.sessionID), at: path)

        let result = try await Self.locate(files)

        #expect(result == .success(path))
        // The pane's group, then the worktree's, ahead of `%2Fapp`, which
        // lists first.
        #expect(
            await files.statuses == [
                "\(Self.root)/\(Self.group)/\(Self.sessionID)",
                "\(Self.root)/\(worktree)/\(Self.sessionID)", path,
            ])
    }

    @Test func reportsAPartialSearchWhenTheBudgetRunsOut() async throws {
        let files = VirtualHostFiles()
        for index in 0..<6 {
            await files.makeDirectory("\(Self.root)/%2Fsrv%2Fp\(index)")
        }
        let path = Self.transcriptPath(group: "%2Fsrv%2Fp5")
        await files.write(Self.record(sessionID: Self.sessionID), at: path)

        #expect(try await Self.locate(files, groupBudget: 3) == .failure(.notFound(searchedAll: false)))
        #expect(try await Self.locate(files, groupBudget: 20) == .success(path))

        await files.remove(path)
        await files.remove("\(Self.root)/%2Fsrv%2Fp5/\(Self.sessionID)")
        #expect(try await Self.locate(files, groupBudget: 20) == .failure(.notFound(searchedAll: true)))
    }

    // MARK: The session's file

    @Test func aSessionFolderWithoutUpdatesIsNotFoundYet() async throws {
        let files = VirtualHostFiles()
        await files.write("{}", at: "\(Self.root)/\(Self.group)/\(Self.sessionID)/summary.json")
        let path = Self.transcriptPath()

        #expect(try await Self.locate(files) == .failure(.notFound(searchedAll: false)))
        // The session's folder is here, so no other group is searched.
        #expect(await files.listings.isEmpty)

        // Grok writes the file next, then its first record.
        await files.write(Data(), at: path)
        #expect(try await Self.locate(files) == .failure(.notFound(searchedAll: false)))
        await files.write(try Self.record(cutInsideIDAfter: 8), at: path)
        #expect(try await Self.locate(files) == .failure(.notFound(searchedAll: false)))

        await files.write(Self.record(sessionID: Self.sessionID), at: path)
        #expect(try await Self.locate(files) == .success(path))
    }

    @Test func rejectsAHeadThatNamesAnotherSession() async throws {
        let files = VirtualHostFiles()
        await files.write(Self.record(sessionID: Self.otherID), at: Self.transcriptPath())

        #expect(try await Self.locate(files) == .failure(.mismatched))
    }

    @Test func acceptsAForkWhoseCopiedRecordsKeepTheParentsEventIDs() async throws {
        let first = try #require(try ChatFixture.lines("grok/fork-head.jsonl").first)
        let text = String(decoding: first.data, as: UTF8.self)
        #expect(text.contains(#""sessionId":"\#(Self.forkID)""#))
        #expect(text.contains(#""eventId":"\#(Self.parentID)-"#))
        let head = try ChatFixture.data("grok/fork-head.jsonl")
        let files = VirtualHostFiles()
        let fork = Self.transcriptPath(sessionID: Self.forkID)
        await files.write(head, at: fork)
        // A copy under the parent's name is not the parent's.
        await files.write(head, at: Self.transcriptPath(sessionID: Self.parentID))

        #expect(try await Self.locate(files, sessionID: Self.forkID) == .success(fork))
        #expect(try await Self.locate(files, sessionID: Self.parentID) == .failure(.mismatched))
    }

    @Test func readsTheFirstSessionIdInTheHead() throws {
        let two = Self.record(sessionID: Self.sessionID) + Self.record(sessionID: Self.otherID)
        #expect(GrokTranscriptLocator.sessionID(inHead: Data(two.utf8)) == Self.sessionID)
        let copied = Self.record(sessionID: Self.sessionID, eventPrefix: Self.otherID)
        #expect(GrokTranscriptLocator.sessionID(inHead: Data(copied.utf8)) == Self.sessionID)
        // Nothing yet: an empty head, or one cut before the id ends.
        #expect(GrokTranscriptLocator.sessionID(inHead: Data()) == nil)
        #expect(GrokTranscriptLocator.sessionID(inHead: Data(try Self.record(cutInsideIDAfter: 35).utf8)) == nil)
        // A slice of a larger read reads the same.
        let padded = Data(("\n" + Self.record(sessionID: Self.otherID)).utf8)
        #expect(GrokTranscriptLocator.sessionID(inHead: padded.dropFirst()) == Self.otherID)
    }

    // MARK: Engine

    private static func open(_ files: VirtualHostFiles, sessionID: String) async -> ChatConversationSnapshot {
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .grok, sessionID: sessionID),
            cacheKey: ChatCacheKey(hostID: UUID(), herdrSession: "", program: .grok, conversationID: sessionID),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: NumberedChatReducer.adapter())
        return await engine.open(directories: [cwd], context: ChatProjectionContext(activity: .idle))
    }

    @Test func theEngineFollowsTheTranscriptTheLocatorFinds() async throws {
        let files = VirtualHostFiles()
        let path = Self.transcriptPath()
        await files.write(Self.record(sessionID: Self.sessionID) + NumberedChatReducer.lines(0..<2), at: path)
        await files.write(Self.record(sessionID: Self.sessionID), at: Self.transcriptPath(sessionID: Self.otherID))

        let found = await Self.open(files, sessionID: Self.sessionID)

        #expect(found.phase == .following(path: path))
        #expect(found.transcript.entries.map(\.id.rawValue) == ["n-0", "n-1"])
        #expect(await Self.open(files, sessionID: Self.otherID).phase == .unavailable(.mismatched))
        #expect(
            await Self.open(VirtualHostFiles(), sessionID: Self.sessionID).phase
                == .unavailable(.notFound(searchedAll: true)))
    }
}
