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

    @Test func relevanceScoreRanksBlockedHostsFirstThenTheMostRecentUpdate() {
        typealias Counts = AgentActivityAttributes.ContentState.Counts
        let earlier = Date(timeIntervalSince1970: 1_800_000_000.75)
        let later = earlier.addingTimeInterval(60)

        #expect(Counts(working: 0, blocked: 0, done: 0).relevanceScore(at: later) == 0)
        #expect(Counts(working: 0, blocked: 0, done: 1).relevanceScore(at: earlier) == 1_800_000_000)

        let olderBlocked = Counts(working: 0, blocked: 1, done: 0).relevanceScore(at: earlier)
        let newerBlocked = Counts(working: 999, blocked: 1, done: 999).relevanceScore(at: later)
        let newestWorking = Counts(working: 3, blocked: 0, done: 0)
            .relevanceScore(at: later.addingTimeInterval(86_400 * 365 * 100))
        let newerDone = Counts(working: 0, blocked: 0, done: 1).relevanceScore(at: later)
        let olderWorking = Counts(working: 999, blocked: 0, done: 999).relevanceScore(at: earlier)

        #expect(newerBlocked > olderBlocked)
        #expect(olderBlocked > newestWorking)
        #expect(newerDone > olderWorking)
    }

    @Test func updatesThatKeepTheCountsKeepTheirScore() {
        typealias Counts = AgentActivityAttributes.ContentState.Counts
        let pushed = Counts(working: 2, blocked: 0, done: 1)
        let reopened = Date(timeIntervalSince1970: 1_800_000_600)

        #expect(pushed.relevanceScore(at: reopened, replacing: (pushed, 1_800_000_000)) == 1_800_000_000)
        #expect(Counts(working: 1, blocked: 0, done: 2)
            .relevanceScore(at: reopened, replacing: (pushed, 1_800_000_000)) == 1_800_000_600)
        #expect(pushed.relevanceScore(at: reopened, replacing: nil) == 1_800_000_600)
    }
}
