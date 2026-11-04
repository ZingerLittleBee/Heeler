import Foundation
import Testing

@testable import Heeler

@Suite("Chat line framer")
struct ChatLineFramerTests {
    private static let sample = Data(
        """
        {"a":1}
        {"b":"é ünïcode"}

        {"c":[1,2,3]}

        """.utf8)

    private struct Split: Sendable, CustomTestStringConvertible {
        let size: Int
        var testDescription: String { "reads of \(size) bytes" }
    }

    @Test("Every read size yields the same lines", arguments: [1, 2, 3, 7, 64, 4096].map(Split.init))
    private func readSizeInvariance(split: Split) {
        let whole = JSONLLineFramer.lines(in: Self.sample)
        var framer = JSONLLineFramer(startOffset: 0)
        var lines: [ChatLine] = []
        for chunk in ChatFixture.chunks(Self.sample, size: split.size) {
            lines += framer.append(chunk)
        }
        #expect(lines == whole)
        #expect(framer.processedEnd == UInt64(Self.sample.count))
        #expect(framer.pendingByteCount == 0)
    }

    @Test("Lines carry their file offsets and skip empty lines")
    func offsets() {
        let lines = JSONLLineFramer.lines(in: Self.sample)
        #expect(lines.map(\.offset) == [0, 8, 30])
        #expect(lines.map { String(decoding: $0.data, as: UTF8.self) } == [
            #"{"a":1}"#, #"{"b":"é ünïcode"}"#, #"{"c":[1,2,3]}"#,
        ])
        #expect(lines.allSatisfy { !$0.isTruncated })
    }

    @Test("A partial last line waits for its newline")
    func partialLine() {
        var framer = JSONLLineFramer(startOffset: 100)
        #expect(framer.append(Data(#"{"a":1}"#.utf8) + Data("\n{\"b\"".utf8)).count == 1)
        #expect(framer.processedEnd == 108)
        #expect(framer.pendingByteCount == 4)
        let rest = framer.append(Data(":2}\n".utf8))
        #expect(rest == [ChatLine(offset: 108, data: Data(#"{"b":2}"#.utf8))])
        #expect(framer.processedEnd == 116)
    }

    @Test("A tail window skips its leading fragment, a head window does not")
    func leadingFragment() {
        var tail = JSONLLineFramer(startOffset: 5, dropsLeadingFragment: true)
        let lines = tail.append(Data("ment\"}\n{\"x\":1}\n".utf8))
        #expect(lines == [ChatLine(offset: 12, data: Data(#"{"x":1}"#.utf8))])

        var head = JSONLLineFramer(startOffset: 0, dropsLeadingFragment: true)
        #expect(head.append(Data("{\"x\":1}\n".utf8)).count == 1)
    }

    @Test("A line over the cap keeps only its prefix and its true length")
    func oversizedLine() {
        let big = Data(#"{"type":"response_item","payload":""#.utf8)
            + Data(repeating: UInt8(ascii: "x"), count: 5_000) + Data(#""}"#.utf8)
        let data = big + Data("\n".utf8) + Data(#"{"after":true}"#.utf8) + Data("\n".utf8)
        var framer = JSONLLineFramer(startOffset: 0, lineCap: 1_000, prefixCap: 64)
        var lines: [ChatLine] = []
        for chunk in ChatFixture.chunks(data, size: 333) {
            lines += framer.append(chunk)
        }
        #expect(lines.count == 2)
        #expect(lines[0].length == big.count)
        #expect(lines[0].data == big.prefix(64))
        #expect(lines[0].isTruncated)
        #expect(lines[1].offset == UInt64(big.count + 1))
        #expect(String(decoding: lines[1].data, as: UTF8.self) == #"{"after":true}"#)
    }

    @Test("Every split of a captured transcript yields its lines")
    func capturedTranscriptSplits() throws {
        let data = try ChatFixture.data("claude/probe2-transcript.jsonl")
        let whole = JSONLLineFramer.lines(in: data)
        #expect(whole.count == 166)
        let boundaries = whole.map { Int($0.offset) }
        for boundary in boundaries.prefix(40) {
            for offset in [boundary - 1, boundary, boundary + 1] {
                var framer = JSONLLineFramer(startOffset: 0)
                var lines: [ChatLine] = []
                for chunk in ChatFixture.chunks(data, splitAt: [offset]) {
                    lines += framer.append(chunk)
                }
                #expect(lines == whole)
            }
        }
    }
}
