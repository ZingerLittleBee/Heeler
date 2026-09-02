import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Attach user message index")
struct AttachUserMessageIndexTests {
    @Test func assemblesALineAcrossChunksIncludingAUTF8BoundarySplit() {
        let index = AttachUserMessageIndex()
        let text = "请实现这个解析器功能"
        let bytes = Array(text.utf8)
        #expect(bytes.count > 4)

        index.observeOutgoing(Data(bytes.prefix(1)))
        #expect(index.entries.isEmpty)
        index.observeOutgoing(Data(bytes.dropFirst(1).dropLast(2)))
        index.observeOutgoing(Data(bytes.suffix(2)))
        #expect(index.entries.isEmpty)

        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == [text])
    }

    @Test func assemblesASCIIAcrossSeveralChunksThenCloses() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(Data("implement ".utf8))
        index.observeOutgoing(Data("the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test(arguments: [UInt8(0x7F), UInt8(0x08)])
    func backspaceRemovesTheLastCharacterBeforeSubmit(_ backspace: UInt8) {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please implement the parserx".utf8))
        index.observeOutgoing(Data([backspace]))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func backspaceEditsAChineseCharacterNotItsUTF8Bytes() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("请实现这个解析器功错".utf8))
        index.observeOutgoing(Data([0x7F]))
        index.observeOutgoing(Data("能".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["请实现这个解析器功能"])
    }

    @Test(arguments: [
        Data([0x1B, 0x5B, 0x44]),
        Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x43]),
        Data([0x1B, 0x4F, 0x41]),
    ])
    func controlSequencesDoNotLandInTheIndexedText(_ sequence: Data) throws {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(sequence)
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        let raw = try #require(index.entries.first).rawText
        #expect(raw == "please implement the parser")
        #expect(!raw.contains("\u{1B}"))
    }

    @Test func aCSISequenceSplitAcrossChunksIsStillSkipped() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(Data([0x1B]))
        index.observeOutgoing(Data([0x5B, 0x44]))
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func csiIntermediateBytesAreSkipped() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        // CSI 2 SP q (DECSCUSR): SP is an intermediate byte (0x20).
        index.observeOutgoing(Data([0x1B, 0x5B, 0x32, 0x20, 0x71]))
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func anSS3SequenceSplitAfterEscapeIsStillSkipped() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(Data([0x1B]))
        index.observeOutgoing(Data([0x4F, 0x41]))
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func anSS3SequenceSplitAfterTheIntroducerIsStillSkipped() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(Data([0x1B, 0x4F]))
        index.observeOutgoing(Data([0x41]))
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test(arguments: [UInt8(0x0D), UInt8(0x0A)])
    func carriageReturnAndLineFeedBothCloseALine(_ terminator: UInt8) {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please implement the parser".utf8))
        index.observeOutgoing(Data([terminator]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func aComposerInsertedMultilineDraftIsOneEntryAtSubmit() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(
            Data("please approve\nthen continue".utf8),
            source: .composerInsert)
        #expect(index.entries.isEmpty)
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please approve\nthen continue"])
    }

    @Test(arguments: [
        "",
        "   ",
        "\t\t",
        "ok",
        "y",
        "1234567",
    ])
    func rejectsEmptyAndShortLines(_ text: String) {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data(text.utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.isEmpty)
    }

    @Test func acceptsALineAtTheMinimumCharacterCount() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("12345678".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["12345678"])
    }

    @Test func crlfClosesOnce() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please implement the parser\r\n".utf8))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test(arguments: [
        ("❯ please implement the parser", "please implement the parser"),
        ("› please implement the parser", "please implement the parser"),
        ("> please implement the parser", "please implement the parser"),
        ("▎ please implement the parser", "please implement the parser"),
        ("  please implement the parser", "please implement the parser"),
        ("│ please implement the parser", "please implement the parser"),
        ("▎❯ please implement the parser", "please implement the parser"),
    ])
    func normalizeStripsLeadingPromptAndBoxGlyphs(_ input: String, _ expected: String) {
        #expect(AttachUserMessageIndex.normalize(input) == expected)
    }

    @Test func normalizeJoinsASoftWrappedBoxSoItMatchesTheTypedLine() {
        let typed = "please implement the parser for user messages"
        let frame = """
            ▎ please implement the
            ▎ parser for user messages
            """
        #expect(AttachUserMessageIndex.normalize(frame) == typed)

        let index = AttachUserMessageIndex()
        index.record(submitted: typed)
        #expect(index.frameContainsMessage(frame))
    }

    @Test func frameContainsMessageIsFalseWhenTheFrameHasNoIndexedText() {
        let index = AttachUserMessageIndex()
        index.record(submitted: "please implement the parser")
        #expect(
            !index.frameContainsMessage(
                "the agent is thinking about a completely different topic"))
    }

    @Test func frameContainsMessageIsTrueWhenTheAgentQuotesTheUser() {
        let index = AttachUserMessageIndex()
        index.record(submitted: "please implement the parser")
        #expect(
            index.frameContainsMessage(
                "The user asked: please implement the parser\nI'll start there."))
    }

    @Test func frameContainsMessageMatchesABoundedPrefixOfALongEntry() {
        let long = String(repeating: "a", count: 120)
        let index = AttachUserMessageIndex()
        index.record(submitted: long)
        #expect(
            index.frameContainsMessage(
                String(repeating: "a", count: AttachUserMessageIndex.matchPrefixCharacterCount)))
        #expect(!index.frameContainsMessage(String(repeating: "b", count: 64)))
    }

    @Test func recordSubmittedIndexesComposerTextWithoutATerminator() {
        let index = AttachUserMessageIndex()
        index.record(submitted: "please implement the parser")
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
        #expect(index.entries.map(\.normalizedText) == ["please implement the parser"])
    }

    @Test func resetClearsEntriesAndPendingBytes() {
        let index = AttachUserMessageIndex()
        index.record(submitted: "please implement the parser")
        index.observeOutgoing(Data("leftover pending".utf8))
        index.reset()
        #expect(index.entries.isEmpty)

        index.observeOutgoing(Data("please implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func escapeCancelsAComposerInsertedPendingLine() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please approve".utf8), source: .composerInsert)
        index.observeOutgoing(Data([0x1B]), source: .escapeKey)
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.isEmpty)
    }

    @Test func escapeThenANewRequestDoesNotKeepComposerInsertedText() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please approve".utf8), source: .composerInsert)
        index.observeOutgoing(Data([0x1B]), source: .escapeKey)
        index.observeOutgoing(Data("new request".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["new request"])
    }

    @Test func escapeKeyThenABracketRequestDoesNotKeepComposerInsertedText() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please approve".utf8), source: .composerInsert)
        index.observeOutgoing(Data([0x1B]), source: .escapeKey)
        index.observeOutgoing(Data("[review] do it".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["[review] do it"])
    }

    @Test func keystrokeEscapePreservesPendingText() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please implement ".utf8))
        index.observeOutgoing(Data([0x1B]))
        index.observeOutgoing(Data("the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func capsEntriesByDroppingTheOldest() {
        let index = AttachUserMessageIndex()
        for i in 0...AttachUserMessageIndex.maximumEntryCount {
            let n = String(format: "%03d", i)
            index.record(submitted: "message number \(n) is long enough")
        }
        #expect(index.entries.count == AttachUserMessageIndex.maximumEntryCount)
        #expect(index.entries.first?.rawText == "message number 001 is long enough")
        #expect(index.entries.last?.rawText == "message number 200 is long enough")
    }
}
