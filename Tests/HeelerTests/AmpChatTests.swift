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

    @Test func posixBackendsOfferReadWriteAmpChatAndWindowsAndUnknownStayOff() async throws {
        #expect(HostCapabilities.rexChatPrograms.contains(.amp))
        #expect(HostCapabilities.confirmedLinuxCoreChatPrograms.contains(.amp))
        #expect(HostCapabilities.confirmedMacOSCoreChatPrograms.contains(.amp))
        #expect(HostCapabilities.tmuxChatPrograms.contains(.amp))
        for kernel in [HerdrCoreLocator.linuxKernel, HerdrCoreLocator.macOSKernel] {
            let rex = HostCapabilities(serverKind: .rex, coreKernel: kernel)
            #expect(rex.offersAmpPlugin && rex.offersChat(for: .amp) && !rex.readOnlyChatPrograms.contains(.amp))
            let core = HostCapabilities(serverKind: .herdrCore, platform: .posix, coreKernel: kernel)
            #expect(core.offersAmpPlugin && core.offersChat(for: .amp) && !core.readOnlyChatPrograms.contains(.amp))
            let tmux = HostCapabilities(serverKind: .tmux, coreKernel: kernel)
            #expect(tmux.offersAmpPlugin && tmux.offersChat(for: .amp) && !tmux.readOnlyChatPrograms.contains(.amp))
        }
        for kernel in [nil, HerdrCoreLocator.windowsKernel] {
            let rex = HostCapabilities(serverKind: .rex, coreKernel: kernel)
            #expect(!rex.offersAmpPlugin && !rex.offersChat(for: .amp))
            let core = HostCapabilities(
                serverKind: .herdrCore,
                platform: kernel == HerdrCoreLocator.windowsKernel ? .nativeWindows : .posix,
                coreKernel: kernel)
            #expect(!core.offersAmpPlugin && !core.offersChat(for: .amp))
        }
        for kernel in [nil, "FreeBSD"] {
            let tmux = HostCapabilities(serverKind: .tmux, coreKernel: kernel)
            #expect(!tmux.offersAmpPlugin && !tmux.offersChat(for: .amp))
        }
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

    private nonisolated static let ampThread = "T-0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"

    private actor RecordingAmpPlugin {
        let record: AmpPluginRecord
        let binding: AmpChatBinding
        private(set) var requests: [AmpChatRequest] = []
        private(set) var installs: [(directory: String, previous: Data?)] = []

        init(pid: Int, start: String, thread: String = AmpChatTests.ampThread) {
            let instance = UUID()
            record = AmpPluginRecord(version: 1, contentRevision: 2, pid: pid, start: start, uid: 1000, instance: instance)
            binding = AmpChatBinding(version: 1, instance: instance, revision: 1, thread: thread, pid: pid, start: start)
        }

        func exchange(_ request: AmpChatRequest, record incoming: AmpPluginRecord) throws -> AmpChatReply {
            #expect(incoming == record)
            requests.append(request)
            switch request.op {
            case "binding":
                return AmpChatReply(binding: binding, page: nil, sent: nil, error: nil)
            case "page":
                let row = AmpChatPage.Row(
                    id: "s:0", role: "assistant", createdAt: nil, end: "end_turn",
                    blocks: [.init(type: "text", text: "Hello from Amp", call: nil, name: nil, status: nil)])
                return AmpChatReply(
                    binding: nil, page: AmpChatPage(offset: request.offset ?? 0, total: 1, rows: [row]),
                    sent: nil, error: nil)
            case "send":
                return AmpChatReply(binding: nil, page: nil, sent: true, error: nil)
            default:
                return AmpChatReply(binding: nil, page: nil, sent: nil, error: "invalid")
            }
        }

        func install(directory: String, previous: Data?) {
            installs.append((directory, previous))
        }
    }

    private struct AmpCoreHostServices: HostServices {
        let files: VirtualHostFiles
        let plugin: RecordingAmpPlugin

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

        func exchangeAmpChat(_ request: AmpChatRequest, record: AmpPluginRecord) async throws -> AmpChatReply {
            try await plugin.exchange(request, record: record)
        }

        func installAmpChatPlugin(in directory: String, replacing previous: Data?) async throws {
            await plugin.install(directory: directory, previous: previous)
        }
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var budget = PollBudget(.seconds(5))
        while budget.hasTimeLeft {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    @Test(arguments: [HerdrCoreLocator.linuxKernel, HerdrCoreLocator.macOSKernel])
    func herdrCoreAmpBindsPagesSendsInstallsAndRechecksForegroundAndCore(_ kernel: String) async throws {
        let home = "/home/dev"
        let pid = 420
        let start = "987654321"
        let host = Host(address: "core.example", username: "dev", serverKind: .herdrCore)
        let files = VirtualHostFiles(home: home)
        let plugin = RecordingAmpPlugin(pid: pid, start: start)
        func coreRecord(pid: Int, name: String, argv: [String]) -> JSONValue {
            .object([
                "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
                "argv": .array([.string("/bin/zsh")]), "keep": .bool(false), "title": .string(""),
                "cols": .number(80), "rows": .number(24), "name": .null, "reason": .null,
                "pid": .number(10),
                "foreground": .object([
                    "pid": .number(Double(pid)), "name": .string(name),
                    "argv": .array(argv.map(JSONValue.string)), "cwd": .string("/work/app"),
                ]),
                "status": .null, "labels": .object([:]),
            ])
        }
        let ampRecord = coreRecord(pid: pid, name: "amp", argv: ["amp"])
        let subscribe = JSONValue.object(["seq": .number(1), "terminals": .array([ampRecord]), "channel": .number(1)])
        let transport = ScriptedCoreTransport(
            coreID: "core-1", subscribeResults: [subscribe],
            services: AmpCoreHostServices(files: files, plugin: plugin))
        await transport.setKernel(kernel)
        await transport.setTerminalRecords([.success(ampRecord)])
        await transport.processTable.add(.init(
            pid: 10, name: "zsh", start: "100",
            environment: ["HC_SCOPE": "scope-1", "HOME": home]))
        await transport.processTable.add(.init(
            pid: pid, parent: 10, name: "amp", start: start,
            environment: ["HC_SCOPE": "scope-1", "HOME": home, "XDG_CONFIG_HOME": "/srv/xdg"]))

        let store = ConsoleStore(
            chatCache: VolatileChatTranscriptCache(),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not TUI") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) })
        store.setHosts([host])
        await store.resume()
        defer { store.setHosts([]) }
        try await waitUntil("core snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        await store.resolveHostPlatform(host.id)
        try await waitUntil("core platform and kernel") {
            store.hostPlatforms[host.id] == .posix && store.hostCoreKernels[host.id] == kernel
        }

        let agent = try #require(store.agents.first)
        #expect(store.chatProgram(for: agent) == .amp)
        let chat = try #require(store.chatStore(for: agent, program: .amp))
        defer { chat.end() }
        let connection = try #require(chat.ampConnection)
        #expect(!connection.isReadOnly)

        #expect(try await connection.evidence() == .unavailable(.amp(.missing)))
        let place = try #require(connection.location)
        #expect(place.directory == "/srv/xdg/amp/plugins")
        #expect(place.serverInstance == "core-1")
        try await connection.install(place)
        #expect(await plugin.installs.map(\.directory) == ["/srv/xdg/amp/plugins"])

        await files.write(try JSONEncoder().encode(plugin.record), at: place.recordPath)
        #expect(try await connection.evidence() == .bound(sessionID: Self.ampThread, transcriptRoot: nil, directory: nil))
        let target = try #require(connection.current)
        let (_, page) = try await connection.page(thread: Self.ampThread, expected: target, offset: nil, limit: 20)
        #expect(page.rows.first?.blocks.first?.text == "Hello from Amp")
        let sendID = UUID()
        let outcome = await connection.send(id: sendID, text: "Ship it", target: target)
        #expect(outcome == .submitted)
        let sent = try #require(await plugin.requests.last)
        #expect(sent.op == "send" && sent.requestID == sendID && sent.text == "Ship it")

        await transport.setTerminalRecords([.success(coreRecord(pid: 999, name: "bash", argv: ["bash"]))])
        let refused = await connection.send(id: UUID(), text: "Stale", target: target)
        #expect(refused == .refused(.inputNotReady(AmpChatProblem.changed.explanation)))
        await #expect(throws: AmpChatProblem.changed) { try await connection.install(place) }

        await transport.setTerminalRecords([.success(ampRecord)])
        await transport.setCoreID("core-2")
        await transport.endLink()
        try await waitUntil("replacement core") { store.capabilities(for: host.id).offersAmpPlugin }
        try await waitUntil("core-2 scope") {
            let newPlace = try? await (connection.evidence(), connection.location).1
            return newPlace?.serverInstance == "core-2"
        }
        await #expect(throws: AmpChatProblem.changed) { try await connection.install(place) }
    }

    @Test(arguments: [HerdrCoreLocator.linuxKernel, HerdrCoreLocator.macOSKernel])
    func tmuxAmpBindsPagesSendsInstallsAndRechecksForegroundAndServer(_ kernel: String) async throws {
        let home = ScriptedTmuxHost.home
        let shellPID = 3000
        let ampPID = 3001
        let start = "Thu Nov 12 06:00:00 2026"
        let host = Host(
            address: "tmux.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())
        let files = VirtualHostFiles(home: home)
        let tmux = ScriptedTmuxHost(kernel: kernel, virtualFiles: files)
        let plugin = RecordingAmpPlugin(pid: ampPID, start: start)
        await tmux.setAmpHandlers(
            exchange: { try await plugin.exchange($0, record: $1) },
            install: { await plugin.install(directory: $0, previous: $1) })
        await tmux.setPanes([
            .make(pane: 0, processID: shellPID, command: "amp", path: "/work/app", arguments: ["amp"]),
        ])
        await tmux.setForegroundPID(ampPID, of: "%0")
        let wrongTmux = "\(ScriptedTmuxHost.socketPath()),\(ScriptedTmuxHost.instance.pid),0"
        await tmux.setProcessEnvironment(["TMUX": wrongTmux, "TMUX_PANE": "%9", "HOME": home], forProcess: shellPID, name: "zsh", start: "1")
        await tmux.setProcessEnvironment(["TMUX": wrongTmux, "TMUX_PANE": "%9", "HOME": home], forProcess: ampPID, name: "amp", parent: shellPID, start: start)

        let store = ConsoleStore(
            chatCache: VolatileChatTranscriptCache(),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not TUI") },
                    keepalive: nil)
            },
            makeTmuxSession: { candidate in
                TmuxHostSession(
                    storedPaths: candidate.storedTmuxPaths,
                    connect: { paths in
                        await tmux.transport(socketName: candidate.tmuxSocketName, storedPaths: paths)
                    },
                    reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(20), multiplier: 1, maxDelay: .milliseconds(40)),
                    keepalive: KeepalivePolicy(interval: .seconds(60)),
                    settledLoopLife: .zero)
            })
        store.setHosts([host])
        await store.resume()
        defer { store.setHosts([]) }
        try await waitUntil("tmux snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }

        let agent = try #require(store.agents.first)
        #expect(store.chatProgram(for: agent) == .amp)
        let chat = try #require(store.chatStore(for: agent, program: .amp))
        defer { chat.end() }
        let connection = try #require(chat.ampConnection)
        #expect(!connection.isReadOnly)

        #expect(try await connection.evidence() == .unavailable(.amp(.unidentified)))

        await tmux.setProcessEnvironment(["TMUX": wrongTmux, "TMUX_PANE": "%0", "HOME": home], forProcess: shellPID, name: "zsh", start: "1")
        await tmux.setProcessEnvironment(["TMUX": wrongTmux, "TMUX_PANE": "%0", "HOME": home, "XDG_CONFIG_HOME": nil], forProcess: ampPID, name: "amp", parent: shellPID, start: start)
        #expect(try await connection.evidence() == .unavailable(.amp(.missing)))
        let place = try #require(connection.location)
        #expect(place.directory == "\(home)/.config/amp/plugins")
        #expect(place.serverInstance == ScriptedTmuxHost.instance.id)
        try await connection.install(place)
        #expect(await plugin.installs.map(\.directory) == ["\(home)/.config/amp/plugins"])

        await files.write(try JSONEncoder().encode(plugin.record), at: place.recordPath)
        #expect(try await connection.evidence() == .bound(sessionID: Self.ampThread, transcriptRoot: nil, directory: nil))
        let target = try #require(connection.current)
        let (_, page) = try await connection.page(thread: Self.ampThread, expected: target, offset: nil, limit: 20)
        #expect(page.rows.first?.blocks.first?.text == "Hello from Amp")
        let sendID = UUID()
        #expect(await connection.send(id: sendID, text: "Run checks", target: target) == .submitted)
        let sent = try #require(await plugin.requests.last)
        #expect(sent.op == "send" && sent.requestID == sendID && sent.text == "Run checks")

        await tmux.setPanes([
            .make(pane: 0, processID: shellPID, command: "zsh", path: "/work/app", arguments: ["zsh"]),
        ])
        await tmux.setForegroundPID(shellPID, of: "%0")
        #expect(await connection.send(id: UUID(), text: "Stale", target: target)
                == .refused(.inputNotReady(AmpChatProblem.changed.explanation)))
        await #expect(throws: AmpChatProblem.changed) { try await connection.install(place) }

        let replacement = TmuxServerInstance(pid: 9191, startTime: 1_794_399_999)
        await tmux.startServer(instance: replacement, panes: [
            .make(pane: 0, processID: shellPID, command: "amp", path: "/work/app", arguments: ["amp"]),
        ])
        await tmux.setForegroundPID(ampPID, of: "%0")
        let nextTmux = "\(ScriptedTmuxHost.socketPath()),\(replacement.pid),0"
        await tmux.setProcessEnvironment(["TMUX": nextTmux, "TMUX_PANE": "%0", "HOME": home], forProcess: shellPID, name: "zsh", start: "1")
        await tmux.setProcessEnvironment(["TMUX": nextTmux, "TMUX_PANE": "%0", "HOME": home, "XDG_CONFIG_HOME": nil], forProcess: ampPID, name: "amp", parent: shellPID, start: start)
        try await waitUntil("replacement tmux server") {
            let newPlace = try? await (connection.evidence(), connection.location).1
            return newPlace?.serverInstance == replacement.id
        }
        await #expect(throws: AmpChatProblem.changed) { try await connection.install(place) }
    }

    @Test(arguments: [("linux_x86_64", HerdrCoreLocator.linuxKernel), ("darwin_arm64", HerdrCoreLocator.macOSKernel)])
    func rexAmpAllowsSendChecksScreenInstallsAndRechecksForegroundAndServer(
        _ platform: String, _ expectedKernel: String
    ) async throws {
        let socket = "/run/user/1000/rex/server.sock"
        let home = "/home/dev"
        let pid = 4242
        let start = "Thu Nov 12 06:00:00 2026"
        let host = Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: socket))
        var studio = FakeRexWorld.studio()
        var ampBlock = FakeRexWorld.Block.running("block:left", program: "amp")
        ampBlock.label = "amp"
        ampBlock.directory = "/home/dev/app"
        studio.windows[0].layers[0].blocks[2] = ampBlock
        let world = FakeRexWorld(sessions: [studio], platform: platform)
        let firstServer = FakeRexServer()
        await world.install(on: firstServer)
        let idleScreen = try ScreenFixture.text("amp-01-idle")
        await firstServer.answer(RexInventoryWire.terminalMethod("screen"), using: { _ in
            .result(["screen": .string(idleScreen), "cols": 80, "rows": 24])
        })
        let secondServer = FakeRexServer()
        await world.install(on: secondServer)

        let files = VirtualHostFiles(home: home)
        let table = ScriptedProcessTable()
        await table.add(.init(pid: pid, name: "amp", start: start, environment: ["HOME": home]))
        let plugin = RecordingAmpPlugin(pid: pid, start: start)
        let connection = ScriptedRexHost(
            control: [.server(firstServer), .server(secondServer)],
            files: files,
            processes: { try await table.read($0) })
        await connection.setAmpHandlers(
            exchange: { try await plugin.exchange($0, record: $1) },
            install: { await plugin.install(directory: $0, previous: $1) })

        let dialer = RexHostSessionTests.Dialer([connection])
        let store = ConsoleStore(
            chatCache: VolatileChatTranscriptCache(),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not TUI") },
                    keepalive: nil)
            },
            makeRexSession: { candidate in
                RexHostSession(
                    storedSocket: candidate.rexSocket,
                    connect: { try await dialer.dial($0, $1) },
                    reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)))
            })
        store.setHosts([host])
        await store.resume()
        defer { store.setHosts([]) }
        try await waitUntil("rex snapshot and kernel") {
            !store.hostsAwaitingSnapshot.contains(host.id) && store.hostCoreKernels[host.id] == expectedKernel
                && !store.agents.isEmpty
        }

        let paneID = RexPaneAddress(sessionID: "session:studio", blockID: "block:left").paneID
        let agent = try #require(store.agents.first { $0.agent.paneID == paneID })
        #expect(store.chatProgram(for: agent) == .amp)
        let chat = try #require(store.chatStore(for: agent, program: .amp))
        defer { chat.end() }
        let amp = try #require(chat.ampConnection)
        #expect(!amp.isReadOnly)

        let screen = try await chat.screenIO.readScreen()
        #expect(AmpInputBox.read(screen) == .empty(placeholder: nil))

        #expect(try await amp.evidence() == .unavailable(.amp(.missing)))
        let place = try #require(amp.location)
        #expect(place.directory == "\(home)/.config/amp/plugins")
        #expect(place.serverInstance == "instance-0001")
        try await amp.install(place)
        #expect(await plugin.installs.map(\.directory) == ["\(home)/.config/amp/plugins"])

        await files.write(try JSONEncoder().encode(plugin.record), at: place.recordPath)
        #expect(try await amp.evidence() == .bound(sessionID: Self.ampThread, transcriptRoot: nil, directory: nil))
        let target = try #require(amp.current)
        let (_, page) = try await amp.page(thread: Self.ampThread, expected: target, offset: nil, limit: 20)
        #expect(page.rows.first?.blocks.first?.text == "Hello from Amp")
        let sendID = UUID()
        #expect(await amp.send(id: sendID, text: "Hello Rex Amp", target: target) == .submitted)
        let sent = try #require(await plugin.requests.last)
        #expect(sent.op == "send" && sent.requestID == sendID && sent.text == "Hello Rex Amp")
        #expect(await connection.log.contains("amp send"))

        await firstServer.answer(RexInventoryWire.terminalMethod("process"), using: { _ in
            .result(["foreground": ["name": "bash", "argv0": "/bin/bash", "pid": 4242]])
        })
        #expect(await amp.send(id: UUID(), text: "Stale", target: target)
                == .refused(.inputNotReady(AmpChatProblem.changed.explanation)))
        await #expect(throws: AmpChatProblem.changed) { try await amp.install(place) }

        world.restart(as: "instance-0002")
        await firstServer.close(.goingAway, reason: "restart")
        try await waitUntil("rex instance-0002") {
            let newPlace = try? await (amp.evidence(), amp.location).1
            return newPlace?.serverInstance == "instance-0002"
        }
        await #expect(throws: AmpChatProblem.changed) { try await amp.install(place) }
    }
}
