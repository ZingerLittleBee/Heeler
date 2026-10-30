import Foundation
import Testing

@testable import Heeler

@Suite struct HerdrCoreWireTests {
    @Test func requestsAreJSONRPCAndKeepPromptTextInJSON() throws {
        let prompt = "quote: '\"; $(touch never)\nsecond line"
        let line = try HerdrCoreWire.requestLine(
            id: "request", method: "terminal.send",
            params: .object(["terminal": .string("t3"), "text": .string(prompt)]))
        #expect(line.last == "\n")
        #expect(line.filter { $0 == "\n" }.count == 1)
        let decoded = try json(line)
        #expect(decoded["jsonrpc"] == .string("2.0"))
        #expect(decoded["id"] == .string("request"))
        #expect(decoded["params"]?["text"] == .string(prompt))
    }

    @Test func responsesRequireTheRightProtocolAndRequestIdentity() throws {
        let good = #"{"jsonrpc":"2.0","id":"request","result":{"future":true}}"#
        #expect(try HerdrCoreWire.result(from: Data(good.utf8), id: "request") == .object(["future": .bool(true)]))
        for bad in [
            #"{"id":"request","result":{}}"#,
            #"{"jsonrpc":"2.0","id":"other","result":{}}"#,
            #"{"jsonrpc":"2.0","id":"request"}"#,
            "not JSON",
        ] {
            #expect(throws: TransportError.self) {
                try HerdrCoreWire.result(from: Data(bad.utf8), id: "request")
            }
        }
    }

    @Test func coreErrorKindsAndRecoveryHintsSurvive() throws {
        let line = #"{"jsonrpc":"2.0","id":"request","error":{"code":-32000,"message":"program blocked","data":{"kind":"blocked","hint":"Inspect its prompt."}}}"#
        #expect(throws: HerdrAPIError(code: "blocked", message: "program blocked Inspect its prompt.")) {
            try HerdrCoreWire.result(from: Data(line.utf8), id: "request")
        }
    }

    @Test func handshakeChecksCoreGenerationAndRequiredOperations() throws {
        var fields: [String: JSONValue] = [
            "generation": .number(1), "version": .string("0.1.13"),
            "methods": .array([
                "terminal.list", "terminal.get", "terminal.read", "terminal.send",
                "terminal.keys", "events.subscribe", "future.method",
            ].map(JSONValue.string)),
            "future": .bool(true),
        ]
        #expect(try HerdrCoreWire.serverInfo(from: .object(fields)) == ServerInfo(version: "0.1.13", protocolVersion: 1))
        fields["generation"] = .number(2)
        #expect(throws: TransportError.self) { try HerdrCoreWire.serverInfo(from: .object(fields)) }
        fields["generation"] = .number(1)
        fields["methods"] = .array([.string("terminal.list")])
        #expect(throws: TransportError.self) { try HerdrCoreWire.serverInfo(from: .object(fields)) }
    }

    @Test func desktopAgentsAndShellsShareStableDirectoryInventory() throws {
        let snapshot = try HerdrCoreWire.snapshot(from: json(Self.inventory))
        #expect(snapshot.agents.map(\.paneID) == ["t3", "t9", "t10"])
        #expect(snapshot.agents.map(\.agent) == ["claude", "pi", "claude"])
        #expect(snapshot.agents.map(\.agentStatus) == [.working, .idle, .blocked])
        #expect(snapshot.panes.map(\.paneID) == ["t3", "t9", "t10", "t11"])
        #expect(snapshot.tabs.map(\.tabID) == snapshot.panes.map(\.paneID))
        #expect(snapshot.workspaces.count == 2)
        #expect(snapshot.workspaces[0].workspaceID == "core:/work/project")
        #expect(snapshot.workspaces[0].paneCount == 3)
        #expect(snapshot.workspaces[0].agentStatus == .blocked)
        #expect(snapshot.agents[0].foregroundCwd == "/work/project/child")
        #expect(snapshot.agents[0].cwd == "/work/project")
        #expect(snapshot.agents[0].completionSeq == 7)
        #expect(snapshot.agents[0].stateChangeSeq == 12345)
        #expect(snapshot.agents[0].name == "review")
        #expect(snapshot.agents[0].agentSession == nil)
        #expect(HerdrCoreWire.directory(forWorkspaceID: snapshot.workspaces[0].workspaceID) == "/work/project")
        #expect(HerdrCoreWire.directory(forWorkspaceID: "w1") == nil)
        #expect(snapshot.protocolVersion == 1)
    }

    @Test func titlesAndForegroundDirectoryDoNotChangeIdentity() throws {
        var record = try json(Self.terminal)
        let first = try HerdrCoreWire.agent(from: record)
        guard case .object(var fields) = record else { Issue.record("fixture is not an object"); return }
        fields["title"] = .string("new title")
        fields["foreground"] = .object(["cwd": .string("/work/elsewhere")])
        record = .object(fields)
        let next = try HerdrCoreWire.agent(from: record)
        #expect(first.paneID == next.paneID && first.terminalID == next.terminalID)
        #expect(first.workspaceID == next.workspaceID && first.tabID == next.tabID)
        #expect(next.title == "new title")
        #expect(next.foregroundCwd == "/work/elsewhere")
    }

    @Test func unreportedAgentsAreRecognizedButOrdinaryProgramsAreNot() throws {
        let snapshot = try HerdrCoreWire.snapshot(from: json(#"{"terminals":[{"address":"t1","cwd":"/a","state":"live","argv":["/bin/zsh"],"status":null,"foreground":{"name":"codex","argv":["/opt/bin/codex"],"cwd":"/b"}},{"address":"t2","cwd":"/a","state":"live","argv":["/bin/sh"],"status":{"app":"build","state":"working"}},{"address":"t3","cwd":"/a","state":"live","argv":["/opt/bin/pi"],"status":null}]}"#))
        #expect(snapshot.agents.map(\.agent) == ["codex", "pi"])
        #expect(snapshot.agents.allSatisfy { $0.agentStatus == .unknown })
        #expect(snapshot.panes.count == 3)
        #expect(throws: HerdrAPIError.self) {
            try HerdrCoreWire.agent(from: json(#"{"address":"t2","cwd":"/a","state":"live","argv":["/bin/sh"],"status":null}"#))
        }
    }

    @Test func interpreterEntrypointsIdentifyUnreportedDesktopAgents() throws {
        let cases: [([String], String)] = [
            (["node", "/opt/bin/gemini.js"], "gemini"),
            (["node", "/opt/lib/node_modules/@anthropic-ai/claude-code/cli.js"], "claude"),
            (["node", "/opt/lib/node_modules/@google/gemini-cli/dist/index.js"], "gemini"),
            (["node", "/opt/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js"], "pi"),
            (["node", "/opt/bin/pi-cli.js"], "pi"),
            (["/opt/bin/pi-cli"], "pi"),
            (["node", "--enable-source-maps", "/opt/bin/gemini.js"], "gemini"),
            (["node", "--require", "loader.js", "/opt/bin/gemini.js"], "gemini"),
            (["bun", "--", "/opt/bin/pi-cli"], "pi"),
        ]
        for (arguments, expected) in cases {
            let snapshot = try inventory(arguments: ["/bin/zsh"], foreground: arguments)
            #expect(snapshot.agents.first?.agent == expected, "\(arguments)")
            #expect(snapshot.agents.first?.agentStatus == .unknown)
        }
    }

    @Test func exactDesktopShellWrappersRevealTheCommandPosition() throws {
        let local = ["/bin/zsh", "-ic", "\"$@\"; exec \"$0\" -i", "/bin/zsh", "node", "/opt/bin/gemini.js", "task"]
        let remote = ["sh", "-c", "\"$@\"; exec \"${SHELL:-sh}\" -i", "sh", "pi", "task"]
        #expect(try inventory(arguments: local).agents.first?.agent == "gemini")
        #expect(try inventory(arguments: remote).agents.first?.agent == "pi")
        // A wrapper that returned to its shell no longer hosts the Agent.
        #expect(try inventory(arguments: local, foreground: ["/bin/zsh", "-i"]).agents.isEmpty)
    }

    @Test func staleReportsCannotKeepAnAgentInAPositivelyIdentifiedPlainShell() throws {
        let wrapper = ["/bin/zsh", "-ic", "\"$@\"; exec \"$0\" -i", "/bin/zsh", "claude"]
        for foreground in [
            ["/bin/sh", "-i"], ["-zsh"], ["bash", "--noprofile", "--norc", "-il"], ["fish"],
        ] {
            let record: JSONValue = .object([
                "address": .string("t1"), "cwd": .string("/project"), "state": .string("live"),
                "argv": .array(wrapper.map(JSONValue.string)),
                "foreground": .object(["argv": .array(foreground.map(JSONValue.string))]),
                "status": .object(["app": .string("claude-code"), "state": .string("idle")]),
            ])
            let snapshot = try HerdrCoreWire.snapshot(from: .object(["terminals": .array([record])]))
            #expect(snapshot.agents.isEmpty, "\(foreground)")
            #expect(snapshot.panes.count == 1 && snapshot.panes.first?.agent == nil)
            #expect(throws: HerdrAPIError.self) { try HerdrCoreWire.agent(from: record) }
        }
        // A shell still executing a command/script is not a known returned shell.
        for foreground in [wrapper, ["sh", "-c", "custom-agent-wrapper"], ["sh", "/opt/agent.sh"], []] {
            let record: JSONValue = .object([
                "address": .string("t1"), "cwd": .string("/project"), "state": .string("live"),
                "argv": .array(wrapper.map(JSONValue.string)),
                "foreground": .object(["name": .string("sh"), "argv": .array(foreground.map(JSONValue.string))]),
                "status": .object(["app": .string("claude-code"), "state": .string("idle")]),
            ])
            #expect(try HerdrCoreWire.agent(from: record).kind == "claude")
        }
    }

    @Test func coreErrorRemainsAnErrorAndGetsWorkspaceAttention() throws {
        let snapshot = try HerdrCoreWire.snapshot(from: json(#"{"terminals":[{"address":"t1","cwd":"/project","state":"live","argv":["claude"],"status":{"app":"claude-code","state":"error"}}]}"#))
        #expect(snapshot.agents.first?.agentStatus == .error)
        #expect(snapshot.panes.first?.agentStatus == .error)
        #expect(snapshot.tabs.first?.agentStatus == .error)
        #expect(snapshot.workspaces.first?.agentStatus == .error)
        let event = try HerdrCoreWire.decodeEvent(fromLine: Data(#"{"jsonrpc":"2.0","method":"event","params":{"seq":1,"type":"status","terminal":"t1","data":{"status":{"app":"claude-code","state":"error","title":"Authentication failed"}}}}"#.utf8))
        #expect(event?.data["agent_status"] == .string("error"))
        #expect(event?.data["core_status"]?["app"] == .string("claude-code"))
        #expect(event?.data["core_status"]?["title"] == .string("Authentication failed"))
    }

    @Test func unrelatedArgumentsAndEvaluatedCodeDoNotCreateAgents() throws {
        for arguments in [
            ["echo", "claude"],
            ["node", "server.js", "claude"],
            ["node", "-e", "claude", "/opt/bin/gemini.js"],
            ["node", "--eval=claude", "/opt/bin/gemini.js"],
            ["node", "--require", "/opt/bin/gemini.js", "server.js"],
            ["python3", "-c", "gemini", "claude"],
            ["sh", "-c", "echo \"$@\"", "sh", "claude"],
            ["node", "/tmp/unrelated/cli.js", "@anthropic-ai/claude-code"],
        ] {
            let snapshot = try inventory(arguments: arguments)
            #expect(snapshot.agents.isEmpty, "\(arguments)")
            #expect(snapshot.panes.count == 1)
        }
    }

    @Test func recognizedWrappersKeepTheProgramsOwnUnknownStatus() throws {
        let record: JSONValue = .object([
            "address": .string("t1"), "cwd": .string("/project"), "state": .string("live"),
            "argv": .array(["node", "/opt/bin/gemini.js"].map(JSONValue.string)),
            "status": .object(["state": .string("future-state")]),
        ])
        let snapshot = try HerdrCoreWire.snapshot(from: .object(["terminals": .array([record])]))
        #expect(snapshot.agents.first?.agent == "gemini")
        #expect(snapshot.agents.first?.agentStatus == AgentStatus(rawValue: "future-state"))
    }

    private func inventory(arguments: [String], foreground: [String]? = nil) throws -> SessionSnapshot {
        var record: [String: JSONValue] = [
            "address": .string("t1"), "cwd": .string("/project"), "state": .string("live"),
            "argv": .array(arguments.map(JSONValue.string)), "status": .null,
        ]
        if let foreground {
            record["foreground"] = .object([
                "name": .string(foreground.first ?? ""),
                "argv": .array(foreground.map(JSONValue.string)),
            ])
        }
        return try HerdrCoreWire.snapshot(from: .object(["terminals": .array([.object(record)])]))
    }

    @Test func malformedInventoryCannotMasqueradeAsEmptySuccess() throws {
        for value in [
            #"{}"#,
            #"{"terminals":[{"state":"live","cwd":"/a"}]}"#,
            #"{"terminals":[{"address":"t1","state":"live","cwd":"relative"}]}"#,
            #"{"terminals":[{"address":"t1","state":"live","cwd":"/a"},{"address":"t1","state":"live","cwd":"/a"}]}"#,
        ] {
            #expect(throws: TransportError.self) { try HerdrCoreWire.snapshot(from: json(value)) }
        }
        #expect(try HerdrCoreWire.snapshot(from: json(#"{"terminals":[]}"#)).agents.isEmpty)
    }

    @Test func readPreservesPartialHistoryAndText() throws {
        let read = try HerdrCoreWire.read(
            from: json(#"{"text":"current screen","complete":false,"how":"screen","why":"working"}"#),
            target: "t3", source: .recentUnwrapped)
        #expect(read.text == "current screen" && read.truncated)
        #expect(read.source == .recentUnwrapped && read.paneID == "t3")
        #expect(throws: TransportError.self) {
            try HerdrCoreWire.read(from: json(#"{"complete":true}"#), target: "t3")
        }
    }

    @Test func eventsDriveStatusAndMembershipUpdates() throws {
        let status = try HerdrCoreWire.decodeEvent(fromLine: Data(#"{"jsonrpc":"2.0","method":"event","params":{"seq":2,"type":"status","terminal":"t3","data":{"status":{"state":"working","app":"claude-code"}}}}"#.utf8))
        #expect(status?.kind == PaneEventKind.agentStatusChanged.kind)
        #expect(status?.data["pane_id"] == .string("t3"))
        #expect(status?.data["agent_status"] == .string("working"))
        for (type, kind) in [
            ("created", GlobalEventKind.paneCreated), ("restarted", .paneCreated),
            ("removed", .paneClosed), ("finished", .paneExited),
            ("foreground", .paneAgentDetected),
        ] {
            let line = try notification(type: type, target: "t3", sequence: 3)
            #expect(try HerdrCoreWire.decodeEvent(fromLine: line)?.kind == kind.kind)
        }
        #expect(try HerdrCoreWire.decodeEvent(fromLine: notification(type: "status", target: "remote/t3", sequence: 3)) == nil)
        let clear = try HerdrCoreWire.decodeEvent(fromLine: notification(type: "status", target: "t3", sequence: 3))
        #expect(clear?.data["agent_status"] == .string("unknown"))
    }

    @Test func titleNotificationsAreLocalPresentationDeltas() throws {
        let line = Data(#"{"jsonrpc":"2.0","method":"event","params":{"seq":5,"type":"title","terminal":"t3","data":{"title":"Working"}}}"#.utf8)
        let event = try #require(try HerdrCoreWire.decodeEvent(fromLine: line))
        #expect(event.kind == .terminalTitleChanged)
        #expect(event.data == .object(["pane_id": .string("t3"), "title": .string("Working")]))
        let snapshot = try HerdrCoreWire.snapshot(from: json(Self.inventory))
        #expect(snapshot.tabs.first?.label == "review")
        #expect(snapshot.tabs[1].label == "")
        #expect(snapshot.panes.first?.terminalTitleStripped == "Reviewing")
        // An explicit empty terminal title stays cleared on the next snapshot.
        let cleared = try HerdrCoreWire.snapshot(from: json(#"{"terminals":[{"address":"t3","cwd":"/work","state":"live","argv":["claude"],"title":"","status":{"app":"claude-code","state":"idle","title":"Status label"}}]}"#))
        #expect(cleared.agents.first?.terminalTitle == "")
        #expect(cleared.panes.first?.terminalTitleStripped == "")
    }

    @Test func missedSnapshotAdvancesCursorAndRejectsOlderBufferedEvents() throws {
        var cursor = HerdrCoreEventCursor()
        try cursor.acknowledge(.object(["seq": .number(10), "terminals": .array([])]))
        #expect(try cursor.decodeEvent(fromLine: notification(type: "created", target: "t3", sequence: 10)) == nil)
        #expect(try cursor.decodeEvent(fromLine: notification(type: "created", target: "t3", sequence: 11))?.kind == GlobalEventKind.paneCreated.kind)
        let missed = Data(#"{"jsonrpc":"2.0","method":"missed","params":{"seq":20,"terminals":[]}}"#.utf8)
        #expect(try cursor.decodeEvent(fromLine: missed) == .eventsDropped)
        #expect(try cursor.decodeEvent(fromLine: notification(type: "removed", target: "t3", sequence: 19)) == nil)
        #expect(try cursor.decodeEvent(fromLine: notification(type: "status", target: "t3", sequence: 21)) != nil)
        let heartbeat = Data(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":21}}"#.utf8)
        #expect(try cursor.decodeEvent(fromLine: heartbeat) == nil)
        #expect(cursor.sequence == 21)
        #expect(throws: TransportError.self) { try cursor.acknowledge(.object([:])) }
    }

    @Test func heartbeatDoesNotDiscardEventsStillQueuedForDelivery() throws {
        var cursor = HerdrCoreEventCursor()
        try cursor.acknowledge(.object(["seq": .number(10), "terminals": .array([])]))
        let heartbeat = Data(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":12}}"#.utf8)
        #expect(try cursor.decodeEvent(fromLine: heartbeat) == nil)
        #expect(cursor.sequence == 10)
        #expect(try cursor.decodeEvent(fromLine: notification(type: "created", target: "t3", sequence: 11))?.kind == GlobalEventKind.paneCreated.kind)
        #expect(try cursor.decodeEvent(fromLine: notification(type: "status", target: "t3", sequence: 12))?.kind == PaneEventKind.agentStatusChanged.kind)
        #expect(cursor.sequence == 12)
    }

    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    private func notification(type: String, target: String, sequence: Int) throws -> Data {
        try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "type": .string(type), "terminal": .string(target),
                "seq": .number(Double(sequence)), "data": .object([:]),
            ]),
        ]))
    }

    // Full terminal records from the generation-1 API, not `hc ls`'s
    // compact presentation. Unknown fields intentionally remain present.
    private static let terminal = #"{"address":"t3","argv":["python3","fake.py"],"cwd":"/work/project","state":"live","name":"review","status":{"app":"claude-code","state":"working"},"status_ms":12345,"turn":7,"title":"Reviewing","foreground":{"cwd":"/work/project/child"},"future":true}"#
    private static let inventory = """
        {"terminals":[
          \(terminal),
          {"address":"t9","argv":["pi"],"cwd":"/work/second","state":"live","status":{"state":"idle"}},
          {"address":"t10","argv":["claude"],"cwd":"/work/project","state":"live","status":{"state":"blocked"}},
          {"address":"t11","argv":["/bin/zsh"],"cwd":"/work/project","state":"live","status":null},
          {"address":"t12","argv":["codex"],"cwd":"/work/project","state":"finished"},
          {"address":"remote/t3","argv":["claude"],"cwd":"/remote/project","state":"live"}
        ],"hidden_finished":1}
        """
}

@Suite struct HerdrCoreCommandTests {
    @Test func bridgeSelectsAnExplicitCoreSessionAndClearsInheritedTargets() throws {
        let command = try HerdrCoreCommand.connect(session: "phone-work", executable: "/opt/bin/hc")
        #expect(command.hasPrefix("/bin/sh -c "))
        #expect(command.contains("export HC_SESSION=\"$1\"; shift"))
        #expect(command.contains("unset HC_SOCKET HC_TERMINAL_ID"))
        #expect(command.contains("core=\"$1\"; shift"))
        #expect(command.hasSuffix("'phone-work' '/opt/bin/hc' 'connect'"))
        #expect(command.contains(HerdrCoreCommand.streamMarker))
        #expect(!command.contains("HERDR_SOCKET_PATH"))
        #expect(!command.contains("remote-client-bridge"))
    }

    @Test func attachmentUsesTheCoreAddressAndReleasesTheBootstrapGate() throws {
        let command = try HerdrCoreCommand.attach(
            session: "default",
            request: TerminalAttachRequest(target: .agentPane("t10"), takeover: true, cols: 80, rows: 24), executable: "/opt/bin/hc")
        #expect(command.hasSuffix("'default' '/opt/bin/hc' 'attach' 't10'"))
        #expect(!command.contains("--takeover"))
        #expect(!command.contains(HerdrCoreCommand.streamMarker))
        // The shared PTY pump withholds all screen bytes until this marker.
        #expect(command.contains(AttachBootstrapHandshake.markerPrintfFormat))
        let shell = try HerdrCoreCommand.attach(
            session: "default",
            request: TerminalAttachRequest(target: .terminal("t10"), cols: 80, rows: 24), executable: "/opt/bin/hc")
        #expect(shell == command)
    }

    @Test func unsafeSessionsAndTargetsNeverReachARemoteShell() throws {
        for session in [".", "..", "a/b", "a\nb", "a:b", "bad|name"] {
            #expect(throws: TransportError.self) { try HerdrCoreCommand.connect(session: session, executable: "/opt/bin/hc") }
        }
        for target in ["", "-option", "other/t1", "t1; id", "$(id)", "t1'", "t1\n", "t1 t2"] {
            #expect(throws: TransportError.self) { try HerdrCoreCommand.validateTarget(target) }
            #expect(throws: TransportError.self) {
                try HerdrCoreCommand.attach(
                    session: "default", request: TerminalAttachRequest(target: target, cols: 80, rows: 24), executable: "/opt/bin/hc")
            }
        }
    }

    @Test func coreSessionNamesStayQuotedAndAreNotLimitedToLegacyGrammar() throws {
        for session in ["work team", "東京", "work; id", "$(id)", "a'b", String(repeating: "a", count: 65)] {
            let command = try HerdrCoreCommand.connect(session: session, executable: "/opt/bin/my core")
            #expect(command.hasSuffix(GitProbe.singleQuoted(session) + " '/opt/bin/my core' 'connect'"))
        }
    }

    @Test func aDeadlineSealsDispatchBeforeALateChannelCanWrite() async throws {
        let dispatch = CoreMutationDispatch()
        #expect(await dispatch.seal() == false)
        await #expect(throws: TransportError.cancelled) { try await dispatch.begin() }
        #expect(await dispatch.seal() == false)
        let written = CoreMutationDispatch()
        try await written.begin()
        #expect(await written.seal())
        await #expect(throws: TransportError.cancelled) { try await written.begin() }
    }

    @Test func aCancelledContinuationCannotBeginAMutation() async {
        let dispatch = CoreMutationDispatch()
        let operation = Task {
            // Simulate an underlying channel open that ignores cancellation.
            try? await Task.sleep(for: .seconds(1))
            try await dispatch.begin()
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await dispatch.seal() == false)
    }

    @Test func attachmentRejectsUnrepresentableGeometry() throws {
        for (columns, rows) in [(0, 24), (80, 0), (-1, 24), (65536, 24), (80, 65536)] {
            #expect(throws: TransportError.self) {
                try HerdrCoreCommand.attach(
                    session: "default", request: TerminalAttachRequest(target: "t1", cols: columns, rows: rows), executable: "/opt/bin/hc")
            }
        }
        _ = try HerdrCoreCommand.attach(
            session: "default", request: TerminalAttachRequest(target: "t1", cols: 65535, rows: 65535), executable: "/opt/bin/hc")
    }
}
