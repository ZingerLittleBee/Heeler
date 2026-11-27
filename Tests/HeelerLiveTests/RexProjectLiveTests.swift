import CryptoKit
import Foundation
import Testing

@testable import Heeler

/// Starts only uniquely named lab sessions on the pinned SSH account in the fixture.
/// The executable named claude records its argv, environment and PID without a model account.
@Suite("Rex projects over SSH", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct RexProjectLiveTests {
    private struct Lab: Decodable {
        let port: Int
        let user: String
        let seed: String
        let fingerprint: String
        let rexSocket: String
        let rexSession: String
        let rexBlock: String
        let project: String
        let recorder: String
        let labBin: String?
        let previewPort: UInt16

        static func configured() throws -> Self {
            let path = try #require(ProcessInfo.processInfo.environment["HEELER_REX_PROJECT_LAB"],
                                    "Set HEELER_REX_PROJECT_LAB to the private disposable SSH fixture")
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
    }

    private struct Receipt: Decodable {
        let pid: Int
        let cwd: String
        let argv: [String]
        let env: [String: String]
    }

    @MainActor
    private struct Connection {
        let host: Host
        let session: RexHostSession
        let console: ConsoleStore

        init(_ lab: Lab) throws {
            let socket = try #require(RexSocket(path: lab.rexSocket))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: #require(Data(base64Encoded: lab.seed)))
            let settings = SSHTransportSettings(host: "127.0.0.1", port: lab.port, username: lab.user,
                credentials: .ed25519(key), hostKeyPolicy: .init(knownHosts: InMemoryKnownHostsStore()) {
                    $0.fingerprint.displayString == lab.fingerprint
                }, socket: .absolutePath("/nonexistent/herdr.sock"))
            host = Host(name: "heeler-lab-projects", address: "127.0.0.1", port: lab.port,
                        username: lab.user, serverKind: .rex)
            let session = RexHostSession(storedSocket: socket) { saved, previous in
                try await RexSSHTransport.connect(over: HeelerSSHTransport.connect(settings: settings),
                                                  socket: saved, resuming: previous)
            }
            self.session = session
            console = ConsoleStore(
                connectPortPreview: { _ in try await HeelerSSHTransport.connect(settings: settings) },
                makeRexSession: { _ in session })
            console.setHosts([host])
        }

        func view(_ id: String) async throws -> JSONValue {
            try await session.withConnection { connection in
                try await connection.control.call("session.view", payload: ["session_id": id]).result(JSONValue.self)
            }
        }

        func removeLabSession(_ id: String, named label: String) async throws {
            let view = try await view(id)
            try #require(label.hasPrefix("heeler-lab-") && view["label"]?.stringValue == label)
            try await session.withConnection { connection in
                _ = try await connection.control.call("session.destroy", payload: ["session_id": id])
            }
        }

        func foreground(_ address: RexPaneAddress) async throws -> RexInventoryWire.Process {
            let block = try await session.blockRequests(at: address, readDeadline: .sharedLinkRead)
            return try await RexInventoryWire.process(block.read(.process))
        }

        func receipt(_ lab: Lab, pid: Int) async throws -> Receipt {
            let folder = (lab.recorder as NSString).deletingLastPathComponent
            let file = RemoteFileRange(path: "\(folder)/\(pid).json", offset: 0, maxBytes: 32768)
            // The foreground can be visible before it publishes its per-PID file atomically.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while true {
                let slice = try await session.withConnection { try await $0.transport.reads.readHostFileRange(file) }
                if slice.length != nil {
                    return try JSONDecoder().decode(Receipt.self, from: slice.data)
                }
                try #require(ContinuousClock.now < deadline, "The foreground did not publish its launch receipt")
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func wait(_ message: String, until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(22))
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        try #require(Bool(false), "\(message)")
    }

    @Test func readsSkillsChangesAndPatchesFromTheSelectedProject() async throws {
        let lab = try Lab.configured()
        let link = try Connection(lab)
        let console = link.console, id = link.host.id
        defer { console.setHosts([]) }
        await console.resume()
        try await wait("Rex has reported a POSIX kernel and the desktop session") {
            console.capabilities(for: id).readsProjects && console.workspaces(for: id).contains { $0.id == lab.rexSession }
        }
        let skills = try await console.fetchSkills(kind: .codex, projectRoot: lab.project, on: id)
        let skill = try #require(skills.first { $0.command == "$heeler-lab-daily" && $0.scope == .global })
        let body = try await console.readSkillFile(path: skill.path, on: id)
        #expect(body.contains("Global Codex fixture body."))
        let changes = try await console.readChanges(.init(directory: lab.project), on: id).changes
        #expect(!changes.checkout.isLinkedWorktree)
        for path in ["sample.txt", "new 文件.txt"] {
            let file = try #require(changes.files.first { $0.path == Data(path.utf8) })
            let request = try #require(FilePatchRequest(file: file, checkout: changes.checkout))
            let patch = try await console.readFilePatch(request, on: id)
            #expect(patch.files.contains { !$0.hunks.isEmpty })
        }
    }

    @Test func opensHostFilesStagesAFileAndReachesTheLoopbackPreview() async throws {
        let lab = try Lab.configured()
        let link = try Connection(lab)
        let console = link.console, id = link.host.id
        defer { console.setHosts([]) }
        await console.resume()
        let pane = RexPaneAddress(sessionID: lab.rexSession, blockID: lab.rexBlock).paneID
        try await wait("the fixture pane is listed") { console.terminals.contains { $0.paneID == pane } }
        let files = console.chatHostFiles(for: id)
        let entries = try #require(try await files.list(.init(directory: lab.project)))
        #expect(entries.entries.contains { $0.name == "new 文件.txt" })
        let remote = try await files.read(.init(path: lab.project + "/sample.txt", offset: 0, maxBytes: 2048))
        #expect(!remote.data.isEmpty)
        let name = "heeler-lab-文件 notes-" + UUID().uuidString + ".txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let body = Data(("中文\n\n    " + name).utf8)
        try body.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let picked = PreparedFile(fileURL: url, fileExtension: "txt", byteCount: Int64(body.count), pickedName: name)
        let stage = console.fileStager(for: id, beside: pane, keepingTo: console.corePin(on: id))
        let staged = try await stage(picked, AttachmentStageProgressReporter { _ in })
        let uploaded = try await files.read(.init(path: staged.path, offset: 0, maxBytes: 4096))
        #expect(uploaded.data == body && staged.fileURL.lastPathComponent == picked.remoteFilename)
        let preview = try #require(console.portPreviewLink(for: id))
        let ports = try await preview.listeningPorts()
        #expect(ports.contains { $0.port == Int(lab.previewPort) })
        let stream = try await preview.openStream(port: lab.previewPort)
        try await stream.write(Data("GET /heeler-lab-preview HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8))
        var response = Data()
        while let chunk = try await stream.read(), response.count < 65536 { response.append(chunk) }
        await stream.close()
        await preview.close()
        #expect(String(decoding: response, as: UTF8.self).hasSuffix("heeler-lab-preview-ok"))
    }

    @Test func replacingABlockInTheSameSessionCannotReceiveTheDepartedAgentsDraft() async throws {
        let lab = try Lab.configured()
        let link = try Connection(lab)
        let console = link.console, host = link.host.id
        defer { console.setHosts([]) }
        await console.resume()
        try await wait("the Host can launch its fixture Agent") { console.capabilities(for: host).startsAgents }
        let label = "heeler-lab-rebuild-" + UUID().uuidString.lowercased()
        let workspace = try await console.createShellWorkspace(.init(directory: lab.project, label: label), tabLabel: nil, on: host)
        let peer = try #require(RexPaneAddress(paneID: workspace.paneID))
        do {
            try await wait("the Workspace and its first shell are in the current inventory") {
                console.workspaces(for: host).contains { $0.id == peer.sessionID }
                    && console.terminals.contains { $0.paneID == peer.paneID }
            }
            let environment = lab.labBin.map { ["PATH": $0 + ":/usr/bin:/bin:/usr/sbin:/sbin"] } ?? [:]
            let request = AgentLaunchRequest(kind: "claude", name: label, workspaceID: peer.sessionID,
                                             cwd: lab.project, environment: environment)
            let original = try await console.startAgent(request, on: host)
            let old = try #require(RexPaneAddress(paneID: original.paneID))
            try #require(old.sessionID == peer.sessionID && old.blockID != peer.blockID)
            try await wait("the original foreground and its neighboring shell are live") {
                let peerProcess = try await link.foreground(peer)
                return peerProcess.processID != nil && console.agents.contains { $0.agent.paneID == old.paneID }
            }
            let agent = try #require(console.agents.first { $0.agent.paneID == old.paneID })
            let composer = console.composerStore(for: agent)
            let marker = "HEELER_LAB_DEPARTED_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            composer.replaceDraft(with: marker)
            let before = try await link.view(peer.sessionID)
            let neighborPID = try #require(try await link.foreground(peer).processID)
            let ownerPID = try #require(try await link.foreground(old).processID)
            try #require(try await link.receipt(lab, pid: ownerPID).cwd == lab.project)
            try #require(before["label"]?.stringValue == label)
            // An independent desktop closes this one proven lab foreground. The app's Composer stays open.
            try await link.session.withConnection { connection in
                _ = try await connection.control.call("block.close", payload: [
                    "session_id": old.sessionID, "block_id": old.blockID,
                ])
            }
            await console.refreshTerminalInventory(on: host)
            try await wait("the original Agent left the session") {
                !console.terminals.contains { $0.paneID == old.paneID }
                    && console.terminals.contains { $0.paneID == peer.paneID }
            }
            let created = try await console.createShellTerminal(.init(workspaceID: peer.sessionID, cwd: lab.project,
                                                                       label: label), on: host)
            let replacement = try #require(RexPaneAddress(paneID: created.paneID))
            try #require(replacement.sessionID == old.sessionID && replacement.blockID != old.blockID)
            await console.refreshTerminalInventory(on: host)
            try await wait("fresh inventory dropped the old block and found the new shell") {
                !console.terminals.contains { $0.paneID == old.paneID }
                    && console.terminals.contains { $0.paneID == replacement.paneID }
            }
            switch await composer.send() {
            case .refused, .ignored: break
            case .failed:
                let failed = try #require(composer.messages.last)
                composer.withdrawToDraft(failed.id)
            default: Issue.record("The old Composer must refuse delivery to a replaced block")
            }
            #expect(composer.draft == marker)
            do {
                try await console.sendAgentKeys(["enter"], to: old.paneID, on: host)
                Issue.record("The replaced Agent accepted its old key")
            } catch {}
            for address in [peer, replacement] {
                let requests = try await link.session.blockRequests(at: address, readDeadline: .sharedLinkRead)
                let screen = try await RexChatScreen.read(on: requests).screen
                let visibleText = screen.rows.map(\.text).joined().filter { !$0.isWhitespace }
                #expect(!visibleText.contains(marker))
            }
            #expect(try await link.foreground(peer).processID == neighborPID)
            let after = try await link.view(peer.sessionID)
            #expect(after["active_window_id"] == before["active_window_id"])
            let windows = try #require(RexInventoryWire.view(after)?.windows)
            #expect(windows.first { $0.id == workspace.tabID }?.focusedBlockID == peer.blockID)
        } catch {
            try? await link.removeLabSession(peer.sessionID, named: label)
            throw error
        }
        try await link.removeLabSession(peer.sessionID, named: label)
    }

    @Test func anAgentWithNoDirectoryInheritsTheDesktopFocusedSplit() async throws {
        let lab = try Lab.configured()
        let link = try Connection(lab)
        let console = link.console, id = link.host.id
        defer { console.setHosts([]) }
        await console.resume()
        try await wait("the desktop is available") { console.capabilities(for: id).startsAgents }
        let label = "heeler-lab-focus-" + UUID().uuidString.lowercased()
        let made = try await console.createShellWorkspace(.init(directory: lab.project, label: label),
                                                          tabLabel: nil, on: id)
        let first = try #require(RexPaneAddress(paneID: made.paneID))
        let home = try await console.remoteHomeDirectory(on: id)
        let focused = try await link.session.withConnection { connection in
            try await connection.control.call("session.new_split", payload: JSONValue.object([
                "session_id": .string(first.sessionID), "anchor_id": .string(first.blockID),
                "direction": .string("horizontal"), "side": .string("after"), "focus": .bool(true),
                "layout": .object(["block": .object(["flavor": .string("com.superlogical.terminal.shell"),
                                                       "options": .object(["cwd": .string(home)])])]),
            ])).result(JSONValue.self)
        }
        guard case .array(let blocks)? = focused["block_ids"], let blockID = blocks.first?.stringValue else {
            try await link.removeLabSession(first.sessionID, named: label)
            Issue.record("Rex did not return the new split")
            return
        }
        await console.refreshTerminalInventory(on: id)
        try await wait("the launch follows the focused split directory") {
            console.launchDirectory(ofWorkspace: first.sessionID, asked: "", on: id) == home
        }
        let environment = lab.labBin.map { ["PATH": $0 + ":/usr/bin:/bin:/usr/sbin:/sbin"] } ?? [:]
        let request = AgentLaunchRequest(kind: "claude", name: label, workspaceID: first.sessionID, environment: environment)
        let agent = try await console.startAgent(request, on: id)
        let address = try #require(RexPaneAddress(paneID: agent.paneID))
        try await wait("the new Agent recorded the focused block directory") {
            let fg = try await link.foreground(address)
            guard fg.program == "claude", let pid = fg.processID else { return false }
            return try await link.receipt(lab, pid: pid).cwd == home
        }
        let raw = try await link.view(first.sessionID)
        #expect(raw["active_window_id"]?.stringValue == made.tabID)
        guard case .array(let windows)? = raw["windows"] else { throw TransportError.rexServerGone }
        #expect(windows.first { $0["window_id"]?.stringValue == made.tabID }?["focused_block_id"]?.stringValue == blockID)
        #expect(try await link.foreground(first).directory == lab.project)
        try await link.removeLabSession(first.sessionID, named: label)
    }

    /// The user can remove a clean checkout from another Terminal after its Agent exits.
    /// Git refuses dirty checkouts and the branch stays in the original repository.
    private func removeCheckoutInTerminal(
        _ checkout: String, branch: String, in shell: RexPaneAddress, project: String, link: Connection
    ) async throws {
        let before = try await link.foreground(shell)
        try #require(before.processID != nil && before.directory == project)
        let attach = AttachTerminalStore(target: .terminal(shell.paneID),
            runTerminal: link.console.terminalRunner(for: link.host.id, keepingTo: link.console.corePin(on: link.host.id)))
        let files = link.console.chatHostFiles(for: link.host.id)
        let tag = "REMOVED_" + UUID().uuidString.prefix(8)
        let git = "git -C " + HostHelperScript.quote(project)
        let command = git + " worktree remove " + HostHelperScript.quote(checkout)
            + " && " + git + " show-ref --verify --quiet " + HostHelperScript.quote("refs/heads/" + branch)
            + " && echo " + tag
        let original = try await link.console.readChanges(.init(directory: project), on: link.host.id).changes
        do {
            attach.viewDidResize(cols: 100, rows: 32)
            try await wait("the selected shell is open in Terminal") { attach.status == .live }
            try #require(try await link.foreground(shell).processID == before.processID)
            let block = try await link.session.blockRequests(at: shell, readDeadline: .sharedLinkRead)
            attach.send(Data((command + "\r").utf8))
            try await wait("Git removed the checkout and verified its original branch") {
                let rows = try await RexChatScreen.read(on: block).screen.rows
                return rows.contains { $0.trimmedText == tag }
            }
            try #require(try await files.status(checkout) == nil)
            let remaining = try await link.console.readChanges(.init(directory: project), on: link.host.id).changes
            #expect(remaining.head == original.head && remaining.files == original.files)
        } catch {
            await attach.stop()
            throw error
        }
        await attach.stop()
        #expect(try await link.foreground(shell).processID == before.processID)
    }

    @Test func launchesInTheChosenWorkspaceAndWorktreeWithoutTakingTheDesktop() async throws {
        let lab = try Lab.configured()
        let link = try Connection(lab)
        let console = link.console, id = link.host.id
        defer { console.setHosts([]) }
        await console.resume()
        try await wait("Rex has listed the original terminal and enabled New Agent") {
            console.capabilities(for: id).startsAgents && console.workspaces(for: id).contains { $0.id == lab.rexSession }
        }
        let reportedRevision = try await link.session.withConnection { $0.control.apiRevision }
        #expect(console.capabilities(for: id).rexAPIRevision == reportedRevision)
        print("Rex project fixture negotiated API revision " + String(reportedRevision))
        let installed = try await console.availableAgentKinds(on: id)
        try #require(installed.contains(.claude))
        let original = try await link.view(lab.rexSession)
        let absent = lab.project + "/heeler-lab-missing-" + UUID().uuidString
        let invalid = AgentLaunchRequest(kind: "claude", name: "heeler-lab-missing",
                                         workspaceID: lab.rexSession, cwd: absent)
        await #expect(throws: TransportError.self) { try await console.startAgent(invalid, on: id) }
        #expect(try await link.view(lab.rexSession)["windows"] == original["windows"])
        let observer = RexPaneAddress(sessionID: lab.rexSession, blockID: lab.rexBlock)
        let originalProcess = try await link.foreground(observer)
        let marker = "heeler-lab-" + UUID().uuidString.lowercased()
        let identity = try await console.createShellWorkspace(.init(directory: lab.project, label: marker),
                                                              tabLabel: "heeler-lab-first", on: id)
        let anchor = try #require(RexPaneAddress(paneID: identity.paneID))
        try await wait("the created workspace is listed") { console.workspaces(for: id).contains { $0.id == anchor.sessionID } }
        let pin = console.corePin(on: id)
        let name = marker + "-renamed"
        try await console.renameWorkspace(anchor.sessionID, label: name, on: id, keepingTo: pin)
        let renamed = try await link.view(anchor.sessionID)
        #expect(renamed["label"]?.stringValue == name)
        let activeWindow = try #require(renamed["active_window_id"]?.stringValue)
        #expect(RexInventoryWire.view(renamed)?.windows.first?.label == "heeler-lab-first")
        let second = try await console.createShellTerminal(.init(workspaceID: anchor.sessionID, cwd: lab.project,
                                                                  label: "heeler-lab-second"), on: id)
        let extra = try #require(RexInventoryWire.view(try await link.view(anchor.sessionID))?.windows.first { $0.id == second.tabID })
        #expect(extra.label == "heeler-lab-second")
        let home = try await console.remoteHomeDirectory(on: id)
        var preset = LaunchPreset(name: marker, kind: .claude, accountDirectory: "~/heeler-lab-preset",
                                  arguments: "--session-id " + UUID().uuidString.lowercased(),
                                  environment: [.init(name: "HEELER_LAB_MARKER", value: marker)])
        if let bin = lab.labBin {
            preset.environment.append(.init(name: "PATH", value: bin + ":/usr/bin:/bin:/usr/sbin:/sbin"))
        }
        let folderVariable = try await console.accountVariable(for: .claude, on: id)
        let launch = try preset.launch(formArguments: ["two words", "中文", "", "quote'\"$"],
                                       home: home, accountVariable: folderVariable)
        let request = AgentLaunchRequest(kind: "claude", name: marker, arguments: launch.arguments,
            workspaceID: anchor.sessionID, cwd: lab.project, environment: launch.environment)
        let started = try await console.startAgent(request, on: id)
        let branch = marker + "-worktree"
        let linked = try await console.startAgentInNewWorktree(request, worktree: .init(branch: branch), on: id)
        #expect(started.workspaceID == anchor.sessionID)
        #expect(started.paneID != linked.paneID && linked.workspaceID != started.workspaceID)
        var checkoutPath: String?
        for agent in [started, linked] {
            let address = try #require(RexPaneAddress(paneID: agent.paneID))
            try await wait("the real recorder holds the selected block") {
                try await link.foreground(address).program == "claude" && console.agents.contains { $0.agent.paneID == agent.paneID }
            }
            let process = try await link.foreground(address)
            let pid = try #require(process.processID)
            let receipt = try await link.receipt(lab, pid: pid)
            #expect(receipt.pid == pid && receipt.env["HEELER_LAB_MARKER"] == marker)
            #expect(receipt.env["CLAUDE_CONFIG_DIR"] == home + "/heeler-lab-preset")
            #expect(Array(receipt.argv.dropFirst()) == launch.arguments)
            #expect(receipt.cwd == process.directory)
            let changes = try await console.readChanges(.init(directory: receipt.cwd), on: id).changes
            if agent.paneID == linked.paneID {
                #expect(changes.checkout.isLinkedWorktree && changes.head.branch == .named(branch))
                try #require(changes.isClean && changes.checkout.isLinkedWorktree)
                checkoutPath = receipt.cwd
            } else {
                #expect(!changes.checkout.isLinkedWorktree && !changes.isClean)
            }
        }
        let current = try #require(console.agents.first { $0.agent.paneID == started.paneID })
        let title = current.agent.title
        #expect(!console.offersTitleRename(for: current))
        let rename = console.agentNameStore(for: current, keepingTo: pin)
        rename.input = "heeler-lab-renamed"
        await rename.submit()
        #expect(rename.state == .renamed)
        try await wait("the renamed block kept its foreground title") {
            console.agents.contains { $0.agent.name == rename.input && $0.agent.paneID == started.paneID && $0.agent.title == title }
        }
        let edited = try #require(RexInventoryWire.view(try await link.view(anchor.sessionID)))
        #expect(edited.windows.first { $0.id == started.tabID }?.blocks.first?.label == rename.input)
        rename.input = ""
        await rename.submit()
        #expect(rename.state == .renamed)
        try await wait("the default block label is no longer a custom Agent name") {
            console.agents.contains { $0.agent.paneID == started.paneID && $0.agent.name == nil }
        }
        let after = try await link.view(anchor.sessionID)
        #expect(after["active_window_id"]?.stringValue == activeWindow)
        let checkout = try #require(checkoutPath)
        try #require((checkout as NSString).lastPathComponent == branch)
        try await link.removeLabSession(linked.workspaceID, named: branch)
        try await removeCheckoutInTerminal(checkout, branch: branch, in: anchor, project: lab.project, link: link)
        let neighbor = try #require(RexPaneAddress(paneID: started.paneID))
        #expect(try await link.foreground(neighbor).program == "claude")
        #expect(try await link.view(anchor.sessionID)["active_window_id"]?.stringValue == activeWindow)
        try await link.removeLabSession(anchor.sessionID, named: name)
        let desktop = try await link.view(lab.rexSession)
        #expect(desktop["active_window_id"] == original["active_window_id"])
        #expect(try await link.foreground(observer).processID == originalProcess.processID)
    }
}
