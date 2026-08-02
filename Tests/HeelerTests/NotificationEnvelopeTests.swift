import Foundation
import Testing

@testable import Heeler

/// Decrypt-direction tests for the notification envelope v1 (#69), driven by
/// the shared vectors in `plugin/test-vectors/notification-payload-v1.json` —
/// the same file the Node plugin tests consume for the encrypt direction, so
/// the two implementations cannot drift.
@Suite("Notification envelope")
struct NotificationEnvelopeTests {
    private static let vectors = NotificationVectorFile.shared

    /// Guards against silently loading an empty or truncated vector file;
    /// mirrors the same assertion in the Node suite.
    @Test func sharedVectorFileHasCases() {
        #expect(Self.vectors.valid.count >= 3)
        #expect(Self.vectors.invalid.count >= 10)
        #expect(Self.vectors.invalid.contains { $0.error == "decrypt_failed" })
    }

    @Test(arguments: vectors.valid)
    func decryptsValidVector(vector: NotificationVectorFile.Valid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))

        let payload = try NotificationEnvelope.decrypt(
            Data(vector.envelope.utf8), using: key)

        #expect(payload.paneID == vector.payload.paneId)
        #expect(payload.agentKind == vector.payload.agentKind)
        #expect(payload.status.rawValue == vector.payload.status)
        #expect(
            payload.timestamp
                == Date(timeIntervalSince1970: TimeInterval(vector.payload.timestamp)))
        #expect(payload.project == vector.payload.project)
        #expect(payload.title == vector.payload.title)
    }

    /// The key id is derived, never stored: both ends must agree on the
    /// derivation or the extension cannot select the right Notification Key.
    @Test(arguments: vectors.valid)
    func derivesKeyID(vector: NotificationVectorFile.Valid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        #expect(NotificationEnvelope.keyID(for: key) == vector.keyId)
    }

    /// Undecryptable input of any shape must surface as a typed
    /// `NotificationEnvelopeError` (driving the generic-banner fallback),
    /// never as a crash or an untyped error.
    @Test(arguments: vectors.invalid)
    func rejectsInvalidVector(vector: NotificationVectorFile.Invalid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        do {
            _ = try NotificationEnvelope.decrypt(Data(vector.envelope.utf8), using: key)
            Issue.record("unexpectedly decrypted \(vector.name)")
        } catch {
            #expect(error.wireCode == vector.error, "\(vector.name)")
        }
    }
}
