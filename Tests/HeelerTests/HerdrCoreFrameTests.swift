import Foundation
import Testing

@testable import Heeler

@Suite struct HerdrCoreFrameTests {
    @Test func aFrameEncodesItsHeaderLittleEndian() throws {
        let frame = HerdrCoreFrame(channel: 0x0102_0304, kind: .data, payload: Data("hi".utf8))
        // A known-good literal: channel 04 03 02 01, kind 00, length 02 00 00 00.
        #expect(try frame.encoded() == Data([4, 3, 2, 1, 0, 2, 0, 0, 0, 0x68, 0x69]))
    }

    @Test func framesRoundTripForEveryKind() throws {
        let frames: [HerdrCoreFrame] = [
            HerdrCoreFrame(channel: 0, kind: .data, payload: Data("{}".utf8)),
            HerdrCoreFrame.credit(channel: 7, bytes: 256 * 1024),
            HerdrCoreFrame(channel: 7, kind: .close),
            try HerdrCoreFrame.resize(channel: 9, columns: 80, rows: 24),
            HerdrCoreFrame(channel: 9, kind: .focus, payload: Data([1])),
            HerdrCoreFrame(channel: 9, kind: .facts, payload: Data(##"{"fg":"#ffffff"}"##.utf8)),
        ]
        var decoder = HerdrCoreFrameDecoder()
        for frame in frames {
            decoder.append(try frame.encoded())
            #expect(try decoder.next() == frame)
        }
        #expect(try decoder.next() == nil)
    }

    @Test func aHeaderAnnouncingMoreThanTheLimitIsRefusedBeforeItsPayloadArrives() throws {
        var header = Data([1, 0, 0, 0, 0])
        // One byte over 16 MiB, and only the header has arrived.
        header.append(contentsOf: [0x01, 0x00, 0x00, 0x01])
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(header)
        #expect(throws: HerdrCoreFrameError.oversized(length: 16 * 1024 * 1024 + 1)) { try decoder.next() }
        // The refusal sticks, and later bytes are not kept behind it.
        decoder.append(Data(repeating: 0, count: 1024))
        #expect(decoder.bufferedByteCount == 0)
        #expect(throws: HerdrCoreFrameError.oversized(length: 16 * 1024 * 1024 + 1)) { try decoder.next() }
    }

    @Test func aFrameOfExactlyTheLimitPasses() throws {
        let payload = Data(repeating: 0x41, count: 16 * 1024 * 1024)
        let frame = HerdrCoreFrame(channel: 1, kind: .data, payload: payload)
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(try frame.encoded())
        #expect(try decoder.next() == frame)
    }

    @Test func aPayloadOverTheLimitIsRefusedOnEncode() {
        let frame = HerdrCoreFrame(channel: 1, kind: .data, payload: Data(count: 16 * 1024 * 1024 + 1))
        #expect(throws: HerdrCoreFrameError.oversized(length: 16 * 1024 * 1024 + 1)) { try frame.encoded() }
    }

    @Test func inputSplitAtEveryByteDecodesTheSameFrames() throws {
        let frames = [
            HerdrCoreFrame(channel: 0, kind: .data, payload: Data("{\"id\":\"1\"}".utf8)),
            HerdrCoreFrame(channel: 3, kind: .close),
            HerdrCoreFrame.credit(channel: 3, bytes: 16),
        ]
        let bytes = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        for split in 0...bytes.count {
            var decoder = HerdrCoreFrameDecoder()
            var decoded: [HerdrCoreFrame] = []
            for part in [bytes.prefix(split), bytes.dropFirst(split)] {
                decoder.append(Data(part))
                while let frame = try decoder.next() { decoded.append(frame) }
            }
            #expect(decoded == frames, "split at \(split)")
        }
        var decoder = HerdrCoreFrameDecoder()
        var decoded: [HerdrCoreFrame] = []
        for byte in bytes {
            decoder.append(Data([byte]))
            while let frame = try decoder.next() { decoded.append(frame) }
        }
        #expect(decoded == frames)
    }

    @Test func manyFramesInOneChunkAllDecodeInOrder() throws {
        let frames = (0..<500).map { HerdrCoreFrame.credit(channel: UInt32($0), bytes: UInt32($0)) }
        let bytes = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(bytes)
        var decoded: [HerdrCoreFrame] = []
        while let frame = try decoder.next() { decoded.append(frame) }
        #expect(decoded == frames)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func theHelloReplyLineAndTheFirstFrameCanArriveInOneRead() throws {
        let line = Data(#"{"jsonrpc":"2.0","id":"hello","result":{}}"#.utf8)
        let frame = HerdrCoreFrame(channel: 1, kind: .data, payload: Data("early".utf8))
        let read = line + Data([0x0A]) + (try frame.encoded())
        let split = try #require(HerdrCoreFrameDecoder.splitHelloLine(read))
        #expect(split.line == line)
        var decoder = HerdrCoreFrameDecoder(leftover: split.rest)
        #expect(try decoder.next() == frame)
        #expect(HerdrCoreFrameDecoder.splitHelloLine(line) == nil)
    }

    @Test func creditAndResizePayloadsThatAreNotFourBytesAreRejectedOnEncode() {
        for count in [0, 3, 5] {
            for kind in [HerdrCoreFrameKind.credit, .resize] {
                let frame = HerdrCoreFrame(channel: 1, kind: kind, payload: Data(count: count))
                #expect(throws: HerdrCoreFrameError.invalidPayload(kind: kind, length: count)) {
                    try frame.encoded()
                }
            }
        }
    }

    @Test func creditAndResizeEncodeLittleEndianPayloads() throws {
        #expect(HerdrCoreFrame.credit(channel: 1, bytes: 0x0403_0201).payload == Data([1, 2, 3, 4]))
        #expect(try HerdrCoreFrame.resize(channel: 1, columns: 0x0102, rows: 0x0304).payload == Data([2, 1, 4, 3]))
    }

    @Test func aResizeSideOutsideItsRangeIsRefused() throws {
        for (columns, rows) in [(0, 24), (80, 0), (-1, 24), (80, -1), (65536, 24), (80, 65536)] {
            #expect(throws: HerdrCoreFrameError.invalidGeometry(columns: columns, rows: rows)) {
                try HerdrCoreFrame.resize(channel: 1, columns: columns, rows: rows)
            }
        }
        _ = try HerdrCoreFrame.resize(channel: 1, columns: 1, rows: 1)
        _ = try HerdrCoreFrame.resize(channel: 1, columns: 65535, rows: 65535)
    }

    @Test func unknownKindsAreSkippedWithTheirPayload() throws {
        var bytes = Data([5, 0, 0, 0, 200, 2, 0, 0, 0, 0xAA, 0xBB])
        let known = HerdrCoreFrame(channel: 5, kind: .close)
        bytes.append(try known.encoded())
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(bytes)
        #expect(try decoder.next() == known)
        #expect(try decoder.next() == nil)
    }

    @Test func anUnknownKindStillCountsAgainstTheLimit() {
        let header = Data([5, 0, 0, 0, 200, 0x01, 0x00, 0x00, 0x01])
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(header)
        #expect(throws: HerdrCoreFrameError.oversized(length: 16 * 1024 * 1024 + 1)) { try decoder.next() }
    }

    @Test func payloadsAreIndependentlyIndexableFromZero() throws {
        let frames = [
            HerdrCoreFrame(channel: 0, kind: .data, payload: Data("first".utf8)),
            HerdrCoreFrame(channel: 0, kind: .data, payload: Data("second".utf8)),
        ]
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(try frames.reduce(into: Data()) { $0.append(try $1.encoded()) })
        _ = try decoder.next()
        let second = try #require(try decoder.next())
        #expect(second.payload.startIndex == 0)
        #expect(second.payload[0] == 0x73)
    }
}
