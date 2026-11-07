import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@Suite("Claude transcript records")
struct ClaudeTranscriptRecordTests {
    private static let probe = "claude/probe2-transcript.jsonl"

    private static func record(_ json: String, offset: UInt64 = 0) throws -> ClaudeRecord {
        guard case .record(let record) = ClaudeLine.decode(ChatLine(offset: offset, data: Data(json.utf8))) else {
            throw DecodeFailure(json: json)
        }
        return record
    }

    private struct DecodeFailure: Error, CustomStringConvertible {
        let json: String
        var description: String { "not a record: \(json)" }
    }

    @Test("Every line of the second probe decodes: 119 records and 47 metadata lines")
    func decodeAll() throws {
        let lines = try ChatFixture.lines(Self.probe)
        var records = 0
        var metadata = 0
        var invalid = 0
        for line in lines {
            switch ClaudeLine.decode(line) {
            case .record: records += 1
            case .metadata: metadata += 1
            case .invalid: invalid += 1
            }
        }
        #expect(lines.count == 166)
        #expect(records == 119)
        #expect(metadata == 47)
        #expect(invalid == 0)

        var reducer = ClaudeTranscriptReducer()
        reducer.append(lines)
        #expect(reducer.index.records.count == 119)
        #expect(reducer.index.title == "create-and-verify-probe-file")
        #expect(reducer.index.permissionMode == "default")
        #expect(reducer.index.model == "claude-sonnet-5-5")
        #expect(reducer.index.diagnostics == ChatTranscriptDiagnostics())
    }

    @Test("The newest main reply's effort is the session's; a sidechain's is not")
    func effortOfNewestReply() throws {
        func reply(_ uuid: String, effort: String, sidechain: Bool = false) -> String {
            #"{"type":"assistant","uuid":"\#(uuid)","parentUuid":null,"isSidechain":\#(sidechain),"effort":"\#(effort)","message":{"id":"m-\#(uuid)","model":"claude-fable-5-1","content":[{"type":"text","text":"ok"}]}}"#
        }
        #expect(try Self.record(reply("a1", effort: "high")).effort == "high")
        var reducer = ClaudeTranscriptReducer()
        reducer.append([
            ChatLine(offset: 0, data: Data(reply("a1", effort: "medium").utf8)),
            ChatLine(offset: 300, data: Data(reply("a2", effort: "high").utf8)),
            ChatLine(offset: 600, data: Data(reply("s1", effort: "low", sidechain: true).utf8)),
        ])
        #expect(reducer.index.effort == "high")
        // A newer reply without an effort clears it; a teammate's reply is not the session's.
        let haiku = #"{"type":"assistant","uuid":"h1","parentUuid":null,"message":{"id":"m-h1","model":"claude-haiku-5-5","content":[{"type":"text","text":"ok"}]}}"#
        let teammate = #"{"type":"assistant","uuid":"t1","parentUuid":null,"teamName":"crew","effort":"max","message":{"id":"m-t1","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}]}}"#
        reducer.append([ChatLine(offset: 900, data: Data(haiku.utf8)), ChatLine(offset: 1200, data: Data(teammate.utf8))])
        #expect(reducer.index.model == "claude-haiku-5-5")
        #expect(reducer.index.effort == nil)
        #expect(AgentSessionSettings(model: "claude-fable-5-1", permissionMode: nil, effort: "high").modelLine == "Fable 5.1 · high")
        #expect(AgentSessionSettings(model: "claude-fable-5-1", permissionMode: nil).modelLine == "Fable 5.1")
    }

    @Test("Metadata is last-wins by file position, whatever order lines arrive in")
    func metadataLastWins() throws {
        let lines = try ChatFixture.lines(Self.probe)
        // Through L87 the latest title is L63's and plan mode is on (L65).
        var head = ClaudeTranscriptReducer()
        head.append(Array(lines.prefix(87)))
        #expect(head.index.title == "c1.txt 文件创建")
        #expect(head.index.permissionMode == "plan")

        var reversed = ClaudeTranscriptReducer()
        reversed.append(Array(lines.dropFirst(87)))
        reversed.prepend(Array(lines.prefix(87)))
        #expect(reversed.index.title == "create-and-verify-probe-file")
        #expect(reversed.index.permissionMode == "default")
    }

    @Test("A typed prompt keeps its provenance and position")
    func typedPrompt() throws {
        let line = try #require(try ChatFixture.lines(Self.probe).first { $0.offset == 391 })
        guard case .record(let record) = ClaudeLine.decode(line) else {
            Issue.record("L5 is not a record")
            return
        }
        #expect(record.uuid == "e6fda38c-45bf-49c6-b0a2-5e1cf39cbef9")
        #expect(record.parentUUID == nil)
        #expect(record.kind == .user)
        #expect(record.byteOffset == 391)
        #expect(record.byteLength == line.length)
        #expect(record.promptSource == "typed")
        #expect(record.originKind == "human")
        #expect(record.sessionID == "e951205e-24af-4a5e-baa7-3ccbebd2de2c")
        #expect(record.texts == ["Use the Bash tool to run: touch c1.txt"])
    }

    @Test("Blocks of one API message are separate records sharing its id (L74, L76)")
    func splitMessage() throws {
        let lines = try ChatFixture.lines(Self.probe)
        let write = try #require(lines.first { $0.offset == 35529 })
        let search = try #require(lines.first { $0.offset == 38558 })
        guard case .record(let first) = ClaudeLine.decode(write), case .record(let second) = ClaudeLine.decode(search)
        else {
            Issue.record("L74 or L76 is not a record")
            return
        }
        #expect(first.messageID != nil)
        #expect(first.messageID == second.messageID)
        #expect(first.apiBlockIndex == 0)
        #expect(second.apiBlockIndex == 1)
        #expect(first.toolUses.map(\.name) == ["Write"])
        #expect(second.toolUses.map(\.name) == ["ToolSearch"])
        // L76 hangs off the result of L74's call, not off L74.
        #expect(second.parentUUID == "2791fe96-4b8f-4838-9796-2265181ea0bf")
    }

    @Test("A decline keeps its kind and the user's feedback (L26)")
    func declineFields() throws {
        let line = try #require(try ChatFixture.lines(Self.probe).first { $0.offset == 7319 })
        guard case .record(let record) = ClaudeLine.decode(line) else {
            Issue.record("L26 is not a record")
            return
        }
        let result = try #require(record.toolResults.first)
        #expect(result.toolUseID == "toolu_01TbgUciZNfX5qWyWVahrgJY")
        #expect(result.isError)
        #expect(record.toolResult?.denialKind == "user-rejected")
        #expect(record.toolResult?.userFeedback == "Do not create it; reply with the single word skipped")
    }

    @Test("A write keeps line counts and capped hunks, never the file")
    func writeReduction() throws {
        let big = String(repeating: "line of a large file\n", count: 5_000)
        let json = """
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result",\
            "tool_use_id":"toolu_w","content":"The file has been updated."}]},"toolUseResult":{"type":"update",\
            "filePath":"/w/big.txt","content":\(Self.quoted(big)),"originalFile":\(Self.quoted(big)),\
            "structuredPatch":[{"oldStart":3,"oldLines":2,"newStart":3,"newLines":3,"lines":[" keep","-old","+new","+added"]}]}}
            """
        let record = try Self.record(json)
        let result = try #require(record.toolResult?.result)
        #expect(result.diff == ChatDiffStats(added: 2, removed: 1))
        let hunk = ChatDiffHunk(oldStart: 3, oldLines: 2, newStart: 3, newLines: 3, lines: [" keep", "-old", "+new", "+added"])
        #expect(
            result.fileChanges
                == ChatFileChanges(files: [
                    ChatFileChange(path: "/w/big.txt", kind: .updated, added: 2, removed: 1, lineCount: 4, hunks: [hunk])
                ]))
        #expect(result.filePath == "/w/big.txt")
        #expect(record.blocks.count == 1)

        let created = try Self.record(
            """
            {"type":"user","uuid":"r2","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result",\
            "tool_use_id":"toolu_c","content":"File created"}]},"toolUseResult":{"type":"create","filePath":"/w/new.txt",\
            "content":\(Self.quoted(big)),"structuredPatch":[]}}
            """)
        let creation = try #require(created.toolResult?.result)
        #expect(creation.diff == ChatDiffStats(added: 5_000, removed: 0))
        let file = try #require(creation.fileChanges?.files.first)
        #expect(file.kind == .created)
        #expect(file.added == 5_000 && file.removed == 0 && file.lineCount == 5_000)
        #expect(file.heldLineCount == ChatFileChanges.rowLimits.lines)
        #expect(file.hunks.first?.lines.first == "+line of a large file")
        #expect(file.hunks.first?.newStart == 1 && file.hunks.first?.newLines == 5_000)
        #expect(!file.isComplete)
    }

    @Test("Images keep only their count")
    func imagesAreCounted() throws {
        let data = String(repeating: "iVBORw0KGgo", count: 2_000)
        let prompt = try Self.record(
            """
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":[{"type":"text","text":"What is this?"},\
            {"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(data)"}}]},"promptSource":"typed"}
            """)
        #expect(prompt.blocks == [.text("What is this?"), .image])
        #expect(prompt.imageCount == 1)

        let result = try Self.record(
            """
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result",\
            "tool_use_id":"toolu_r","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(data)"}}]}]}}
            """)
        #expect(result.toolResults == [
            ClaudeToolResult(toolUseID: "toolu_r", isError: false, content: ChatToolPreview(text: "", isTruncated: false, imageCount: 1))
        ])
    }

    @Test("A field of an unexpected type reads as absent")
    func lenientFields() throws {
        let record = try Self.record(
            """
            {"type":"user","uuid":"u1","parentUuid":7,"isMeta":"yes","promptSource":["typed"],"origin":"human",\
            "message":{"role":"user","content":[{"type":"text","text":"hi"},42,"loose",{"type":"tool_use","input":[]}]},\
            "toolDenialUnanswered":"stream-closed"}
            """)
        #expect(record.parentUUID == nil)
        #expect(!record.isMeta)
        #expect(record.promptSource == nil)
        #expect(record.originKind == nil)
        #expect(record.texts == ["hi"])
        #expect(record.blocks.count == 4)
        #expect(record.toolUses == [ClaudeToolUse(id: "", name: "", input: ClaudeToolInput())])
    }

    @Test("Unreadable lines are counted once each, never fatal")
    func diagnostics() {
        let texts = [
            #"not json"#,
            #"["an","array"]"#,
            #"{"no":"type"}"#,
            #"{"type":"user","parentUuid":null}"#,
            #"{"type":"brand-new-metadata","sessionId":"s"}"#,
            #"{"type":"future-record","uuid":"f1","parentUuid":null}"#,
            #"{"type":"system","subtype":"future_subtype","uuid":"y1","parentUuid":"f1"}"#,
        ]
        var offset: UInt64 = 0
        var lines: [ChatLine] = []
        for text in texts {
            lines.append(ChatLine(offset: offset, data: Data(text.utf8)))
            offset += UInt64(text.utf8.count + 1)
        }
        // A line longer than the framer keeps arrives as a prefix.
        lines.append(ChatLine(offset: offset, length: 20_000_000, data: Data(#"{"type":"user","uuid":"#.utf8)))

        var reducer = ClaudeTranscriptReducer()
        reducer.append(lines)
        reducer.append(lines)
        #expect(
            reducer.index.diagnostics
                == ChatTranscriptDiagnostics(
                    invalidLines: 4, oversizedLines: 1,
                    unknownRecordTypes: ["brand-new-metadata", "future-record", "system/future_subtype"]))
        // The unknown record stays on the tree so records below it are reachable.
        #expect(reducer.index.records["f1"]?.kind == .unknown("future-record"))
        #expect(reducer.index.records["y1"]?.parentUUID == "f1")
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Agent session settings", .serialized)
struct AgentSessionSettingsTests {
    @Test("A fresh Claude session shows live settings and keeps its confirmed mode while switching", arguments: [false, true])
    @MainActor func newConversationSettings(initiallyEmpty: Bool) async throws {
        let host = Host.fixture()
        let sessionID = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
        let info = AgentInfo(
            agentStatus: .idle, focused: false, paneID: "w1:p1", revision: 1,
            tabID: "t1", terminalID: "term-1", workspaceID: "w1", agent: "claude",
            agentSession: .init(agent: "claude", kind: .id, source: "herdr:claude", value: sessionID),
            cwd: "/home/dev/proj")
        let transport = ScriptedTransport(snapshot: .fixture(agents: [info]))
        let files = VirtualHostFiles()
        await files.makeDirectory("/home/dev/.claude/session-env/\(sessionID)")
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(info))
        let rule = String(repeating: "─", count: 93)
        // Claude Code 2.1.319's fresh-session screen, with no transcript yet.
        let screen = [
            " ▐▛███▛█   Claude Code v2.1.319",
            "▝▜██████▀  Sonnet 5.5 · Claude Ultra",
            " ▝▝   ▝▝   ~/proj", "", rule, "❯ ", rule,
            "  ⏵⏵ bypass permissions on (shift+tab to cycle)",
        ].joined(separator: "\r\n")
        if !initiallyEmpty { await transport.setPaneText(screen, paneID: info.paneID) }
        let console = ConsoleStore(chatCache: VolatileChatTranscriptCache()) { _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        console.setHosts([host])
        defer { console.setHosts([]) }
        await console.resume()
        var budget = PollBudget(.seconds(5))
        while console.agents.isEmpty, budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        let agent = try #require(console.agents.first)
        let chat = try #require(console.chatStore(for: agent, program: .claude))
        let suite = "new-claude-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agent.back-header-expanded")
        let controller = UIHostingController(rootView: NavigationStack {
            HerdrCoreChatTests.chatDetail(of: agent, console: console, defaults: defaults)
                .defaultAppStorage(defaults)
        })
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { window in
            if initiallyEmpty {
                var budget = PollBudget(.seconds(2))
                while await transport.agentReadCount == 0, budget.hasTimeLeft {
                    try await Task.sleep(for: .milliseconds(20))
                    budget.charge()
                }
                try #require(await transport.agentReadCount > 0)
                #expect(accessibleElement(labeled: "Permission mode", in: window)?.accessibilityValue == "Permission")
                // The screen finishes painting without another status event.
                await transport.setPaneText(screen, paneID: info.paneID)
            }
            var budget = PollBudget(.seconds(3))
            while budget.hasTimeLeft {
                if chat.conversation.phase == .unavailable(.awaitingFirstMessage(.claude)),
                    accessibleElement(labeled: "Permission mode", in: window)?.accessibilityValue == "bypass",
                    accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue == "Sonnet 5.5" { break }
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            #expect(chat.conversation.phase == .unavailable(.awaitingFirstMessage(.claude)))
            #expect(accessibleElement(labeled: "Permission mode", in: window)?.accessibilityValue == "bypass")
            #expect(accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue == "Sonnet 5.5")
            let model = try #require(accessibleElement(labeled: "Agent settings", in: window))
            let permission = try #require(accessibleElement(labeled: "Permission mode", in: window))
            #expect(model.accessibilityFrame.maxY < permission.accessibilityFrame.minY)
            let frame = window.convert(model.accessibilityFrame, from: nil)
            for y in [frame.minY + 10, frame.maxY - 10] {
                let button = try #require(window.hitTest(CGPoint(x: frame.midX, y: y), with: nil) as? UIButton)
                #expect(button.isEnabled)
            }

            try await HostedMenu.select("plan", labeled: "Permission mode", in: window)
            budget = PollBudget(.seconds(2))
            while accessibleElement(labeled: "Permission mode", in: window)?.accessibilityValue != "Switching from bypass", budget.hasTimeLeft {
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            // Stale terminal frames must leave the last confirmed mode visible.
            try await Task.sleep(for: .milliseconds(300))
            #expect(accessibleElement(labeled: "Permission mode", in: window)?.accessibilityValue == "Switching from bypass")
            #expect(accessibleElement(labeled: "Permission mode", in: window)?.accessibilityTraits.contains(.notEnabled) == true)
            #expect(accessibleElement(labeled: "Agent settings", in: window)?.accessibilityTraits.contains(.notEnabled) == false)
            // Browsing remains available, but it cannot start another switch.
            let items = try await HostedMenu.items(labeled: "Agent settings", in: window) { menu in
                func actions(in menu: UIMenu) -> [UIAction] {
                    menu.children.flatMap { item in
                        if let submenu = item as? UIMenu { return actions(in: submenu) }
                        return (item as? UIAction).map { [$0] } ?? []
                    }
                }
                let choices = actions(in: menu)
                #expect(choices.count == 9)
                #expect(choices.allSatisfy { $0.attributes.contains(.disabled) })
            }
            #expect(items.count == 1)
            if !initiallyEmpty {
                await transport.setPaneText(
                    screen.replacingOccurrences(of: "⏵⏵ bypass permissions on", with: "⏸ plan mode on"),
                    paneID: info.paneID)
            }
            // One case confirms the switch; the other times out on the old footer.
            let finalMode = initiallyEmpty ? "bypass" : "plan"
            budget = PollBudget(.seconds(4))
            while accessibleElement(labeled: "Permission mode", in: window)?.accessibilityValue != finalMode, budget.hasTimeLeft {
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            #expect(accessibleElement(labeled: "Permission mode", in: window)?.accessibilityValue == finalMode)
            #expect(accessibleElement(labeled: "Permission mode", in: window)?.accessibilityTraits.contains(.notEnabled) == false)
            #expect(accessibleElement(labeled: "Agent settings", in: window)?.accessibilityTraits.contains(.notEnabled) == false)

            let reply = #"{"type":"assistant","uuid":"a1","parentUuid":null,"effort":"high","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"Hello"}]}}"#
            await files.write(Data((reply + "\n").utf8), at: "/home/dev/.claude/projects/-home-dev-proj/\(sessionID).jsonl")
            chat.retry()
            budget = PollBudget(.seconds(3))
            while accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue != "Opus 5.5 · high", budget.hasTimeLeft {
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            #expect(accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue == "Opus 5.5 · high")
        }
    }

    @Test("An old transcript cannot offer bypass without a current launch opt-in")
    @MainActor func permissionMenuRequiresBypassAvailability() async throws {
        for available in [false, true] {
            var selected: String?
            let controller = UIHostingController(rootView: AgentPermissionModeLabel(
                settings: .init(model: "claude-opus-5-5", permissionMode: "bypassPermissions"),
                controls: .init(
                    isEnabled: true, allowsBypassPermissions: available,
                    setPermissionMode: { selected = $0 },
                    setModel: { _ in }, setEffort: { _ in }))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading))
            try await withTestWindow(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller
            ) { window in
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                let menus = try await HostedMenu.items(labeled: "Permission mode", in: window)
                let expected = available
                    ? ["manual", "accept edits", "plan", "bypass", "auto"]
                    : ["manual", "accept edits", "plan", "auto"]
                #expect(menus == [expected])
                try await HostedMenu.select("auto", labeled: "Permission mode", in: window)
                #expect(selected == "auto")
                try await HostedMenu.select("manual", labeled: "Permission mode", in: window)
                #expect(selected == "default")
            }
        }
    }

    @Test("Opening fixed shortcuts sends nothing; only a selection sends its alias", arguments: ["claude-opus-5-5", "openai/gpt-5.6-luna"])
    @MainActor func modelAndEffortMenuSelections(currentModel: String) async throws {
        var model: String?
        var effort: String?
        let settings = AgentSessionSettings(model: currentModel, permissionMode: "default", effort: "high")
        let controls = AgentSessionControls(
            isEnabled: true, setPermissionMode: { _ in },
            setModel: { model = $0 },
            setEffort: { effort = $0 })
        let controller = UIHostingController(rootView: VStack {
            AgentDetailHeader(
                palette: .system, isExpanded: .constant(true), onBack: {},
                title: .init(title: "Review changes", kind: "claude", directory: "/home/dev/payments-api"),
                sessionSettings: settings, sessionControls: controls)
                .padding(.horizontal, 12)
            Spacer()
            AgentDetailStatusChrome(
                status: .idle, hostTelemetry: nil, session: settings,
                sessionControls: controls, chromeColorScheme: .light)
        })
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller
        ) { window in
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            #expect(accessibleElements(in: window).filter { $0.accessibilityLabel == "Agent settings" }.count == 1)
            for _ in 0..<2 {
                let menu = try await HostedMenu.items(labeled: "Agent settings", in: window) { menu in
                    #expect(menu.children.count == 1)
                    #expect((menu.children.first as? UIMenu)?.title == "Model")
                }
                #expect(menu.flatMap { $0 } == ["Opus", "Sonnet", "Haiku", "Fable", "low", "medium", "high", "xhigh", "max"])
                #expect(model == nil)
                #expect(effort == nil)
            }
            try await HostedMenu.select("Sonnet", labeled: "Agent settings", in: window)
            #expect(model == "sonnet")
            #expect(effort == nil)
            try await HostedMenu.select("medium", labeled: "Agent settings", in: window)
            #expect(model == "sonnet")
            #expect(effort == "medium")
            let expectedLabel = currentModel == "claude-opus-5-5" ? "Opus 5.5 · high" : "openai/gpt-5.6-luna · high"
            #expect(accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue == expectedLabel)
        }
    }

    @Test("Bypass launch hints parse options, not arbitrary flag-looking text")
    func bypassLaunchOptions() {
        let allow = "--allow-dangerously-skip-permissions"
        for args in [
            [allow], ["--dangerously-skip-permissions"], ["--permission-mode", "bypassPermissions"],
            ["--permission-mode=bypassPermissions"], ["--permission-mode", "manual", allow],
            ["--tools", "", "--strict-mcp-config", "--settings", "", allow],
            ["--settings=", "--model=", allow], [allow, "--", "a prompt"],
        ] {
            #expect(ClaudePermissionMode.optsIntoBypass(argv: [""] + args), "\(args)")
        }
        for args in [
            [], ["--permission-mode", "manual"], ["--", allow], ["--system-prompt", allow],
            ["--settings", "--permission-mode=bypassPermissions"], [allow, "--restricted"],
            ["--permission-mode", "bypassPermissions", "--permission-mode=manual"],
            ["--permission-mode=bypassPermissions", "--permission-mode", "manual"],
            ["--unknown", allow], ["--tools", "", "-", allow], ["--allow-dangerously-skip-permissions=false"],
            ["some prompt quoting " + allow],
        ] {
            #expect(!ClaudePermissionMode.optsIntoBypass(argv: [""] + args), "\(args)")
        }
    }

    @Test("A rejected bypass hint lasts only for that process, and unknown never inherits a hint")
    @MainActor func bypassHintFollowsTheProcess() throws {
        let state = AgentSettingOverrides()
        func launch(_ start: String, optedIn: Bool = true) throws -> ClaudePermissionMode.Launch {
            try #require(ClaudePermissionMode.Launch(pid: "42", facts: .init(
                start: .value(start), argumentVector: .value(
                    optedIn ? ["claude", "--allow-dangerously-skip-permissions"] : ["claude"]))))
        }
        #expect(!state.allowsBypassPermissions)
        let original = try launch("100")
        state.refreshPermissionLaunch(original, liveMode: "default")
        #expect(state.allowsBypassPermissions)
        state.bypassWasMissingFromCycle()
        state.refreshPermissionLaunch(nil, liveMode: nil)
        state.refreshPermissionLaunch(original, liveMode: "plan")
        #expect(!state.allowsBypassPermissions)
        state.refreshPermissionLaunch(try launch("101"), liveMode: "default")
        #expect(state.allowsBypassPermissions)
        state.refreshPermissionLaunch(try launch("102", optedIn: false), liveMode: "default")
        #expect(!state.allowsBypassPermissions)
        state.refreshPermissionLaunch(nil, liveMode: "bypassPermissions")
        #expect(state.allowsBypassPermissions)
        state.refreshPermissionLaunch(nil, liveMode: nil)
        #expect(!state.allowsBypassPermissions)
    }

    @Test("A missing mode finishes one cycle at its starting mode, including delayed frames")
    @MainActor func permissionSwitchWaitsAndStopsAtTheOriginalMode() async {
        for hasBypass in [false, true] {
            let footers = ["? for shortcuts", "⏵⏵ accept edits on", "⏸ plan mode on"]
                + (hasBypass ? ["⏵⏵ bypass permissions on"] : []) + ["⏵⏵ auto mode on"]
            var index = 0
            var pending: Int?
            var staleFrames = 0
            var keys = 0
            let result = await ClaudePermissionMode.switchTo(
                "bypassPermissions", readScreen: {
                    if let next = pending {
                        if staleFrames > 0 { staleFrames -= 1 } else { index = next; pending = nil }
                    }
                    return Self.permissionScreen(footers[index])
                }, press: { _ in
                    #expect(pending == nil, "Never send a second key over an unconfirmed first key")
                    keys += 1
                    pending = (index + 1) % footers.count
                    staleFrames = 4
                }, mayContinue: { true }, pause: {})
            #expect(result.reachedTarget == hasBypass)
            #expect(result.completedCycle == !hasBypass)
            #expect(result.mode == (hasBypass ? "bypassPermissions" : "default"))
            #expect(keys == (hasBypass ? 3 : 4))
            #expect(index == (hasBypass ? 3 : 0))
        }
    }

    @Test("Missing feedback, a dialog or an interrupted switch never sends more keys")
    @MainActor func permissionSwitchStopsOnUncertainty() async {
        var keys = 0
        let stuck = await ClaudePermissionMode.switchTo(
            "bypassPermissions", readScreen: { Self.permissionScreen("? for shortcuts") },
            press: { _ in keys += 1 }, mayContinue: { true }, pause: {})
        #expect(keys == 1 && stuck.feedbackTimedOut && !stuck.completedCycle && !stuck.reachedTarget)
        keys = 0
        let interrupted = await ClaudePermissionMode.switchTo(
            "bypassPermissions", readScreen: { Self.permissionScreen("? for shortcuts") },
            press: { _ in keys += 1 }, mayContinue: { keys == 0 }, pause: {})
        #expect(keys == 1 && !interrupted.completedCycle && !interrupted.reachedTarget)
        keys = 0
        let unknown = await ClaudePermissionMode.switchTo(
            "default", readScreen: { ANSIScreenDecoder.decode("Connecting…") },
            press: { _ in keys += 1 }, mayContinue: { true }, pause: {})
        #expect(keys == 0 && !unknown.reachedTarget)
        let missingFooter = await ClaudePermissionMode.switchTo(
            "default", readScreen: { Self.permissionScreen("") },
            press: { _ in keys += 1 }, mayContinue: { true }, pause: {})
        #expect(keys == 0 && missingFooter.mode == nil && !missingFooter.reachedTarget)
    }

    private static func permissionScreen(_ footer: String) -> ANSIScreen {
        let rule = String(repeating: "─", count: 60)
        return ANSIScreenDecoder.decode([rule, "❯ ", rule, footer].joined(separator: "\r\n"))
    }

    @Test("Default mode is quiet without controls and an empty model has no subtitle")
    func quietWhenDefault() {
        #expect(AgentSessionSettings(model: nil, permissionMode: "default").notablePermissionMode == nil)
        #expect(AgentSessionSettings(model: "", permissionMode: nil).modelLine == nil)
        #expect(AgentSessionSettings(model: nil, permissionMode: "bypassPermissions").notablePermissionMode == "bypassPermissions")
        #expect(AgentSessionSettings.permissionTitle("bypassPermissions") == "bypass")
        #expect(AgentSessionSettings.permissionTitle("weird") == "weird")
    }

    @Test("Claude model ids shorten to the footer's name; others stay")
    func modelTitle() {
        #expect(AgentSessionSettings.modelTitle("claude-opus-5-5") == "Opus 5.5")
        #expect(AgentSessionSettings.modelTitle("claude-opus-5-5[1m]") == "Opus 5.5")
        #expect(AgentSessionSettings.modelTitle("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(AgentSessionSettings.modelTitle("claude-3-5-sonnet-20241022") == "claude-3-5-sonnet-20241022")
        #expect(AgentSessionSettings.modelTitle("deepseek-v4.1-flash") == "deepseek-v4.1-flash")
        #expect(AgentSessionSettings.modelTitle("mystery-1") == "mystery-1")
        #expect(AgentSessionSettings.modelTitle("sonnet") == "Sonnet")
        #expect(AgentSessionSettings.model("claude-opus-5-5[1m]", is: "opus"))
        #expect(!AgentSessionSettings.model("claude-opus-5-5", is: "sonnet"))
        #expect(AgentSessionSettings.modelChoices.allSatisfy { !AgentSessionSettings.model("openai/gpt-5.6-luna", is: $0.id) })
    }

    @Test("Only a pristine Claude welcome banner supplies a model before the first reply")
    func welcomeModel() throws {
        let ready = try ScreenFixture.text("claude-01-ready")
        #expect(AgentSessionSettings.welcomeModel(onScreen: ANSIScreenDecoder.decode(ready)) == "Sonnet 5.5")
        #expect(AgentSessionSettings.welcomeModel(onScreen: Self.permissionScreen("[Opus 5.5 high]")) == nil)
        let changed = ready.replacingOccurrences(of: "Claude Code", with: "Some reply quoting Claude Code")
        // A banner left above a command or reply cannot name the current model.
        let banner = [" ▐▛███▛█   Claude Code v2.1.319", "▝▜██████▀  Sonnet 5.5 · Claude Ultra", " ▝▝   ▝▝   ~/proj"]
        #expect(AgentSessionSettings.welcomeModel(onScreen: ScreenFixture.synthetic(banner + ["❯ /model opus", "Set model to Opus 5.5"])) == nil)
        #expect(AgentSessionSettings.welcomeModel(onScreen: ANSIScreenDecoder.decode(changed)) == nil)
    }

    @Test("A switch's answer is the line below the newest echo of its command, not a recount")
    func switchOutcome() {
        func outcome(_ rows: [String]) -> AgentSessionSettings.Outcome {
            .init(of: "/model sonnet", done: "Set model to", kept: "Kept model as",
                  on: ANSIScreenDecoder.decode(rows.joined(separator: "\r\n")))
        }
        let before = outcome(["> /model sonnet", "  ⎿  Kept model as Opus 5.5", "> /model opus", "  ⎿  Set model to Opus 5.5", "> "])
        #expect(before.echoes == 1 && before.result == false)
        // Typed, not answered yet: the old Kept is not this command's.
        #expect(outcome(["> /model sonnet", "  ⎿  Kept model as Opus 5.5", "> "]).answered(since: before) == nil)
        // A full screen dropped both old lines, so no count of Set grows.
        let scrolled = outcome(["  ⎿  Set model to Opus 5.5", "> /model sonnet", "  ⎿  Set model to Sonnet 5.5", "> "])
        #expect(scrolled.value == "Sonnet 5.5")
        #expect(outcome(["> /model sonnet", "  ⎿  Set model to probe/small-model", "> "]).value == "probe/small-model")
        #expect(outcome(["> /model sonnet", "  ⎿  Set model to probe/small-model and saved as your default for new sessions", "> "]).value == "probe/small-model")
        #expect(before.value == nil)
        #expect(scrolled.answered(since: AgentSessionSettings.Outcome(
            of: "/model sonnet", done: "Set model to", kept: "Kept model as",
            on: ANSIScreenDecoder.decode("  ⎿  Set model to Opus 5.5\r\n> "))) == true)
        #expect(outcome(["> /model sonnet", "  ⎿  Kept model as Opus 5.5", "> /model sonnet", "  ⎿  Kept model as Opus 5.5"])
            .answered(since: before) == false)
    }

    @Test("A confirmed switch stands until the transcript records other values")
    @MainActor func overridesStandOverTheirTranscript() {
        let overrides = AgentSettingOverrides()
        let before: [String?] = ["default", "claude-opus-5-5", "high"]
        overrides.set(.model, "sonnet", over: before)
        overrides.set(.effort, "low", over: before)
        #expect(overrides.value(.model, over: before) == "sonnet")
        #expect(overrides.value(.effort, over: before) == "low")
        #expect(overrides.value(.permissionMode, over: before) == nil)
        // A newer reply records its own; the switch no longer stands over it.
        #expect(overrides.value(.model, over: ["default", "claude-sonnet-5-5", "low"]) == nil)
        // The footer's mode is not the reply's to replace.
        overrides.set(.permissionMode, "auto", over: before)
        #expect(overrides.value(.permissionMode, over: ["default", "claude-sonnet-5-5", "low"]) == "auto")
    }

    @Test("The permission mode is read off Claude Code's footer, not the conversation above it")
    func permissionModeOnScreen() throws {
        func screen(_ rows: [String]) -> ANSIScreen { ANSIScreenDecoder.decode(rows.joined(separator: "\r\n")) }
        let filler = Array(repeating: "", count: 6)
        #expect(AgentSessionSettings.permissionMode(onScreen: screen([])) == nil)
        #expect(AgentSessionSettings.permissionMode(onScreen: Self.permissionScreen("")) == nil)
        #expect(AgentSessionSettings.permissionMode(onScreen: try ScreenFixture.screen("claude-01-ready")) == "default")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["> hi", "", "  ⏵⏵ bypass permissions on (shift+tab to cycle)"])) == "bypassPermissions")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["  ⏸ plan mode on (shift+tab to cycle)"])) == "plan")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["  ⏵⏵ accept edits on"])) == "acceptEdits")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["plan mode on, said the reply"] + filler + ["  ? for shortcuts"])) == "default")
        // Claude Code 2.1.291 after a plan approval: four footer lines below the box.
        #expect(AgentSessionSettings.permissionMode(onScreen: try ScreenFixture.screen("claude-21-c6-after")) == "auto")
        let rule = String(repeating: "─", count: 40)
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["⏺ It printed bypass permissions on", rule, "> ", rule, "  ⏸ plan mode on (shift+tab to cycle)"])) == "plan")
        #expect(AgentSessionSettings.permissionMode(onScreen: screen(["⏺ bypass permissions on", rule, "> ", rule, "  ? for shortcuts"])) == "default")
    }
}
