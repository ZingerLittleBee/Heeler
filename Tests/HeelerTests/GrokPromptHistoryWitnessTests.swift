import Foundation
import Testing

@testable import Heeler

/// Grok Build's prompt history as the post-send witness reads it: the
/// complete lines appended since a send's mark, which name the session
/// that took each prompt.
@Suite("Grok Build prompt history witness")
struct GrokPromptHistoryWitnessTests {
    private static let bound = "01900000-0000-7000-8000-000000000004"
    private static let other = "01900000-0000-7000-8000-000000000054"
    private static let third = "01900000-0000-7000-8000-000000000055"
    private static let group = "/home/dev/.grok/sessions/%2Fhome%2Fdev%2Fproj"
    private static let transcript = "\(group)/\(bound)/updates.jsonl"
    private static let history = "\(group)/prompt_history.jsonl"

    /// One line as Grok's serde writes it.
    private static func line(_ prompt: String, session: String, isBash: Bool = false) throws -> String {
        let record: [String: Any] = [
            "timestamp": "2026-10-20T03:00:00.000Z", "session_id": session, "prompt": prompt, "is_bash": isBash,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The verdict for `sent` once `appended` follows what the log held
    /// when the send's mark was taken.
    private static func verdict(
        _ sent: String, before: String = "", appended: String,
        witness: ChatSendWitness = GrokPromptHistoryWitness.witness
    ) async throws -> ChatSendWitnessVerdict {
        let files = VirtualHostFiles()
        if !before.isEmpty { await files.write(before, at: history) }
        let mark = try #require(try await witness.mark(forTranscript: transcript, files: files.hostFiles()))
        await files.append(appended, to: history)
        let read = try #require(try await witness.appended(since: mark, files: files.hostFiles()))
        return witness.verdict(
            lines: read.lines, key: GrokTranscriptReducer.echoKey(sent), sessionID: bound,
            isWholeAppend: read.isWholeAppend, echoKey: GrokTranscriptReducer.echoKey)
    }

    @Test func aLineNamingAnotherSessionIsElsewhere() async throws {
        let before = try Self.line("Reply with exactly the word pong.", session: Self.bound)
        let appended = try Self.line("Summarize the README", session: Self.third)
            + Self.line("Reply with the word kiwi.", session: Self.other)

        #expect(try await Self.verdict("Reply with the word kiwi. ", before: before, appended: appended) == .elsewhere)
    }

    /// The same text sent to two sessions: one of them is this one.
    @Test func aLineNamingThisSessionWins() async throws {
        let appended = try Self.line("Reply with the word kiwi.", session: Self.other)
            + Self.line("Reply with the word kiwi.", session: Self.bound)

        #expect(try await Self.verdict("Reply with the word kiwi. ", appended: appended) == .here)
    }

    @Test func twoOtherLinesWithTheTextSayNothing() async throws {
        let appended = try Self.line("Reply with the word kiwi.", session: Self.other)
            + Self.line("Reply with the word kiwi.", session: Self.third)

        #expect(try await Self.verdict("Reply with the word kiwi. ", appended: appended) == .unknown)
    }

    /// More was appended than one read takes: the lines past it may name
    /// this session.
    @Test func aTruncatedReadNeverSaysElsewhere() async throws {
        let appended = try Self.line("Reply with the word kiwi.", session: Self.other)
            + Self.line("Reply with the word kiwi.", session: Self.bound)
        var witness = GrokPromptHistoryWitness.witness
        witness.readLimit = try Self.line("Reply with the word kiwi.", session: Self.other).utf8.count + 10

        #expect(try await Self.verdict("Reply with the word kiwi. ", appended: appended, witness: witness) == .unknown)
        // The other line alone, cut short of a second one, says no more.
        let alone = try Self.line("Reply with the word kiwi.", session: Self.other)
            + Self.line("Summarize the README", session: Self.third)
        #expect(try await Self.verdict("Reply with the word kiwi. ", appended: alone, witness: witness) == .unknown)
    }

    /// The mark falls between lines: the send's line starts right at it,
    /// whether the log already held lines or did not exist yet.
    @Test func theSendsOwnLineRightAfterTheMarkCounts() async throws {
        let own = try Self.line("Reply with the word kiwi.", session: Self.other)
        let before = try Self.line("Reply with exactly the word pong.", session: Self.bound)

        #expect(try await Self.verdict("Reply with the word kiwi. ", before: before, appended: own) == .elsewhere)
        #expect(try await Self.verdict("Reply with the word kiwi. ", appended: own) == .elsewhere)
    }

    /// A stat taken while Grok was writing a line: what follows the mark
    /// up to the next newline belongs to that earlier line.
    @Test func aMarkThatSplitALineDropsTheFragment() throws {
        let split = Data(#"ADME"}"#.utf8) + Data("\n{\"a\":1}\n{\"b\":2}\n".utf8)
        let between = Data("\n{\"a\":1}\n".utf8)

        let first = Data(#"{"a":1}"#.utf8)
        let second = Data(#"{"b":2}"#.utf8)

        #expect(ChatSendWitness.completeLines(split, startsBeforeMark: true) == [first, second])
        #expect(ChatSendWitness.completeLines(between, startsBeforeMark: true) == [first])
        #expect(ChatSendWitness.completeLines(first + Data("\n".utf8), startsBeforeMark: false) == [first])
    }

    /// Grok may still be writing the send's line.
    @Test func aTrailingPartialLineIsIgnored() async throws {
        let own = try Self.line("Reply with the word kiwi.", session: Self.other)

        #expect(try await Self.verdict("Reply with the word kiwi. ", appended: String(own.dropLast())) == .unknown)
        #expect(ChatSendWitness.completeLines(Data(own.dropLast().utf8), startsBeforeMark: false).isEmpty)
    }

    /// `!command` lines record a shell command typed in Grok.
    @Test func shellLinesAreSkipped() async throws {
        let appended = try Self.line("ls", session: Self.other, isBash: true)

        #expect(try await Self.verdict("ls", appended: appended) == .unknown)
        #expect(GrokPromptHistoryWitness.witness.entry(Data(appended.utf8)) == nil)
    }

    /// Grok records the text without the space Chat adds, and a paste's
    /// line ends as the transcript does.
    @Test func comparesWithTheEchoKey() async throws {
        let kiwi = try Self.line("Reply with the word kiwi.", session: Self.other)
        let pasted = try Self.line("First line\nsecond line", session: Self.other)

        #expect(try await Self.verdict("Reply with the word kiwi. ", appended: kiwi) == .elsewhere)
        #expect(try await Self.verdict("First line\r\nsecond line ", appended: pasted) == .elsewhere)
        #expect(try await Self.verdict("Reply with the word kiwi, please. ", appended: kiwi) == .unknown)
    }

    @Test func logPathIsTheGroupsPromptHistory() {
        #expect(GrokPromptHistoryWitness.witness.logPath(Self.transcript) == Self.history)
    }
}
