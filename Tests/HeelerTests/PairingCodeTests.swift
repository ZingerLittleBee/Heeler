import Foundation
import Testing

@testable import Heeler

/// Decoder tests for the Pairing Code v1 envelope (#62), driven by the shared
/// vectors in `plugin/test-vectors/pairing-code-v1.json` — the same file the
/// Node plugin tests consume, so the two implementations cannot drift.
@Suite("Pairing Code envelope")
struct PairingCodeTests {
    private static let vectors = PairingCodeVectorFile.shared

    /// Guards against silently loading an empty or truncated vector file;
    /// mirrors the same assertion in the Node suite.
    @Test func sharedVectorFileHasCases() {
        #expect(Self.vectors.valid.count >= 3)
        #expect(Self.vectors.invalid.count >= 10)
    }

    @Test(arguments: vectors.valid)
    func decodesValidVector(vector: PairingCodeVectorFile.Valid) throws {
        let code = try PairingCode.decode(vector.code)

        #expect(code.addresses == vector.payload.addresses)
        #expect(code.port == vector.payload.port)
        #expect(code.username == vector.payload.username)
        #expect(code.hostKeyFingerprint.displayString == vector.payload.hostKeyFingerprint)

        if let expectedSeed = vector.payload.bootstrapSeed {
            let bootstrap = try #require(code.bootstrap)
            #expect(bootstrap.seed.base64URLEncodedString() == expectedSeed)
            let expectedExpiry = try #require(vector.payload.expiresAt)
            #expect(bootstrap.expiresAt == Date(timeIntervalSince1970: TimeInterval(expectedExpiry)))
        } else {
            #expect(code.bootstrap == nil)
        }
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
}
