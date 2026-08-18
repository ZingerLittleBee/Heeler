import Foundation
import Testing

@testable import Heeler

/// Decodes relay-assembled `content-state` bytes with the exact decoder
/// ActivityKit uses (default `JSONDecoder`), proving a pushed update cannot
/// be silently dropped by an OS-side decode mismatch.
@Suite("Relay content-state decode")
struct RelayContentStateDecodeTests {
    @Test func decodesRelayAssembledContentState() throws {
        // Written by the one-off Node script that reproduces the relay's
        // buildLiveActivityApnsBody splice; skip when absent.
        let url = URL(fileURLWithPath: "/tmp/relay-content-state.json")
        guard let data = try? Data(contentsOf: url) else { return }

        let state = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: data)

        #expect(state.counts.working == 9)
        #expect(state.counts.blocked == 1)
        let envelope = try #require(state.envelope)
        #expect(envelope.v == 1)
        #expect(!envelope.ct.isEmpty)
    }
}
