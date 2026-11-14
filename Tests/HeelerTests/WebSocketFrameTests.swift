import Foundation
import Testing

@testable import Heeler

@Suite struct WebSocketFrameTests {
    private static func bytes(_ hex: String) -> Data {
        Data(hex.split(separator: " ").compactMap { UInt8($0, radix: 16) })
    }

    /// Everything a client-side reader hands up for `chunks`, and the
    /// violation it stopped at, if any.
    private static func read(
        _ chunks: [Data], maximumMessageBytes: Int = 1 << 20
    ) -> (inbound: [WebSocketInbound], violation: WebSocketViolation?) {
        var reader = WebSocketMessageReader(maximumMessageBytes: maximumMessageBytes)
        var inbound: [WebSocketInbound] = []
        do throws(WebSocketViolation) {
            for chunk in chunks {
                reader.append(chunk)
                while let next = try reader.next() { inbound.append(next) }
            }
        } catch {
            return (inbound, error)
        }
        return (inbound, nil)
    }

    private static func violation(_ stream: Data, maximumMessageBytes: Int = 1 << 20) -> WebSocketViolation? {
        read([stream], maximumMessageBytes: maximumMessageBytes).violation
    }

    // MARK: RFC 6455 section 5.7

    @Test func readsTheUnmaskedSingleFrameTextExample() {
        let result = Self.read([Self.bytes("81 05 48 65 6c 6c 6f")])
        #expect(result.inbound == [.message(.text("Hello"))])
        #expect(result.violation == nil)
    }

    @Test func masksTheSingleFrameTextExampleWithItsKey() throws {
        let encoded = WebSocketFrame(opcode: .text, payload: Data("Hello".utf8)).encoded(maskKey: 0x37fa_213d)
        #expect(encoded == Self.bytes("81 85 37 fa 21 3d 7f 9f 4d 51 58"))

        var server = WebSocketFrameDecoder(role: .server)
        server.append(encoded)
        let frame = try #require(try server.next(payloadLimit: 1024))
        #expect(frame.payload == Data("Hello".utf8))
        #expect(frame.maskKey == 0x37fa_213d)
    }

    @Test func joinsTheFragmentedTextExample() {
        let result = Self.read([Self.bytes("01 03 48 65 6c"), Self.bytes("80 02 6c 6f")])
        #expect(result.inbound == [.message(.text("Hello"))])
    }

    @Test func readsThePingExampleAndMasksItsPong() {
        #expect(Self.read([Self.bytes("89 05 48 65 6c 6c 6f")]).inbound == [.ping(Data("Hello".utf8))])
        let pong = WebSocketFrame(opcode: .pong, payload: Data("Hello".utf8)).encoded(maskKey: 0x37fa_213d)
        #expect(pong == Self.bytes("8a 85 37 fa 21 3d 7f 9f 4d 51 58"))
    }

    @Test func encodesAndReadsThe256ByteBinaryExample() {
        let payload = Data((0..<256).map { UInt8(truncatingIfNeeded: $0) })
        let encoded = WebSocketFrame(opcode: .binary, payload: payload).encoded(maskKey: nil)
        #expect(encoded.prefix(4) == Self.bytes("82 7e 01 00"))
        #expect(encoded.count == 4 + 256)
        #expect(Self.read([encoded]).inbound == [.message(.binary(payload))])
    }

    @Test func encodesAndReadsThe64KiBBinaryExample() {
        let payload = Data(repeating: 0x5a, count: 65536)
        let encoded = WebSocketFrame(opcode: .binary, payload: payload).encoded(maskKey: nil)
        #expect(encoded.prefix(10) == Self.bytes("82 7f 00 00 00 00 00 01 00 00"))
        #expect(encoded.count == 10 + 65536)
        #expect(Self.read([encoded]).inbound == [.message(.binary(payload))])
    }

    // MARK: Splits

    /// A stream that touches every path: a fragmented text with a ping
    /// between its fragments, a 16-bit length, a pong, and a close.
    private static let mixedStream: Data = {
        var stream = Data()
        stream += WebSocketFrame(opcode: .text, payload: Data("caf".utf8), isFinal: false).encoded(maskKey: nil)
        stream += WebSocketFrame(opcode: .ping, payload: Data("p1".utf8)).encoded(maskKey: nil)
        // "é" split across fragments: neither half is UTF-8 on its own.
        stream += WebSocketFrame(opcode: .continuation, payload: Data([0xC3]), isFinal: false).encoded(maskKey: nil)
        stream += WebSocketFrame(opcode: .continuation, payload: Data([0xA9, 0x21])).encoded(maskKey: nil)
        stream += WebSocketFrame(opcode: .binary, payload: Data(repeating: 7, count: 300)).encoded(maskKey: nil)
        stream += WebSocketFrame(opcode: .pong, payload: Data()).encoded(maskKey: nil)
        stream += WebSocketFrame.close(WebSocketCloseCode(rawValue: 4000), reason: "block closed").encoded(maskKey: nil)
        return stream
    }()

    @Test func anySplitReadsTheSameAsTheWholeStream() {
        let whole = Self.read([Self.mixedStream])
        #expect(whole.violation == nil)
        #expect(
            whole.inbound == [
                .ping(Data("p1".utf8)), .message(.text("café!")),
                .message(.binary(Data(repeating: 7, count: 300))), .pong(Data()),
                .close(WebSocketClose(code: WebSocketCloseCode(rawValue: 4000), reason: "block closed")),
            ])
        for offset in 0...Self.mixedStream.count {
            let split = Self.read([Self.mixedStream.prefix(offset), Self.mixedStream.dropFirst(offset)].map { Data($0) })
            #expect(split.inbound == whole.inbound, "split at \(offset)")
            #expect(split.violation == nil, "split at \(offset)")
        }
        let byteByByte = Self.read(Self.mixedStream.map { Data([$0]) })
        #expect(byteByByte.inbound == whole.inbound)
    }

    @Test func anySplitStopsAtTheSameViolation() {
        let stream =
            WebSocketFrame(opcode: .text, payload: Data("ok".utf8)).encoded(maskKey: nil)
            + Self.bytes("c1 02 68 69")  // RSV1 with no extension
        let whole = Self.read([stream])
        #expect(whole.inbound == [.message(.text("ok"))])
        #expect(whole.violation == .reservedBitsSet)
        for offset in 0...stream.count {
            let split = Self.read([stream.prefix(offset), stream.dropFirst(offset)].map { Data($0) })
            #expect(split.inbound == whole.inbound, "split at \(offset)")
            #expect(split.violation == whole.violation, "split at \(offset)")
        }
    }

    // MARK: Violations

    @Test func failsAMaskedServerFrame() {
        let masked = WebSocketFrame(opcode: .text, payload: Data("hi".utf8)).encoded(maskKey: 1)
        #expect(Self.violation(masked) == .maskedServerFrame)
        #expect(WebSocketViolation.maskedServerFrame.closeCode == .protocolError)
    }

    @Test func failsAnUnmaskedClientFrameOnTheServerSide() {
        var server = WebSocketFrameDecoder(role: .server)
        server.append(Self.bytes("81 02 68 69"))
        #expect(throws: WebSocketViolation.unmaskedClientFrame) { try server.next(payloadLimit: 1024) }
    }

    @Test(arguments: ["c1 00", "a1 00", "91 00"])
    func failsEveryReservedBit(header: String) {
        #expect(Self.violation(Self.bytes(header)) == .reservedBitsSet)
    }

    @Test func failsAnUnknownOpcode() {
        #expect(Self.violation(Self.bytes("83 00")) == .unknownOpcode)
        #expect(Self.violation(Self.bytes("8b 00")) == .unknownOpcode)
    }

    @Test func failsAnOversizedControlFrameFromItsHeader() {
        // A 126-byte ping, judged before any payload arrives.
        #expect(Self.violation(Self.bytes("89 7e 00 7e")) == .oversizedControlFrame)
        let largest = WebSocketFrame(opcode: .ping, payload: Data(repeating: 1, count: 125)).encoded(maskKey: nil)
        #expect(Self.read([largest]).inbound == [.ping(Data(repeating: 1, count: 125))])
    }

    @Test func failsAFragmentedControlFrame() {
        #expect(Self.violation(Self.bytes("09 00")) == .fragmentedControlFrame)
    }

    @Test func failsAnOversizedMessageBeforeItsPayloadArrives() {
        // The header alone declares 2000 bytes.
        let header = Self.bytes("82 7e 07 d0")
        #expect(Self.violation(header, maximumMessageBytes: 1000) == .messageTooBig)
        #expect(WebSocketViolation.messageTooBig.closeCode == .messageTooBig)

        let fragments =
            WebSocketFrame(opcode: .binary, payload: Data(count: 600), isFinal: false).encoded(maskKey: nil)
            + WebSocketFrame(opcode: .continuation, payload: Data(count: 600)).encoded(maskKey: nil)
        #expect(Self.violation(fragments, maximumMessageBytes: 1000) == .messageTooBig)
        #expect(Self.violation(fragments, maximumMessageBytes: 1200) == nil)
    }

    @Test func failsALengthWithItsTopBitSet() {
        #expect(Self.violation(Self.bytes("82 7f 80 00 00 00 00 00 00 01")) == .invalidLength)
    }

    @Test func failsTextThatIsNotUTF8() {
        let invalid = WebSocketFrame(opcode: .text, payload: Data([0x68, 0xC3, 0x28])).encoded(maskKey: nil)
        #expect(Self.violation(invalid) == .invalidUTF8)
        #expect(WebSocketViolation.invalidUTF8.closeCode == .invalidPayload)
        let binary = WebSocketFrame(opcode: .binary, payload: Data([0xC3, 0x28])).encoded(maskKey: nil)
        #expect(Self.read([binary]).inbound == [.message(.binary(Data([0xC3, 0x28])))])
    }

    @Test func failsFragmentsOutOfOrder() {
        #expect(Self.violation(Self.bytes("80 01 61")) == .unexpectedContinuation)
        #expect(Self.violation(Self.bytes("01 01 61 81 01 62")) == .expectedContinuation)
    }

    @Test func readsAndChecksCloseFrames() {
        #expect(Self.read([Self.bytes("88 00")]).inbound == [.close(WebSocketClose(code: .noStatusReceived))])
        #expect(Self.violation(Self.bytes("88 01 03")) == .malformedClosePayload)
        // 1005 and 999 never go in a close frame; 1013 and 4000 may.
        #expect(Self.violation(Self.bytes("88 02 03 ed")) == .invalidCloseCode)
        #expect(Self.violation(Self.bytes("88 02 03 e7")) == .invalidCloseCode)
        #expect(Self.read([Self.bytes("88 02 03 f5")]).inbound == [.close(WebSocketClose(code: .tryAgainLater))])
        #expect(Self.violation(Self.bytes("88 04 0f a0 c3 28")) == .invalidUTF8)
    }

    @Test func cutsALongCloseReasonAtACharacterBoundary() throws {
        let reason = String(repeating: "é", count: 100)
        let frame = WebSocketFrame.close(.goingAway, reason: reason)
        #expect(frame.payload.count == 2 + 122)
        let close = try WebSocketClose(payload: frame.payload)
        #expect(close == WebSocketClose(code: .goingAway, reason: String(repeating: "é", count: 61)))
        #expect(WebSocketFrame.close(nil).payload.isEmpty)
    }
}
