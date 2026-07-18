import Foundation
import Testing

@testable import HerdrMobile

// Canonical event naming and subscription wire shapes: pure, no sshd. The
// kind list mirrors herdr 0.7.4's schema (26 subscribable kinds); event-line
// fixtures follow the snake_case spelling the live wire uses.
@Suite struct HerdrEventsTests {
    @Test func snakeCaseWireNamesMapToCanonicalDottedKinds() {
        #expect(HerdrEventKind(wireName: "pane_created") == GlobalEventKind.paneCreated.kind)
        #expect(
            HerdrEventKind(wireName: "workspace_metadata_updated")
                == GlobalEventKind.workspaceMetadataUpdated.kind)
        #expect(
            HerdrEventKind(wireName: "pane_agent_status_changed")
                == PaneEventKind.agentStatusChanged.kind)
    }

    @Test func everyKnownKindMapsFromItsSnakeCaseWireName() {
        for kind in HerdrEventKind.known {
            let snake = kind.name.replacingOccurrences(of: ".", with: "_")
            #expect(HerdrEventKind(wireName: snake) == kind)
        }
    }

    @Test func dottedWireNamesAreAcceptedToo() {
        // herdr's schema spells the typed event kinds dotted while the live
        // wire sends snake_case; both spellings land on one canonical kind.
        #expect(
            HerdrEventKind(wireName: "pane.agent_status_changed")
                == PaneEventKind.agentStatusChanged.kind)
    }

    @Test func unknownWireNamesPassThroughUnchanged() {
        // herdr's API has no stability guarantee: a kind we do not know keeps
        // its wire spelling instead of being guess-mangled.
        #expect(HerdrEventKind(wireName: "pane_haunted").name == "pane_haunted")
    }

    @Test func subscribeRequestLineUsesDottedTypesAndPaneIDs() throws {
        let line = try HerdrWire.subscribeRequestLine(
            id: "req-1",
            subscriptions: [
                .global(.paneCreated),
                .pane(.agentStatusChanged, paneID: "w1:p1"),
            ])

        #expect(line.hasSuffix("\n"))
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let envelope = try #require(object)
        #expect(envelope["id"] as? String == "req-1")
        #expect(envelope["method"] as? String == "events.subscribe")
        let params = try #require(envelope["params"] as? [String: Any])
        let subscriptions = try #require(params["subscriptions"] as? [[String: Any]])
        try #require(subscriptions.count == 2)
        #expect(subscriptions[0]["type"] as? String == "pane.created")
        #expect(subscriptions[0]["pane_id"] == nil)
        #expect(subscriptions[1]["type"] as? String == "pane.agent_status_changed")
        #expect(subscriptions[1]["pane_id"] as? String == "w1:p1")
    }

    @Test func eventLineDecodesToCanonicalKindAndPayload() {
        // Payload fields per the schema's PaneAgentStatusChangedEvent.
        let line =
            #"{"event":"pane_agent_status_changed","data":{"pane_id":"w3:pB","workspace_id":"w3","agent_status":"blocked","state_labels":{}}}"#

        let event = HerdrWire.decodeEvent(fromLine: Data(line.utf8))

        #expect(event?.kind == PaneEventKind.agentStatusChanged.kind)
        #expect(event?.data["pane_id"] == .string("w3:pB"))
        #expect(event?.data["agent_status"] == .string("blocked"))
    }

    @Test func eventLineWithUnknownKindStillDecodes() {
        let line = #"{"event":"pane_haunted","data":{"pane_id":"w1:p1"}}"#

        let event = HerdrWire.decodeEvent(fromLine: Data(line.utf8))

        #expect(event?.kind.name == "pane_haunted")
        #expect(event?.data["pane_id"] == .string("w1:p1"))
    }

    @Test func eventLineWithoutDataDecodesToNullPayload() {
        let event = HerdrWire.decodeEvent(fromLine: Data(#"{"event":"pane_created"}"#.utf8))

        #expect(event == HerdrEvent(kind: GlobalEventKind.paneCreated.kind, data: .null))
    }

    @Test func nonEventLinesDecodeToNil() {
        // Response envelopes, junk, and empty lines are not events; they are
        // dropped instead of killing the stream.
        let responseLine = #"{"id":"x","result":{"type":"subscription_started"}}"#

        #expect(HerdrWire.decodeEvent(fromLine: Data(responseLine.utf8)) == nil)
        #expect(HerdrWire.decodeEvent(fromLine: Data("not json".utf8)) == nil)
        #expect(HerdrWire.decodeEvent(fromLine: Data()) == nil)
    }
}
