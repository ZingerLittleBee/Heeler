import CryptoKit
import Foundation
import Testing

@testable import Heeler

/// Uses named private SSH fixtures. GitHub writes require their own loopback
/// enterprise endpoint. Hand Off uses two real Pi processes and never presses Send.
@MainActor
@Suite("Rex Host services over SSH", .serialized, .timeLimit(.minutes(3)))
struct RexHostServicesLiveTests {
    fileprivate struct Fixture: Decodable {
        let port: Int
        let user: String
        let seed: String
        let fingerprint: String
        let rexSocket: String?
        let program: ChatProgram?
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
        let openCodeSession: String?
        let openCodePeer: String?
        let managementProject: String?
        let managementBin: String?
        let managementReceipts: String?
        let managementCommit: String?
        let managementEvidence: String?
        let home: String?
        let recorder: String?
        let macGitHubWriteRoot: String?

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
            let socket = rexSocket.flatMap { RexSocket(path: $0) }
            if kind == .rex { try #require(socket != nil) }
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
                               sourceMarker: fixture.sourceMarker ?? "REX_LAB_SEED_PIHANDOFFA",
                               peerMarker: fixture.peerMarker ?? "REX_LAB_SEED_PIHANDOFFB")
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
            try #require(data.length == UInt64(data.data.count) && !data.data.isEmpty, "Incomplete fixture file at \(path)")
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

extension RexHostServicesLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_REX_GITHUB_WRITE_LAB"] != nil))
    func aCommentOnThePrivateEnterpriseIssueIsPostedOnceAndReadBack() async throws {
        let fixture = try Fixture.load("HEELER_REX_GITHUB_WRITE_LAB")
        let name = "heeler-lab-github-write-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let (host, console) = try fixture.connect(.rex, defaults: defaults)
        defer { console.setHosts([]) }
        await console.resume()
        try await wait("the private GitHub write Host") { console.hostStatuses[host.id] == .connected }

        let (preflight, receipts) = try privateGitHubWriteEndpoint(macRoot: fixture.macGitHubWriteRoot)
        let isolation = try await console.runGitHubSeamScript(Data(preflight.utf8), on: host.id)
        try #require(isolation.exitStatus == 0, "The private loopback enterprise endpoint is required")

        let tab = console.gitHub
        let machine = try #require(tab.selectedHost)
        try #require(machine.records == [host.id])
        await tab.appear(showing: .issue)
        let listing = try #require(tab.shown(.issue, on: machine))
        try #require(listing.login == "heeler-lab-write-fixture")
        let issue = try #require(listing.list.items.first { $0.id == "LAB_WRITE_9666" })
        let address = "https://heeler-lab-github-write.test/lab/write-fixture/issues/9666"
        try #require(issue.url == address && issue.repository == "lab/write-fixture" && issue.number == 9666)
        await tab.openDetail(issue, on: machine)
        let before = try #require(tab.detailState(of: issue, on: machine).detail)
        try #require(before.item.url == address && before.viewer == listing.login)

        let body = "Heeler private fixture " + UUID().uuidString + "\nSecond line."
        let presenter = UUID()
        tab.present(presenter)
        defer { tab.leave(presenter) }
        let delivery = await tab.write(.comment(body), on: issue, host: machine, shownBy: presenter)
        guard case .result(let result) = delivery else {
            Issue.record("The open comment form did not receive its result")
            return
        }
        try #require(result.isPlainSuccess && result.readFailure == nil)
        let after = try #require(result.detail)
        #expect(after.item.id == issue.id && after.item.url == address)
        #expect(after.item.commentCount == before.item.commentCount + 1)
        #expect(tab.detailState(of: issue, on: machine).detail?.item.commentCount == after.item.commentCount)

        struct Receipt: Decodable { let node, body, client: String }
        let read = try await console.runGitHubSeamScript(
            Data("cat '\(receipts)'".utf8), on: host.id)
        try #require(read.exitStatus == 0)
        let entries = try read.stdout.split(separator: 10).map { try JSONDecoder().decode(Receipt.self, from: Data($0)) }
        let matches = entries.filter { $0.body == body && $0.node == issue.id && $0.client.hasPrefix("GitHub CLI") }
        #expect(matches.count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_PRIVATE_GITHUB_PULL_LAB"] != nil))
    func approvingThePrivatePullRequestRunsOnceAndReadsTheReview() async throws {
        try await exercisePrivatePull(approve: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_PRIVATE_GITHUB_PULL_LAB"] != nil))
    func mergingThePrivatePullRequestMatchesItsDisplayedHeadOnce() async throws {
        try await exercisePrivatePull(approve: false)
    }

    private struct PullAttempt: Decodable {
        let action, node, head, client: String
        let requestHead, body, method: String?
        let accepted: Bool
    }

    private struct PullHeadRead: Decodable {
        let node, head, state, client: String
        let mutations: Int
    }

    private func exercisePrivatePull(approve: Bool) async throws {
        let fixture = try Fixture.load("HEELER_PRIVATE_GITHUB_PULL_LAB")
        let suite = "heeler-lab-private-pull-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (host, console) = try fixture.connect(.rex, defaults: defaults)
        defer { console.setHosts([]) }
        await console.resume()
        try await wait("the private pull request Host") { console.hostStatuses[host.id] == .connected }
        let (preflight, comments) = try privateGitHubWriteEndpoint(macRoot: fixture.macGitHubWriteRoot)
        let folder = (comments as NSString).deletingLastPathComponent
        let check = preflight + "\n[ \"$(cat '\(folder)/pull-fixture-version')\" = heeler-private-pulls-v1 ]"
        let isolated = try await console.runGitHubSeamScript(Data(check.utf8), on: host.id)
        try #require(isolated.exitStatus == 0)
        func attempts() async throws -> [PullAttempt] {
            let command = "cat '\(folder)/pull-attempts.jsonl'"
            let read = try await console.runGitHubSeamScript(Data(command.utf8), on: host.id)
            try #require(read.exitStatus == 0)
            return try read.stdout.split(separator: 10).map { try JSONDecoder().decode(PullAttempt.self, from: Data($0)) }
        }

        let tab = console.gitHub
        let machine = try #require(tab.selectedHost)
        try #require(machine.records == [host.id])
        await tab.appear(showing: .pullRequest)
        let listing = try #require(tab.shown(.pullRequest, on: machine))
        let number = approve ? 9671 : 9672
        let node = "LAB_PULL_\(number)"
        let expectedHead = String(repeating: approve ? "a" : "b", count: 40)
        let item = try #require(listing.list.items.first { $0.id == node })
        try #require(listing.login == "heeler-lab-write-fixture" && item.repository == "lab/write-fixture")
        try #require(item.number == number && item.url == "https://heeler-lab-github-write.test/lab/write-fixture/pull/\(number)")
        await tab.openDetail(item, on: machine)
        let before = try #require(tab.detailState(of: item, on: machine).detail)
        let pull = try #require(before.pullRequest)
        let initialHead = try #require(pull.headCommit)
        try #require(before.item.state == .open && before.item.id == node && initialHead == expectedHead)
        try #require(GitHubWrite.actions(for: before).contains(approve ? .approve : .merge))
        let history = try await attempts()
        try #require(!history.contains { $0.node == node }, "Use a fresh private pull fixture for this action.")

        let presenter = UUID()
        tab.present(presenter)
        defer { tab.leave(presenter) }
        let message = "Heeler private approval " + UUID().uuidString
        let head: String
        if approve {
            head = initialHead
        } else {
            let advance = "umask 077 && mkdir '\(folder)/pull-head-9672-advanced'"
            let moved = try await console.runGitHubSeamScript(Data(advance.utf8), on: host.id)
            try #require(moved.exitStatus == 0)
            let stale = await tab.write(.merge(.squash, deleteBranch: false, headCommit: initialHead),
                                        on: item, host: machine, shownBy: presenter)
            guard case .result(let refusal) = stale, case .notRun = refusal.outcome else {
                Issue.record("A changed head must be rejected before gh can merge.")
                return
            }
            let unchanged = try await attempts()
            try #require(unchanged.count == history.count)
            let refreshed = try #require(tab.detailState(of: item, on: machine).detail)
            head = try #require(refreshed.pullRequest?.headCommit)
            try #require(refreshed.item.id == item.id && head == String(repeating: "d", count: 40))
        }
        let write: GitHubWrite = approve ? .approve(message) : .merge(.squash, deleteBranch: false, headCommit: head)
        async let first = tab.write(write, on: item, host: machine, shownBy: presenter)
        try await wait("the first private pull write") { tab.isWriting(item, on: machine) }
        let repeated = await tab.write(write, on: item, host: machine, shownBy: presenter)
        #expect(repeated == .ranNothing)
        let delivery = await first
        guard case .result(let result) = delivery else {
            Issue.record("The visible form did not receive the pull request result.")
            return
        }
        try #require(result.isPlainSuccess && result.readFailure == nil)
        let after = try #require(result.detail)
        let saved = try #require(tab.detailState(of: item, on: machine).detail)
        try #require(after.item.id == node && saved == after && after.pullRequest?.headCommit == head)
        if approve {
            #expect(after.item.state == .open && after.pullRequest?.review == .approved(by: [listing.login]))
        } else {
            #expect(after.item.state == .merged && !GitHubWrite.actions(for: after).contains(.merge))
        }
        let final = try await attempts()
        try #require(final.count == history.count + 1)
        let attempt = try #require(final.last)
        #expect(attempt.accepted && attempt.client.hasPrefix("GitHub CLI"))
        #expect(attempt.node == node && attempt.head == head)
        let readLog = try await console.runGitHubSeamScript(Data("cat '\(folder)/pull-reads.jsonl'".utf8), on: host.id)
        try #require(readLog.exitStatus == 0)
        let reads = try readLog.stdout.split(separator: 10).map {
            try JSONDecoder().decode(PullHeadRead.self, from: Data($0))
        }.filter { $0.node == node && $0.client.hasPrefix("GitHub CLI") }
        #expect(reads.contains { $0.head == initialHead && $0.state == "OPEN" && $0.mutations == 0 })
        #expect(reads.contains { $0.head == head && $0.state == "OPEN" && $0.mutations == 0 })
        #expect(reads.contains { $0.head == head && $0.state == (approve ? "OPEN" : "MERGED") && $0.mutations == 1 })
        if approve {
            #expect(attempt.action == "approve" && attempt.body == message)
            #expect(attempt.requestHead == nil || attempt.requestHead == head)
        } else {
            #expect(attempt.action == "merge" && attempt.requestHead == head && attempt.method == "SQUASH")
        }
    }

    /// Each Host proves its loopback destination before the shared write case runs.
    private func privateGitHubWriteEndpoint(macRoot: String?) throws -> (preflight: String, receipts: String) {
        if let root = macRoot {
            let format = #"\A/private/tmp/heeler-lab-mac-github-write\.[A-Za-z0-9_-]{6,16}\z"#
            try #require(root.range(of: format, options: .regularExpression) != nil)
            let script = """
            set -eu
            test "$(uname -s)" = Darwin
            test "$HOME" = '\(root)/home'
            test "$GH_CONFIG_DIR" = '\(root)/gh-config'
            test "$GH_HOST" = heeler-lab-github-write.test
            test -z "${NO_PROXY:-}"
            test -z "${no_proxy:-}"
            port=$(cat '\(root)/proxy.port')
            case "$port" in ''|*[!0-9]*) exit 1 ;; esac
            test "$port" -gt 0 && test "$port" -le 65535
            test "$HTTPS_PROXY" = "http://127.0.0.1:$port"
            test "$HTTP_PROXY" = "$HTTPS_PROXY"
            test "$SSL_CERT_FILE" = '\(root)/service/ca.pem'
            test "$(command -v gh)" = '\(root)/bin/gh'
            challenge=$(cat '\(root)/service/challenge')
            case "$challenge" in ''|*[!0-9a-f]*) exit 1 ;; esac
            test "${#challenge}" = 48
            test "$(gh api --hostname "$GH_HOST" /meta --jq .heelerFixture)" = "$challenge"
            """
            return (script, root + "/service/comments.jsonl")
        }
        let linux = """
        set -eu
        test "$GH_HOST" = heeler-lab-github-write.test
        test "$HTTPS_PROXY" = http://127.0.0.1:9
        test "$HTTP_PROXY" = http://127.0.0.1:9
        test "$NO_PROXY" = heeler-lab-github-write.test,127.0.0.2
        test "$SSL_CERT_FILE" = /home/heelerlab/heeler-lab-gh-write/ca.pem
        test "$(getent ahostsv4 "$GH_HOST" | awk '{print $1}' | sort -u)" = 127.0.0.2
        test "$(command -v gh)" = /usr/bin/gh
        """
        return (linux, "/home/heelerlab/heeler-lab-gh-write/comments.jsonl")
    }
}

@MainActor
@Suite("OpenCode history on a private Rex Host", .timeLimit(.minutes(2)))
struct RexOpenCodeHistoryLiveTests {
    @Test func choosingHistoryKeepsInputInTheTerminal() async throws {
        let fixture = try RexHostServicesLiveTests.Fixture.load("HEELER_REX_OPENCODE_LAB")
        let pane = RexPaneAddress(sessionID: try #require(fixture.rexSession), blockID: try #require(fixture.rexBlock)).paneID
        let peer = RexPaneAddress(sessionID: try #require(fixture.peerSession), blockID: try #require(fixture.peerBlock)).paneID
        let id = try #require(fixture.openCodeSession.flatMap(OpenCodeSessionID.init))
        let peerID = try #require(fixture.openCodePeer.flatMap(OpenCodeSessionID.init))
        let marker = try #require(fixture.sourceMarker)
        let peerMarker = try #require(fixture.peerMarker)
        try #require(pane != peer && id != peerID && marker != peerMarker)
        let suite = "heeler-lab-opencode-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (host, console) = try fixture.connect(.rex, defaults: defaults)
        defer { console.setHosts([]) }
        await console.resume()
        let deadline = ContinuousClock.now + .seconds(30)
        func bothAreVisible() -> Bool {
            [pane, peer].allSatisfy { target in
                console.agents.contains { $0.agent.paneID == target && console.chatProgram(for: $0) == .opencode }
            }
        }
        while !bothAreVisible(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(150))
        }
        try #require(bothAreVisible())
        let agent = try #require(console.agents.first { $0.agent.paneID == pane })
        try #require(!console.capabilities(for: host.id).readOnlyChatPrograms.contains(.opencode))
        let chat = try #require(console.chatStore(for: agent, program: .opencode))
        defer { chat.end() }
        await chat.step()
        try #require(chat.offersCandidates && chat.picksAreReadOnly)
        await chat.listCandidates()
        guard case .listed(let list) = chat.candidates else {
            Issue.record("The private OpenCode sessions were not listed")
            return
        }
        let selected = try #require(list.candidates.first { $0.sessionID == id.rawValue })
        let other = try #require(list.candidates.first { $0.sessionID == peerID.rawValue })
        guard case .conversation = await chat.previewCandidate(other),
              case .conversation = await chat.previewCandidate(selected) else {
            Issue.record("Both conversations must be independently readable before selection")
            return
        }
        await chat.confirmCandidate(selected)
        let readDeadline = ContinuousClock.now + .seconds(12)
        while !chat.isReadingPickedConversation && ContinuousClock.now < readDeadline {
            await chat.step()
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(chat.isReadingPickedConversation)
        let prompts = chat.conversation.transcript.recordedPrompts.map(\.text)
        try #require(prompts.contains { $0.contains(marker) } && !prompts.contains { $0.contains(peerMarker) })
        let query = try #require(console.chatHostFiles(for: host.id).queryOpenCode)
        func rows(_ id: OpenCodeSessionID) async throws -> [OpenCodeRowLine] {
            let result = try await query(.init(session: id, kind: .tail(budget: 65536)))
            guard case .records(let records) = result, !records.rows.isEmpty else { throw TransportError.cancelled }
            return records.rows
        }
        let a = try await rows(id), b = try await rows(peerID)
        let composer = console.composerSession(for: agent).composer
        composer.bindChatDraft(to: chat.composerSessionID, program: .opencode)
        let draft = "HEELER_LAB_READ_ONLY_" + UUID().uuidString
        composer.replaceDraft(with: draft)
        chat.draftDidChange(to: draft)
        var policy = ComposerDeliveryPolicy.chat(rules: .init(program: .opencode, commands: []),
            activity: { ChatAgentActivity(agent.agent.status) },
            readScreen: { try await console.readAgentScreen(pane, on: host.id) },
            confirmSession: { await chat.confirmSessionBeforeSend(for: composer) })
        policy.sessionWrite = chat.composerWriteCheck(for: composer)
        guard case .refused = await composer.send(policy: policy) else {
            Issue.record("A read-only selection accepted input")
            return
        }
        #expect(composer.draft == draft)
        try #require(chat.offersCandidates)
        await chat.listCandidates()
        guard case .conversation = await chat.previewCandidate(other) else { throw TransportError.cancelled }
        await chat.confirmCandidate(other)
        let switchDeadline = ContinuousClock.now + .seconds(12)
        while !chat.conversation.transcript.recordedPrompts.contains(where: { $0.text.contains(peerMarker) }),
              ContinuousClock.now < switchDeadline {
            await chat.step()
            try await Task.sleep(for: .milliseconds(100))
        }
        let peerPrompts = chat.conversation.transcript.recordedPrompts.map(\.text)
        #expect(chat.isReadingPickedConversation && peerPrompts.contains { $0.contains(peerMarker) })
        #expect(!peerPrompts.contains { $0.contains(marker) })
        let after = try await rows(id), peerAfter = try await rows(peerID)
        #expect(after == a && peerAfter == b)
    }
}

/// A real macOS or Linux Rex pair. The independent desktop operator reloads the named
/// plugin or switches A only after the test reaches each corresponding step.
@MainActor
@Suite("Read-only Amp Chat on a POSIX Rex Host", .serialized, .timeLimit(.minutes(5)))
struct RexAmpChatLiveTests {
    private struct Steps: Decodable {
        let firstThread: String
        let peerThread: String
        let nextMarker: String
        let signalDirectory: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_REX_AMP_CHAT_LAB"] != nil))
    func followsTheForegroundThreadAndKeepsInputInTheTerminal() async throws {
        let environment = "HEELER_REX_AMP_CHAT_LAB"
        let fixture = try RexHostServicesLiveTests.Fixture.load(environment)
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[environment]))
        let steps = try JSONDecoder().decode(Steps.self, from: Data(contentsOf: url))
        let signals = URL(fileURLWithPath: steps.signalDirectory, isDirectory: true).standardizedFileURL
        try #require(signals.deletingLastPathComponent().path == url.deletingLastPathComponent().standardizedFileURL.path)
        func signal(_ step: String) throws {
            try Data().write(to: signals.appendingPathComponent(step), options: .withoutOverwriting)
        }
        let pane = RexPaneAddress(sessionID: try #require(fixture.rexSession), blockID: try #require(fixture.rexBlock)).paneID
        let peer = RexPaneAddress(sessionID: try #require(fixture.peerSession), blockID: try #require(fixture.peerBlock)).paneID
        let firstMarker = try #require(fixture.sourceMarker)
        let peerMarker = try #require(fixture.peerMarker)
        try #require(pane != peer && firstMarker != peerMarker && steps.firstThread != steps.peerThread)
        let suite = "heeler-lab-amp-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (host, console) = try fixture.connect(.rex, defaults: defaults)
        defer { console.setHosts([]) }
        await console.resume()

        func wait(_ description: String, until satisfied: @MainActor () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(40)
            while ContinuousClock.now < deadline {
                if try await satisfied() { return }
                try await Task.sleep(for: .milliseconds(180))
            }
            throw NSError(domain: "RexAmpChatLive", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
        }
        try await wait("Rex did not list both Amp terminals") {
            [pane, peer].allSatisfy { id in console.agents.contains { $0.agent.paneID == id && console.chatProgram(for: $0) == .amp } }
        }
        let agent = try #require(console.agents.first { $0.agent.paneID == pane })
        let other = try #require(console.agents.first { $0.agent.paneID == peer })
        let capabilities = console.capabilities(for: host.id)
        try #require(capabilities.offersAmpPlugin && capabilities.offersChat(for: .amp) && !capabilities.readOnlyChatPrograms.contains(.amp))
        let chat = try #require(console.chatStore(for: agent, program: .amp))
        let peerChat = try #require(console.chatStore(for: other, program: .amp))
        defer { chat.end(); peerChat.end() }
        let connection = try #require(chat.ampConnection)
        try #require(!connection.isReadOnly)
        let peerConnection = try #require(peerChat.ampConnection)
        try #require(try await peerConnection.evidence() == .bound(sessionID: steps.peerThread, transcriptRoot: nil, directory: nil))
        let peerTarget = try #require(peerConnection.current)
        let peerPage = try await peerConnection.page(thread: steps.peerThread, expected: peerTarget, offset: nil, limit: 20).1
        try #require(peerPage.rows.contains { $0.role == "assistant" && $0.blocks.contains { $0.text == peerMarker } })
        try #require(try await connection.evidence() == .unavailable(.amp(.missing)))
        let location = try #require(connection.location)
        try await connection.install(location)
        try #require(try await connection.evidence() == .unavailable(.amp(.reload)))
        try signal("place-previous-plugin")
        try await wait("The previous shipping plugin was not offered an update") {
            try await connection.evidence() == .unavailable(.amp(.update))
        }
        try await connection.install(location, updating: true)
        try signal("reload-updated-plugin")
        chat.show()
        func assistant(_ expected: String) -> Bool {
            chat.conversation.transcript.entries.contains {
                if case .assistant(let message) = $0.content { return message.text == expected }
                return false
            }
        }
        try await wait("A did not open its own official thread") { assistant(firstMarker) && chat.displayedAmpBinding?.binding.thread == steps.firstThread }
        try #require(!assistant(peerMarker) && !chat.offersCandidates)
        let original = try #require(chat.displayedAmpBinding)
        let composer = console.composerSession(for: agent).composer
        let draft = "REX_LAB_AMP_UNSUBMITTED_" + UUID().uuidString
        composer.replaceDraft(with: draft)
        let refusal = CheckedSendOutcome.refused(.inputNotReady(AmpChatProblem.readOnly.explanation))
        try #require(await connection.send(id: UUID(), text: draft, target: original) == refusal)
        let permit = try #require(chat.composerWriteCheck(for: composer))
        try #require(await !permit(nil) && composer.draft == draft)
        await #expect(throws: TransportError.self) { try await chat.screenIO.sendKeys(["Escape"]) }
        try signal("switch-a")
        try await wait("Chat did not follow A's newly selected thread") {
            assistant(steps.nextMarker) && chat.displayedAmpBinding?.binding.thread != steps.firstThread
        }
        try #require(!assistant(firstMarker) && !assistant(peerMarker))
        await #expect(throws: ChatSourceUnavailable.self) {
            _ = try await connection.page(thread: steps.firstThread, expected: original, offset: nil, limit: 20)
        }
        try #require(try await peerConnection.evidence() == .bound(sessionID: steps.peerThread, transcriptRoot: nil, directory: nil))
        try #require(peerConnection.current == peerTarget)
        try signal("unload-a-plugin")
        try await wait("Chat retained the old thread after the foreground plugin was unloaded") {
            chat.conversation.phase == .unavailable(.amp(.missing)) && chat.displayedAmpBinding == nil
        }
        try #require(composer.draft == draft && !assistant(steps.nextMarker))
    }
}

/// Runs the same user-side Composer and official transcript checks on the
/// reference backend. Each invocation names a separately prepared A/B pair.
@MainActor
@Suite("Foreground Chat on a private Herdr TUI Host", .timeLimit(.minutes(2)),
       .enabled(if: ProcessInfo.processInfo.environment["HEELER_TUI_FOREGROUND_CHAT_LAB"] != nil))
struct HerdrForegroundChatLiveTests {
    @Test func aMultilineMessageReachesOnlyTheSelectedConversation() async throws {
        let fixture = try RexHostServicesLiveTests.Fixture.load("HEELER_TUI_FOREGROUND_CHAT_LAB")
        let program = try #require(fixture.program)
        try #require([ChatProgram.pi, .omp, .grok, .claude, .codex].contains(program))
        let firstPane = try #require(fixture.sourcePane), peerPane = try #require(fixture.targetPane)
        let firstFile = try #require(fixture.firstFile), peerFile = try #require(fixture.peerFile)
        let firstMarker = try #require(fixture.sourceMarker), peerMarker = try #require(fixture.peerMarker)
        try #require(firstPane != peerPane && firstFile != peerFile && firstMarker != peerMarker)
        try #require([firstFile, peerFile].allSatisfy { $0.contains("heeler-lab-") && RemoteFilePath.isAcceptable($0) })
        let name = "heeler-lab-tui-chat-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let (host, console) = try fixture.connect(.herdrTUI, defaults: defaults)
        defer { console.setHosts([]) }
        await console.resume()
        func wait(_ label: String, for condition: () async throws -> Bool) async throws {
            let until = ContinuousClock.now.advanced(by: .seconds(35))
            while ContinuousClock.now < until {
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(160))
            }
            try #require(Bool(false), "\(label)")
        }
        try await wait("Both live foregrounds were reported in the same directory") {
            let agents = console.agents.filter { $0.hostID == host.id && [firstPane, peerPane].contains($0.agent.paneID) }
            return agents.count == 2 && Set(agents.map(\.agent.cwd)).count == 1
                && agents.allSatisfy { $0.agent.kind == program.rawValue && console.chatProgram(for: $0) == program }
        }
        let target = try #require(console.agents.first { $0.hostID == host.id && $0.agent.paneID == firstPane })
        let other = try #require(console.agents.first { $0.hostID == host.id && $0.agent.paneID == peerPane })
        let chat = try #require(console.chatStore(for: target, program: program))
        let peer = try #require(console.chatStore(for: other, program: program))
        defer { chat.end(); peer.end() }
        try await wait("Each native Chat followed its own official seed and file") {
            await chat.step()
            await peer.step()
            return chat.conversation.phase == .following(path: firstFile) && peer.conversation.phase == .following(path: peerFile)
                && chat.conversation.transcript.recordedPrompts.contains { $0.text == firstMarker }
                && peer.conversation.transcript.recordedPrompts.contains { $0.text == peerMarker }
        }
        let files = console.chatHostFiles(for: host.id)
        func bytes(at path: String) async throws -> Data {
            let size = try #require(try await files.status(path)?.size)
            try #require(size > 0 && size <= 4 << 20)
            return try #require(try await files.read(path: path, from: 0, to: size, chunk: 64 << 10))
        }
        let beforeA = try await bytes(at: firstFile), beforeB = try await bytes(at: peerFile)
        let session = console.composerSession(for: target), composer = session.composer
        let rules = ChatSendRules(program: program, commands: [])
        if program.pinsComposerToSession || chat.tracksConversationDraft {
            composer.bindChatDraft(to: chat.composerSessionID, program: program)
        }
        var confirm: (@MainActor () async -> String?)?
        if chat.confirmsSessionBeforeSend { confirm = { await chat.confirmSessionBeforeSend(for: composer) } }
        var policy = ComposerDeliveryPolicy.chat(rules: rules,
            activity: { ChatAgentActivity(console.agents.first { $0.id == target.id }?.agent.status) },
            readScreen: {
                let screen = try await console.readAgentScreen(firstPane, on: host.id, keepingTo: session.corePin)
                chat.inputBoxWasRead(screen)
                return screen
            }, confirmSession: confirm, heldSession: { chat.sessionRefusalBeforeCheck() },
            sendConcern: { chat.sendConcern(for: $0, after: $1) },
            willReadScreen: { chat.updateSends(ChatComposerEchoes.sentMessages(composer.messages, rules: rules)) },
            conversation: { chat.conversationGeneration })
        policy.sessionWrite = chat.composerWriteCheck(for: composer)
        let marker = "REX_LAB_HERDR_SEND_" + UUID().uuidString.prefix(8)
        let prompt = "Reply only with this marker. 请保留换行。\n\n    " + marker
        composer.replaceDraft(with: prompt)
        chat.draftDidChange(to: prompt)
        let result = await composer.send(policy: policy)
        try #require(result == .deliveredViaPrompt || result == .submittedViaAttach || result == .deliveredViaAttach)
        let outgoing = program == .grok ? rules.outgoingText(prompt) : prompt
        try await wait("Only A recorded the marked user prompt and its reply") {
            await chat.step()
            return chat.conversation.transcript.recordedPrompts.filter { $0.text == outgoing }.count == 1
                && chat.conversation.transcript.entries.filter { $0.content == .assistant(.init(text: marker)) }.count == 1
        }
        await peer.step()
        #expect(try await bytes(at: firstFile).starts(with: beforeA))
        #expect(try await bytes(at: peerFile) == beforeB)
        #expect(!peer.conversation.transcript.recordedPrompts.contains { $0.text.contains(marker) })
    }
}
