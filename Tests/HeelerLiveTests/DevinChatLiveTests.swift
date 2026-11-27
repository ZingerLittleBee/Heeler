import Foundation
import SwiftUI
import Testing

@testable import Heeler

@MainActor
@Suite("Devin Chat over loopback SSH", .serialized)
struct DevinChatLiveTests {
    private struct Lab: Decodable, LiveChatBackendLab {
        let port: Int
        let user, seed, fingerprint, coreName, tmuxSocket, tmuxExecutable, rexSocket, rexSession, rexBlock: String
        let panes, sessions: [String: String]
        let directory: String
        var herdrSocket: String?
        struct Startup: Decodable { let pane, directory: String }
        var startup: [String: Startup]?
    }

    private func config(_ platform: String) throws -> Lab {
        let key = "HEELER_DEVIN_LAB_" + platform.uppercased()
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[key]))
        return try JSONDecoder().decode(Lab.self, from: Data(contentsOf: url))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DEVIN_MAC_REX_WRITERS"] != nil))
    func keepsSameDirectoryRexWritersSeparateOnMacOS() async throws {
        struct Writer: Decodable {
            let lab: Lab
            let pid, start: String
        }
        let path = try #require(ProcessInfo.processInfo.environment["HEELER_DEVIN_MAC_REX_WRITERS"])
        let pair = try JSONDecoder().decode([Writer].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(pair.count == 2)
        let a = pair[0], b = pair[1]
        try #require(a.lab.directory == b.lab.directory && a.lab.rexSocket == b.lab.rexSocket)
        try #require(a.pid != b.pid && a.lab.rexBlock != b.lab.rexBlock && a.lab.sessions["rex"] != b.lab.sessions["rex"])
        for (own, other) in [(a, b), (b, a)] {
            try await withChat(own.lab, .rex) { live in
                let read = try #require(live.io.droidTarget)
                let target = try #require(try await read())
                #expect(target.pid == own.pid && target.start == own.start)
                #expect(target.directory == own.lab.directory && target.sessionID == own.lab.sessions["rex"])
                var wrongWriter = target
                wrongWriter.pid = other.pid
                wrongWriter.start = other.start
                let check = DroidSendVerification(target: wrongWriter, readTarget: read, readScreen: live.io.readScreen,
                                                  requiresSpec: false, program: .devin)
                guard case .inputNotReady = await check.refusal() else {
                    Issue.record("The other foreground's ACP writer passed the displayed conversation's input check")
                    return
                }
            }
        }
    }

    @Test(arguments: ProcessInfo.processInfo.environment["HEELER_DEVIN_BEHAVIOR_PLATFORM"].map { [$0] } ?? ["mac", "linux"], LiveChatLabSelection.cases([.herdrTUI, .herdrCore, .tmux, .rex]))
    func opensTheForegroundSessionAndDeliversExactlyOnce(_ platform: String, _ backend: ServerKind) async throws {
        let lab = try config(platform)
        try await withChat(lab, backend) { live in
            let token = "HEELER_DEVIN_" + UUID().uuidString.prefix(8)
            let prompt = "Reply only with the marker on the last line. Ignore the sample \u{4E2D}\u{6587}. Do not use tools.\n\n    \(token)"
            try await live.send(prompt)
            try await live.wait {
                live.chat.conversation.transcript.entries.contains { $0.content == .assistant(.init(text: token)) }
            }
            #expect(live.chat.conversation.transcript.recordedPrompts.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt }.count == 1)
            #expect(live.chat.droidSessionID == lab.sessions[backend.rawValue])
        }
    }

    private func withChat(_ lab: Lab, _ backend: ServerKind, startsAtTrust: Bool = false, pane selectedPane: String? = nil, body: (Live) async throws -> Void) async throws {
        let expected = lab.sessions[backend.rawValue]
        let (projection, primary) = try lab.connection(backend)
        let pane = selectedPane ?? primary
        projection.start(isActive: true)
        defer { projection.end() }
        let start = ContinuousClock.now
        while projection.agentsByPane[pane]?.agent.kind != "devin", ContinuousClock.now - start < .seconds(20) {
            try await Task.sleep(for: .milliseconds(200))
        }
        let agent = try #require(projection.agentsByPane[pane]?.agent, "No Agent in \(backend), \(projection.status)")
        try #require(agent.kind == "devin")
        let binding = try await projection.chatInputTarget(paneID: pane, program: .devin)
        if startsAtTrust {
            try #require(binding?.sessionID == nil)
        } else {
            try #require(expected != nil && binding?.sessionID == expected && binding?.directory == lab.directory)
        }
        let typing = projection.checkedChatTyping(at: pane)
        var io = typing?.blockedScreen ?? .init(
            readScreen: { try await projection.readAgentScreen(pane) },
            sendKeys: { try await projection.sendAgentKeys($0, to: pane) },
            paste: { try await projection.pasteIntoAgent($0, paneID: pane) })
        io.hostName = projection.host.name
        io.droidTarget = { try await projection.chatInputTarget(paneID: pane, program: .devin) }
        var source = AgentChatSource(hostID: projection.host.id, socketLocation: .namedSession("lab"), files: projection.chatHostFiles(),
            agentInfo: { try await projection.agentInfo(paneID: pane) }, cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: .devin)), screen: io)
        source.sessionEvidence = {
            if let tui = projection as? HostConsoleProjection { return try await tui.droidSessionEvidence(paneID: pane, program: .devin) }
            return try await projection.checkChatSession(paneID: pane, program: .devin)
        }
        source.coreScope = projection.chatCacheScope
        source.requiresIndependentInputSession = projection is RexConsoleProjection
        let chat = AgentChatStore(agentID: .init(hostID: projection.host.id, paneID: pane), agent: agent, program: .devin, source: source)
        defer { chat.end() }
        await chat.step()
        chat.show()
        if !startsAtTrust {
            try #require(chat.displayedDroidTarget == binding && chat.droidSessionID == expected, "Chat failed to bind: \(chat.conversation.phase)")
        }
        let sender = projection.checkedComposerSend(for: pane, keepingTo: TerminalCorePin(joined: projection.inventoryCore), live: { projection })
        let composer = AgentComposerStore(target: pane, checkedSend: sender) { message in
            try #require(backend == .herdrTUI)
            return try await projection.promptAgent(message)
        }
        composer.bindDroidDraft(to: chat.composerSessionID, program: .devin)
        let policy = ComposerDeliveryPolicy.chat(rules: .init(program: .devin, commands: []),
            activity: { ChatAgentActivity(projection.agentsByPane[pane]?.agent.status ?? .unknown) },
            readScreen: io.readScreen, droidTarget: io.droidTarget,
            displayedDroidTarget: { chat.displayedDroidTarget }, confirmSession: { await chat.confirmSessionBeforeSend() })
        try await body(.init(chat: chat, composer: composer, policy: policy, projection: projection, pane: pane, io: io))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DEVIN_BEHAVIOR_PLATFORM"] != nil),
          arguments: LiveChatLabSelection.cases([.herdrTUI, .herdrCore, .tmux, .rex]))
    func approvalsQuestionsAndStaleDrafts(_ backend: ServerKind) async throws {
        let lab = try config(try #require(ProcessInfo.processInfo.environment["HEELER_DEVIN_BEHAVIOR_PLATFORM"]))
        try await withChat(lab, backend) { live in
            let tag = String(UUID().uuidString.prefix(8))
            let fileA = "approval-a-" + tag + ".txt", fileB = "approval-b-" + tag + ".txt"
            let session = try #require(live.chat.droidSessionID)
            let files = live.projection.chatHostFiles()
            let marker = "DEVIN_A_" + tag
            let rawRex = backend == .rex && live.chat.agent.status == .unknown
            try await live.send("Use write to create exactly " + lab.directory + "/" + fileA + " with contents " + marker + ". Use this full path. Do not use exec or ask a follow-up question.")
            if rawRex {
                try await live.wait { try await DevinDialog.parse(live.io.readScreen()).dialog?.kind == .devinPermission }
                if case .card = live.chat.blocked.content { Issue.record("Unknown Rex exposed an actionable card") }
                try await live.projection.sendAgentKeys(["esc"], to: live.pane)
            } else {
                let first = try await live.card(.devinPermission)
                try #require(first.request?.summary == lab.directory + "/" + fileA)
                try await capture(live.chat.blocked, name: "write-" + backend.rawValue)
                await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: first)
                try await live.wait {
                    let chunk = try await files.read(.init(path: lab.directory + "/" + fileA, offset: 0, maxBytes: 128))
                    return String(decoding: chunk.data, as: UTF8.self).trimmingCharacters(in: .newlines) == marker
                }
                try await live.send("Use write to create exactly " + lab.directory + "/" + fileB + " with contents DEVIN_B. Use this full path. Do not use exec.")
                let second = try await live.card(.devinPermission)
                try #require(second.request?.summary == lab.directory + "/" + fileB && second.request?.callID != first.request?.callID)
                await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: first)
                try #require(try await DevinDialog.parse(live.io.readScreen()).dialog?.subject.filePath?.hasSuffix(fileB) == true)
                try await live.projection.sendAgentKeys(["esc"], to: live.pane)
                try await live.wait { try await DevinInputBox.read(live.io.readScreen()).isSendable }
                await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: second)
                #expect(try await files.status(lab.directory + "/" + fileB) == nil)

                try await live.send("Call ask_user_question now. Ask 'Which color?' (Red or Blue) and 'Which size?' (Small or Large). Give each option a short description. Wait for both answers.")
                let color = try await live.card(.devinQuestion)
                try #require(color.request?.questions.count == 2)
                try await capture(live.chat.blocked, name: "question-" + backend.rawValue)
                await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: color)
                try await live.wait {
                    guard case .card(let next) = live.chat.blocked.content else { return false }
                    return next.dialog.kind == .devinQuestion && next.dialog.title != color.dialog.title
                }
                let size = try await live.card(.devinQuestion)
                let field = try #require(size.dialog.options.first(where: { $0.role == .otherText }))
                await live.chat.blocked.perform(.respond(ordinal: field.ordinal, text: "Medium"), shownCard: size)
                try await live.wait { try await DevinInputBox.read(live.io.readScreen()).isSendable }
            }

            let draft = "PARKED_" + tag
            live.composer.replaceDraft(with: draft)
            live.chat.draftDidChange(to: draft)
            try await live.wait { try await DevinInputBox.read(live.io.readScreen()).isSendable }
            try await live.desktop("/clear")
            let limit = ContinuousClock.now + .seconds(15)
            var next: String?
            repeat {
                next = try? await live.io.droidTarget?()?.sessionID
                if next != nil && next != session { break }
                try await Task.sleep(for: .milliseconds(180))
            } while ContinuousClock.now < limit
            let other = try #require(next)
            try #require(other != session)
            guard case .refused = await live.composer.send(policy: live.policy) else { Issue.record("The parked draft left the original session"); return }
            try await live.bindVerifiedSession(other)
            try #require(!live.chat.conversation.transcript.recordedPrompts.contains { $0.text.contains(draft) })
            #expect(live.composer.draft.isEmpty)
            let peerMarker = "PEER_" + tag
            try await live.send("Reply with exactly " + peerMarker + ". Do not use tools.")
            try await live.wait { live.chat.conversation.transcript.entries.contains { $0.content == .assistant(.init(text: peerMarker)) } }
            try await live.desktop("/resume " + session)
            try await live.bindVerifiedSession(session)
            try #require(live.composer.draft == draft)

            // Change the terminal from an independent SSH connection while the
            // mobile projection is offline, then exercise the old Send button.
            let (desktop, pane) = try lab.connection(backend)
            desktop.start(isActive: true)
            defer { desktop.end() }
            let deadline = ContinuousClock.now + .seconds(20)
            while desktop.agentsByPane[pane]?.agent.kind != "devin", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(150))
            }
            try #require(try await desktop.chatInputTarget(paneID: pane, program: .devin)?.sessionID == session)
            live.chat.suspend()
            await live.projection.suspend()
            try await desktop.pasteIntoAgent("/resume " + other, paneID: pane)
            try await Task.sleep(for: .milliseconds(300))
            try await desktop.sendAgentKeys(["enter"], to: pane)
            let moved = ContinuousClock.now + .seconds(15)
            while try await desktop.chatInputTarget(paneID: pane, program: .devin)?.sessionID != other,
                  ContinuousClock.now < moved { try await Task.sleep(for: .milliseconds(180)) }
            try #require(try await desktop.chatInputTarget(paneID: pane, program: .devin)?.sessionID == other)
            await live.projection.resume()
            let afterReconnect = await live.composer.send(policy: live.policy)
            guard case .refused = afterReconnect else {
                Issue.record("Unexpected result for the parked draft after reconnect: \(afterReconnect)"); return
            }
            live.chat.resume()
            try await live.bindVerifiedSession(other)
            #expect(live.composer.draft.isEmpty)
            #expect(live.chat.conversation.transcript.entries.contains { $0.content == .assistant(.init(text: peerMarker)) })
            #expect(!live.chat.conversation.transcript.recordedPrompts.contains { $0.text.contains(draft) })
            try await live.desktop("/resume " + session)
            try await live.bindVerifiedSession(session)
            #expect(live.composer.draft == draft)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DEVIN_BEHAVIOR_PLATFORM"] != nil))
    func firstTrustAndDeclineBeforeTheSessionExists() async throws {
        let lab = try config(try #require(ProcessInfo.processInfo.environment["HEELER_DEVIN_BEHAVIOR_PLATFORM"]))
        let backend = try LiveChatLabSelection.backend()
        for key in ["trust", "decline"] {
            let entry = try #require(lab.startup?[key])
            let pane = entry.pane, directory = entry.directory
            try await withChat(lab, backend, startsAtTrust: true, pane: pane) { live in
                let chat = live.chat, composer = live.composer
                try await live.wait { if case .card = chat.blocked.content { return true }; return false }
                guard case .card(let shown) = chat.blocked.content else { throw TransportError.cancelled }
                try #require(shown.dialog.kind == .devinWorkspaceTrust && shown.dialog.subject.workspacePath == directory)
                try #require(shown.target?.directory == directory && shown.target?.sessionID == nil)
                if key == "trust" {
                    try await capture(chat.blocked, name: "trust")
                    await chat.blocked.perform(.choose(ordinal: 1), shownCard: shown)
                    try await live.wait { chat.composerSessionID != nil }
                    composer.bindDroidDraft(to: chat.composerSessionID, program: .devin)
                    let token = "TRUST_" + UUID().uuidString.prefix(8)
                    try await live.send("Reply with exactly " + token + ". Do not use tools.")
                    try await live.wait { chat.conversation.transcript.entries.contains { $0.content == .assistant(.init(text: token)) } }
                } else {
                    await chat.blocked.perform(.choose(ordinal: 2), shownCard: shown)
                    var running = true
                    let deadline = ContinuousClock.now + .seconds(25)
                    while ContinuousClock.now < deadline {
                        if let tui = live.projection as? HostConsoleProjection {
                            running = (try? await tui.processInfo(paneID: pane).foregroundProcesses?.contains { $0.name == "devin" }) == true
                        } else {
                            running = live.projection.agentsByPane[pane]?.agent.kind == "devin"
                        }
                        if !running { break }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    try #require(!running)
                    await chat.blocked.perform(.choose(ordinal: 1), shownCard: shown)
                    let replacement = try? await live.projection.chatInputTarget(paneID: pane, program: .devin)
                    #expect(replacement == nil)
                }
            }
        }
    }

    /// A fresh account-data directory keeps each startup independent. Rex
    /// Unknown owns no Chat keys, including at trust.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DEVIN_STARTUP_LABS"] != nil),
          arguments: LiveChatLabSelection.cases([.herdrCore, .tmux, .rex]))
    func firstTrustOverTheBackendTypingPath(_ backend: ServerKind) async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["HEELER_DEVIN_STARTUP_LABS"])
        let path = URL(fileURLWithPath: folder).appendingPathComponent(backend.rawValue + ".json")
        let lab = try JSONDecoder().decode(Lab.self, from: Data(contentsOf: path))
        try await withChat(lab, backend, startsAtTrust: true) { live in
            try await live.wait { try await DevinDialog.parse(live.io.readScreen()).dialog?.subject.workspacePath == lab.directory }
            if backend == .rex, live.chat.agent.status == .unknown {
                #expect(live.chat.displayedDroidTarget == nil)
                if case .card = live.chat.blocked.content { Issue.record("Unknown Rex offered a trust choice") }
                // The user confirms the displayed directory from the terminal.
                let screen = try await live.io.readScreen()
                let dialog = try #require(DevinDialog.parse(screen).dialog)
                try #require(dialog.subject.workspacePath == lab.directory && dialog.focus.focusedOrdinal == 1)
                try await live.projection.sendAgentKeys(["enter"], to: live.pane)
            } else {
                try await live.wait {
                    guard case .card(let card) = live.chat.blocked.content else { return false }
                    return card.dialog.kind == .devinWorkspaceTrust && card.target?.directory == lab.directory
                }
                guard case .card(let card) = live.chat.blocked.content else { throw TransportError.cancelled }
                await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: card)
            }
            try await live.wait { live.chat.composerSessionID != nil }
            live.composer.bindDroidDraft(to: live.chat.composerSessionID, program: .devin)
            let marker = "FRESH_" + UUID().uuidString.prefix(8)
            try await live.send("Reply with exactly " + marker + ". Do not use tools.")
            try await live.wait { live.chat.conversation.transcript.entries.contains { $0.content == .assistant(.init(text: marker)) } }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DEVIN_BACKGROUND_LAB"] != nil))
    func reopensTheSameBackgroundShellsAndChildOverSSH() async throws {
        struct Fixture: Decodable {
            let lab: Lab
            let shells: [String: String]
            let child, childOutput: String?
            let shellsOnly: Bool?
            let backend: ServerKind?
            let stoppedShell: String?
        }
        let path = try #require(ProcessInfo.processInfo.environment["HEELER_DEVIN_BACKGROUND_LAB"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let child: (id: String, output: String)?
        if fixture.shellsOnly == true {
            try #require(!fixture.shells.isEmpty)
            child = nil
        } else {
            child = (try #require(fixture.child), try #require(fixture.childOutput))
        }
        let backend = try LiveChatLabSelection.backend(for: fixture.backend)
        let expected = Set(fixture.shells.keys).union(child.map { [$0.id] } ?? [])
        for _ in 0..<2 {
            try await withChat(fixture.lab, backend) { live in
                try await live.wait {
                    let transcript = live.chat.conversation.transcript
                    let work = transcript.backgroundWork
                    if Set(work.compactMap(\.taskID)).isSuperset(of: expected) {
                        return true
                    }
                    return false
                }
                let transcript = live.chat.conversation.transcript
                for (shell, output) in fixture.shells {
                    let jobs = transcript.backgroundWork.filter { $0.taskID == shell }
                    try #require(jobs.count == 1)
                    #expect(jobs[0].state == .completed && jobs[0].reportedOutput == output)
                }
                if let stopped = fixture.stoppedShell {
                    let job = try #require(transcript.backgroundWork.first { $0.taskID == stopped })
                    #expect(job.state == .stopped)
                }
                if let child {
                    let children = transcript.backgroundWork.filter { $0.taskID == child.id }
                    try #require(children.count == 1)
                    #expect(children[0].reportedOutput?.contains(child.output) == true)
                }
                #expect(!transcript.recordedPrompts.contains { $0.text.hasPrefix("<subagent_completion_notification>") })
            }
        }
    }

    /// A fresh signed-in client, two fixture commands and a delayed public report.
    /// The phone initiates all three jobs. The fixture releases the child's file
    /// only after the parent has returned and Chat still shows that child running.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DEVIN_COMPOSER_WORK_LAB"] != nil))
    func launchesBackgroundWorkFromComposerAndReopensIt() async throws {
        struct Work: Decodable {
            let lab: Lab
            let backend: ServerKind
            let tag, storeRoot, successCommand, failureCommand: String
            let childFile, releaseSignal, childReport: String
        }
        let config = try #require(ProcessInfo.processInfo.environment["HEELER_DEVIN_COMPOSER_WORK_LAB"])
        let fixtureURL = URL(fileURLWithPath: config)
        let work = try JSONDecoder().decode(Work.self, from: Data(contentsOf: fixtureURL))
        let signal = fixtureURL.deletingLastPathComponent().appendingPathComponent(work.releaseSignal)
        try #require(!work.releaseSignal.contains("/") && !FileManager.default.fileExists(atPath: signal.path))
        let rules = ChatSendRules(program: .devin, commands: [])
        let success = "REX_LAB_PHONE_ZERO_" + work.tag
        let failure = "REX_LAB_PHONE_FAILED_" + work.tag
        let parent = "REX_LAB_PHONE_PARENT_" + work.tag
        let session = try #require(work.lab.sessions[work.backend.rawValue])
        var expected: [String: String] = [:]
        var childID: String?
        try await withChat(work.lab, work.backend) { live in
            for (command, marker, wanted) in [(work.successCommand, success, ChatBackgroundWorkItem.State.completed),
                                              (work.failureCommand, failure, .failed)] {
                let prompt = "Use exec with timeout 0, omitting shell_id, to run exactly this command: " + command
                    + ". Use the returned ID in get_output with a positive timeout to read the terminal exit. Do not edit or rerun the command. Reply only with PHONE_FINISHED_" + marker
                try await live.send(prompt)
                let card = try await live.card(.devinPermission)
                try #require(card.request?.summary == command && card.dialog.options.first?.label == "Allow · Once")
                await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: card)
                try await live.wait {
                    let transcript = live.chat.conversation.transcript
                    guard let job = transcript.backgroundWork.first(where: { $0.title == command }),
                        job.state == wanted, job.reportedOutput?.contains(marker) == true, let id = job.taskID,
                        transcript.turns.last?.ending == .completed else { return false }
                    expected[marker] = id
                    return true
                }
                #expect(live.chat.conversation.transcript.recordedPrompts.filter { $0.text == rules.outgoingText(prompt) }.count == 1)
            }
            let title = "Heeler file witness " + work.tag
            let childPrompt = "Call run_subagent exactly once with is_background true and title '" + title
                + "'. Give the child this task: read only " + work.childFile
                + "; if its first line is PENDING, read it again until it changes, without running commands or modifying files. Report exactly the changed first line."
                + " Once the background launch is acknowledged, immediately finish your own turn with exactly " + parent
                + ". Do not wait for the child or call another tool."
            try await live.send(childPrompt)
            try await live.wait {
                let transcript = live.chat.conversation.transcript
                guard transcript.entries.contains(where: { $0.content == .assistant(.init(text: parent)) }),
                    transcript.turns.last?.ending == .completed,
                    let child = transcript.backgroundWork.first(where: { $0.kind == .subagent && $0.title == title }),
                    child.state == .running, let id = child.taskID else { return false }
                childID = id
                return true
            }
            #expect(live.chat.conversation.transcript.recordedPrompts.filter { $0.text == rules.outgoingText(childPrompt) }.count == 1)
            try Data(work.tag.utf8).write(to: signal, options: .withoutOverwriting)
            try await live.wait {
                live.chat.conversation.transcript.backgroundWork.contains {
                    $0.taskID == childID && $0.state == .completed && $0.reportedOutput?.contains(work.childReport) == true
                }
            }
        }
        let child = try #require(childID)
        let successID = try #require(expected[success])
        let failureID = try #require(expected[failure])
        try #require(Set([successID, failureID, child]).count == 3)
        for _ in 0..<2 {
            try await withChat(work.lab, work.backend) { live in
                try await live.wait {
                    let jobs = live.chat.conversation.transcript.backgroundWork
                    return jobs.contains { $0.taskID == successID && $0.state == .completed && $0.reportedOutput?.contains(success) == true }
                        && jobs.contains { $0.taskID == failureID && $0.state == .failed && $0.reportedOutput?.contains(failure) == true }
                        && jobs.contains { $0.taskID == child && $0.state == .completed && $0.reportedOutput?.contains(work.childReport) == true }
                }
                let query = try #require(live.projection.chatHostFiles().queryDevin)
                var rows: [DevinSessionPage.Row] = []
                var offset = 0
                repeat {
                    let page = try await query(.init(session: session, root: work.storeRoot, offset: offset, limit: 24))
                    try #require(page.offset == offset && page.total <= 256)
                    rows.append(contentsOf: page.rows)
                    offset += page.rows.count
                    if offset == page.total { break }
                    try #require(!page.rows.isEmpty)
                } while true
                for (id, code) in [(successID, 0), (failureID, 17)] {
                    let lookup = rows.flatMap(\.calls).filter { $0.name == "get_output" && $0.arguments.shell_id == id }.map(\.id)
                    #expect(rows.contains { row in
                        row.isExecutionResult == true && row.shellExit?.code == code && row.resultFor.map(lookup.contains) == true
                    })
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DEVIN_STOP_PLATFORM"] != nil))
    func stopsOnlyTheCurrentlyDisplayedTurn() async throws {
        let lab = try config(try #require(ProcessInfo.processInfo.environment["HEELER_DEVIN_STOP_PLATFORM"]))
        try await withChat(lab, LiveChatLabSelection.backend()) { live in
            let plan = ChatStopPlan.standard(for: .devin)
            let check = try #require(plan.screenGuard)
            let keys = ChatAgentKeysStore(send: { try await live.projection.sendAgentKeys($0, to: live.pane) })
            let context: @MainActor () async throws -> ChatStopContext = {
                let screen = try await live.io.readScreen()
                let verified = if live.projection is TmuxConsoleProjection { await live.chat.droidStopVerification()() } else { false }
                return .init(screen: screen, activity: ChatAgentActivity(live.chat.agent.status), hasVerifiedTurn: verified)
            }
            var previous: AgentComposerInterrupt?
            for _ in 0..<2 {
                try await live.send("Count to 1000 in words, on individual lines, without using tools. Begin with " + UUID().uuidString.prefix(8) + ".")
                try await live.wait {
                    let turn = live.chat.conversation.transcript.turns.last
                    let verdict = try await check(context())
                    return turn != nil && turn?.ending == nil && verdict == .press
                }
                if let previous { try #require(await previous.perform() == .failed(ChatStopPlan.changedDroidTurn)) }
                let verify = live.projection is RexConsoleProjection ? live.chat.rexStopVerification() : live.chat.droidStopVerification()
                let stop = live.projection.checkedChatStop(
                    for: live.pane, program: .devin, keepingTo: TerminalCorePin(joined: live.projection.inventoryCore),
                    agentKeys: keys, followThrough: nil, confirmTarget: verify, live: { live.projection }
                ) ?? plan.composerInterrupt(context: context, agentKeys: keys, confirmTarget: verify)
                try #require(await stop.perform() == .sent)
                try await live.wait { try await DevinInputBox.read(live.io.readScreen()).isSendable }
                previous = stop
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DEVIN_PLAN_LAB"] != nil))
    func declinesAPlanAndSendsFeedbackWithoutTakingTheMessageDraft() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HEELER_DEVIN_PLAN_LAB"])
        let lab = try JSONDecoder().decode(Lab.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let fixture = try ProcessInfo.processInfo.environment["HEELER_DEVIN_PLAN_BACKEND"].map { name in
            try #require(ServerKind(rawValue: name), "Unknown Devin plan backend: \(name)")
        }
        try await withChat(lab, LiveChatLabSelection.backend(for: fixture)) { live in
            try await live.desktop("/plan")
            try await live.wait { try await DevinInputBox.isPlan(live.io.readScreen()) }
            try await live.send("Propose writing a note.txt in this empty test folder. Write a very short plan with two plain numbered steps and no headings, then call exit_plan_mode to request approval. Make no changes to the workspace.")
            let card = try await live.card(.devinPlan)
            try #require(card.request?.summary.isEmpty == false && card.dialog.options.count == 3)
            try await capture(live.chat.blocked, name: "plan")
            live.composer.replaceDraft(with: "Ordinary message kept apart")
            await live.chat.blocked.perform(.choose(ordinal: 3), shownCard: card)
            try await live.wait { live.chat.blocked.droidRevision != nil }
            let feedback = try #require(live.chat.blocked.droidRevision)
            feedback.text = "Thank you. End the conversation without changing files. Reply with PLAN_FEEDBACK_RECEIVED."
            try #require(await live.composer.sendDroidRevision(feedback, policy: live.policy, readScreen: live.io.readScreen))
            let submitted = ChatSendRules(program: .devin, commands: []).outgoingText(feedback.text)
            try await live.wait {
                let transcript = live.chat.conversation.transcript
                return transcript.recordedPrompts.filter { $0.text == submitted }.count == 1
                    && transcript.entries.contains { $0.content == .assistant(.init(text: "PLAN_FEEDBACK_RECEIVED")) }
            }
            #expect(live.composer.draft == "Ordinary message kept apart")
            #expect(try await live.projection.chatHostFiles().status(lab.directory + "/note.txt") == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DEVIN_COMMAND_LABS"] != nil), arguments: ProcessInfo.processInfo.environment["HEELER_DEVIN_BEHAVIOR_PLATFORM"].map { [$0] } ?? ["mac", "linux"])
    func approvesTheDisplayedLongCommandOnce(_ platform: String) async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["HEELER_DEVIN_COMMAND_LABS"])
        let url = URL(fileURLWithPath: folder).appendingPathComponent("lab-" + platform + ".json")
        let lab = try JSONDecoder().decode(Lab.self, from: Data(contentsOf: url))
        try await withChat(lab, LiveChatLabSelection.backend()) { live in
            let marker = "DEVIN_COMMAND_" + UUID().uuidString.prefix(8)
            let command = "sleep 1 && echo DEVIN_LONG_COMMAND_SEQUENCE_ALPHA_0123456789 DEVIN_LONG_COMMAND_SEQUENCE_BETA_0123456789 " + marker
            try await live.send("Use exec once with this exact command. Do not touch any files.\n\n" + command)
            let first = try await live.card(.devinPermission)
            try #require(first.request?.summary == command && first.dialog.subject.devinScope == 1)
            try #require(first.dialog.options.prefix(4).map(\.label) == ["Allow · Once", "Allow · Session", "Allow · Project", "Allow · Always"])
            try await capture(live.chat.blocked, name: "command-" + platform)
            // Move the terminal cursor to Session, then have the native card
            // choose Once. No persistent permission is granted in this fixture.
            try await live.projection.sendAgentKeys(["right"], to: live.pane)
            try await live.wait {
                guard case .card(let current) = live.chat.blocked.content else { return false }
                return current.request?.callID == first.request?.callID && current.dialog.focus.focusedOrdinal == 2
            }
            let selected = try await live.card(.devinPermission)
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: selected)
            try await live.wait {
                live.chat.conversation.transcript.entries.contains {
                    guard case .tool(let tool) = $0.content, tool.callID == selected.request?.callID else { return false }
                    return tool.status == .succeeded && tool.preview?.text.contains(marker) == true
                }
            }
        }
    }

    private func capture(_ store: BlockedCardStore, name: String) async throws {
        guard let dir = ProcessInfo.processInfo.environment["HEELER_DEVIN_SCREENSHOTS"] else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let view = BlockedCardView(store: store, maxHeight: pad ? 540 : 430, openTerminal: {})
            .padding().frame(maxWidth: pad ? 640 : .infinity).background(.background)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(450))
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + (pad ? "-ipad.png" : "-iphone.png"))
        try #require(image.pngData()).write(to: url)
    }

    @MainActor private struct Live {
        let chat: AgentChatStore
        let composer: AgentComposerStore
        let policy: ComposerDeliveryPolicy
        let projection: any ConsoleHostProjection
        let pane: String
        let io: BlockedScreenIO

        func bindVerifiedSession(_ session: String) async throws {
            try await wait {
                guard chat.droidSessionID == session, chat.displayedDroidTarget?.sessionID == session,
                      let owner = chat.composerSessionID else { return false }
                composer.bindDroidDraft(to: owner, program: .devin)
                return composer.droidDraftMatches(owner)
            }
        }

        func send(_ text: String) async throws {
            try await wait { try await DevinInputBox.read(io.readScreen()).isSendable }
            composer.replaceDraft(with: text)
            chat.draftDidChange(to: text)
            var current = policy
            current.sessionWrite = chat.composerWriteCheck(for: composer)
            let sent = await composer.send(policy: current)
            try #require([.deliveredViaAttach, .submittedViaAttach, .deliveredViaPrompt].contains(sent), "Delivery via \(projection.host.serverKind): \(sent)")
        }

        func wait(at location: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool) async throws {
            let limit = ContinuousClock.now + .seconds(65)
            repeat {
                if let updated = projection.agentsByPane[pane]?.agent { chat.agentDidChange(updated) }
                await chat.step()
                await chat.blocked.refresh()
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(300))
            } while ContinuousClock.now < limit
            throw NSError(domain: "DevinLive", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Timed out at \(location.line) on \(projection.host.serverKind) (\(chat.agent.status), \(chat.conversation.phase), \(chat.blocked.notice ?? ""))"])
        }

        func card(_ kind: BlockedDialogKind) async throws -> BlockedCard {
            var found: BlockedCard?
            try await wait {
                guard case .card(let card) = chat.blocked.content, card.dialog.kind == kind,
                      card.target?.sessionID == chat.droidSessionID, card.request?.callID != nil else { return false }
                found = card
                return true
            }
            return try #require(found)
        }

        func desktop(_ text: String) async throws {
            try await projection.pasteIntoAgent(text, paneID: pane)
            try await Task.sleep(for: .milliseconds(300))
            try await projection.sendAgentKeys(["enter"], to: pane)
        }
    }
}
