import Foundation
import Testing

@testable import Heeler

// Round-trip tests for the schema-generated wire types (#7). Response
// fixtures mirror herdr 0.7.5 (protocol 17) responses, trimmed to
// representative size and with local paths/titles sanitized.
//
// Round-trip = decode the capture, re-encode, decode again, compare. Key
// order and dropped unknown fields make byte equality meaningless; value
// equality after a full encode/decode cycle is the invariant that matters.
@Suite struct GeneratedWireTypesTests {
    /// Decodes `json`, re-encodes, decodes again, and expects both decoded
    /// values to be equal. Returns the first decode for field assertions.
    private func roundTrip<T: Codable & Equatable>(
        _ type: T.Type, _ json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> T {
        let first = try JSONDecoder().decode(T.self, from: Data(json.utf8))
        let reencoded = try JSONEncoder().encode(first)
        let second = try JSONDecoder().decode(T.self, from: reencoded)
        #expect(first == second, sourceLocation: sourceLocation)
        return first
    }

    // MARK: Result payloads

    @Test func pongResponseRoundTripsLiveCapture() throws {
        let line = #"{"id":"fix-1","result":{"type":"pong","version":"0.7.5","protocol":17,"capabilities":{"live_handoff":true,"detached_server_daemon":true}}}"#

        let pong = try HerdrWire.decodeResult(
            PongResponse.self, fromResponseLine: Data(line.utf8), requestID: "fix-1")

        #expect(pong.version == "0.7.5")
        #expect(pong.protocolVersion == 17)
        #expect(pong.capabilities == ServerCapabilities(liveHandoff: true, detachedServerDaemon: true))
        _ = try roundTrip(PongResponse.self, #"{"type":"pong","version":"0.7.5","protocol":17,"capabilities":{"live_handoff":true,"detached_server_daemon":true}}"#)
    }

    @Test func agentListResponseRoundTripsLiveCapture() throws {
        // Trimmed to one agent; unknown fields left in place.
        let line = #"{"id":"fix-1","result":{"type":"agent_list","agents":[{"terminal_id":"term_656c59f7b902d1e","agent":"codex","terminal_title":"✳ GoDrop","terminal_title_stripped":"GoDrop","agent_status":"working","workspace_id":"w3","tab_id":"w3:t2","pane_id":"w3:pB","focused":false,"cwd":"/Users/u/GoDrop","foreground_cwd":"/Users/u/GoDrop","revision":5}]}}"#

        let list = try HerdrWire.decodeResult(
            AgentListResponse.self, fromResponseLine: Data(line.utf8), requestID: "fix-1")

        let info = try #require(list.agents.first)
        #expect(info.terminalID == "term_656c59f7b902d1e")
        #expect(info.agent == "codex")
        #expect(info.terminalTitle == "✳ GoDrop")
        #expect(info.terminalTitleStripped == "GoDrop")
        #expect(info.agentStatus == .working)
        #expect(info.workspaceID == "w3")
        #expect(info.tabID == "w3:t2")
        #expect(info.paneID == "w3:pB")
        #expect(info.focused == false)
        #expect(info.cwd == "/Users/u/GoDrop")
        #expect(info.foregroundCwd == "/Users/u/GoDrop")
        #expect(info.revision == 5)
        _ = try roundTrip(AgentListResponse.self, #"{"type":"agent_list","agents":[{"terminal_id":"term_656c59f7b902d1e","agent":"codex","terminal_title":"✳ GoDrop","terminal_title_stripped":"GoDrop","agent_status":"working","workspace_id":"w3","tab_id":"w3:t2","pane_id":"w3:pB","focused":false,"cwd":"/Users/u/GoDrop","foreground_cwd":"/Users/u/GoDrop","revision":5}]}"#)
    }

    @Test func agentInfoResponseRoundTripsLiveCapture() throws {
        // `agent.get` live capture.
        let json = #"{"type":"agent_info","agent":{"terminal_id":"term_656c59f7b902d1e","agent":"codex","terminal_title":"GoDrop","terminal_title_stripped":"GoDrop","agent_status":"idle","workspace_id":"w3","tab_id":"w3:t2","pane_id":"w3:pB","focused":false,"cwd":"/Users/u/GoDrop","foreground_cwd":"/Users/u/GoDrop","revision":5}}"#

        let response = try roundTrip(AgentInfoResponse.self, json)

        #expect(response.agent.agentStatus == .idle)
        #expect(response.agent.paneID == "w3:pB")
    }

    @Test func agentPromptedResponseRoundTripsLiveCapture() throws {
        let json = #"{"type":"agent_prompted","agent":{"terminal_id":"term_656c59f7b902d1e","agent":"codex","terminal_title":"GoDrop","terminal_title_stripped":"GoDrop","agent_status":"working","workspace_id":"w3","tab_id":"w3:t2","pane_id":"w3:pB","focused":false,"cwd":"/Users/u/GoDrop","foreground_cwd":"/Users/u/GoDrop","revision":6}}"#

        let response = try roundTrip(AgentPromptedResponse.self, json)

        #expect(response.agent.agentStatus == .working)
        #expect(response.agent.paneID == "w3:pB")
    }

    @Test func sessionSnapshotResponseRoundTripsLiveCapture() throws {
        // Trimmed to one workspace/tab/pane/layout/agent; the layout keeps a
        // real split so PaneLayoutSplit is exercised.
        let json = #"""
            {"type":"session_snapshot","snapshot":{"version":"0.7.5","protocol":17,"workspaces":[{"workspace_id":"w1","number":1,"label":"Proj","focused":false,"pane_count":3,"tab_count":3,"active_tab_id":"w1:t1","agent_status":"unknown","worktree":{"repo_key":"/Users/u/Proj/.git","repo_name":"Proj","repo_root":"/Users/u/Proj","checkout_path":"/Users/u/Proj","is_linked_worktree":false}}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"w1:pA","terminal_id":"term_656c4d830ea7d1","workspace_id":"w1","tab_id":"w1:t1","focused":false,"cwd":"/Users/u/Proj","foreground_cwd":"/Users/u/Proj","terminal_title":"~/D/Proj","terminal_title_stripped":"~/D/Proj","agent_status":"unknown","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":49},"revision":1}],"layouts":[{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":26,"y":1,"width":186,"height":49},"focused_pane_id":"w1:pA","panes":[{"pane_id":"w1:pA","focused":true,"rect":{"x":26,"y":1,"width":93,"height":49}},{"pane_id":"w1:pB","focused":false,"rect":{"x":119,"y":1,"width":93,"height":49}}],"splits":[{"id":"split_0_root","direction":"right","ratio":0.5,"rect":{"x":26,"y":1,"width":186,"height":49}}]}],"agents":[{"terminal_id":"term_656c59f7b902d1e","agent":"codex","terminal_title":"GoDrop","terminal_title_stripped":"GoDrop","agent_status":"idle","workspace_id":"w3","tab_id":"w3:t2","pane_id":"w3:pB","focused":false,"cwd":"/Users/u/GoDrop","foreground_cwd":"/Users/u/GoDrop","revision":5}],"focused_workspace_id":"wS","focused_tab_id":"wS:t1","focused_pane_id":"wS:p1"}}
            """#

        let response = try roundTrip(SessionSnapshotResponse.self, json)
        let snapshot = response.snapshot

        #expect(snapshot.version == "0.7.5")
        #expect(snapshot.protocolVersion == 17)
        #expect(snapshot.focusedPaneID == "wS:p1")
        #expect(snapshot.workspaces.first?.worktree?.repoName == "Proj")
        #expect(snapshot.tabs.first?.paneCount == 1)
        #expect(snapshot.panes.first?.scroll?.viewportRows == 49)
        let layout = try #require(snapshot.layouts.first)
        #expect(layout.splits.first?.direction == .right)
        #expect(layout.splits.first?.ratio == 0.5)
        #expect(layout.panes.count == 2)
        #expect(snapshot.agents.first?.agentStatus == .idle)
    }

    @Test func paneReadResponseRoundTripsLiveCapture() throws {
        // Text trimmed; the capture's shape (all fields, UTF-8 text) is kept.
        let json = #"{"type":"pane_read","read":{"pane_id":"w3:pB","workspace_id":"w3","tab_id":"w3:t2","source":"visible","format":"text","text":"› 为什么失败？\n","revision":0,"truncated":false}}"#

        let response = try roundTrip(PaneReadResponse.self, json)

        #expect(response.read.paneID == "w3:pB")
        #expect(response.read.source == .visible)
        #expect(response.read.format == .text)
        #expect(response.read.text == "› 为什么失败？\n")
        #expect(response.read.truncated == false)
    }

    @Test func agentExplainResponseCarriesFreeFormJSON() throws {
        // The schema leaves `explain` untyped (`true`); trimmed live capture.
        let json = #"{"type":"agent_explain","explain":{"agent":"codex","evaluated_rules":[{"id":"osc_title_blocked","matched":false,"priority":1100}]}}"#

        let response = try roundTrip(AgentExplainResponse.self, json)

        #expect(response.explain["agent"]?.stringValue == "codex")
    }

    @Test func subscriptionStartedAckDecodes() throws {
        // Live-captured ack shape of `events.subscribe`.
        let line = #"{"id":"fix-1","result":{"type":"subscription_started"}}"#

        _ = try HerdrWire.decodeResult(
            SubscriptionStartedResponse.self, fromResponseLine: Data(line.utf8), requestID: "fix-1")
    }

    @Test func workspaceInfoResponseRoundTripsLiveCapture() throws {
        // `workspace.rename` live capture (herdr 0.7.5, sanitized).
        let json = #"{"type":"workspace_info","workspace":{"workspace_id":"w9","number":12,"label":"Proj","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w9:t1","agent_status":"unknown"}}"#

        let response = try roundTrip(WorkspaceInfoResponse.self, json)

        #expect(response.workspace.workspaceID == "w9")
        #expect(response.workspace.label == "Proj")
    }

    @Test func worktreeCreatedResponseRoundTripsLiveCapture() throws {
        // `worktree.create` live capture (herdr 0.7.5, sanitized, #97): the
        // new workspace arrives with its tab and root pane, plus the
        // worktree's git identity.
        let json = #"{"type":"worktree_created","workspace":{"workspace_id":"w9","number":9,"label":"calm-field-cc11","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w9:t1","agent_status":"unknown","worktree":{"repo_key":"/Users/u/Proj/.git","repo_name":"Proj","repo_root":"/Users/u/Proj","checkout_path":"/Users/u/Documents/worktree/Proj/calm-field-cc11","is_linked_worktree":true}},"tab":{"tab_id":"w9:t1","workspace_id":"w9","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"w9:p1","terminal_id":"term_wt","workspace_id":"w9","tab_id":"w9:t1","focused":false,"agent_status":"unknown","revision":0},"worktree":{"path":"/Users/u/Documents/worktree/Proj/calm-field-cc11","branch":"worktree/calm-field-cc11","is_bare":false,"is_detached":false,"is_prunable":false,"is_linked_worktree":true,"label":"calm-field-cc11","open_workspace_id":"w9"}}"#

        let response = try roundTrip(WorktreeCreatedResponse.self, json)

        #expect(response.workspace.workspaceID == "w9")
        #expect(response.rootPane.paneID == "w9:p1")
        #expect(response.worktree.branch == "worktree/calm-field-cc11")
        #expect(response.worktree.openWorkspaceID == "w9")
        #expect(response.workspace.worktree?.isLinkedWorktree == true)
    }

    @Test func worktreeRemovedResponseRoundTrips() throws {
        let json = #"{"type":"worktree_removed","workspace_id":"w9","path":"/Users/u/Documents/worktree/Proj/calm-field-cc11","forced":false}"#

        let response = try roundTrip(WorktreeRemovedResponse.self, json)

        #expect(response.workspaceID == "w9")
        #expect(response.forced == false)
    }

    @Test func okResponseDecodes() throws {
        // The bare-acknowledgement result shape (`pane.close`).
        _ = try roundTrip(OkResponse.self, #"{"type":"ok"}"#)
    }

    @Test func agentSessionInfoRoundTrips() throws {
        // Synthetic per the schema: no live pane carried an agent_session at
        // capture time. Field set matches `$defs/AgentSessionInfo` exactly.
        let json = #"{"source":"osc","agent":"claude","kind":"id","value":"sess-1234"}"#

        let session = try roundTrip(AgentSessionInfo.self, json)

        #expect(session.kind == .id)
        #expect(session.value == "sess-1234")
    }

    // MARK: Leniency

    @Test func unknownEnumValuesDecodeLeniently() throws {
        // herdr's API has no stability guarantee: new enum values must not
        // break decoding. Raw-string wrappers keep the unknown value intact.
        let json = #"{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","source":"psychic","format":"text","text":"","revision":1,"truncated":false}"#

        let read = try roundTrip(PaneReadResult.self, json)

        #expect(read.source == ReadSource(rawValue: "psychic"))
        #expect(read.source != .visible)
    }

    // MARK: Params

    @Test func paneReadParamsEncodeOnlyProvidedFields() throws {
        let params = PaneReadParams(paneID: "w1:p1", source: .visible)

        let data = try JSONEncoder().encode(params)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let fields = try #require(object)

        #expect(fields.keys.sorted() == ["pane_id", "source"])
        #expect(fields["source"] as? String == "visible")
    }

    @Test func agentSendKeysParamsRoundTrip() throws {
        let params = AgentSendKeysParams(keys: ["ctrl+c", "enter"], target: "w1:p1")

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(AgentSendKeysParams.self, from: data)

        #expect(decoded == params)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let fields = try #require(object)
        #expect(fields.keys.sorted() == ["keys", "target"])
        #expect(fields["target"] as? String == "w1:p1")
        #expect(fields["keys"] as? [String] == ["ctrl+c", "enter"])
    }

    @Test func agentStartParamsRoundTrip() throws {
        let params = AgentStartParams(
            kind: "claude", name: "reviewer", paneID: "w1:p1",
            args: ["--continue"], timeoutMs: 5_000)

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(AgentStartParams.self, from: data)

        #expect(decoded == params)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let fields = try #require(object)
        #expect(fields.keys.sorted() == ["args", "kind", "name", "pane_id", "timeout_ms"])
    }

    @Test func agentPromptParamsOmitWait() throws {
        let params = AgentPromptParams(target: "w1:p1", text: "Continue")

        let data = try JSONEncoder().encode(params)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let fields = try #require(object)

        #expect(fields.keys.sorted() == ["target", "text"])
        #expect(fields["target"] as? String == "w1:p1")
        #expect(fields["text"] as? String == "Continue")
    }

    @Test func tabCreateParamsEncodeProtocolSeventeenFields() throws {
        let params = TabCreateParams(focus: false, workspaceID: "w1")

        let data = try JSONEncoder().encode(params)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let fields = try #require(object)

        #expect(fields.keys.sorted() == ["focus", "workspace_id"])
        #expect(fields["focus"] as? Bool == false)
        #expect(fields["workspace_id"] as? String == "w1")
    }

    @Test func worktreeCreateParamsEncodeOnlyProvidedFields() throws {
        // Nil branch/base/label/path must drop their keys so herdr applies
        // its own defaults (generated branch off HEAD, #97).
        let fields = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                WorktreeCreateParams(focus: false, workspaceID: "w1"))
        ) as? [String: Any]
        #expect(fields?.keys.sorted() == ["focus", "workspace_id"])
        #expect(fields?["focus"] as? Bool == false)
    }

    @Test func agentRenameParamsOmitNilNameToClearIt() throws {
        // Verified live (herdr 0.7.5): omitting `name` clears the custom
        // name back to the detected kind, so nil must drop the key, not
        // send `"name":null`.
        let cleared = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AgentRenameParams(target: "w1:p1"))
        ) as? [String: Any]
        #expect(cleared?.keys.sorted() == ["target"])

        let named = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AgentRenameParams(target: "w1:p1", name: "reviewer"))
        ) as? [String: Any]
        #expect(named?.keys.sorted() == ["name", "target"])
        #expect(named?["name"] as? String == "reviewer")
    }

    @Test func workspaceRenameParamsEncodeSnakeCase() throws {
        let fields = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WorkspaceRenameParams(label: "Proj", workspaceID: "w9"))
        ) as? [String: Any]
        #expect(fields?.keys.sorted() == ["label", "workspace_id"])
        #expect(fields?["workspace_id"] as? String == "w9")
    }

    @Test func paneTargetTravelsThroughTheRequestEnvelope() throws {
        let line = try HerdrWire.requestLine(
            id: "req-1", method: "pane.close", params: PaneTarget(paneID: "w1:p1"))

        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let envelope = try #require(object)
        #expect((envelope["params"] as? [String: Any])?["pane_id"] as? String == "w1:p1")
    }

    @Test func agentTargetEncodesItsWireName() throws {
        let target = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AgentTarget(target: "w1:p1"))
        ) as? [String: Any]
        #expect(target?.keys.sorted() == ["target"])
    }
}
