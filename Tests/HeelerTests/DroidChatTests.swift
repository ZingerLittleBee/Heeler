import Foundation
import Testing

@testable import Heeler

@Suite("Droid Chat")
struct DroidChatTests {
    private let session = "c5cc3f15-8d61-4921-a9e4-06419e62b300"
    private let other = "0160cefa-7648-4324-b7d3-b2fb89d4f2d3"

    private func header(_ id: String) -> String {
        #"{"type":"session_start","id":"\#(id)","title":"Read a file","version":2,"cwd":"/repo"}"# + "\n"
    }

    @Test func followsOnlyTheReportedSessionAcrossProjectsAndRewrites() async throws {
        let files = VirtualHostFiles(home: "/home/test")
        let root = "/home/test/.factory/sessions"
        let misplaced = "\(root)/-repo/\(session).jsonl"
        let resumed = "\(root)/-old-dir/\(session).jsonl"
        await files.write(header(other), at: misplaced)
        await files.write(header(other), at: "\(root)/-repo/\(other).jsonl")
        await files.write(header(session), at: resumed)
        let reference = ConversationReference(program: .droid, sessionID: session)
        let engine = ChatConversationEngine(
            reference: reference, cacheKey: .init(hostID: UUID(), herdrSession: "", program: .droid, conversationID: session),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: .droid)), now: { Date() })
        let snapshot = await engine.open(directories: ["/repo"], context: .init())
        #expect(snapshot.phase == .following(path: resumed))
        #expect(snapshot.transcript.title == "Read a file")

        await files.write(header(other) + #"{"type":"message","id":"new","message":{"role":"assistant","content":"other conversation"}}"# + "\n", at: resumed)
        let replaced = await engine.poll(context: .init())
        #expect(replaced.phase == .unavailable(.mismatched))
        #expect(replaced.transcript.entries.isEmpty)
    }

    @Test func projectsVisibleMessagesAndMatchesToolResultsAcrossPages() throws {
        // The fields and roles are from Droid 1.21.1, with test text and ids.
        let data = header(session) + """
            {"type":"message","id":"hook","message":{"role":"user","visibility":"user_only","hookEventName":"SessionStart","content":"hook output"}}
            {"type":"message","id":"ctx","message":{"role":"user","visibility":"llm_only","content":[{"type":"text","text":"host context"}]}}
            {"type":"message","id":"u","timestamp":"2026-11-27T00:00:00.000Z","message":{"role":"user","userMessageSource":"cli_tui","content":[{"type":"text","text":"Read the file"}]}}
            {"type":"message","id":"a","message":{"role":"assistant","modelId":"model","content":[{"type":"thinking","thinking":"Looking up the file"},{"type":"tool_use","name":"Read","id":"c","input":{"file_path":"/repo/LICENSE"}}]}}
            {"type":"message","id":"r","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c","is_error":false,"content":"license text","model_content":"internal copy"},{"type":"text","text":"tool context"}]}}
            {"type":"message","id":"b","message":{"role":"assistant","content":"Here it is."}}
            {"type":"agent_turn_outcome","turnId":"u","reason":"completed","resultKind":"text"}
            """ + "\n"
        let lines = JSONLLineFramer.lines(in: Data(data.utf8))
        var reducer = DroidTranscriptReducer()
        reducer.append(Array(lines.suffix(3)))
        reducer.prepend(Array(lines.dropLast(3)))
        let transcript = reducer.transcript(.init(activity: .idle))
        #expect(transcript.recordedPrompts.map(\.text) == ["Read the file"])
        #expect(transcript.entries.count == 4)
        let tool = try #require(transcript.entries.compactMap { entry -> ChatToolActivity? in
            guard case .tool(let value) = entry.content else { return nil }
            return value
        }.first)
        #expect(tool.title == "LICENSE")
        #expect(tool.status == .succeeded)
        #expect(tool.preview?.text == "license text")
        let resultLine = try #require(lines.first { $0.offset == tool.output?.offset })
        #expect(reducer.output(of: resultLine, for: tool) == .preview(.init(capping: "license text")))
        #expect(transcript.entries.last?.content == .assistant(.init(text: "Here it is.")))
        #expect(transcript.turns.map(\.ending) == [.completed])
    }

    @Test func hookPlacementPreservesCustomLaunchSettingsAndExistingUserHooks() async throws {
        let config = "/home/dev/.factory/settings.json"
        let original = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-stop"}]}]},"other":true}"#.utf8)
        let host = InMemoryHostFiles(files: [config: original])
        func place(_ action: DroidChatHook.Action) async throws -> String {
            try await DroidChatHook.place(on: host, action: action) { try await host.createHostFolder(path: $0) }
        }
        let launch = try await place(.launch)
        #expect(await host.files[config] == original)
        #expect(await host.files[launch] != nil)
        for arguments in [["--settings", "/custom.json"], ["--settings=/custom.json"]] {
            #expect(!DroidChatHook.offersLaunchSettings(kind: "droid", arguments: arguments, kernel: HerdrCoreLocator.macOSKernel))
        }
        _ = try await place(.register)
        let added = try #require(await host.files[config])
        #expect(added != original)
        _ = try await place(.register)
        #expect(await host.files[config] == added)
        _ = try await place(.removeRegistration)
        #expect(await host.files[config] == original)
    }

    @Test func sendsOnlyAtAnEmptyDroidPromptAndInterruptsOnlyAWorkingTurn() {
        func screen(_ field: String, above: String = "", footer: String = "MCP ✓ | IDE ◌") -> ANSIScreen {
            ANSIScreenDecoder.decode("\(above)\n╭──────────────────────────────────────╮\n│ > \(field) │\n╰──────────────────────────────────────╯\n\(footer)")
        }
        #expect(DroidInputBox.read(screen("")) == .empty(placeholder: nil))
        for status in ["MCP ✓ | TMUX ⧉", "MCP ✓ | GHOSTTY ᗣ"] {
            #expect(DroidInputBox.read(screen("", footer: status)) == .empty(placeholder: nil))
        }
        #expect(DroidInputBox.read(screen("draft")) == .text("draft"))
        #expect(!DroidInputBox.read(screen("", footer: "> 1. Trust this folder\nEnter to confirm")).allowsSendAnyway)
        #expect(!DroidInputBox.read(ANSIScreenDecoder.decode("Trust this folder?\n> 1. Trust this folder")).isSendable)
        let busy = screen("Enter to steer · Ctrl+Enter to queue", above: "⠇ Thinking...  (Press ESC to stop)")
        #expect(DroidInputBox.read(busy) == .disabled(DroidInputBox.working))
        #expect(DroidInputBox.stop(.init(screen: busy, activity: .working)) == .press)
        #expect(DroidInputBox.stop(.init(screen: screen(""), activity: .working)) != .press)
    }
}
