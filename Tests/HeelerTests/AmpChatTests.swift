import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Amp Chat")
struct AmpChatTests {
    @Test func foregroundAndDirectoryBelongToOneProcess() throws {
        let pid = 101
        let amp = PaneProcessInfoProcess(name: "amp", pid: pid)
        let one = PaneProcessInfo(paneID: "pane", foregroundProcesses: [amp])
        #expect(AmpPluginLocation.foreground(one) == pid)
        let two = PaneProcessInfo(paneID: "pane", foregroundProcesses: [amp, .init(name: "amp", pid: 102)])
        #expect(AmpPluginLocation.foreground(two) == nil)
        var facts = HostProcessReader.Facts()
        facts.start = .value("123")
        facts.variables = ["HOME": .value("/users/test"), "XDG_CONFIG_HOME": .value("/data/amp-config")]
        #expect(AmpPluginLocation(pid: pid, facts: facts)?.directory == "/data/amp-config/amp/plugins")
        facts.variables["XDG_CONFIG_HOME"] = .unset
        #expect(AmpPluginLocation(pid: pid, facts: facts)?.directory == "/users/test/.config/amp/plugins")
        facts.variables["XDG_CONFIG_HOME"] = .unavailable
        #expect(AmpPluginLocation(pid: pid, facts: facts) == nil)
    }

    @Test func repeatedMessagesAndUpdatedToolResultsKeepTheirOwnIDs() throws {
        func line(_ index: UInt64, _ json: String) -> ChatLine { .init(offset: index, data: Data(json.utf8)) }
        let first = line(0, #"{"id":"n:1","role":"user","blocks":[{"type":"text","text":"same"}]}"#)
        let second = line(3, #"{"id":"s:1","role":"user","blocks":[{"type":"text","text":"same"}]}"#)
        let call = line(1, #"{"id":"s:a","role":"assistant","blocks":[{"type":"tool_use","call":"x","name":"Read","text":"file"}]}"#)
        let done = line(2, #"{"id":"s:b","role":"user","blocks":[{"type":"tool_result","call":"x","status":"done","text":"ok"}]}"#)
        var reducer = AmpTranscriptReducer()
        reducer.append([second])
        reducer.prepend([first, call, done])
        reducer.append([done, second])
        let result = reducer.transcript(.init())
        #expect(result.entries.count == 3)
        #expect(result.recordedPrompts.map(\.text) == ["same", "same"])
        #expect(Set(result.entries.map(\.id)).count == 3)
        guard case .tool(let tool) = result.entries[1].content else { Issue.record("Missing tool call"); return }
        #expect(tool.status == .succeeded)
        #expect(tool.preview?.text == "ok")
    }

    @Test func sendAnywayOverridesAnUnconfirmedAmpBoxAndHoldsOnDraftsAndMenus() async throws {
        let ready = try ScreenFixture.text("amp-01-idle")
        let streaming = ready.replacingOccurrences(of: "╰─", with: "╰ ∼ Streaming 32─")
        let rules = ChatSendRules(program: .amp, commands: [])
        #expect(rules.outgoingText("hello") == "hello")
        func policy(_ value: String) -> ComposerDeliveryPolicy {
            .chat(rules: rules, activity: { .working }, readScreen: { ANSIScreenDecoder.decode(value) })
        }
        for value in ["Unknown screen", streaming] {
            let delivery = policy(value)
            guard case .unconfirmedInputBox = await delivery.preflight?("hello") else {
                Issue.record("An unconfirmed Amp input box must offer Send Anyway"); continue
            }
            #expect(await delivery.admittingUnconfirmedInputBox().preflight?("hello") == nil)
        }
        for value in [
            ready.replacingOccurrences(of: "│        ", with: "│ draft  "),
            streaming.replacingOccurrences(of: "│        ", with: "│ draft  "),
            try ScreenFixture.text("amp-02-command-palette"),
        ] {
            let delivery = policy(value)
            let refusal = await delivery.preflight?("hello")
            guard case .inputNotReady = refusal else {
                Issue.record("A terminal draft or menu must hold Amp Send"); continue
            }
            #expect(await delivery.admittingUnconfirmedInputBox().preflight?("hello") == refusal)
        }
    }

    @Test func expandingAnAmpToolReadsItsOwnResultPastThePreview() throws {
        func line(_ offset: UInt64, _ json: String) -> ChatLine { .init(offset: offset, data: Data(json.utf8)) }
        let call = line(2, #"{"id":"s:a","role":"assistant","blocks":[{"type":"tool_use","call":"build","name":"shell_command"}]}"#)
        let preview = line(3, #"{"id":"s:b","role":"user","blocks":[{"type":"tool_result","call":"build","status":"done","text":"start","truncated":true}]}"#)
        var reducer = AmpTranscriptReducer()
        reducer.append([call, preview])
        let entry = try #require(reducer.transcript(.init()).entries.first)
        guard case .tool(let tool) = entry.content else { Issue.record("Missing tool"); return }
        let reference = try #require(tool.output)
        #expect(reference.offset == 3)
        #expect(tool.previewIsIncomplete)
        let full = String(repeating: "x", count: 8192) + " final error"
        let expanded = line(3, #"{"id":"s:b","role":"user","blocks":[{"type":"tool_result","call":"other","text":"wrong"},{"type":"tool_result","call":"build","text":"\#(full)"}]}"#)
        let result = ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits) {
            reducer.output(of: expanded, for: tool)
        }
        guard case .preview(let output, _)? = result else { Issue.record("Missing expanded result"); return }
        #expect(output?.text == full)
        #expect(output?.isTruncated == false)
    }

    @Test func aTranscriptTableAllowsSendButAFloatingPaletteStillHoldsIt() async throws {
        let composer = try ScreenFixture.text("amp-01-idle")
        let rules = ChatSendRules(program: .amp, commands: [])
        func preflight(_ history: [String]) async -> ComposerRefusal? {
            let screen = ANSIScreenDecoder.decode(history.joined(separator: "\r\n") + "\r\n" + composer)
            let policy = ComposerDeliveryPolicy.chat(rules: rules, activity: { .idle }, readScreen: { screen })
            return await policy.preflight?("Continue")
        }
        for table in [
            [" ╭────────┬────────╮", " │ Case   │ Result │", " ├────────┼────────┤",
             " │ Taipei │ Free   │", " ╰────────┴────────╯"],
            [" ╭────────╮ █", " │ Result │ █", " ├────────┤ █", " │ Free   │ █", " ╰────────╯ █"],
            [" ╭───────┬──────╮", " │ Case  │ Free │", " ├───────┼──────┤", " │ Day 1 │ Yes  │"],
            ["Use ╭─ to begin a rounded border."],
            ["Example: ╭────╮ and ╰────╯."],
            ["╭────╮", "│ UI │", "╰────╯"],
            ["The palette is drawn as ╭─ Command Palette ─╮ in the terminal."],
        ] {
            #expect(await preflight(table) == nil)
        }
        let overlay = [" earlier ╭─ Command Palette ─╮ still visible", " result  │ >                 │",
                       " text    ╰───────────────────╯ behind it"]
        guard case .inputNotReady = await preflight(overlay) else {
            Issue.record("A palette floating entirely above the composer must hold Send"); return
        }
    }

    @Test func ampSendsFileReferencesAndUnicodeAsOrdinaryText() {
        let rules = ChatSendRules(program: .amp, commands: [])
        let path = HostFilesBrowser.reference(to: "/tmp/report.csv", from: "/work")
        let draft = path + " 👩🏽‍💻 ❤️\r\ncheck the total"
        #expect(rules.validate(draft) == nil)
        #expect(rules.outgoingText(draft) == path + " 👩🏽‍💻 ❤️\ncheck the total")
        guard case .unsafeText = rules.validate("/help") else {
            Issue.record("Amp commands belong in Terminal"); return
        }
    }

    @Test func onlyAmpAssistantReplyTrailersAreRemovedFromMessages() throws {
        let tag = "<suggested-replies>\nRun the tests\n</suggested-replies>"
        let quoted = "Example:\n\n```xml\n" + tag + "\n```"
        let literal = "An inline `<suggested-replies>` tag."
        func entry(_ role: String, _ parts: [String]) throws -> [ChatEntry.Content] {
            let row = AmpChatPage.Row(id: "s:msg", role: role, createdAt: nil, end: nil,
                blocks: parts.map { .init(type: "text", text: $0, call: nil, name: nil, status: nil) })
            var reducer = AmpTranscriptReducer()
            reducer.append([.init(offset: 1, data: try JSONEncoder().encode(row))])
            return reducer.transcript(.init()).entries.map(\.content)
        }
        #expect(try entry("assistant", [quoted + "\n\n" + tag]) == [.assistant(.init(text: quoted))])
        #expect(try entry("assistant", ["Seven passed.", tag]) == [.assistant(.init(text: "Seven passed."))])
        #expect(try entry("assistant", ["First.", "Second.", "<suggested-replies>", "Run", "</suggested-replies>"])
                == [.assistant(.init(text: "First.")), .assistant(.init(text: "Second."))])
        #expect(try entry("assistant", ["Seven passed.\n\n<suggested-replies>\nRun"]) == [.assistant(.init(text: "Seven passed."))])
        for text in [quoted, literal, "~~~~xml\n" + tag, "<pre>\n" + tag,
                     "    <suggested-replies>\n    x\n    </suggested-replies>",
                     "Example:\n\n" + tag + "\n\nHere is what that means."] {
            #expect(try entry("assistant", [text]) == [.assistant(.init(text: text))])
        }
        #expect(try entry("user", [tag]) == [.user(.init(text: tag))])
    }

    @Test func aSavedAmpReplyCanBeReadOfflineWithoutItsOldSuggestionMarkup() async throws {
        let reference = ConversationReference(program: .amp, sessionID: "T-offline")
        let key = ChatCacheKey(hostID: UUID(), herdrSession: "", program: .amp, conversationID: reference.sessionID)
        let prompt = ChatEntry(id: .init("amp:prompt:0"), sourceOffset: 1, content: .user(.init(text: "<suggested-replies>")))
        let answer = ChatEntry(id: .init("amp:reply:0"), sourceOffset: 2, content: .assistant(.init(text: "Seven passed.")))
        let suggestions = ChatEntry(id: .init("amp:reply:1"), sourceOffset: 2, content: .assistant(
            .init(text: "<suggested-replies>\nRerun\n</suggested-replies>")))
        let cache = VolatileChatTranscriptCache()
        await cache.save(ChatCacheDocument(key: key, adapterRevision: 1, transcriptPath: "amp/T-offline",
            head: Data(reference.sessionID.utf8), coverageStart: 0, coverageEnd: 3, reachedStart: true,
            title: "Booking", entries: [prompt, answer, suggestions], savedAt: Date()))
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .amp))
        let engine = ChatConversationEngine(reference: reference, cacheKey: key, files: VirtualHostFiles().hostFiles(),
                                           cache: cache, adapter: adapter)
        let snapshot = await engine.restore()
        #expect(snapshot.isFromCache)
        #expect(snapshot.transcript.entries == [prompt, answer])
        #expect(snapshot.transcript.title == "Booking")
        #expect(snapshot.readOffset == 3)
    }

    @Test func installationDistinguishesAnAbsentDirectoryFromAnOccupiedPath() async throws {
        var facts = HostProcessReader.Facts()
        facts.start = .value("123")
        facts.variables = ["HOME": .value("/home/test"), "XDG_CONFIG_HOME": .unset]
        let location = try #require(AmpPluginLocation(pid: 123, facts: facts))
        func files(_ list: @escaping @Sendable (RemoteFileListingRequest) async throws -> RemoteFileListing?) -> ChatHostFiles {
            ChatHostFiles(status: { _ in nil }, list: list, read: { _ in throw AmpChatProblem.unreachable },
                          home: { "/home/test" })
        }
        #expect(try await location.installation(files { _ in throw TransportError.hostFileUnreadable(status: 2) }).problem == .missing)
        #expect(try await location.installation(files { _ in
            .init(entries: [.init(name: "heeler-chat.js", status: .init(kind: .symlink, size: 0))])
        }).problem == .conflict)
        let bundled = try AmpPluginLocation.bundledContents()
        for (contents, problem) in [(bundled, AmpChatProblem.reload), (Data(repeating: 32, count: 8078), .conflict)] {
            let size = UInt64(contents.count)
            let regular = ChatHostFiles(status: { _ in nil }, list: { _ in
                .init(entries: [.init(name: "heeler-chat.js", status: .init(kind: .regular, size: size))])
            }, read: { _ in .init(data: contents, length: size) }, home: { "/home/test" })
            #expect(try await location.installation(regular).problem == problem)
        }
    }
}
