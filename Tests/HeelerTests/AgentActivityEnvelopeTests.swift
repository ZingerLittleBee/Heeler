import Foundation
import Testing

@testable import Heeler

/// Open and seal tests for the Live Activity details envelope v1, driven by
/// the shared vectors in `plugin/test-vectors/live-activity-content-v1.json`.
/// Non-`decodeOnly` valid vectors must seal byte-for-byte; every valid
/// vector must open; invalid vectors (including the cross-AAD case) must
/// fail with the given typed error.
@Suite("Agent activity envelope")
struct AgentActivityEnvelopeTests {
    private static let vectors = LiveActivityVectorFile.shared

    @Test func sharedVectorFileHasCases() {
        #expect(Self.vectors.valid.count >= 4)
        #expect(Self.vectors.invalid.count >= 5)
        #expect(Self.vectors.valid.contains { $0.decodeOnly })
        #expect(
            Self.vectors.invalid.contains {
                $0.error == "decrypt_failed" && $0.name.contains("domain separation")
            })
    }

    @Test(arguments: vectors.valid)
    func opensValidVector(vector: LiveActivityVectorFile.Valid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))

        let details = try AgentActivityEnvelope.open(Data(vector.envelope.utf8), using: key)

        #expect(details.hostName == vector.payload.host)
        #expect(details.agents.count == vector.payload.agents.count)
        for (got, expected) in zip(details.agents, vector.payload.agents) {
            #expect(got.paneID == expected.pane)
            #expect(got.kind == expected.kind)
            #expect(got.status == expected.status)
            #expect(got.title == expected.title)
        }
    }

    @Test(arguments: vectors.valid)
    func derivesKeyID(vector: LiveActivityVectorFile.Valid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        #expect(AgentActivityEnvelope.keyID(for: key) == vector.keyId)
    }

    @Test(arguments: vectors.valid.filter { !$0.decodeOnly })
    func sealsValidVectorByteForByte(vector: LiveActivityVectorFile.Valid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        let nonce = try nonce(in: vector.envelope)
        let details = AgentActivityDetails(
            hostName: vector.payload.host,
            agents: vector.payload.agents.map {
                AgentActivityDetails.AgentDetail(
                    paneID: $0.pane, kind: $0.kind, status: $0.status, title: $0.title)
            })

        let sealed = try AgentActivityEnvelope.seal(details, using: key, nonce: nonce)

        #expect(String(data: sealed, encoding: .utf8) == vector.envelope, "\(vector.name)")
    }

    @Test(arguments: vectors.invalid)
    func rejectsInvalidVector(vector: LiveActivityVectorFile.Invalid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        do {
            _ = try AgentActivityEnvelope.open(Data(vector.envelope.utf8), using: key)
            Issue.record("unexpectedly opened \(vector.name)")
        } catch {
            #expect(error.wireCode == vector.error, "\(vector.name)")
        }
    }

    private func nonce(in envelope: String) throws -> Data {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        let text = try #require(object["n"] as? String)
        return try #require(Data(base64URLEncoded: text))
    }
}
