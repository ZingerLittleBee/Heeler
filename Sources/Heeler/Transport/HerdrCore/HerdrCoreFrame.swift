import Foundation

enum HerdrCoreFrameKind: UInt8, Sendable {
    case data = 0
    case credit = 1
    case close = 2
    case resize = 3
    case focus = 4
    case facts = 5
}

enum HerdrCoreFrameError: Error, Equatable {
    case oversized(length: Int)
    case invalidPayload(kind: HerdrCoreFrameKind, length: Int)
    case invalidGeometry(columns: Int, rows: Int)
}

/// One frame of herdr-core's framed mode: channel (u32 LE), kind (u8), length
/// (u32 LE), payload.
struct HerdrCoreFrame: Equatable, Sendable {
    static let headerLength = 9
    static let maximumPayload = 16 * 1024 * 1024
    /// The credit a stream starts with before the client returns any.
    static let initialCredit = 256 * 1024

    let channel: UInt32
    let kind: HerdrCoreFrameKind
    let payload: Data

    init(channel: UInt32, kind: HerdrCoreFrameKind, payload: Data = Data()) {
        self.channel = channel
        self.kind = kind
        self.payload = payload
    }

    static func credit(channel: UInt32, bytes: UInt32) -> HerdrCoreFrame {
        HerdrCoreFrame(channel: channel, kind: .credit, payload: littleEndian(bytes))
    }

    static func resize(channel: UInt32, columns: Int, rows: Int) throws -> HerdrCoreFrame {
        guard let columnsSide = UInt16(exactly: columns), let rowsSide = UInt16(exactly: rows),
            columnsSide >= 1, rowsSide >= 1
        else { throw HerdrCoreFrameError.invalidGeometry(columns: columns, rows: rows) }
        return HerdrCoreFrame(
            channel: channel, kind: .resize,
            payload: littleEndian(columnsSide) + littleEndian(rowsSide))
    }

    func encoded() throws -> Data {
        guard payload.count <= Self.maximumPayload else {
            throw HerdrCoreFrameError.oversized(length: payload.count)
        }
        if kind == .credit || kind == .resize, payload.count != 4 {
            throw HerdrCoreFrameError.invalidPayload(kind: kind, length: payload.count)
        }
        var bytes = Data(capacity: Self.headerLength + payload.count)
        bytes.append(Self.littleEndian(channel))
        bytes.append(kind.rawValue)
        bytes.append(Self.littleEndian(UInt32(payload.count)))
        bytes.append(payload)
        return bytes
    }

    private static func littleEndian<Value: FixedWidthInteger>(_ value: Value) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

/// Splits a byte stream into frames. A header announcing more than the limit
/// is refused as soon as it is complete, before any of its payload is kept,
/// and the refusal sticks: nothing after it can be trusted to be a frame.
struct HerdrCoreFrameDecoder {
    private var buffer: Data
    private var head = 0
    private var failure: HerdrCoreFrameError?

    /// `leftover` is what followed the plain `hello` line in the same read.
    init(leftover: Data = Data()) {
        buffer = leftover
    }

    var bufferedByteCount: Int { buffer.count - head }

    /// The plain `hello` reply line, without its newline, and the bytes after it.
    static func splitHelloLine(_ bytes: Data) -> (line: Data, rest: Data)? {
        guard let newline = bytes.firstIndex(of: 0x0A) else { return nil }
        return (
            bytes.subdata(in: bytes.startIndex..<newline),
            bytes.subdata(in: (newline + 1)..<bytes.endIndex)
        )
    }

    mutating func append(_ bytes: Data) {
        guard failure == nil else { return }
        buffer.append(bytes)
    }

    /// The next complete frame of a known kind, or nil until more bytes arrive.
    /// Frames of unknown kinds are skipped.
    mutating func next() throws -> HerdrCoreFrame? {
        if let failure { throw failure }
        while bufferedByteCount >= HerdrCoreFrame.headerLength {
            let base = buffer.startIndex + head
            let length = Int(littleEndianUInt32(at: base + 5))
            guard length <= HerdrCoreFrame.maximumPayload else {
                buffer = Data()
                head = 0
                let refusal = HerdrCoreFrameError.oversized(length: length)
                failure = refusal
                throw refusal
            }
            let frameLength = HerdrCoreFrame.headerLength + length
            guard bufferedByteCount >= frameLength else { break }
            let channel = littleEndianUInt32(at: base)
            let kind = HerdrCoreFrameKind(rawValue: buffer[base + 4])
            let payload = buffer.subdata(in: (base + HerdrCoreFrame.headerLength)..<(base + frameLength))
            head += frameLength
            if let kind {
                return HerdrCoreFrame(channel: channel, kind: kind, payload: payload)
            }
        }
        if head > 0 {
            buffer = buffer.subdata(in: (buffer.startIndex + head)..<buffer.endIndex)
            head = 0
        }
        return nil
    }

    private func littleEndianUInt32(at index: Data.Index) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, offset in
            value | UInt32(buffer[index + offset]) << UInt32(8 * offset)
        }
    }
}
