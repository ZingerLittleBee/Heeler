import Foundation
import Testing

@testable import Heeler

/// ContentState must decode the contract sample with a plain default
/// `JSONDecoder` — ActivityKit uses that decoder on the APNs update, and
/// any type mismatch drops the whole update.
@Suite("Agent activity ContentState")
struct AgentActivityContentStateTests {
    /// Exact sample from docs/agents/live-activity-contract.md.
    private static let contractJSON = """
        {"counts": {"working": 2, "blocked": 1, "done": 0},
         "envelope": {"v": 1, "kid": "Yw3NKWbEM2Y", "n": "AAECAwQFBgcICQoL", "ct": "PCC3fA"}}
        """

    @Test func decodesTheContractSampleWithTheDefaultDecoder() throws {
        let state = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: Data(Self.contractJSON.utf8))

        #expect(state.counts.working == 2)
        #expect(state.counts.blocked == 1)
        #expect(state.counts.done == 0)
        let envelope = try #require(state.envelope)
        #expect(envelope.v == 1)
        #expect(envelope.kid == "Yw3NKWbEM2Y")
        #expect(envelope.n == "AAECAwQFBgcICQoL")
        #expect(envelope.ct == "PCC3fA")
    }

    @Test func roundTripsThroughTheDefaultCoder() throws {
        let original = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: Data(Self.contractJSON.utf8))

        let decoded = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self,
            from: try JSONEncoder().encode(original))

        #expect(decoded == original)
    }

    @Test func absentEnvelopeDecodesAsNil() throws {
        let json = #"{"counts":{"working":0,"blocked":0,"done":1}}"#

        let state = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: Data(json.utf8))

        #expect(state.counts == .init(working: 0, blocked: 0, done: 1))
        #expect(state.envelope == nil)
    }
}
