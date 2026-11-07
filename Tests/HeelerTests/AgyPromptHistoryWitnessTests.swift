import Foundation
import Testing

@testable import Heeler

/// Antigravity CLI's prompt log as the post-send witness reads it: the
/// complete lines appended to the data root's `history.jsonl` since a
/// send's mark, which name the conversation that took each prompt.
@Suite("Antigravity CLI prompt history witness")
struct AgyPromptHistoryWitnessTests {
    private static let followed = "00000000-0000-4000-8000-000000000002"
    private static let other = "00000000-0000-4000-8000-000000000005"
    private static let root = "/Users/developer/.gemini/antigravity-cli"
    private static let transcript = AgyTranscriptLocator.transcriptPath(
        inFolder: AgyTranscriptLocator.folder(in: root, id: followed))
    private static let history = "\(root)/history.jsonl"

    /// One line as agy writes it; agy leaves `conversationId` out of a
    /// conversation's first prompt.
    private static func line(_ display: String, conversation: String?, type: String? = nil) throws -> String {
        var record: [String: Any] = [
            "display": display, "timestamp": 1_794_074_286_952, "workspace": "/Users/developer/projects/fruits",
        ]
        if let conversation { record["conversationId"] = conversation }
        if let type { record["type"] = type }
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func verdict(_ sent: String, before: String = "", appended: String) async throws
        -> ChatSendWitnessVerdict
    {
        let witness = AgyPromptHistoryWitness.witness
        let files = VirtualHostFiles()
        if !before.isEmpty { await files.write(before, at: history) }
        let mark = try #require(try await witness.mark(forTranscript: transcript, files: files.hostFiles()))
        await files.append(appended, to: history)
        let read = try #require(try await witness.appended(since: mark, files: files.hostFiles()))
        return witness.verdict(
            lines: read.lines, key: AgyTranscriptReducer.echoKey(sent), sessionID: followed,
            isWholeAppend: read.isWholeAppend, echoKey: AgyTranscriptReducer.echoKey)
    }

    @Test(arguments: ["/Users/developer/.gemini/antigravity-cli", "/Users/developer/work-account"])
    func theLogIsInTheTranscriptsDataRoot(root: String) {
        let transcript = AgyTranscriptLocator.transcriptPath(
            inFolder: AgyTranscriptLocator.folder(in: root, id: Self.followed))

        #expect(AgyPromptHistoryWitness.witness.logPath(transcript) == "\(root)/history.jsonl")
    }

    @Test func aLineNamingAnotherConversationIsElsewhere() async throws {
        let before = try Self.line("Reply with only the word pear.", conversation: Self.followed)
        let appended = try Self.line("Reply with only the word plum.", conversation: Self.other)

        #expect(try await Self.verdict("Reply with only the word plum. ", before: before, appended: appended) == .elsewhere)
    }

    @Test func aLineNamingThisConversationIsHere() async throws {
        let appended = try Self.line("Reply with only the word plum.", conversation: Self.followed)

        #expect(try await Self.verdict("Reply with only the word plum. ", appended: appended) == .here)
    }

    /// The first prompt of a conversation `/clear` or a launch started has
    /// no id, so the log cannot tell where it went.
    @Test func aFirstPromptWithoutAnIdSaysNothing() async throws {
        let appended = try Self.line("Reply with only the word plum.", conversation: nil)

        #expect(try await Self.verdict("Reply with only the word plum. ", appended: appended) == .unknown)
    }

    /// `/clear` is recorded as a local command under the conversation it
    /// leaves; a command line never stands for a send.
    @Test func aLocalCommandLineSaysNothing() async throws {
        let appended = try Self.line("/clear", conversation: Self.other, type: "slash_command")

        #expect(try await Self.verdict("/clear", appended: appended) == .unknown)
    }

    /// `/compact` runs in the model's turn and is recorded as a prompt.
    @Test func compactIsRecordedAsAPrompt() async throws {
        let appended = try Self.line("/compact", conversation: Self.other)

        #expect(try await Self.verdict("/compact ", appended: appended) == .elsewhere)
    }

    /// Plan mode records every prompt with `/plan ` before it.
    @Test func aPlanModePromptMatchesItsSend() async throws {
        let appended = try Self.line("/plan Add a multiply function to calc.py", conversation: Self.other)

        #expect(try await Self.verdict("Add a multiply function to calc.py ", appended: appended) == .elsewhere)
    }
}
