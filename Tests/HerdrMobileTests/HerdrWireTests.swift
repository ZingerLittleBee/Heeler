import Foundation
import Testing

@testable import HerdrMobile

// Pure wire-format tests: no sshd, no sockets. Response fixtures are captured
// verbatim from a live herdr 0.7.4 (protocol 16) server.
@Suite struct HerdrWireTests {
    @Test func requestLineHasEnvelopeShapeAndTrailingNewline() throws {
        let line = try HerdrWire.requestLine(id: "req-1", method: "agent.list")

        #expect(line.hasSuffix("\n"))
        #expect(!line.dropLast().contains("\n"))
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let envelope = try #require(object)
        #expect(envelope["id"] as? String == "req-1")
        #expect(envelope["method"] as? String == "agent.list")
        #expect((envelope["params"] as? [String: Any])?.isEmpty == true)
        #expect(envelope.count == 3)
    }

    @Test func pingResultDecodesLeniently() throws {
        // Live capture; "type" and "capabilities" are unknown fields to us.
        let line = #"{"id":"req-1","result":{"type":"pong","version":"0.7.4","protocol":16,"capabilities":{"live_handoff":true,"detached_server_daemon":true}}}"#

        let pong = try HerdrWire.decodeResult(
            PongResponse.self, fromResponseLine: Data(line.utf8), requestID: "req-1")

        #expect(pong.version == "0.7.4")
        #expect(pong.protocolVersion == 16)
    }

    @Test func agentListResponseMapsToDomainAgents() throws {
        // Live capture, trimmed to one agent; unknown fields left in place.
        let line = #"{"id":"req-1","result":{"type":"agent_list","agents":[{"terminal_id":"term_656c59f7b902d1e","agent":"codex","terminal_title":"✳ GoDrop","terminal_title_stripped":"GoDrop","agent_status":"working","workspace_id":"w3","tab_id":"w3:t2","pane_id":"w3:pB","focused":false,"cwd":"/Users/u/GoDrop","foreground_cwd":"/Users/u/GoDrop","revision":5}]}}"#

        let result = try HerdrWire.decodeResult(
            AgentListResponse.self, fromResponseLine: Data(line.utf8), requestID: "req-1")

        let expected = Agent(
            terminalID: "term_656c59f7b902d1e",
            kind: "codex",
            title: "GoDrop",
            status: .working,
            workspaceID: "w3",
            tabID: "w3:t2",
            paneID: "w3:pB",
            cwd: "/Users/u/GoDrop",
            revision: 5
        )
        #expect(result.agents.map(Agent.init) == [expected])
    }

    @Test func agentMappingDegradesMissingWireFields() throws {
        // herdr's API has no stability guarantee: nullable wire fields must
        // degrade in the domain mapping, never drop the Agent.
        let json = #"{"terminal_id":"t","agent_status":"haunted","workspace_id":"w","tab_id":"w:t","pane_id":"w:p","focused":false,"revision":0}"#

        let agent = Agent(try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8)))

        #expect(agent.kind == "unknown")
        #expect(agent.title == "")
        #expect(agent.cwd == "")
        // An unrecognized status survives with its raw value intact.
        #expect(agent.status == AgentStatus(rawValue: "haunted"))
    }

    @Test func agentMappingFallsBackToUnstrippedTitle() throws {
        let json = #"{"terminal_id":"t","agent":"claude","terminal_title":"⠐ Fix","agent_status":"working","workspace_id":"w","tab_id":"w:t","pane_id":"w:p","focused":true,"revision":1}"#

        let agent = Agent(try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8)))

        #expect(agent.title == "⠐ Fix")
    }

    @Test func errorEnvelopeThrowsHerdrAPIError() throws {
        let line = #"{"id":"req-1","error":{"code":404,"message":"no such method"}}"#

        #expect(throws: HerdrAPIError(code: "404", message: "no such method")) {
            try HerdrWire.decodeResult(
                PongResponse.self, fromResponseLine: Data(line.utf8), requestID: "req-1")
        }
    }

    @Test func stringErrorCodeIsAccepted() throws {
        let line = #"{"id":"req-1","error":{"code":"not_found","message":"gone"}}"#

        #expect(throws: HerdrAPIError(code: "not_found", message: "gone")) {
            try HerdrWire.decodeResult(
                PongResponse.self, fromResponseLine: Data(line.utf8), requestID: "req-1")
        }
    }

    @Test func errorEnvelopeWithBlankIDStillThrowsAPIError() throws {
        // Live capture: herdr answers a request it could not parse with
        // id "" — the error must surface, not an id-mismatch complaint.
        let line =
            #"{"id":"","error":{"code":"invalid_request","message":"invalid request: missing field `source` at line 1 column 123"}}"#

        #expect(
            throws: HerdrAPIError(
                code: "invalid_request",
                message: "invalid request: missing field `source` at line 1 column 123")
        ) {
            try HerdrWire.decodeResult(
                PongResponse.self, fromResponseLine: Data(line.utf8), requestID: "req-1")
        }
    }

    @Test func responseIDMismatchIsMalformed() throws {
        let line = #"{"id":"someone-else","result":{"version":"0.7.4","protocol":16}}"#

        #expect(throws: TransportError.self) {
            try HerdrWire.decodeResult(
                PongResponse.self, fromResponseLine: Data(line.utf8), requestID: "req-1")
        }
    }

    @Test func missingResultAndErrorIsMalformed() throws {
        let line = #"{"id":"req-1"}"#

        #expect(throws: TransportError.self) {
            try HerdrWire.decodeResult(
                PongResponse.self, fromResponseLine: Data(line.utf8), requestID: "req-1")
        }
    }

    @Test func nonJSONResponseIsMalformed() throws {
        let line = "2026/07/18 socat[123] E connect(): No such file or directory"

        #expect(throws: TransportError.self) {
            try HerdrWire.decodeResult(
                PongResponse.self, fromResponseLine: Data(line.utf8), requestID: "req-1")
        }
    }
}
