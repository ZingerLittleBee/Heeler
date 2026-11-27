import CryptoKit
import Foundation
import Testing

@testable import Heeler

/// Two running clients of the same program use a single disposable directory and
/// distinct seeded conversations. The independent driver records both files
/// before it starts the suite. Only the first client receives input.
@MainActor
@Suite("Foreground Chat on a private Rex Host", .serialized, .timeLimit(.minutes(3)))
struct RexForegroundChatLiveTests {
    private struct Fixture: Decodable {
        let port: Int
        let user, seed, fingerprint, rexSocket, rexSession, rexBlock: String
        let program: ChatProgram
        let directory, firstFile, peerSession, peerBlock, peerFile: String
        let firstID, peerID: String?
        let nativeControls, nativePermissions: Bool?
        let receiptFaultBlock: String?

        func connect() async throws -> RexSSHTransport {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: #require(Data(base64Encoded: seed)))
            var ssh = SSHTransportSettings(
                host: "127.0.0.1", port: port, username: user, credentials: .ed25519(key),
                hostKeyPolicy: .init(knownHosts: InMemoryKnownHostsStore()) { $0.fingerprint.displayString == self.fingerprint },
                socket: .defaultSession)
            ssh.serverKind = .rex
            let socket = try #require(RexSocket(path: rexSocket))
            return try await RexSSHTransport.connect(over: HeelerSSHTransport.connect(settings: ssh), socket: socket)
        }
    }

    @Test func sameDirectoryPeersKeepTheirConversationsAndDesktopSize() async throws {
        try await run(fixtureKey: "HEELER_REX_FOREGROUND_CHAT_LAB", loseReceipt: false)
    }

    fileprivate func run(fixtureKey: String, loseReceipt: Bool) async throws {
        let path = try #require(ProcessInfo.processInfo.environment[fixtureKey])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require([ChatProgram.pi, .omp, .grok, .claude, .codex].contains(fixture.program))
        let isDisposable = fixture.directory.split(separator: "/").contains { $0.hasPrefix("heeler-lab-") }
        try #require(isDisposable && fixture.firstFile != fixture.peerFile && fixture.rexBlock != fixture.peerBlock)
        if loseReceipt {
            try #require(fixture.program == .pi && fixture.receiptFaultBlock == fixture.rexBlock)
        }
        let observer = try await fixture.connect()
        do {
            try await check(fixture, desktop: observer.control, loseReceipt: loseReceipt)
            await observer.close()
        } catch {
            await observer.close()
            throw error
        }
    }

    private func check(_ fixture: Fixture, desktop: RexControlLink, loseReceipt: Bool) async throws {
        let first = RexPaneAddress(sessionID: fixture.rexSession, blockID: fixture.rexBlock)
        let peer = RexPaneAddress(sessionID: fixture.peerSession, blockID: fixture.peerBlock)
        _ = try await desktop.call("session.attach_all", payload: JSONValue.object(["event_scope": .string("all")]))
        for address in [first, peer] {
            let session = JSONValue.object(["session_id": .string(address.sessionID)])
            let view = try await desktop.call("session.view", payload: session).result(JSONValue.self)
            let isLab = view["label"]?.stringValue?.hasPrefix("heeler-lab-") == true
            try #require(isLab)
            _ = try await desktop.call("session.attach", payload: session)
            _ = try await desktop.call(RexTerminalAttach.takeMethod, payload: RexTerminalAttach.ownershipPayload(address, take: true))
        }
        func size(_ address: RexPaneAddress) async throws -> JSONValue {
            let payload = JSONValue.object(["session_id": .string(address.sessionID), "block_id": .string(address.blockID)])
            return try await desktop.call(RexInventoryWire.terminalMethod("size"), payload: payload).result(JSONValue.self)
        }
        let before = try await size(first)
        let peerBefore = try await size(peer)
        let owner = try #require(desktop.clientID)
        let ownsBoth = before["owner"]?.stringValue == owner && peerBefore["owner"]?.stringValue == owner
        try #require(ownsBoth)

        let socket = try #require(RexSocket(path: fixture.rexSocket))
        let connection = RexHostSession(storedSocket: socket) { _, _ in try await fixture.connect() }
        let host = Host(name: "Chat Lab", address: "127.0.0.1", port: fixture.port, username: fixture.user, serverKind: .rex, rexSocket: socket)
        let projection = RexConsoleProjection(host: host, session: connection, pins: .init(), onChange: {})
        projection.start(isActive: true)
        defer { projection.end() }
        let program = fixture.program
        try await wait(for: "both foreground programs in the fixture directory") {
            [first, peer].allSatisfy {
                let agent = projection.agentsByPane[$0.paneID]?.agent
                return agent?.kind == program.rawValue && agent?.cwd == fixture.directory
            }
        }

        func fixtureBinding(file: String, id: String?) throws -> String {
            switch program {
            case .pi, .omp: return file
            case .grok: return URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
            default: return try #require(id)
            }
        }
        let firstID = try fixtureBinding(file: fixture.firstFile, id: fixture.firstID)
        let peerID = try fixtureBinding(file: fixture.peerFile, id: fixture.peerID)
        try #require(firstID != peerID)
        func binding(_ address: RexPaneAddress) async throws -> String? {
            guard case .bound(let identity, _, _) = try await projection.checkChatSession(paneID: address.paneID, program: program)
            else { return nil }
            return identity
        }
        try await wait(for: "the independent foreground identity of each client") {
            let one = try await binding(first)
            let two = try await binding(peer)
            return one == firstID && two == peerID
        }

        let pane = first.paneID
        let agent = try #require(projection.agentsByPane[pane]?.agent)
        let files = projection.chatHostFiles()
        let typing = try #require(projection.checkedChatTyping(at: pane))
        let source = AgentChatSource(hostID: host.id, socketLocation: .namedSession("lab"), files: files,
            agentInfo: { try await projection.agentInfo(paneID: pane) }, cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: program)), screen: typing.blockedScreen,
            sessionEvidence: { try await projection.checkChatSession(paneID: pane, program: program) },
            requiresIndependentInputSession: true, coreScope: projection.chatCacheScope)
        let chat = AgentChatStore(agentID: .init(hostID: host.id, paneID: pane), agent: agent, program: program, source: source)
        defer { chat.end() }
        await chat.step()
        let followingFirst = chat.conversation.phase == .following(path: fixture.firstFile)
        try #require(followingFirst)
        let checked = projection.checkedComposerSend(for: pane, keepingTo: TerminalCorePin(joined: projection.inventoryCore), live: { projection })
        let sender = try #require(checked)
        let composer = AgentComposerStore(target: pane, checkedSend: sender) { _ in
            Issue.record("A Rex Chat send must use the checked terminal sender")
            throw TransportError.cancelled
        }
        let rules = ChatSendRules(program: program, commands: [])
        composer.bindChatDraft(to: chat.composerSessionID, program: program)
        let firstDraftOwner = try #require(chat.composerSessionID)
        // SwiftUI builds a new policy for each render and tap.
        var policy: ComposerDeliveryPolicy {
            var policy = ComposerDeliveryPolicy.chat(rules: rules,
            activity: { ChatAgentActivity(projection.agentsByPane[pane]?.agent.status ?? .unknown) },
            readScreen: typing.blockedScreen.readScreen, confirmSession: { await chat.confirmSessionBeforeSend(for: composer) },
            heldSession: { chat.sessionRefusalBeforeCheck() },
            sendConcern: { chat.sendConcern(for: $0, after: $1) },
            willReadScreen: { chat.updateSends(ChatComposerEchoes.sentMessages(composer.messages, rules: rules)) },
            conversation: { chat.conversationGeneration })
            policy.sessionWrite = chat.composerWriteCheck(for: composer)
            return policy
        }
        if loseReceipt {
            try await checkLostReceipt(fixture, projection: projection, chat: chat, composer: composer, policy: policy)
            let finalSize = try await size(first), peerFinalSize = try await size(peer)
            #expect(finalSize == before && peerFinalSize == peerBefore)
            return
        }
        let marker = "REX_LAB_SEND_" + UUID().uuidString.prefix(8)
        let prompt = "Reply only with this marker. Do not use tools.\n\n    " + marker
        composer.replaceDraft(with: prompt)
        chat.draftDidChange(to: prompt)
        let sent = await composer.send(policy: policy)
        try #require(sent == .submittedViaAttach || sent == .deliveredViaAttach, "\(String(describing: sent))")
        // Grok retains the completion-dismissing space in its ACP user chunk.
        let recordedPrompt = program == .grok ? rules.outgoingText(prompt) : prompt
        try await wait(for: "one matching user message and reply in the displayed conversation") {
            await chat.step()
            return chat.conversation.transcript.recordedPrompts.filter { $0.text == recordedPrompt }.count == 1
                && chat.conversation.transcript.entries.filter { $0.content == .assistant(.init(text: marker)) }.count == 1
        }
        var native: (path: String, oldStop: AgentComposerInterrupt)?
        if fixture.nativeControls == true {
            native = try await checkNativeControls(projection: projection, pane: pane, program: program,
                composer: composer, chat: chat, policy: policy, directory: fixture.directory,
                checksPermissions: fixture.nativePermissions ?? true, clearDesktopLine: {
                    _ = try await desktop.call(RexInventoryWire.terminalMethod("write"), payload: JSONValue.object([
                        "session_id": .string(first.sessionID), "block_id": .string(first.blockID),
                        "args": .object(["data": .string("\u{15}")]),
                    ]))
                })
        }

        let heldMarker = "REX_LAB_HELD_" + UUID().uuidString.prefix(8)
        let held = heldMarker + (native.map { " " + $0.path } ?? "")
        let heldImage = native == nil ? nil : try await stageDraftImage(projection: projection, pane: pane, composer: composer)
        composer.replaceDraft(with: held)
        chat.draftDidChange(to: held)
        func desktopLine(_ line: String) async throws {
            for part in [line, "\r"] {
                let write = JSONValue.object([
                    "session_id": .string(first.sessionID), "block_id": .string(first.blockID),
                    "args": .object(["data": .string(part)]),
                ])
                _ = try await desktop.call(RexInventoryWire.terminalMethod("write"), payload: write)
                if part == line { try await Task.sleep(for: .milliseconds(150)) }
            }
        }
        try await desktopLine(program == .claude ? "/clear" : "/new")
        if program == .grok {
            // Grok discards keyboard input while /new is replacing the editor.
            // Its first rendered prompt names the new conversation explicitly.
            try await wait(for: "Grok to draw the new session before the desktop types") {
                let screen = try await typing.blockedScreen.readScreen()
                guard case .empty = InputBoxStateDetector.detect(screen, program: .grok) else { return false }
                return screen.rows.contains { row in
                    let words = row.text.split(whereSeparator: \.isWhitespace)
                    guard words.first == "Session", let token = words.dropFirst().first,
                        token.last == ",", let shown = ConversationReference.lowercaseUUID(String(token.dropLast()))
                    else { return false }
                    return shown != firstID && shown != peerID
                }
            }
        } else if program == .codex {
            var selectedCurrentWorktree = false
            try await wait(for: "Codex to draw the new empty thread before the desktop types") {
                let screen = try await typing.blockedScreen.readScreen()
                // Codex 0.172.0 asks this in a Git checkout. The independent desktop keeps its existing directory.
                let rows = screen.rows.map(\.trimmedText)
                if !selectedCurrentWorktree,
                   let title = rows.lastIndex(of: "Where should the new conversation run?") {
                    let options = rows.dropFirst(title + 1)
                    if options.contains(where: { $0.hasPrefix("› 1. Use current Git worktree ") }),
                       options.contains(where: { $0.hasPrefix("2. Create new Git worktree ") }),
                       options.contains("enter select · esc back") {
                        selectedCurrentWorktree = true
                        let write = JSONValue.object([
                            "session_id": .string(first.sessionID), "block_id": .string(first.blockID),
                            "args": .object(["data": .string("\r")]),
                        ])
                        _ = try await desktop.call(RexInventoryWire.terminalMethod("write"), payload: write)
                    }
                    return false
                }
                guard case .empty = InputBoxStateDetector.detect(screen, program: .codex) else { return false }
                return screen.rows.contains { $0.text.contains("OpenAI Codex") }
                    && !screen.rows.contains { $0.text.contains("REX_LAB_") }
            }
        } else {
            try await wait(for: "the first client to leave its old binding") {
                try await binding(first) != firstID
            }
        }
        // A fresh embedded Codex may have a thread-writer lock before it
        // holds a rollout. Give the new conversation its own desktop turn.
        let rotated = "REX_LAB_ROTATED_" + UUID().uuidString.prefix(8)
        try await desktopLine("Reply only with " + rotated + ". Do not use tools.")
        var needsPick = false
        try await wait(for: "the first client to leave its old identity with its peer still in place") {
            guard try await binding(peer) == peerID else { return false }
            let evidence = try await projection.checkChatSession(paneID: pane, program: program)
            switch evidence {
            case .bound(let id, _, _): return id != firstID && id != peerID
            case .unavailable(.multipleSessions(let kind, offersPick: true)) where kind == program && (kind == .codex || kind == .grok):
                needsPick = true
                return true
            default: return false
            }
        }
        let outcome = await composer.send(policy: policy)
        guard case .refused = outcome else {
            Issue.record("A draft for the old conversation was accepted after the desktop switched sessions")
            return
        }
        #expect(composer.draft == held)
        var successor: String?
        if let native {
            // Each independent desktop turn must finish before the driver types
            // the next. Codex can otherwise append to or interrupt that turn.
            func waitForDesktopReply(_ marker: String) async throws {
                let rendered = program == .claude ? ["⏺ " + marker, "● " + marker] : ["• " + marker]
                try await wait(for: "the independent desktop reply " + marker) {
                    let screen = try await typing.blockedScreen.readScreen()
                    guard let status = projection.agentsByPane[pane]?.agent.status,
                          status == .idle || status == .done else { return false }
                    guard screen.rows.filter({ rendered.contains($0.trimmedText) }).count == 1 else { return false }
                    guard program == .claude else { return true }
                    guard let id = try await binding(first), ConversationReference.lowercaseUUID(id) == id,
                          id != firstID && id != peerID else { return false }
                    let file = URL(fileURLWithPath: fixture.firstFile).deletingLastPathComponent()
                        .appendingPathComponent(id + ".jsonl").path
                    guard let size = try await files.status(file)?.size, size > 0 && size <= 1 << 20,
                          let bytes = try await files.read(path: file, from: 0, to: size, chunk: 64 << 10)
                    else { return false }
                    let answers = bytes.split(separator: 0x0a).filter { line in
                        guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                              row["type"] as? String == "assistant", row["sessionId"] as? String == id,
                              let message = row["message"] as? [String: Any], message["role"] as? String == "assistant",
                              let parts = message["content"] as? [[String: Any]]
                        else { return false }
                        return parts.contains { $0["type"] as? String == "text" && $0["text"] as? String == marker }
                    }
                    return answers.count == 1
                }
            }
            try await waitForDesktopReply(rotated)
            let next = "REX_LAB_SUCCESSOR_SWITCHED_" + UUID().uuidString.prefix(8)
            try await desktopLine(next)
            try await wait(for: "the successor conversation to start a fresh turn") {
                projection.agentsByPane[pane]?.agent.status == .working
            }
            let stale = await native.oldStop.perform()
            try #require(stale == .failed(ChatStopPlan.changedDroidTurn))
            try await waitForDesktopReply(next)
            successor = next
            #expect(composer.draft == held)
        }
        let wrongPickMarker = "REX_LAB_WRONG_PICK_" + UUID().uuidString.prefix(8)
        if needsPick {
            guard case .listed(let oldList) = try await projection.chatCandidates(paneID: pane, program: program),
                  let oldChoice = oldList.candidates.first(where: { $0.sessionID == firstID && $0.origins.contains(.heldOpen) })
            else { throw RexLab.LabError.unreadable("the earlier conversation was not offered for reading") }
            try await projection.writeChatPick(oldChoice, of: oldList, paneID: pane)
            chat.sessionEvidenceMayHaveChanged()
            try await wait(for: "the old choice to be displayed while the terminal is in the new conversation") {
                await chat.step()
                return chat.conversation.phase == .following(path: fixture.firstFile)
            }
            composer.replaceDraft(with: wrongPickMarker)
            chat.draftDidChange(to: wrongPickMarker)
            guard case .refused = await composer.send(policy: policy) else {
                throw RexLab.LabError.unreadable("a read selection sent a draft to the other conversation")
            }
            #expect(composer.draft == wrongPickMarker)
            if native != nil, program == .codex {
                let permission = "REX_LAB_APPROVE_WRONG_PICK_" + UUID().uuidString.prefix(8)
                try await desktopLine(permission)
                try await checkReadOnlyPermission(permission, directory: fixture.directory, chat: chat, projection: projection, pane: pane)
                _ = try await desktop.call(RexInventoryWire.terminalMethod("write"), payload: JSONValue.object([
                    "session_id": .string(first.sessionID), "block_id": .string(first.blockID), "args": .object(["data": .string("\u{1B}")]),
                ]))
                try await wait(for: "the desktop to dismiss its own permission") {
                    guard let status = projection.agentsByPane[pane]?.agent.status else { return false }
                    return status == .idle || status == .done
                }
                #expect(composer.draft == wrongPickMarker)
            }
            composer.replaceDraft(with: held)
            chat.draftDidChange(to: held)
            try await wait(for: "the explicitly selected conversation to contain the desktop marker") {
                guard case .listed(let list) = try await projection.chatCandidates(paneID: pane, program: program)
                else { return false }
                var matching: [ChatSessionCandidate] = []
                for candidate in list.candidates where candidate.origins.contains(.heldOpen) && candidate.sessionID != firstID && candidate.sessionID != peerID {
                    let file: String?
                    if program == .codex {
                        let result = try await CodexTranscriptLocator(files: files).locate(threadID: candidate.sessionID, configRoot: list.transcriptRoot)
                        guard case .success(let location) = result else { continue }
                        file = location.live?.path
                    } else {
                        let result = try await GrokTranscriptLocator(files: files).locate(sessionID: candidate.sessionID, directories: list.directories, configRoot: list.transcriptRoot)
                        guard case .success(let path) = result else { continue }
                        file = path
                    }
                    guard let file,
                          let size = try await files.status(file)?.size, size <= 1 << 20,
                          let data = try await files.read(path: file, from: 0, to: size, chunk: 64 << 10),
                          data.range(of: Data(rotated.utf8)) != nil else { continue }
                    matching.append(candidate)
                }
                guard matching.count == 1, let picked = matching.first else { return false }
                try await projection.writeChatPick(picked, of: list, paneID: pane)
                let evidence = try await projection.checkChatSession(paneID: pane, program: program)
                guard case .picked(let id, _) = evidence else { return false }
                return id == picked.sessionID
            }
            chat.sessionEvidenceMayHaveChanged()
        }
        var nextFile: String?
        try await wait(for: "the switched Chat to read its new desktop reply") {
            await chat.step()
            guard case .following(let path) = chat.conversation.phase, path != fixture.firstFile, path != fixture.peerFile,
                  chat.conversation.transcript.entries.contains(where: { $0.content == .assistant(.init(text: rotated)) })
            else { return false }
            if let successor, !chat.conversation.transcript.entries.contains(where: { $0.content == .assistant(.init(text: successor)) }) {
                return false
            }
            nextFile = path
            return true
        }
        var nextDraftMarker: String?
        if let heldImage {
            let nextOwner = try #require(chat.composerSessionID)
            try #require(nextOwner != firstDraftOwner)
            // The new conversation finished a real turn. A render can already
            // see that owner before onChange has moved the old draft out.
            for _ in 0..<2 {
                guard case .refused = await composer.send(policy: policy) else {
                    throw RexLab.LabError.unreadable("a rebuilt policy submitted the previous conversation's draft")
                }
                try #require(composer.draft == held && composer.readyImagePaths == [heldImage])
            }
            composer.bindChatDraft(to: nextOwner, program: program)
            try #require(composer.draft.isEmpty && composer.readyImagePaths.isEmpty)
            let emptySend = await composer.send(policy: policy)
            try #require(emptySend == .ignored)
            let text = "REX_LAB_NEW_DRAFT_" + UUID().uuidString.prefix(8)
            composer.replaceDraft(with: text)
            chat.draftDidChange(to: text)
            let sent = await composer.send(policy: policy)
            if needsPick {
                guard case .refused = sent else { throw RexLab.LabError.unreadable("the picked history accepted a new draft") }
                try #require(composer.draft == text)
            } else {
                try #require(sent == .submittedViaAttach || sent == .deliveredViaAttach, "\(String(describing: sent))")
                try await wait(for: "the independent new conversation to receive only its own phone draft") {
                    await chat.step()
                    return chat.conversation.transcript.recordedPrompts.filter { $0.text == text }.count == 1 &&
                        chat.conversation.transcript.entries.contains { $0.content == .assistant(.init(text: text)) }
                }
            }
            nextDraftMarker = text
            if needsPick {
                guard case .listed(let list) = try await projection.chatCandidates(paneID: pane, program: program),
                      let old = list.candidates.first(where: { $0.sessionID == firstID && $0.origins.contains(.heldOpen) })
                else { throw RexLab.LabError.unreadable("the original conversation was no longer available to read") }
                try await projection.writeChatPick(old, of: list, paneID: pane)
            } else {
                try #require(program == .claude)
                try await desktopLine("/resume " + firstID)
                try await wait(for: "Claude to resume the original conversation") { try await binding(first) == firstID }
            }
            chat.sessionEvidenceMayHaveChanged()
            try await wait(for: "the original conversation to regain its own draft") {
                await chat.step()
                return chat.composerSessionID == firstDraftOwner && chat.conversation.phase == .following(path: fixture.firstFile)
            }
            composer.bindChatDraft(to: chat.composerSessionID, program: program)
            try #require(composer.draft == held && composer.readyImagePaths == [heldImage])
        }
        for path in [fixture.firstFile, fixture.peerFile, try #require(nextFile)] {
            let info = try #require(try await files.status(path))
            let bytes = try #require(info.size)
            try #require(bytes <= 1 << 20)
            let data = try #require(try await files.read(path: path, from: 0, to: bytes, chunk: 64 << 10))
            if let nextDraftMarker {
                let receivedDraft = data.range(of: Data(nextDraftMarker.utf8)) != nil
                #expect(receivedDraft == (path == nextFile && !needsPick))
            }
            let containsHeld = data.range(of: Data(heldMarker.utf8)) != nil
            #expect(!containsHeld)
            let containsWrongPick = data.range(of: Data(wrongPickMarker.utf8)) != nil
            #expect(!containsWrongPick)
            if path != nextFile {
                let containsNewReply = data.range(of: Data(rotated.utf8)) != nil
                #expect(!containsNewReply)
            }
            if path == fixture.peerFile {
                let containsSent = data.range(of: Data(marker.utf8)) != nil
                #expect(!containsSent)
            }
        }
        let firstSizeUnchanged = try await size(first) == before
        let peerSizeUnchanged = try await size(peer) == peerBefore
        #expect(firstSizeUnchanged && peerSizeUnchanged)
    }

    private func wait(for observation: String, _ condition: () async throws -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(22)
        while ContinuousClock.now < until {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RexLab.LabError.unreadable(observation)
    }
}

private extension RexForegroundChatLiveTests {
    private func checkLostReceipt(_ fixture: Fixture, projection: RexConsoleProjection, chat: AgentChatStore,
                          composer: AgentComposerStore, policy: ComposerDeliveryPolicy) async throws {
        let marker = "REX_LAB_RECEIPT_" + UUID().uuidString.prefix(8)
        let files = projection.chatHostFiles()
        let pane = RexPaneAddress(sessionID: fixture.rexSession, blockID: fixture.rexBlock).paneID
        let image = try await stageDraftImage(projection: projection, pane: pane, composer: composer)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heeler-lab-" + marker)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("reply 文件.txt")
        let bytes = Data(marker.utf8)
        try bytes.write(to: local)
        let file = PreparedFile(fileURL: local, fileExtension: "txt", byteCount: Int64(bytes.count), pickedName: local.lastPathComponent)
        let stage = projection.fileStager(beside: pane, keepingTo: .init(joined: projection.inventoryCore))
        let staged = try await stage(file, .init { _ in })

        composer.replaceDraft(with: "请只回复标记。\n\n    " + marker)
        composer.insertPathIntoDraft(staged.path)
        let draft = composer.draft
        chat.draftDidChange(to: draft)
        let result = await composer.send(policy: policy)
        try #require(result == .outcomeUnknown)
        let pending = try #require(composer.messages.first)
        #expect(pending.state == .outcomeUnknown && pending.stagedImagePaths == [image])
        #expect(await composer.retry(pending.id, policy: policy) == .ignored)
        composer.withdrawToDraft(pending.id)
        #expect(composer.draft == draft && composer.readyImagePaths == [image])
        try await wait(for: "fresh inventory and the one recorded prompt after the lost Enter response") {
            if projection.status != .connected { await projection.revalidate(); return false }
            await chat.step()
            let replies = chat.conversation.transcript.entries.filter { $0.content == .assistant(.init(text: marker)) }
            return chat.conversation.transcript.recordedPrompts.filter { $0.text.contains(marker) }.count == 1
                && replies.count == 1
        }
        let copy = try await files.read(path: staged.path, from: 0, to: UInt64(bytes.count), chunk: 4096)
        #expect(copy == bytes)
        let length = try #require(try await files.status(fixture.peerFile)?.size)
        try #require(length > 0 && length <= 1 << 20)
        let peer = try #require(try await files.read(path: fixture.peerFile, from: 0, to: length, chunk: 64 << 10))
        #expect(peer.range(of: bytes) == nil)
    }

    func stageDraftImage(projection: RexConsoleProjection, pane: String, composer: AgentComposerStore) async throws -> String {
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg=="))
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("heeler-lab-\(UUID()).png")
        try bytes.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let stager = projection.fileStager(beside: pane, keepingTo: .init(joined: projection.inventoryCore))
        let file = PreparedFile(fileURL: local, fileExtension: "png", byteCount: Int64(bytes.count), pickedName: local.lastPathComponent)
        let staged = try await stager(file, .init { _ in })
        let readback = try await projection.chatHostFiles().read(path: staged.path, from: 0, to: UInt64(bytes.count), chunk: 4096)
        try #require(readback == bytes)
        composer.imageStagingDidBegin(operationID: 1)
        composer.imageStagingDidComplete(operationID: 1, path: staged.path, preview: nil)
        return staged.path
    }

    /// A retained action on the desktop's real prompt while the phone is
    /// explicitly reading the previous thread. Only the desktop may answer.
    func checkReadOnlyPermission(_ marker: String, directory: String, chat: AgentChatStore, projection: RexConsoleProjection, pane: String) async throws {
        try #require(chat.isReadingPickedConversation)
        chat.blocked.show()
        defer { chat.blocked.hide() }
        var shown: BlockedCardStore.Content = .none
        try await wait(for: "the desktop permission beside the explicitly selected history") {
            if let updated = projection.agentsByPane[pane]?.agent { chat.agentDidChange(updated) }
            await chat.step()
            await chat.blocked.refresh()
            switch chat.blocked.content {
            case .card(let card):
                guard card.dialog.kind == .codexExec, card.dialog.subject.command?.contains(marker) == true else { return false }
            case .generic(let excerpt):
                guard excerpt.rows.map(\.text).joined(separator: " ").contains(marker), excerpt.numbered[1]?.contains("Yes") == true else { return false }
            case .unreadable:
                guard chat.blocked.unreadableNote != nil else { return false }
            default: return false
            }
            shown = chat.blocked.content
            return true
        }
        switch shown {
        case .card(let card):
            let allow = try #require(card.dialog.options.first { $0.role == .approve })
            await chat.blocked.perform(.choose(ordinal: allow.ordinal), shownCard: card)
        case .generic:
            await chat.blocked.press(number: 1)
        case .unreadable:
            await chat.blocked.press(number: 1)
            await chat.blocked.sendKeys(["enter"])
        default:
            throw RexLab.LabError.unreadable("No retained permission action")
        }
        let typing = try #require(projection.checkedChatTyping(at: pane))
        let screen = try await typing.blockedScreen.readScreen()
        try #require(screen.rows.contains { $0.text.contains("Would you like to run") })
        let file = directory + "/heeler-lab-" + marker.lowercased() + ".txt"
        let written = try await projection.chatHostFiles().status(file)
        try #require(written == nil)
    }

    func checkNativeControls(
        projection: RexConsoleProjection, pane: String, program: ChatProgram,
        composer: AgentComposerStore, chat: AgentChatStore, policy: ComposerDeliveryPolicy, directory: String,
        checksPermissions: Bool, clearDesktopLine: () async throws -> Void
    ) async throws -> (path: String, oldStop: AgentComposerInterrupt) {
        try #require(program == .claude || program == .codex)
        let tag = UUID().uuidString.prefix(8)
        let marker = "REX_LAB_ATTACHMENT_" + tag
        let contents = Data(("Lab attachment " + marker).utf8)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("heeler-lab-\(tag).txt")
        try contents.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let pin = TerminalCorePin(joined: projection.inventoryCore)
        let stager = projection.fileStager(beside: pane, keepingTo: pin)
        let prepared = PreparedFile(fileURL: local, fileExtension: "txt", byteCount: Int64(contents.count), pickedName: local.lastPathComponent)
        let staged = try await stager(prepared, .init { _ in })
        let files = projection.chatHostFiles()
        let copied = try await files.read(path: staged.path, from: 0, to: UInt64(contents.count), chunk: 4096)
        try #require(copied == contents)
        composer.replaceDraft(with: "This fixture includes one file.")
        composer.insertPathIntoDraft(staged.path)
        composer.insertIntoDraft("Reply only with " + marker + ".")
        let outgoing = composer.draft
        chat.draftDidChange(to: outgoing)
        let sent = await composer.send(policy: policy)
        try #require(sent == .submittedViaAttach || sent == .deliveredViaAttach, "\(String(describing: sent))")
        try await wait(for: "the one recorded attachment path and its reply") {
            await chat.step()
            return chat.conversation.transcript.recordedPrompts.filter { $0.text == outgoing }.count == 1
                && chat.conversation.transcript.entries.contains { $0.content == .assistant(.init(text: marker)) }
        }

        let pending = "REX_LAB_STOP_" + tag
        composer.replaceDraft(with: pending)
        chat.draftDidChange(to: pending)
        let started = await composer.send(policy: policy)
        try #require(started == .submittedViaAttach || started == .deliveredViaAttach)
        try await wait(for: "the agent working on the controlled long request") {
            projection.agentsByPane[pane]?.agent.status == .working
        }
        try await wait(for: "the active turn recorded by the original conversation") {
            if let fresh = projection.agentsByPane[pane]?.agent { chat.agentDidChange(fresh) }
            await chat.step()
            guard let turn = chat.conversation.transcript.turns.last else { return false }
            return turn.ending == nil && chat.conversation.transcript.recordedPrompts.contains { $0.text == pending }
        }
        let agentKeys = ChatAgentKeysStore { keys in try await projection.sendAgentKeys(keys, to: pane) }
        let checkedStop = projection.checkedChatStop(for: pane, program: program, keepingTo: pin,
            agentKeys: agentKeys, confirmTarget: chat.rexStopVerification(), live: { projection })
        let stop = try #require(checkedStop)
        let interrupted = await stop.perform()
        try #require(interrupted == .sent)
        try await wait(for: "the agent to leave Working after Chat Stop") {
            guard let status = projection.agentsByPane[pane]?.agent.status else { return false }
            return status == .idle || status == .done
        }

        let successor = "REX_LAB_SUCCESSOR_SAME_" + tag
        composer.replaceDraft(with: successor)
        chat.draftDidChange(to: successor)
        if program == .claude {
            let typing = try #require(projection.checkedChatTyping(at: pane))
            let screen = try await typing.blockedScreen.readScreen()
            if case .text(let restored) = InputBoxStateDetector.detect(screen, program: program), restored == pending {
                // Claude can restore an interrupted prompt into its desktop input.
                // Keep the phone draft until the independent terminal clears it.
                let held = await composer.send(policy: policy)
                guard case .refused = held else { throw RexLab.LabError.unreadable("Send overwrote the restored desktop prompt") }
                try #require(composer.draft == successor)
                try await clearDesktopLine()
                try await wait(for: "the desktop to clear its own restored prompt") {
                    let current = try await typing.blockedScreen.readScreen()
                    if case .empty = InputBoxStateDetector.detect(current, program: program) { return true }
                    return false
                }
            }
        }
        let restarted = await composer.send(policy: policy)
        try #require(restarted == .submittedViaAttach || restarted == .deliveredViaAttach)
        try await wait(for: "the next turn of the same conversation to start") {
            projection.agentsByPane[pane]?.agent.status == .working
        }
        let stale = await stop.perform()
        try #require(stale == .failed(ChatStopPlan.changedDroidTurn))
        try await wait(for: "the later turn of the same conversation to complete") {
            await chat.step()
            return chat.conversation.transcript.entries.contains { $0.content == .assistant(.init(text: successor)) }
        }
        guard checksPermissions else { return (staged.path, stop) }

        chat.blocked.show()
        defer { chat.blocked.hide() }
        var declinedCard: BlockedCard?
        for role in [DialogOptionRole.approve, .decline, .decline] {
            let request = (role == .approve ? "REX_LAB_APPROVE_" : "REX_LAB_DECLINE_") + tag
            let path = directory + "/heeler-lab-" + request.lowercased() + ".txt"
            let original = try await files.status(path)
            try #require(original == nil)
            composer.replaceDraft(with: request)
            chat.draftDidChange(to: request)
            let result = await composer.send(policy: policy)
            try #require(result == .submittedViaAttach || result == .deliveredViaAttach)
            var observed: BlockedCard?
            var lastReading = ""
            do {
                try await wait(for: "the named single-use permission on the native Chat card") {
                    if let updated = projection.agentsByPane[pane]?.agent { chat.agentDidChange(updated) }
                    await chat.step()
                    await chat.blocked.refresh()
                    switch chat.blocked.content {
                    case .card(let card):
                        lastReading = "card " + String(describing: card.dialog.kind)
                        let matches = [card.request?.summary, card.dialog.subject.command].compactMap { $0 }
                            .contains { $0.contains(request) }
                        guard card.dialog.kind == (program == .claude ? .claudeBash : .codexExec), matches else { return false }
                        observed = card
                        return true
                    case .generic(let excerpt): lastReading = excerpt.reason
                    case .none: lastReading = "no card, status " + String(describing: chat.agent.status)
                    case .unreadable: lastReading = "unreadable, status " + String(describing: chat.agent.status)
                    }
                    return false
                }
            } catch {
                throw RexLab.LabError.unreadable("Single-use permission: " + lastReading)
            }
            let card = try #require(observed)
            let currentCall = try #require(card.request?.callID)
            if let declinedCard {
                let previousCall = try #require(declinedCard.request?.callID)
                try #require(previousCall != currentCall)
                try #require(declinedCard.request?.summary == card.request?.summary)
                try #require(declinedCard.dialog.fingerprint.matches(card.dialog.fingerprint))
                let staleAllow = try #require(declinedCard.dialog.options.first { $0.role == .approve })
                await chat.blocked.perform(.choose(ordinal: staleAllow.ordinal), shownCard: declinedCard)
                await chat.step()
                await chat.blocked.refresh()
                guard case .card(let current) = chat.blocked.content else {
                    throw RexLab.LabError.unreadable("The second permission disappeared after a stale action.")
                }
                try #require(current.request?.callID == currentCall)
                let premature = try await files.status(path)
                try #require(premature == nil)
            }
            let choice = try #require(card.dialog.options.first { $0.role == role })
            await chat.blocked.perform(.choose(ordinal: choice.ordinal), shownCard: card)
            try await wait(for: "the native Agent to finish the answered permission") {
                guard let status = projection.agentsByPane[pane]?.agent.status,
                      status == .idle || status == .done else { return false }
                if let updated = projection.agentsByPane[pane]?.agent { chat.agentDidChange(updated) }
                await chat.step()
                await chat.blocked.refresh()
                if case .card(let pending) = chat.blocked.content, pending.dialog.fingerprint == card.dialog.fingerprint { return false }
                return true
            }
            if role == .approve {
                let data = try await files.read(path: path, from: 0, to: UInt64(request.utf8.count), chunk: 4096)
                try #require(data == Data(request.utf8))
            } else {
                let declined = try await files.status(path)
                try #require(declined == nil)
                declinedCard = card
            }
        }
        return (staged.path, stop)
    }
}

@MainActor
@Suite("Rex Chat with a lost Enter response", .timeLimit(.minutes(2)))
struct RexLostReceiptLiveTests {
    @Test func editDraftRecoversTheUploadedFilesAfterRexAcceptedEnter() async throws {
        try await RexForegroundChatLiveTests().run(fixtureKey: "HEELER_REX_RECEIPT_LAB", loseReceipt: true)
    }
}
