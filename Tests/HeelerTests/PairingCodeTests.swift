import Foundation
import Testing

@testable import Heeler

/// Decoder tests for the Pairing Code envelope (#62, #380), driven by the
/// shared vectors in `plugin/test-vectors/pairing-code-v1.json` — the same
/// file the Node plugin tests consume, so the two implementations cannot
/// drift — and the app-only `pairing-code-v2.json` (ADR 0021).
@Suite("Pairing Code envelope")
struct PairingCodeTests {
    private static let vectors = PairingCodeVectorFile.shared
    private static let v2Vectors = PairingCodeVectorFile.v2

    /// Guards against silently loading an empty or truncated vector file;
    /// mirrors the same assertion in the Node suite.
    @Test func sharedVectorFileHasCases() {
        #expect(Self.vectors.valid.count >= 3)
        #expect(Self.vectors.invalid.count >= 10)
    }

    /// The same guard for the v2 file, which no Node suite reads.
    @Test func v2VectorFileHasCases() {
        #expect(Self.v2Vectors.valid.count >= 5)
        #expect(Self.v2Vectors.invalid.count >= 13)
    }

    @Test(arguments: vectors.valid)
    func decodesValidVector(vector: PairingCodeVectorFile.Valid) throws {
        let code = try PairingCode.decode(vector.code)

        try expectDecoded(code, matches: vector.payload)
        // Version 1 never carries a Herdr Endpoint.
        #expect(code.endpoint == nil)
    }

    @Test(arguments: vectors.invalid)
    func rejectsInvalidVector(vector: PairingCodeVectorFile.Invalid) {
        do {
            _ = try PairingCode.decode(vector.code)
            Issue.record("unexpectedly decoded \(vector.name)")
        } catch {
            #expect(error.wireCode == vector.error, "\(vector.name)")
        }
    }

    @Test(arguments: v2Vectors.valid)
    func decodesValidV2Vector(vector: PairingCodeVectorFile.Valid) throws {
        let code = try PairingCode.decode(vector.code)

        try expectDecoded(code, matches: vector.payload)
    }

    @Test(arguments: v2Vectors.invalid)
    func rejectsInvalidV2Vector(vector: PairingCodeVectorFile.Invalid) {
        do {
            _ = try PairingCode.decode(vector.code)
            Issue.record("unexpectedly decoded \(vector.name)")
        } catch {
            #expect(error.wireCode == vector.error, "\(vector.name)")
        }
    }

    /// Version 2 validates the v1 fields first, with the same reasons: a v1
    /// body with a broken port fails on the port under version 2 as well,
    /// not on its missing endpoint.
    @Test func v2ChecksTheV1FieldsFirstWithTheSameReasons() throws {
        let portZero = try #require(Self.vectors.invalid.first { $0.name == "port zero" })
        let v2Code = portZero.code.replacingOccurrences(
            of: "HERDR-PAIR:1:", with: "HERDR-PAIR:2:")
        #expect(v2Code != portZero.code)

        let v1Error = try #require(decodeError(portZero.code))
        #expect(decodeError(v2Code) == v1Error)
    }

    /// Checks a decoded code against a vector payload, including its Herdr
    /// Endpoint: none when the payload names no socket.
    private func expectDecoded(
        _ code: PairingCode, matches payload: PairingCodeVectorFile.Payload
    ) throws {
        #expect(code.addresses == payload.addresses)
        #expect(code.port == payload.port)
        #expect(code.username == payload.username)
        #expect(code.hostKeyFingerprint.displayString == payload.hostKeyFingerprint)

        if let expectedSeed = payload.bootstrapSeed {
            let bootstrap = try #require(code.bootstrap)
            #expect(bootstrap.seed.base64URLEncodedString() == expectedSeed)
            let expectedExpiry = try #require(payload.expiresAt)
            #expect(bootstrap.expiresAt == Date(timeIntervalSince1970: TimeInterval(expectedExpiry)))
        } else {
            #expect(code.bootstrap == nil)
        }

        if let expectedSocketPath = payload.socketPath {
            let endpoint = try #require(code.endpoint)
            #expect(endpoint.socketPath == expectedSocketPath)
            let expectedHerdrPath = try #require(payload.herdrPath)
            #expect(endpoint.executablePath == expectedHerdrPath)
        } else {
            #expect(payload.herdrPath == nil)
            #expect(code.endpoint == nil)
        }
    }

    private func decodeError(_ scanned: String) -> PairingCodeError? {
        do {
            _ = try PairingCode.decode(scanned)
            return nil
        } catch {
            return error
        }
    }
}
