import Foundation
import Testing

@testable import Heeler

/// Decoder tests for the compact binary Pairing Code v2 envelope, built
/// byte-by-byte from the wire-format table (magic "HP", version 0x02, flags,
/// port, username, digest, optional bootstrap, addresses). The shared-vector
/// suite below covers the cross-implementation file once it exists.
@Suite("Pairing Code v2 envelope")
struct PairingCodeV2Tests {
    /// The digest behind the v1 vectors' fingerprint, so both envelope
    /// versions are checked against the same display string.
    static let digestBytes = [UInt8](
        Data(base64Encoded: "6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg=")!)
    static let fingerprint = "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg"

    @Test func decodesConfigOnlyEnvelope() throws {
        let code = try PairingCode.decodeV2(Envelope().data)

        #expect(code.addresses == ["192.168.1.42"])
        #expect(code.port == 22)
        #expect(code.username == "ada")
        #expect(code.hostKeyFingerprint.displayString == Self.fingerprint)
        #expect(code.bootstrap == nil)
    }

    @Test func decodesBootstrapEnvelope() throws {
        var envelope = Envelope()
        envelope.flags = 0x01
        envelope.bootstrap = (seed: (0...31).map { UInt8($0) }, expiresAt: 1_753_305_600)

        let code = try PairingCode.decodeV2(envelope.data)

        let bootstrap = try #require(code.bootstrap)
        #expect(bootstrap.seed == Data((0...31).map { UInt8($0) }))
        #expect(bootstrap.expiresAt == Date(timeIntervalSince1970: 1_753_305_600))
    }

    @Test func decodesEveryAddressKindInTryOrder() throws {
        var envelope = Envelope()
        envelope.addresses = [
            [0x04, 192, 168, 1, 42],
            [0x06, 0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01],
            [0x00, 16] + Array("mac-studio.local".utf8),
        ]

        let code = try PairingCode.decodeV2(envelope.data)

        #expect(code.addresses == ["192.168.1.42", "fd7a:115c:a1e0::1", "mac-studio.local"])
    }

    @Test(arguments: [
        (Array(repeating: UInt8(0), count: 15) + [1], "::1"),
        (
            [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1] as [UInt8],
            "2001:db8::1:0:0:1"
        ),
        (
            [0x20, 0x01, 0x0D, 0xB8, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6] as [UInt8],
            "2001:db8:1:2:3:4:5:6"
        ),
        // RFC 5952 §4.2.2: an isolated zero group must not become "::".
        (
            [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1] as [UInt8],
            "2001:db8:0:1:1:1:1:1"
        ),
    ])
    func canonicalizesIPv6(raw: [UInt8], expected: String) throws {
        var envelope = Envelope()
        envelope.addresses = [[0x06] + raw]

        #expect(try PairingCode.decodeV2(envelope.data).addresses == [expected])
    }

    @Test func acceptsMaximumPort() throws {
        var envelope = Envelope()
        envelope.port = 65535

        #expect(try PairingCode.decodeV2(envelope.data).port == 65535)
    }

    /// A byte-mode payload surfaced as text is one Unicode scalar per byte
    /// (the Latin-1 reading); recovering it must reproduce the exact bytes.
    @Test func roundTripsThroughTheScannedStringPath() throws {
        var envelope = Envelope()
        envelope.flags = 0x01
        envelope.bootstrap = (seed: (0...31).map { UInt8($0) }, expiresAt: 1_753_305_600)
        let data = envelope.data

        let viaString = try PairingCode.decodeScanned(latin1String(data))

        #expect(viaString == (try PairingCode.decodeV2(data)))
    }

    @Test func rejectsScannedStringWithScalarAboveLatin1() {
        #expect(throws: PairingCodeError.badEncoding) {
            try PairingCode.decodeScanned("HP\u{02}\u{0102}")
        }
    }

    @Test func scannedStringWithoutMagicTakesTheV1Path() {
        #expect(throws: PairingCodeError.badPrefix) {
            try PairingCode.decodeScanned("https://example.com/some-other-qr")
        }
    }

    struct RejectCase: Sendable, CustomStringConvertible {
        let name: String
        let data: Data
        let wireCode: String
        var description: String { name }
    }

    static let rejectCases: [RejectCase] = {
        var cases: [RejectCase] = []
        func add(_ name: String, _ wireCode: String, _ mutate: (inout Envelope) -> Void) {
            var envelope = Envelope()
            mutate(&envelope)
            cases.append(RejectCase(name: name, data: envelope.data, wireCode: wireCode))
        }
        add("wrong magic", "bad_prefix") { $0.magic = [0x51, 0x52] }
        add("version 1", "unsupported_version") { $0.version = 0x01 }
        add("version 3", "unsupported_version") { $0.version = 0x03 }
        add("reserved flag bit", "bad_encoding") { $0.flags = 0x02 }
        add("reserved flag bit alongside bootstrap", "bad_encoding") { envelope in
            envelope.flags = 0x81
            envelope.bootstrap = (seed: Array(repeating: 0, count: 32), expiresAt: 1)
        }
        add("bootstrap expiry zero", "bad_payload") { envelope in
            envelope.flags = 0x01
            envelope.bootstrap = (seed: (0...31).map { UInt8($0) }, expiresAt: 0)
        }
        add("port zero", "bad_payload") { $0.port = 0 }
        add("username length zero", "bad_payload") { envelope in
            envelope.username = []
            envelope.usernameLength = 0
        }
        add("username is not UTF-8", "bad_encoding") { $0.username = [0xC3, 0x28, 0x41] }
        add("username contains whitespace", "bad_payload") { $0.username = [0x61, 0x20, 0x62] }
        add("declared username length overruns the envelope", "bad_encoding") {
            $0.usernameLength = 200
        }
        add("address count zero", "bad_payload") { envelope in
            envelope.addresses = []
            envelope.addressCount = 0
        }
        add("address count overruns the envelope", "bad_encoding") { $0.addressCount = 3 }
        add("unknown address type", "bad_encoding") { $0.addresses = [[0x07, 1, 2, 3, 4]] }
        add("hostname length zero", "bad_payload") { $0.addresses = [[0x00, 0x00]] }
        add("hostname is not UTF-8", "bad_encoding") { $0.addresses = [[0x00, 2, 0xC3, 0x28]] }
        add("hostname contains whitespace", "bad_payload") {
            $0.addresses = [[0x00, 3] + Array("a b".utf8)]
        }
        add("trailing bytes", "bad_encoding") { $0.trailing = [0x00] }
        return cases
    }()

    @Test(arguments: rejectCases)
    func rejects(testCase: RejectCase) {
        do {
            _ = try PairingCode.decodeV2(testCase.data)
            Issue.record("unexpectedly decoded \(testCase.name)")
        } catch {
            #expect(error.wireCode == testCase.wireCode, "\(testCase.name)")
        }
    }

    /// Every proper prefix of a valid envelope is truncated input. The
    /// decoder reads strictly front to back, so each cut must surface as
    /// `badEncoding`, never a misleading field error or a successful decode.
    @Test func rejectsEveryTruncation() {
        var envelope = Envelope()
        envelope.flags = 0x01
        envelope.bootstrap = (seed: (0...31).map { UInt8($0) }, expiresAt: 1_753_305_600)
        envelope.addresses = [
            [0x04, 10, 0, 0, 7],
            [0x00, 5] + Array("studio".utf8.prefix(5)),
        ]
        let data = envelope.data

        for length in 0..<data.count {
            #expect(throws: PairingCodeError.badEncoding, "cut at \(length)") {
                try PairingCode.decodeV2(data.prefix(length))
            }
        }
    }

    @Test func reportsTheFoundVersion() {
        var envelope = Envelope()
        envelope.version = 0x07
        do {
            _ = try PairingCode.decodeV2(envelope.data)
            Issue.record("unexpectedly decoded a version-7 envelope")
        } catch {
            #expect(error == .unsupportedVersion(found: "7"))
        }
    }

    // MARK: Scan-entry dispatch

    static let v1Code = PairingCodeVectorFile.shared.valid[0].code

    @Test func dispatchesV1StringsToTheV1Decoder() throws {
        let viaDispatch = try PairingCode.decodeScanned(
            ScannedQRCode(string: Self.v1Code, bytes: nil))

        #expect(viaDispatch == (try PairingCode.decode(Self.v1Code)))
    }

    @Test func dispatchesV2BytesToTheV2Decoder() throws {
        let data = Envelope().data

        let viaDispatch = try PairingCode.decodeScanned(ScannedQRCode(string: nil, bytes: data))

        #expect(viaDispatch == (try PairingCode.decodeV2(data)))
    }

    /// When Vision surfaces both a (lossy) string and descriptor-recovered
    /// bytes for a binary payload, the bytes win.
    @Test func prefersBytesOverANonV1String() throws {
        let data = Envelope().data

        let viaDispatch = try PairingCode.decodeScanned(
            ScannedQRCode(string: "HP\u{02}mangled", bytes: data))

        #expect(viaDispatch == (try PairingCode.decodeV2(data)))
    }

    @Test func dispatchesV1TextArrivingAsBytes() throws {
        let viaBytes = try PairingCode.decodeScannedBytes(Data(Self.v1Code.utf8))

        #expect(viaBytes == (try PairingCode.decode(Self.v1Code)))
    }

    @Test func rejectsBytesThatAreNeitherEnvelope() {
        #expect(throws: PairingCodeError.badPrefix) {
            try PairingCode.decodeScannedBytes(Data([0xFF, 0xFE, 0x00]))
        }
    }

    @Test func rejectsAnEmptyScan() {
        #expect(throws: PairingCodeError.badPrefix) {
            try PairingCode.decodeScanned(ScannedQRCode(string: nil, bytes: nil))
        }
    }
}

/// Builds v2 envelopes from the wire-format table, with each field
/// overridable to produce the invalid shapes.
private struct Envelope {
    var magic: [UInt8] = PairingCode.v2Magic
    var version: UInt8 = PairingCode.v2Version
    var flags: UInt8 = 0x00
    var port: UInt16 = 22
    var username: [UInt8] = Array("ada".utf8)
    /// Overrides the length byte; nil derives it from `username`.
    var usernameLength: UInt8?
    var digest: [UInt8] = PairingCodeV2Tests.digestBytes
    var bootstrap: (seed: [UInt8], expiresAt: UInt32)?
    /// Overrides the count byte; nil derives it from `addresses`.
    var addressCount: UInt8?
    var addresses: [[UInt8]] = [[0x04, 192, 168, 1, 42]]
    var trailing: [UInt8] = []

    var data: Data {
        var bytes = magic
        bytes.append(version)
        bytes.append(flags)
        bytes.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
        bytes.append(usernameLength ?? UInt8(username.count))
        bytes.append(contentsOf: username)
        bytes.append(contentsOf: digest)
        if let bootstrap {
            bytes.append(contentsOf: bootstrap.seed)
            for shift in stride(from: 24, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: bootstrap.expiresAt >> shift))
            }
        }
        bytes.append(addressCount ?? UInt8(addresses.count))
        for address in addresses {
            bytes.append(contentsOf: address)
        }
        bytes.append(contentsOf: trailing)
        return Data(bytes)
    }
}

/// The byte-per-scalar string a Latin-1 reading of a byte-mode QR payload
/// produces.
private func latin1String(_ data: Data) -> String {
    var view = String.UnicodeScalarView()
    for byte in data {
        view.append(Unicode.Scalar(byte))
    }
    return String(view)
}

/// Fixtures captured from Vision on macOS 26.5: real
/// `CIQRCodeDescriptor.errorCorrectedPayload` streams (byte-identical to
/// `VNBarcodeObservation.payloadData`) for QR codes generated from known
/// payloads, so the segment walk is checked against what the scanner
/// actually hands over, padding and all.
@Suite("QR code content extraction")
struct QRCodeContentTests {
    @Test func extractsASingleByteModeSegment() {
        // 9 binary bytes incl. NULs, version-1 symbol.
        let stream = Data(hexEncoded: "40948500200001600017f0ec11ec11ec11ec11")!

        let bytes = QRCodeContent.segmentBytes(errorCorrectedPayload: stream, symbolVersion: 1)

        #expect(bytes == Data(hexEncoded: "48500200001600017f"))
    }

    @Test func extractsAFullV2Envelope() {
        // An 84-byte bootstrap envelope, version-5 symbol.
        let stream = Data(
            hexEncoded: "45448500201001603616461ebe8e770d7626ec1b672abdfa0b0291ab3bc0af2300"
                + "04333b01f888a53acf2d8000102030405060708090a0b0c0d0e0f10111213141516"
                + "1718191a1b1c1d1e1f688230800104c0a8012a0ec11ec11ec11ec11ec11ec11ec11"
                + "ec11ec11ec11ec11")!

        let bytes = QRCodeContent.segmentBytes(errorCorrectedPayload: stream, symbolVersion: 5)

        #expect(
            bytes
                == Data(
                    hexEncoded: "48500201001603616461ebe8e770d7626ec1b672abdfa0b0291ab3bc0af230"
                        + "004333b01f888a53acf2d8000102030405060708090a0b0c0d0e0f101112131415"
                        + "161718191a1b1c1d1e1f688230800104c0a8012a"))
    }

    @Test func extractsMixedAlphanumericAndByteSegments() {
        // CoreImage split this v1-style ASCII envelope into alphanumeric and
        // byte segments; the walk must reassemble the original text.
        let text = "HERDR-PAIR:1:eyJhZGRycyI6WyIxOTIuMTY4LjEuNDIiXSwicG9ydCI6MjIsInVzZXIiOiJhZGEi"
            + "LCJmcCI6IlNIQTI1Njo2K2puY05kaWJzRzJjcXZmb0xBcEdyTzhDdklBQUVNenNCK0lpbE9zOHRnIn0"
        let stream = Data(
            hexEncoded: "206b0b9993a237b45f7b6247b2bca5342d23a93cb1bca49b2bbca4bc27aa24baa6"
                + "aa2c9a263522baa72224b4ac29bbb4b1a39cbcb221a49b26b524b9a4b72b3d2d2c24b4a7"
                + "b4a5342d23a2b4a621a536b1a1a49b24b62724a8aa2498a73537992599383aac981ab5b0"
                + "aba53d293d253531ac2d36b1183c2131a2b23caa3d34223235b62128aaab2732b72721a5"
                + "98363831229cbd27a4293724b71800")!

        let bytes = QRCodeContent.segmentBytes(errorCorrectedPayload: stream, symbolVersion: 7)

        #expect(bytes == Data(text.utf8))
    }

    @Test func extractsNumericSegmentsInAVersion10PlusSymbol() {
        // A 304-byte payload in a version-11 symbol (16-bit byte counts);
        // CoreImage carved digit runs into numeric segments.
        var expected = Data([0x48, 0x50, 0x02, 0x00])
        expected.append(contentsOf: (0..<300).map { UInt8(truncatingIfNeeded: $0 % 251 + 1) })
        let stream = Data(
            hexEncoded: "40033485002000102030405060708090a0b0c0d0e0f101112131415161718191a1"
                + "b1c1d1e1f202122232425262728292a2b2c2d2e2f100a03159a9a50001ce8ecf0f4f8fd"
                + "0080d1cd452a1570b3d732fd628cada13596e0e1d400d25b5c5d5e5f60616263646566"
                + "6768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a"
                + "8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadae"
                + "afb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2"
                + "d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6"
                + "f7f8f9fafb0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
                + "202122232425262728292a2b2c2d2e2f30310ec11ec11ec11ec11ec11ec11ec11ec11ec1"
                + "1ec11ec11")!

        let bytes = QRCodeContent.segmentBytes(errorCorrectedPayload: stream, symbolVersion: 11)

        #expect(bytes == expected)
    }

    @Test func refusesSegmentKindsItCannotDecode() {
        // ECI (0111) leading the stream: bail out rather than misread.
        #expect(
            QRCodeContent.segmentBytes(
                errorCorrectedPayload: Data([0x71, 0xA4, 0x00]), symbolVersion: 1) == nil)
    }

    @Test func refusesAnEmptyStream() {
        #expect(
            QRCodeContent.segmentBytes(errorCorrectedPayload: Data([0x00, 0xEC]), symbolVersion: 1)
                == nil)
    }
}

/// The cross-implementation v2 vectors, mirroring the v1 arrangement. The
/// file is produced by the plugin package; until it lands on an integrated
/// branch these tests skip.
@Suite(
    "Pairing Code v2 shared vectors",
    .enabled(if: PairingCodeV2VectorFile.shared != nil))
struct PairingCodeV2VectorTests {
    private static let vectors = PairingCodeV2VectorFile.shared

    @Test func sharedVectorFileHasCases() {
        #expect((Self.vectors?.valid.count ?? 0) >= 1)
        #expect((Self.vectors?.invalid.count ?? 0) >= 1)
    }

    @Test(arguments: vectors?.valid ?? [])
    func decodesValidVector(vector: PairingCodeV2VectorFile.Valid) throws {
        let data = try #require(Data(hexEncoded: vector.envelopeHex), "envelopeHex must be hex")

        let code = try PairingCode.decodeV2(data)

        #expect(code.addresses == vector.payload.addresses)
        #expect(code.port == vector.payload.port)
        #expect(code.username == vector.payload.username)
        #expect(code.hostKeyFingerprint.displayString == vector.payload.hostKeyFingerprint)
        if let expectedSeed = vector.payload.bootstrapSeed {
            let bootstrap = try #require(code.bootstrap)
            #expect(bootstrap.seed.base64URLEncodedString() == expectedSeed)
            let expectedExpiry = try #require(vector.payload.expiresAt)
            #expect(
                bootstrap.expiresAt == Date(timeIntervalSince1970: TimeInterval(expectedExpiry)))
        } else {
            #expect(code.bootstrap == nil)
        }

        // The same envelope surfaced as a Latin-1 string must decode
        // identically through the scan dispatch.
        #expect(try PairingCode.decodeScanned(latin1String(data)) == code)
    }

    @Test(arguments: vectors?.invalid ?? [])
    func rejectsInvalidVector(vector: PairingCodeV2VectorFile.Invalid) throws {
        do {
            if let envelopeHex = vector.envelopeHex {
                let data = try #require(Data(hexEncoded: envelopeHex), "envelopeHex must be hex")
                _ = try PairingCode.decodeV2(data)
            } else {
                let code = try #require(vector.code, "invalid vector carries neither form")
                _ = try PairingCode.decodeScanned(code)
            }
            Issue.record("unexpectedly decoded \(vector.name)")
        } catch let error as PairingCodeError {
            #expect(error.wireCode == vector.error, "\(vector.name)")
        }
    }
}
