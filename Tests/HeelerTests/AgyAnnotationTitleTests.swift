import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgyAnnotationTitleTests {
    private static let home = "/home/dev"
    private static let defaultRoot = "/home/dev/.gemini/antigravity-cli"
    private static let firstID = "5f0d2b6c-1234-4abc-9def-0123456789ab"
    private static let secondID = "7a1e3c8d-5678-4def-8abc-fedcba987654"
    private static let subagentID = "9b2f4d0e-9999-4111-8222-111122223333"

    private static func pbtxtPath(root: String = defaultRoot, id: String = firstID) -> String {
        "\(root)/annotations/\(id).pbtxt"
    }

    private static func transcriptPath(root: String = defaultRoot, id: String = firstID) -> String {
        "\(root)/brain/\(id)/.system_generated/logs/transcript_full.jsonl"
    }

    private static func subagentTranscript(sender: String) -> String {
        #"{"step_index":0,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-12T18:23:33Z","content":"The following is a <SYSTEM_MESSAGE> not actually sent by the user.\n\n<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-12T18:23:33Z sender=\#(sender) priority=MESSAGE_PRIORITY_HIGH content=task"}"#
            + "\n"
    }

    private static func rootTranscript() -> String {
        #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"hello"}"# + "\n"
    }

    private func waitUntil(
        _ what: String,
        _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    // MARK: - Prototext Parser

    @Test func parseHandlesUTF8DetrandQuotesEscapesCommentsAndNestedBlocks() {
        let standard = """
            # prototext comment with title: "Not a field"
            last_user_view_time: {
              seconds: 1780000000
              title: "Wrong Nested Brace"
            }
            nested_angle: <
              title: "Wrong Nested Angle"
            >
            items: [
              { title: "Wrong List Element" },
              "scalar"
            ]
            title:  "Fix  login 🐝"
            other_field: "ignored"
            """
        #expect(AgyAnnotationTitle.parse(Data(standard.utf8)) == "Fix  login 🐝")

        let singleQuotedAndAdjacent = """
            title: 'Hello "world" '
              "from prototext"
            """
        #expect(AgyAnnotationTitle.parse(Data(singleQuotedAndAdjacent.utf8)) == #"Hello "world" from prototext"#)

        let escaped = #"""
            title: "Line1\t\\ \"A\" \'B\' \344\270\255 \x41 \u0042 \U0001F41D \uD83D\uDC1D"
            """#
        #expect(AgyAnnotationTitle.parse(Data(escaped.utf8)) == #"Line1 \ "A" 'B' 中 A B 🐝 🐝"#)

        let controlWhitespaceNormalized = "title: \"One\\nTwo\\r\\nThree\\tFour\\x07\""
        #expect(AgyAnnotationTitle.parse(Data(controlWhitespaceNormalized.utf8)) == "One Two  Three Four")
    }

    @Test func parseFailsClosedOnUntitledMalformedTruncatedOrOversizedFiles() {
        let untitled = """
            last_user_view_time: {
              seconds: 1780000000
            }
            """
        #expect(AgyAnnotationTitle.parse(Data(untitled.utf8)) == nil)
        #expect(AgyAnnotationTitle.parse(Data()) == nil)
        #expect(AgyAnnotationTitle.parse(Data(#"title: "   \n\t  ""#.utf8)) == nil)

        // Malformed / truncated prototext fails closed.
        #expect(AgyAnnotationTitle.parse(Data(#"title: "unterminated"#.utf8)) == nil)
        #expect(AgyAnnotationTitle.parse(Data(#"meta: { title: "nested" "#.utf8)) == nil)
        #expect(AgyAnnotationTitle.parse(Data(#"title: "bad \uD800lone surrogate""#.utf8)) == nil)
        #expect(AgyAnnotationTitle.parse(Data(#"title: "bad \x""#.utf8)) == nil)
        #expect(AgyAnnotationTitle.parse(Data([0xFF, 0xFE, 0x0A])) == nil)

        // Files larger than 16 KiB fail closed.
        let hugeValue = String(repeating: "a", count: AgyAnnotationTitle.maximumAnnotationBytes + 32)
        let huge = Data("title: \"\(hugeValue)\"\n".utf8)
        #expect(AgyAnnotationTitle.parse(huge) == nil)
    }

    // MARK: - Root Conversation & Multi-Account Resolution

    @Test func resolveRootConversationHandlesMultiAccountSubagentsAndUnverifiedFolders() async throws {
        let files = VirtualHostFiles(home: Self.home)
        let altRoot = "/accounts/work/.gemini/antigravity-cli"
        await files.setAccountDirectories([altRoot], for: .antigravity)

        // Pre-transcript folder only: unverified root so callers do not cache subagent confusion.
        await files.makeDirectory("\(altRoot)/brain/\(Self.firstID)/scratch")
        let unverified = try await AgyAnnotationTitle.resolveRootConversation(
            sessionID: Self.firstID, files: files.hostFiles())
        #expect(
            unverified == AgyAnnotationTitle.ResolvedConversation(
                root: altRoot, rootID: Self.firstID, isVerifiedRoot: false))

        // Annotation-only root (transcript missing): verified under the owning account root.
        await files.write("title: \"Work Account Title\"\n", at: Self.pbtxtPath(root: altRoot, id: Self.firstID))
        let annotationOnly = try await AgyAnnotationTitle.resolveRootConversation(
            sessionID: Self.firstID.uppercased(), files: files.hostFiles())
        #expect(
            annotationOnly == AgyAnnotationTitle.ResolvedConversation(
                root: altRoot, rootID: Self.firstID, isVerifiedRoot: true))

        // Subagent hook ID resolves via `sender=` chain to parent root conversation's .pbtxt.
        await files.write(Self.rootTranscript(), at: Self.transcriptPath(root: altRoot, id: Self.firstID))
        await files.write(
            Self.subagentTranscript(sender: Self.firstID),
            at: Self.transcriptPath(root: altRoot, id: Self.subagentID))
        let resolvedSubagent = try await AgyAnnotationTitle.resolveRootConversation(
            sessionID: Self.subagentID, files: files.hostFiles())
        #expect(
            resolvedSubagent == AgyAnnotationTitle.ResolvedConversation(
                root: altRoot, rootID: Self.firstID, isVerifiedRoot: true))
    }

    // MARK: - Herdr TUI Integration

    @Test func herdrTUIRetriesTurnOneClearsOnSessionChangeRefreshesMacRenameAndUpdatesSavedChats() async throws {
        let host = Host(address: "tui.example", username: "dev", serverKind: .herdrTUI)
        let files = VirtualHostFiles(home: Self.home)

        func makeInfo(sessionID: String?, status: AgentStatus = .idle, revision: Int = 1) -> AgentInfo {
            AgentInfo(
                agentStatus: status, focused: false, paneID: "w1:p1", revision: revision,
                tabID: "w1:t1", terminalID: "term-1", workspaceID: "w1",
                agent: ChatProgram.agy.rawValue,
                agentSession: sessionID.map {
                    AgentSessionInfo(
                        agent: ChatProgram.agy.rawValue, kind: .id,
                        source: "herdr:antigravity_cli", value: $0)
                },
                cwd: "/home/dev/proj",
                terminalTitleStripped: "~/h/d/proj",
                title: "~/h/d/proj")
        }

        let firstInfo = makeInfo(sessionID: Self.firstID, status: .working, revision: 1)
        let transport = ScriptedTransport(snapshot: .fixture(agents: [firstInfo]))
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(firstInfo))

        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            chatPrefetchRetryDelay: .milliseconds(20),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions, connect: { transport },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
                    keepalive: nil)
            })
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("initial agy row") { !store.agents.isEmpty }
        await store.resolveHostPlatform(host.id)

        // Initially no .pbtxt exists -> stays untitled, then Turn 1 writes .pbtxt -> retry picks it up.
        #expect(store.agents.first?.agent.title == "~/h/d/proj")
        await files.write(Self.rootTranscript(), at: Self.transcriptPath(id: Self.firstID))
        await files.write("title: \"Auto First Title\"\n", at: Self.pbtxtPath(id: Self.firstID))
        try await waitUntil("Turn-1 retry picks up .pbtxt title") {
            store.agents.first?.agent.title == "Auto First Title"
        }

        // Mac-side `/rename` edits .pbtxt while status stays idle -> pull-to-refresh + liveChatAgentInfo see it.
        await files.write("title: \"Renamed On Mac\"\n", at: Self.pbtxtPath(id: Self.firstID))
        await store.refreshSidebarLayouts()
        try await waitUntil("refreshSidebarLayouts picks up Mac-side rename") {
            store.agents.first?.agent.title == "Renamed On Mac"
        }

        let liveAgent = try #require(store.agents.first)
        let chat = try #require(store.chatStore(for: liveAgent, program: .agy))
        chat.show()
        try await waitUntil("Chat following and cached with Mac-side title") {
            store.cachedChats.agents(on: host).first?.agent.title == "Renamed On Mac"
        }
        chat.end()

        // Switching to a new untitled conversation (e.g. `/clear`) clears the old title immediately with no bleed.
        let secondInfo = makeInfo(sessionID: Self.secondID, status: .idle, revision: 2)
        await transport.setSnapshot(.fixture(agents: [secondInfo]))
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(secondInfo))
        await transport.emit(HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))
        try await waitUntil("new session clears old title") {
            store.agents.first?.agent.agentSession?.value == Self.secondID
                && store.agents.first?.agent.title == "~/h/d/proj"
        }

        // Once the second conversation gets a title, Saved Chats retains it offline.
        await files.write(Self.rootTranscript(), at: Self.transcriptPath(id: Self.secondID))
        await files.write("title: \"Second Topic\"\n", at: Self.pbtxtPath(id: Self.secondID))
        try await waitUntil("second session picks up its title") {
            store.agents.first?.agent.title == "Second Topic"
        }
        try await waitUntil("Saved Chats records titled session") {
            store.cachedChats.agents(on: host).first?.agent.title == "Second Topic"
        }
        await store.suspend()
        #expect(store.agents.isEmpty)
        #expect(store.cachedChats.agents(on: host).first?.agent.title == "Second Topic")
        #expect(store.chatDisplayAgents.first?.agent.title == "Second Topic")
    }

    // MARK: - POSIX herdr-core Integration

    @Test func posixHerdrCoreReadsAnnotationViaChatBindingAndClearsWhenLockDrops() async throws {
        let host = Host(address: "core.example", username: "dev", serverKind: .herdrCore)
        let files = VirtualHostFiles(home: Self.home)
        let agyRoot = Self.defaultRoot
        let turns = try ChatFixture.data("agy/core-turns.jsonl")
        await files.write(turns, at: Self.transcriptPath(root: agyRoot, id: Self.firstID))
        await files.write("title: \"Core Title From Pbtxt\"\n", at: Self.pbtxtPath(root: agyRoot, id: Self.firstID))

        let services = CoreTestServices(files: files)
        let record = JSONValue.object([
            "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("agy")]), "keep": .bool(true), "title": .string("/work/app"),
            "cols": .number(80), "rows": .number(24), "name": .null, "reason": .null,
            "pid": .number(40),
            "foreground": .object([
                "pid": .number(40), "name": .string("agy"),
                "argv": .array([.string("agy")]), "cwd": .string("/work/app"),
            ]),
            "status": .object(["state": .string("idle"), "app": .string("antigravity")]),
            "labels": .object([:]),
        ])
        let transport = ScriptedCoreTransport(
            coreID: "c1",
            subscribeResults: [
                .object(["seq": .number(1), "terminals": .array([record]), "channel": .number(1)])
            ],
            services: services)
        await transport.setKernel("Darwin")
        let baseProcess = ScriptedProcessTable.Process(
            pid: 40, parent: 1, name: "agy", start: "111",
            environment: ["HC_SCOPE": "scope", "HOME": Self.home], argv: ["agy"],
            openFiles: [
                "\(agyRoot)/presence/\(Self.firstID).lock",
                "\(agyRoot)/conversations/\(Self.firstID).db",
            ])
        await transport.processTable.add(baseProcess)

        let store = ConsoleStore(
            chatPrefetchRetryDelay: .milliseconds(20),
            chatCache: VolatileChatTranscriptCache(),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
            coreLinuxChatPrograms: Set(ChatProgram.allCases),
            coreMacOSChatPrograms: Set(ChatProgram.allCases))
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("core snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) && !store.agents.isEmpty }
        await store.resolveHostPlatform(host.id)
        try await waitUntil("platform resolved") { store.hostPlatforms[host.id] == .posix }
        try await waitUntil("kernel resolved") { store.hostCoreKernels[host.id] == "Darwin" }

        let consoleAgent = try #require(store.agents.first)
        let chat = try #require(store.chatStore(for: consoleAgent, program: .agy))
        chat.show()
        try await waitUntil("Chat binds and updates core agent title from .pbtxt") {
            store.agents.first?.agent.title == "Core Title From Pbtxt"
        }

        // `/clear` removes the old presence lock; status event triggers Chat recheck -> `onAgyConversationBound(nil, nil)` clears title.
        let clearedProcess = ScriptedProcessTable.Process(
            pid: 40, parent: 1, name: "agy", start: "111",
            environment: ["HC_SCOPE": "scope", "HOME": Self.home], argv: ["agy"],
            openFiles: [])
        await transport.processTable.add(clearedProcess)
        let clearedEvent = (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(2), "type": .string("status"), "terminal": .string("t1"),
                "data": .object([
                    "status": .object(["state": .string("idle"), "app": .string("antigravity")]),
                    "records": .object([:]), "reported": .bool(true),
                ]),
            ]),
        ]))) ?? Data()
        await transport.deliver(clearedEvent)

        try await waitUntil("dropping presence lock clears stale core title") {
            store.agents.first?.agent.title == "/work/app"
        }
        chat.end()
    }

    // MARK: - Zero-Config Title Rename End-to-End

    @Test func consoleStoreTitleRenameSeedsEmptyForUntitledWritesOnlyRenameAndRefreshesMacRename() async throws {
        let host = Host(address: "tui.example", username: "dev", serverKind: .herdrTUI)
        let files = VirtualHostFiles(home: Self.home)
        let session = AgentSessionInfo(
            agent: ChatProgram.agy.rawValue, kind: .id,
            source: "herdr:antigravity_cli", value: Self.firstID)
        let initialInfo = AgentInfo(
            agentStatus: .idle, focused: false, paneID: "w1:p1", revision: 1,
            tabID: "w1:t1", terminalID: "term-1", workspaceID: "w1",
            agent: ChatProgram.agy.rawValue, agentSession: session,
            cwd: "/Users/dev/worktree/Heeler/727",
            terminalTitleStripped: "~/D/w/H/727", title: "~/D/w/H/727")

        let transport = ScriptedTransport(snapshot: .fixture(agents: [initialInfo]))
        let readyScreen = try ScreenFixture.text("agy-02-idle-empty-120x40")
        await transport.setPaneText(readyScreen, paneID: "w1:p1")
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(initialInfo))
        await files.write(Self.rootTranscript(), at: Self.transcriptPath(id: Self.firstID))

        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            chatPrefetchRetryDelay: .milliseconds(20),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions, connect: { transport },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
                    keepalive: nil)
            })
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("agent listed") { !store.agents.isEmpty }
        await store.resolveHostPlatform(host.id)

        let listedAgent = try #require(store.agents.first)
        // Reconcile marks the conversation untitled, so `titleRenameStore(for:)` clears the path title (`""`).
        let renameStore = try #require(store.titleRenameStore(for: listedAgent))
        await renameStore.refreshInitialTitle()
        #expect(renameStore.input.isEmpty)

        // Saving sends `/rename Ship Zero Config` only (no `/title on`, no settings.json reads/writes).
        let promptGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: promptGate)
        renameStore.input = "Ship Zero Config"
        let saveTask = Task { await renameStore.save() }

        await promptGate.waitForEntry()
        await files.write("title: \"Ship Zero Config\"\n", at: Self.pbtxtPath(id: Self.firstID))
        await transport.setPaneText(
            "  ⎿  Conversation renamed to: Ship Zero Config\n" + readyScreen,
            paneID: "w1:p1")
        await promptGate.open()
        await saveTask.value

        #expect(renameStore.state == .renamed)
        #expect(await transport.agentPromptParams.map(\.text) == ["/rename Ship Zero Config"])
        #expect(store.agents.first?.agent.title == "Ship Zero Config")
        let allReads = await files.reads
        #expect(!allReads.contains { $0.path.hasSuffix("settings.json") })
        let allStatuses = await files.statuses
        #expect(!allStatuses.contains { $0.hasSuffix("settings.json") })

        // Reopening Rename after a Mac-side `/rename` updates unedited input on `refreshInitialTitle()`.
        await files.write("title: \"Mac Renamed Title\"\n", at: Self.pbtxtPath(id: Self.firstID))
        let reopenedAgent = try #require(store.agents.first)
        let reopened = try #require(store.titleRenameStore(for: reopenedAgent))
        #expect(reopened.input == "Ship Zero Config")
        await reopened.refreshInitialTitle()
        #expect(reopened.input == "Mac Renamed Title")
    }
}

private struct CoreTestServices: HostServices {
    let files: VirtualHostFiles

    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        try await files.readRange(range)
    }

    func fileStatus(atPath path: String) async throws -> RemoteFileStatus? {
        try await files.fileStatus(atPath: path)
    }

    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing? {
        try await files.listFiles(request)
    }

    func hostHomeDirectory() async throws -> String {
        try await files.home()
    }
}
