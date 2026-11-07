import Foundation
import Testing

@testable import Heeler

@Suite("Antigravity CLI transcript locator")
struct AgyTranscriptLocatorTests {
    private static let id = "00000000-0000-4000-8000-000000000001"
    private static let root = "/home/dev/.gemini/antigravity-cli"
    private static let line = #"{"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE"}"# + "\n"

    private static func transcriptPath(root: String = root, id: String = id) -> String {
        "\(root)/brain/\(id)/.system_generated/logs/transcript_full.jsonl"
    }

    private static func locate(
        _ files: VirtualHostFiles, sessionID: String = id, configRoot: String? = nil
    ) async throws -> Result<String, AgyTranscriptLocator.Failure> {
        try await AgyTranscriptLocator(files: files.hostFiles()).locate(sessionID: sessionID, configRoot: configRoot)
    }

    /// The folder is named for the id, so the lookup is two stats and no
    /// listing.
    @Test func findsTheFullTranscriptDirectly() async throws {
        let files = VirtualHostFiles()
        let path = Self.transcriptPath()
        await files.write(Self.line, at: path)
        await files.write(Self.line, at: "\(Self.root)/brain/\(Self.id)/.system_generated/logs/transcript.jsonl")

        #expect(try await Self.locate(files) == .success(path))
        #expect(await files.statuses == ["\(Self.root)/brain/\(Self.id)", path])
    }

    /// The id as herdr may report it, in uppercase, names the folder agy
    /// wrote in lowercase.
    @Test func anUppercaseIDFindsTheFolder() async throws {
        let files = VirtualHostFiles()
        let path = Self.transcriptPath()
        await files.write(Self.line, at: path)

        #expect(try await Self.locate(files, sessionID: Self.id.uppercased()) == .success(path))
    }

    /// The folder can be there before the first message brings the file.
    @Test func aFolderWithoutItsTranscriptIsNotWrittenYet() async throws {
        let files = VirtualHostFiles()
        await files.makeDirectory("\(Self.root)/brain/\(Self.id)/scratch")
        #expect(try await Self.locate(files) == .failure(.notWritten))

        await files.write("", at: Self.transcriptPath())
        #expect(try await Self.locate(files) == .failure(.notWritten))
    }

    @Test func nothingUnderTheRootIsNotFound() async throws {
        #expect(try await Self.locate(VirtualHostFiles()) == .failure(.notFound))
    }

    /// Only a UUID becomes a path.
    @Test(arguments: ["../x", "not-an-id", "", "00000000-0000-4000-8000-000000000001/../.."])
    func aValueThatIsNotAnIDIsNotLookedFor(value: String) async throws {
        let files = VirtualHostFiles()
        #expect(try await Self.locate(files, sessionID: value) == .failure(.notFound))
        #expect(await files.statuses.isEmpty)
    }

    // MARK: Accounts

    @Test func findsTheConversationUnderAnAddedAccount() async throws {
        let files = VirtualHostFiles()
        await files.setAccountDirectories(["/home/dev/agy-work/"], for: .antigravity)
        let path = Self.transcriptPath(root: "/home/dev/agy-work")
        await files.write(Self.line, at: path)

        #expect(try await Self.locate(files) == .success(path))
    }

    @Test func anUnreadableDefaultRootDoesNotHideAnAccount() async throws {
        let files = VirtualHostFiles()
        await files.setAccountDirectories(["/home/dev/agy-work"], for: .antigravity)
        await files.failNext(
            .status, path: "\(Self.root)/brain/\(Self.id)", with: TransportError.hostFileUnreadable(status: 3))
        let path = Self.transcriptPath(root: "/home/dev/agy-work")
        await files.write(Self.line, at: path)

        #expect(try await Self.locate(files) == .success(path))
    }

    @Test func aGivenRootLeavesTheOthersUnsearched() async throws {
        let files = VirtualHostFiles()
        await files.setAccountDirectories(["/home/dev/agy-work"], for: .antigravity)
        await files.write(Self.line, at: Self.transcriptPath())
        await files.write(Self.line, at: Self.transcriptPath(root: "/home/dev/agy-work"))

        #expect(try await Self.locate(files, configRoot: "/srv/agy") == .failure(.notFound))
        let given = Self.transcriptPath(root: "/srv/agy")
        await files.write(Self.line, at: given)
        #expect(try await Self.locate(files, configRoot: "/srv/agy") == .success(given))
    }

    /// An Account's directory holds agy's `brain` folder.
    @Test func anAccountIsADirectoryWithABrainFolder() {
        #expect(SupportedAgentKind.antigravity.accountMarkers.map(\.label) == ["a brain folder"])
        #expect(SupportedAgentKind.antigravity.configDirectoryVariable == nil)
    }

    // MARK: Engine

    private static func open(
        _ files: VirtualHostFiles, sessionMayPrecedeItsStore: Bool = false
    ) async -> ChatConversationSnapshot {
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .agy, sessionID: id),
            cacheKey: ChatCacheKey(hostID: UUID(), herdrSession: "", program: .agy, conversationID: id),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: NumberedChatReducer.adapter(),
            sessionMayPrecedeItsStore: sessionMayPrecedeItsStore)
        return await engine.open(directories: ["/home/dev/proj"], context: ChatProjectionContext(activity: .idle))
    }

    @Test func theEngineFollowsTheTranscriptTheLocatorFinds() async throws {
        let files = VirtualHostFiles()
        let path = Self.transcriptPath()
        await files.write(NumberedChatReducer.lines(0..<2), at: path)

        let found = await Self.open(files)

        #expect(found.phase == .following(path: path))
        #expect(found.transcript.entries.map(\.id.rawValue) == ["n-0", "n-1"])
    }

    /// A folder without its file is a conversation still to start; no
    /// folder at all is one the Host does not have, unless the Agent's own
    /// evidence named the id before its first message.
    @Test func theEngineWaitsForAFirstMessage() async throws {
        let files = VirtualHostFiles()
        #expect(await Self.open(files).phase == .unavailable(.notFound(searchedAll: true)))
        #expect(
            await Self.open(files, sessionMayPrecedeItsStore: true).phase
                == .unavailable(.awaitingFirstMessage(.agy)))

        await files.makeDirectory("\(Self.root)/brain/\(Self.id)")
        #expect(await Self.open(files).phase == .unavailable(.awaitingFirstMessage(.agy)))
    }
}
