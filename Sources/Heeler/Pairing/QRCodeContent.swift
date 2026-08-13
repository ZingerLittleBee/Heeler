import Foundation

/// Recovers the exact data content of a QR symbol from its error-corrected
/// codeword stream — `CIQRCodeDescriptor.errorCorrectedPayload`, which
/// `VNBarcodeObservation.payloadData` returns byte-identical (verified
/// empirically against Vision on this OS generation). The stream is the
/// ISO/IEC 18004 data codewords: a sequence of (mode, count, content)
/// segments, then a terminator and pad bytes. This is the only faithful way
/// to read a binary byte-mode payload, because Vision's decoded string drops
/// or mangles bytes that are not clean UTF-8 text (see the dispatch note in
/// `PairingCodeV2.swift`).
enum QRCodeContent {
    /// The concatenated content of all data segments, or nil when the stream
    /// contains a segment kind we do not decode (ECI, kanji, structured
    /// append, FNC1) or is malformed. Callers treat nil as "not recoverable
    /// here" and fall back to the decoded string.
    static func segmentBytes(errorCorrectedPayload: Data, symbolVersion: Int) -> Data? {
        guard symbolVersion >= 1 else { return nil }
        var reader = BitReader(errorCorrectedPayload)
        var content = Data()
        // A stream that fills the symbol exactly may omit the 4-bit
        // terminator, so running out of bits between segments is a clean end.
        while let mode = reader.read(4), mode != 0b0000 {
            switch mode {
            case 0b0100:  // byte: 8 bits per byte
                guard let count = reader.read(symbolVersion <= 9 ? 8 : 16) else { return nil }
                for _ in 0..<count {
                    guard let byte = reader.read(8) else { return nil }
                    content.append(UInt8(byte))
                }
            case 0b0001:  // numeric: 3 digits per 10 bits
                let countBits = symbolVersion <= 9 ? 10 : symbolVersion <= 26 ? 12 : 14
                guard var remaining = reader.read(countBits) else { return nil }
                while remaining > 0 {
                    let digits = min(remaining, 3)
                    guard
                        let value = reader.read([4, 7, 10][digits - 1]),
                        value < [10, 100, 1000][digits - 1]
                    else { return nil }
                    var text = String(value)
                    text = String(repeating: "0", count: digits - text.count) + text
                    content.append(contentsOf: text.utf8)
                    remaining -= digits
                }
            case 0b0010:  // alphanumeric: 2 characters per 11 bits
                let countBits = symbolVersion <= 9 ? 9 : symbolVersion <= 26 ? 11 : 13
                guard var remaining = reader.read(countBits) else { return nil }
                while remaining > 0 {
                    let characters = min(remaining, 2)
                    guard
                        let value = reader.read(characters == 2 ? 11 : 6),
                        value < (characters == 2 ? 45 * 45 : 45)
                    else { return nil }
                    if characters == 2 {
                        content.append(alphanumeric[value / 45])
                    }
                    content.append(alphanumeric[value % 45])
                    remaining -= characters
                }
            default:
                return nil
            }
        }
        return content.isEmpty ? nil : content
    }

    /// The 45-character alphanumeric-mode table (ISO/IEC 18004 §7.4.4).
    private static let alphanumeric = [UInt8]("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)

    private struct BitReader {
        private let bytes: [UInt8]
        private var bitIndex = 0

        init(_ data: Data) {
            bytes = [UInt8](data)
        }

        mutating func read(_ width: Int) -> Int? {
            guard bitIndex + width <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<width {
                value = (value << 1) | Int((bytes[bitIndex / 8] >> (7 - bitIndex % 8)) & 1)
                bitIndex += 1
            }
            return value
        }
    }
}
