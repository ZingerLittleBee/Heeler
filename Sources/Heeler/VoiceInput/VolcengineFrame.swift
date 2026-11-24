import Foundation

/// Volcengine's binary frames for streaming speech recognition
/// (https://docs.volcengine.com/docs/6561/1354869). A frame is a 4-byte
/// header (version and header size; message type and flags; serialization
/// and compression; a reserved byte), then big-endian fields: an optional
/// sequence number and event, the payload's length, and the payload. Heeler
/// compresses nothing, and the service answers uncompressed.
///
/// Every client frame carries a sequence number, though the docs' example
/// frame leaves it out, and the last audio frame sets flags `0b0011` with
/// its number negated. Checked against the official Python demo's
/// `protocol.py`.
enum VolcengineFrame {
    /// Version 1, with a header of one 4-byte word.
    private static let versionAndHeaderSize: UInt8 = 0x11
    private static let json: UInt8 = 0x1
    private static let raw: UInt8 = 0x0

    private enum Kind: UInt8 {
        case request = 0x1
        case audio = 0x2
        case result = 0x9
        case error = 0xF
    }

    /// Flag bits after the message type.
    private static let hasSequence: UInt8 = 0b0001
    private static let isLast: UInt8 = 0b0010
    private static let hasEvent: UInt8 = 0b0100

    /// The first frame: the request's JSON, numbered 1.
    static func request(_ body: Data) -> Data {
        frame(.request, flags: hasSequence, serialization: json, sequence: 1, payload: body)
    }

    /// Audio numbered `sequence`; the last frame negates it.
    static func audio(_ audio: Data, sequence: Int32, isLast last: Bool) -> Data {
        frame(
            .audio, flags: last ? hasSequence | isLast : hasSequence, serialization: raw,
            sequence: last ? -sequence : sequence, payload: audio)
    }

    /// What the service sent.
    enum Message: Equatable, Sendable {
        /// Everything heard so far; the last result ends the recognition.
        case result(VolcengineResult, isLast: Bool)
        case error(code: Int, message: String)
    }

    static func message(from data: Data) throws(VoiceTranscriptionError) -> Message {
        var reader = Reader(bytes: [UInt8](data))
        guard let header = reader.take(4), header[0] >> 4 == 1,
            let kind = Kind(rawValue: header[1] >> 4), header[2] & 0x0F == 0,
            reader.skip(Int(header[0] & 0x0F) * 4 - 4)
        else { throw .unreadableResponse }
        let flags = header[1] & 0x0F
        if flags & hasSequence != 0, reader.int32() == nil { throw .unreadableResponse }
        if flags & hasEvent != 0, reader.int32() == nil { throw .unreadableResponse }
        switch kind {
        case .result:
            guard let size = reader.int32(), let payload = reader.take(Int(UInt32(bitPattern: size)))
            else { throw .unreadableResponse }
            return .result(try VolcengineResult(json: Data(payload)), isLast: flags & isLast != 0)
        case .error:
            guard let code = reader.int32(), let size = reader.int32(),
                let payload = reader.take(Int(UInt32(bitPattern: size)))
            else { throw .unreadableResponse }
            return .error(
                code: Int(UInt32(bitPattern: code)),
                message: String(decoding: payload, as: UTF8.self))
        case .request, .audio:
            throw .unreadableResponse
        }
    }

    private static func frame(
        _ kind: Kind, flags: UInt8, serialization: UInt8, sequence: Int32, payload: Data
    ) -> Data {
        var data = Data([versionAndHeaderSize, kind.rawValue << 4 | flags, serialization << 4, 0])
        withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }

        mutating func skip(_ count: Int) -> Bool {
            take(count) != nil
        }

        mutating func int32() -> Int32? {
            take(4).map { $0.reduce(0) { $0 << 8 | Int32(truncatingIfNeeded: $1) } }
        }
    }
}

/// One result: the whole text so far and its sentences, each settled once
/// the service has heard its end.
struct VolcengineResult: Equatable, Sendable {
    struct Utterance: Decodable, Equatable, Sendable {
        let text: String
        let definite: Bool

        init(text: String, definite: Bool) {
            self.text = text
            self.definite = definite
        }

        /// A sentence still being heard may leave `definite` out.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            definite = try container.decodeIfPresent(Bool.self, forKey: .definite) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case text, definite
        }
    }

    var text = ""
    var utterances: [Utterance] = []

    /// The acknowledgement of the request carries no result.
    init(json: Data) throws(VoiceTranscriptionError) {
        guard !json.isEmpty else { return }
        guard let body = try? JSONDecoder().decode(Body.self, from: json) else { throw .unreadableResponse }
        text = body.result?.text ?? ""
        utterances = body.result?.utterances ?? []
    }

    init(text: String, utterances: [Utterance]) {
        self.text = text
        self.utterances = utterances
    }

    /// Leading settled sentences, then the rest, still being revised.
    var heard: VoiceHeard {
        let settled = utterances.prefix { $0.definite }
        return VoiceHeard(
            settled: settled.map(\.text).joined(),
            revising: utterances.dropFirst(settled.count).map(\.text).joined())
    }

    private struct Body: Decodable {
        struct Result: Decodable {
            let text: String?
            let utterances: [Utterance]?
        }

        let result: Result?
    }
}
