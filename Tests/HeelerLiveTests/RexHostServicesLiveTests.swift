import CryptoKit
import Foundation
import Testing

@testable import Heeler

/// Reads only the named private SSH fixtures. The GitHub endpoint accepts two
/// fixture queries. Hand Off uses two real Pi processes and never presses Send.
@MainActor
@Suite("Rex Host services over SSH", .serialized, .timeLimit(.minutes(3)))
struct RexHostServicesLiveTests {
    private struct Fixture: Decodable {
        let port: Int
        let user: String
        let seed: String
        let fingerprint: String
        let rexSocket: String
        let herdrSocket: String?
        let rexSession: String?
        let rexBlock: String?
        let peerSession: String?
        let peerBlock: String?
        let firstFile: String?
        let peerFile: String?
        let sourcePane: String?
        let targetPane: String?
        let sourceMarker: String?
        let peerMarker: String?
        let managementProject: String?
        let managementBin: String?
        let managementReceipts: String?
        let managementCommit: String?
        let managementEvidence: String?
        let home: String?
        let recorder: String?

        static func load(_ name: String) throws -> Fixture {
            let path = try #require(ProcessInfo.processInfo.environment[name])
            try #require(path.split(separator: "/").contains(where: { $0.hasPrefix("heeler-lab-") }))
            return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }

        @MainActor
        func connect(_ kind: ServerKind, defaults: UserDefaults) throws -> (Host, ConsoleStore) {
            guard let rawKey = Data(base64Encoded: seed) else { throw TransportError.authenticationFailed }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
            var settings = SSHTransportSettings(
                host: "127.0.0.1", port: port, username: user, credentials: .ed25519(key),
                hostKeyPolicy: .init(knownHosts: InMemoryKnownHostsStore()) { $0.fingerprint.displayString == self.fingerprint },
                socket: .absolutePath(herdrSocket ?? "/unused-heeler-lab.sock"))
            settings.serverKind = kind
            let ssh = settings
            let socket = try #require(RexSocket(path: rexSocket))
            let host = Host(name: "heeler-lab-services", address: "127.0.0.1", port: port, username: user, serverKind: kind)
            let console = ConsoleStore(gitHubSettings: GitHubSettings(defaults: defaults), makeSession: { _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: { try await HeelerSSHTransport.connect(settings: ssh) }, keepalive: nil)
            }, makeRexSession: { _ in
                RexHostSession(storedSocket: socket) { stored, previous in
                    try await RexSSHTransport.connect(over: HeelerSSHTransport.connect(settings: ssh), socket: stored, resuming: previous)
                }
            })
            console.setHosts([host])
            return (host, console)
        }
    }

    @Test(arguments: [ServerKind.herdrTUI, .rex])
    func theGitHubTabReadsFixtureListsAndAnIssueThroughGH(_ kind: ServerKind) async throws {
        let fixture = try Fixture.load("HEELER_REX_GITHUB_LAB")
        let name = "heeler-lab-github-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let (host, console) = try fixture.connect(kind, defaults: defaults)
        defer { console.setHosts([]) }
        await console.resume()
        try await wait("the named Server to connect") { console.hostStatuses[host.id] == .connected }
        let tab = console.gitHub
        let machine = try #require(tab.selectedHost)
        try #require(machine.records == [host.id])
        await tab.appear(showing: .issue)
        let issues = try #require(tab.shown(.issue, on: machine), "\(String(describing: tab.state(of: machine).failure))")
        #expect(issues.login == "heeler-lab-reader")
        let issue = try #require(issues.list.items.first { $0.id == "LAB_ISSUE" })
        #expect(issue.title == "Fixture issue" && issue.repository == "lab/parity")
        #expect(tab.shown(.pullRequest, on: machine)?.list.items.contains { $0.id == "LAB_PR" && $0.title == "Fixture review" } == true)
        await tab.openDetail(issue, on: machine)
        let details = tab.detailState(of: issue, on: machine)
        let detail = try #require(details.detail, "\(String(describing: details.failure))")
        #expect(detail.item == issue && detail.body == "Local read-only fixture body." && detail.viewer == issues.login)
        #expect(detail.defaultBranch == "main")
        console.setGitHubEnabled(false)
        await tab.appear(showing: .issue)
        #expect(tab.shown(.issue, on: machine) == nil && tab.detailState(of: issue, on: machine).detail == nil)
        print("GitHub \(kind.rawValue): account, list and detail matched; disabling the tab cleared them")
    }

    @Test func handOffStagesOnlyTheSourceRecordAndLeavesBothPiTranscriptsUntouched() async throws {
        let fixture = try Fixture.load("HEELER_REX_HANDOFF_LAB")
        let first = RexPaneAddress(sessionID: try #require(fixture.rexSession), blockID: try #require(fixture.rexBlock))
        let peer = RexPaneAddress(sessionID: try #require(fixture.peerSession), blockID: try #require(fixture.peerBlock))
        try await checkHandOff(.rex, on: fixture, from: first.paneID, to: peer.paneID,
                               sourceMarker: "REX_LAB_SEED_PIHANDOFFA", peerMarker: "REX_LAB_SEED_PIHANDOFFB")
    }

    @Test func herdrHandOffStagesOnlyTheSourceRecordAndLeavesBothPiTranscriptsUntouched() async throws {
        let fixture = try Fixture.load("HEELER_HERDR_HANDOFF_LAB")
        try await checkHandOff(.herdrTUI, on: fixture, from: #require(fixture.sourcePane), to: #require(fixture.targetPane),
                               sourceMarker: #require(fixture.sourceMarker), peerMarker: #require(fixture.peerMarker))
    }

    private func checkHandOff(_ kind: ServerKind, on fixture: Fixture, from sourcePane: String, to peerPane: String,
                              sourceMarker: String, peerMarker: String) async throws {
        let firstFile = try #require(fixture.firstFile), peerFile = try #require(fixture.peerFile)
        try #require(firstFile != peerFile && [firstFile, peerFile].allSatisfy {
            $0.contains("heeler-lab-") && $0.hasPrefix("/") && !$0.split(separator: "/").contains("..")
        })
        try #require(sourcePane != peerPane && sourceMarker != peerMarker && !sourceMarker.isEmpty && !peerMarker.isEmpty)
        let name = "heeler-lab-handoff-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let (host, console) = try fixture.connect(kind, defaults: defaults)
        defer { console.setHosts([]) }
        await console.resume()
        try await wait("both private Pi Agents") {
            [sourcePane, peerPane].allSatisfy { pane in console.agents.contains { $0.agent.paneID == pane && $0.agent.kind == "pi" } }
        }
        let source = try #require(console.agents.first { $0.agent.paneID == sourcePane })
        let target = try #require(console.handOffTargets(for: source).first { $0.agent.paneID == peerPane })
        // The first Herdr snapshot can list Pi before this connection's platform probe answers.
        try await wait("the Agent's Hand Off action") { console.offersHandOff(for: source) }
        let files = console.chatHostFiles(for: host.id)
        func bytes(_ path: String) async throws -> Data {
            let slice = try await files.read(.init(path: path, offset: 0, maxBytes: 131072))
            try #require(slice.length == UInt64(slice.data.count) && !slice.data.isEmpty)
            return slice.data
        }
        let original = try await bytes(firstFile), other = try await bytes(peerFile)
        try #require(String(decoding: original, as: UTF8.self).contains(sourceMarker))
        try #require(String(decoding: other, as: UTF8.self).contains(peerMarker))
        let sourceComposer = console.composerSession(for: source).composer
        let recipient = console.composerSession(for: target)
        sourceComposer.replaceDraft(with: "Local source draft")
        recipient.composer.replaceDraft(with: "Keep this recipient draft")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sheet = HandOffStore(source: source, read: { try await console.handOffSource(for: source) },
                                 deliver: { try await console.deliverHandOff($0, message: $1, to: $2) }, directory: directory)
        sheet.mode = .secondOpinion
        await sheet.handOff(to: target.id)
        try #require(sheet.state == .handedOff(target.id), "\(sheet.state)")
        try await wait("the staged record") {
            if case .completed = recipient.staging.state { return true }
            return false
        }
        guard case .completed(let upload) = recipient.staging.state else { throw TransportError.cancelled }
        let markdown = try await bytes(upload.path)
        let text = String(decoding: markdown, as: UTF8.self)
        #expect(text.contains(sourceMarker) && !text.contains(peerMarker))
        #expect(sourceComposer.draft == "Local source draft")
        #expect(recipient.composer.draft.hasPrefix("Keep this recipient draft\n\n" + HandOffMode.secondOpinion.message))
        #expect(recipient.composer.draft.contains(upload.path))
        let sourceAfter = try await bytes(firstFile), targetAfter = try await bytes(peerFile)
        #expect(SHA256.hash(data: sourceAfter) == SHA256.hash(data: original))
        #expect(SHA256.hash(data: targetAfter) == SHA256.hash(data: other))
        print("Hand Off \(kind.rawValue): recipient draft and staged source record matched; both Pi transcript digests stayed identical")
    }


    @Test(arguments: ["macos", "linux"])
    func herdrManagementUsesTheRequestedWorkspaceTabAndCheckout(_ platform: String) async throws {
        let variable = platform == "macos" ? "HEELER_HERDR_MAC_MANAGEMENT_LAB" : "HEELER_HERDR_LINUX_MANAGEMENT_LAB"
        let fixture = try Fixture.load(variable)
        let project = try #require(fixture.managementProject), bin = try #require(fixture.managementBin)
        let receipts = try #require(fixture.managementReceipts), nativeReceipt = try #require(fixture.recorder)
        let baseline = try #require(fixture.managementCommit), home = try #require(fixture.home)
        let localEvidence = URL(fileURLWithPath: try #require(fixture.managementEvidence))
        try #require(project.hasSuffix("/heeler-lab-tui-management") && bin.hasSuffix("/heeler-lab-herdr-management-tools/bin"))
        let marker = "heeler-lab-herdr-management-" + UUID().uuidString.lowercased()
        let branch = marker + "-linked"
        let evidence = localEvidence.deletingPathExtension().appendingPathExtension(marker + ".json")
        var record = ["workspaceLabel": marker, "branch": branch, "project": project]
        func checkpoint() throws {
            try JSONEncoder().encode(record).write(to: evidence, options: .atomic)
        }
        try checkpoint()
        let defaults = try #require(UserDefaults(suiteName: marker))
        defer { defaults.removePersistentDomain(forName: marker) }
        let (host, console) = try fixture.connect(.herdrTUI, defaults: defaults)
        defer { console.setHosts([]) }
        await console.resume()
        try await wait("the private Herdr Server") { console.hostStatuses[host.id] == .connected }
        let files = console.chatHostFiles(for: host.id)
        func read(_ path: String) async throws -> Data {
            let data = try await files.read(.init(path: path, offset: 0, maxBytes: 32768))
            try #require(data.length == UInt64(data.data.count) && !data.data.isEmpty)
            return data.data
        }
        func text(_ path: String) async throws -> String {
            String(decoding: try await read(path), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func physical(_ path: String) -> String {
            path.hasPrefix("/private/tmp/") ? String(path.dropFirst("/private".count)) : path
        }
        let originalHead = try await text(project + "/.git/refs/heads/main")
        try #require(originalHead == baseline)
        let first = try await console.createShellWorkspace(.init(directory: project, label: marker),
                                                           tabLabel: "Heeler lab first", on: host.id)
        try await wait("the named first tab") {
            console.terminals.contains { $0.paneID == first.paneID && $0.tabLabel == "Heeler lab first" && $0.workspaceLabel == marker }
        }
        let initial = try #require(console.terminals.first { $0.paneID == first.paneID })
        let workspace = initial.workspaceID
        record["workspaceID"] = workspace
        try checkpoint()
        let second = try await console.createShellTerminal(.init(workspaceID: workspace, cwd: project, label: "Heeler lab second"), on: host.id)
        try await wait("the named second tab in the same Workspace") {
            console.terminals.contains { $0.paneID == second.paneID && $0.tabLabel == "Heeler lab second" && $0.workspaceID == workspace }
        }
        #expect(first.tabID != second.tabID)
        func agentName(_ side: String) -> String { "lab-" + side + "-" + String(marker.suffix(8)) }
        func launch(_ side: String) -> AgentLaunchRequest {
            AgentLaunchRequest(kind: "claude", name: agentName(side), arguments: ["--heeler-lab", side],
                workspaceID: workspace, cwd: project, tabLabel: "Heeler lab " + side,
                environment: ["PATH": bin + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                              "HOME": home, "CLAUDE_CONFIG_DIR": home + "/heeler-lab-herdr-management-tools",
                              "HEELER_LAB_HERDR_RECEIPT": receipts + "/" + marker + "-" + side + ".pid",
                              "HEELER_LAB_MARKER": marker])
        }
        let current = try await console.startAgent(launch("project"), on: host.id)
        try #require(current.workspaceID == workspace)
        let linked = try await console.startAgentInNewWorktree(launch("linked"),
            worktree: .init(branch: branch, base: "main"), on: host.id)
        try #require(linked.workspaceID != workspace)
        record["linkedWorkspaceID"] = linked.workspaceID
        try checkpoint()
        let checkouts = try await console.listWorktrees(forWorkspaceID: workspace, on: host.id)
        let worktree = try #require(checkouts.worktrees.first { $0.branch == branch && $0.openWorkspaceID == linked.workspaceID })
        try #require(worktree.isLinkedWorktree && worktree.path != project)
        record["checkout"] = worktree.path
        try checkpoint()
        let gitFile = try await text(worktree.path + "/.git")
        try #require(gitFile.hasPrefix("gitdir: "))
        let gitDirectory = String(gitFile.dropFirst("gitdir: ".count))
        try #require(physical(gitDirectory).hasPrefix(physical(project) + "/.git/worktrees/"))
        let linkedHead = try await text(gitDirectory + "/HEAD")
        let branchHead = try await text(project + "/.git/refs/heads/" + branch)
        #expect(linkedHead == "ref: refs/heads/" + branch && branchHead == baseline)
        struct LaunchReceipt: Decodable {
            let pid: Int
            let argv: [String]
            let cwd: String
            let env: [String: String]
        }
        for (side, expectedWorkspace, cwd) in [("project", workspace, project), ("linked", linked.workspaceID, worktree.path)] {
            let pane = side == "project" ? current.paneID : linked.paneID
            try await wait("the named Agent in its checkout") {
                console.agents.contains { $0.agent.paneID == pane && $0.agent.workspaceID == expectedWorkspace &&
                    $0.agent.kind == "claude" && $0.agent.name == agentName(side) && $0.tabLabel == "Heeler lab " + side }
            }
            let recordedPID = try await text(receipts + "/" + marker + "-" + side + ".pid")
            let pid = try #require(Int(recordedPID))
            let path = (nativeReceipt as NSString).deletingLastPathComponent + "/\(pid).json"
            let received = try JSONDecoder().decode(LaunchReceipt.self, from: await read(path))
            #expect(received.pid == pid && received.env["HEELER_LAB_MARKER"] == marker)
            #expect(Array(received.argv.suffix(2)) == ["--heeler-lab", side])
            #expect(physical(received.cwd) == physical(cwd))
            record[side + "PID"] = String(pid)
        }
        try checkpoint()
        let linkedRow = try #require(console.agents.first { $0.agent.paneID == linked.paneID })
        let checkout = try #require(linkedRow.repositoryCheckout)
        try #require(checkout.isLinkedWorktree && physical(checkout.checkoutPath) == physical(worktree.path))
        _ = try await console.removeWorktree(.init(identity: .init(hostID: host.id, workspaceID: linked.workspaceID, checkout: checkout)),
                                              on: host.id)
        try await wait("the private linked Workspace to close") { !console.workspaces(for: host.id).contains { $0.id == linked.workspaceID } }
        for pane in [current.paneID, second.paneID, first.paneID] {
            let terminal = try #require(console.terminals.first { $0.paneID == pane && $0.workspaceID == workspace && $0.workspaceLabel == marker })
            try await console.closeTerminal(terminal)
        }
        try await wait("the private main Workspace to close") { !console.workspaces(for: host.id).contains { $0.id == workspace } }
        record["closed"] = "true"
        try checkpoint()
        print("Herdr \(platform): named Workspace and tabs, project and linked checkout Agent receipts, and cleanup matched.")
    }

    private func wait(_ description: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(18)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(80)) }
        try #require(condition(), "Timed out waiting for \(description)")
    }
}
