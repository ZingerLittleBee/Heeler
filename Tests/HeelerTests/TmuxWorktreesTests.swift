import Foundation
import Testing

@testable import Heeler

/// Worktrees on a tmux Host, through `ConsoleStore` and the real launch path
/// over a scripted server. Rows, options and which Panes survive are what the
/// user sees; a quoted word is the contract for a branch or a path.
@MainActor
@Suite("tmux worktrees", .timeLimit(.minutes(1)))
struct TmuxWorktreesTests {
    private let host = Host(
        address: "mac.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())
    private let repo = "/work/my app"
    private let branch = "feature/login"

    private func console(over tmux: ScriptedTmuxHost) -> ConsoleStore {
        ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in
                        await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths)
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
                    keepalive: KeepalivePolicy(interval: .milliseconds(10)))
            })
    }

    private func started(_ tmux: ScriptedTmuxHost) async -> ConsoleStore {
        let store = console(over: tmux)
        store.setHosts([host])
        await store.resume()
        return store
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        throw WaitExpired()
    }

    private struct WaitExpired: Error {}

    private func commandScripts(_ tmux: ScriptedTmuxHost) async -> [String] {
        await tmux.commands.filter { !$0.contains("show-environment") }
    }

    private func checkout(branch: String) -> String {
        "/Users/dev/.heeler/worktrees/my app/\(HerdrCoreWorktrees.slug(branch))"
    }

    /// A connected Host whose repository is `repo`, with one session there.
    private func connected(
        _ tmux: ScriptedTmuxHost, sessionName: String = "main", path: String? = nil,
        branches: [String] = []
    ) async throws -> ConsoleStore {
        await tmux.plantRepository(repo, branches: branches)
        await tmux.setPanes([.make(sessionName: sessionName, path: path ?? repo)])
        let store = await started(tmux)
        try await waitUntil("the source session") {
            store.workspacesByHost[host.id]?.contains { $0.label == sessionName } == true
        }
        return store
    }

    private func start(
        _ store: ConsoleStore, branch: String, workspaceID: String = "$0", cwd: String? = nil
    ) async throws -> Agent {
        try await store.startAgentInNewWorktree(
            AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: workspaceID, cwd: cwd),
            worktree: WorktreeSpec(branch: branch), on: host.id)
    }

    private func linkedRow(_ store: ConsoleStore, path: String) -> ConsoleAgent? {
        store.agents.first { $0.isLinkedWorktree && $0.checkoutPath == path }
    }

    // MARK: Create

    @Test func aNamedBranchChecksOutUnderHeelerAndOpensANumberedSession() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux, sessionName: branch)
        defer { store.setHosts([]) }
        let path = checkout(branch: branch)

        _ = try await start(store, branch: branch)

        try await waitUntil("the numbered session") { linkedRow(store, path: path) != nil }
        let row = try #require(linkedRow(store, path: path))
        #expect(row.workspaceLabel == "\(branch)-2")
        #expect(row.repositoryCheckout?.repoKey == repo)
        #expect(row.repositoryCheckout?.repoName == "my app")
        #expect(row.repositoryCheckout?.isLinkedWorktree == true)
        let source = try #require(store.workspacesByHost[host.id]?.first { $0.label == branch })
        #expect(source.checkoutPath == nil)
        let marked = try #require(await commandScripts(tmux).first {
            $0.contains("set-option -t ") && $0.contains("@heeler-worktree")
        })
        #expect(marked.contains("-t \(GitProbe.singleQuoted(row.agent.workspaceID))"))
        #expect(marked.contains(GitProbe.singleQuoted(path)))
        let added = try #require(await tmux.gitCommands.last { $0.arguments.dropFirst().first == "add" })
        #expect(added.arguments == ["worktree", "add", "-b", branch, path, "HEAD"])
        #expect(added.directory == repo)
        #expect(added.isMutation)
    }

    @Test func aBranchGitWouldQuoteIsQuotedAndTheSessionKeepsIt() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }
        let branch = "a;b'c$(id)`x`"
        let path = "/Users/dev/.heeler/worktrees/my app/a-b-c-id-x"

        _ = try await start(store, branch: branch)

        try await waitUntil("the quoted branch's session") { linkedRow(store, path: path) != nil }
        let row = try #require(linkedRow(store, path: path))
        #expect(row.workspaceLabel == branch)
        let opened = try #require(await commandScripts(tmux).first { $0.contains("new-session") })
        #expect(opened.contains("-s \(GitProbe.singleQuoted(branch))"))
        let marked = try #require(await commandScripts(tmux).first {
            $0.contains("set-option -t ") && $0.contains("@heeler-worktree")
        })
        #expect(marked.contains(GitProbe.singleQuoted(path)))
        let added = try #require(await tmux.gitCommands.last { $0.arguments.dropFirst().first == "add" })
        let script = String(decoding: GitProbe.commandScript(added, nonce: "n"), as: UTF8.self)
        #expect(script.contains(GitProbe.singleQuoted(branch)))
        #expect(script.contains(GitProbe.singleQuoted(path)))
        #expect(added.arguments == ["worktree", "add", "-b", branch, path, "HEAD"])
    }

    @Test func anExistingBranchIsCheckedOutWithoutCreatingIt() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux, branches: [branch])
        defer { store.setHosts([]) }
        let path = checkout(branch: branch)

        _ = try await start(store, branch: branch)

        try await waitUntil("the existing branch") { linkedRow(store, path: path)?.workspaceLabel == branch }
        let added = try #require(await tmux.gitCommands.last { $0.arguments.dropFirst().first == "add" })
        #expect(added.arguments == ["worktree", "add", path, branch])
        #expect(added.directory == repo)
    }

    @Test func anEmptyBranchNeverReachesGit() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }
        let message = try #require(GitBranchName.validationError(""))
        let before = store.workspacesByHost[host.id]?.map(\.id)

        await #expect(throws: HerdrCoreWorktreeError.invalidBranch(message)) {
            try await start(store, branch: "")
        }

        #expect(store.workspacesByHost[host.id]?.map(\.id) == before)
        #expect(await tmux.gitCommands.isEmpty)
    }

    @Test func aBranchWithNoFolderNameStopsBeforeGit() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }

        await #expect(throws: HerdrCoreWorktreeError.noFolderName(branch: "功.功")) {
            try await start(store, branch: "功.功")
        }

        #expect(await tmux.gitCommands.isEmpty)
        #expect(store.workspacesByHost[host.id]?.map(\.label) == ["main"])
    }

    @Test func aDottedBranchKeepsTheSlugAndUsesASessionNameTmuxAccepts() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }

        _ = try await start(store, branch: "v1.2")

        let path = "/Users/dev/.heeler/worktrees/my app/v1.2"
        try await waitUntil("the dotted branch") { linkedRow(store, path: path) != nil }
        #expect(linkedRow(store, path: path)?.workspaceLabel == "v1-2")
    }

    @Test func theTypedDirectoryIsTheCheckoutSource() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.plantRepository(repo)
        await tmux.setPanes([.make(sessionName: "main", path: "/tmp")])
        let store = await started(tmux)
        defer { store.setHosts([]) }
        try await waitUntil("the source session") { store.workspacesByHost[host.id]?.map(\.label) == ["main"] }
        let path = checkout(branch: branch)

        _ = try await start(store, branch: branch, cwd: repo)

        try await waitUntil("the checkout") { linkedRow(store, path: path) != nil }
        let added = try #require(await tmux.gitCommands.last { $0.arguments.dropFirst().first == "add" })
        #expect(added.directory == repo)
        #expect(added.arguments == ["worktree", "add", "-b", branch, path, "HEAD"])
    }

    @Test func gitWaitsItsTurnAtTheHostsGate() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }
        let held = ScriptedTransportCallGate()
        let changes = Task { [gate = store.gitExecGate(for: host.id)] in
            try await gate.run { await held.waitUntilOpen() }
        }
        await held.waitForEntry()

        let starting = Task { try await start(store, branch: branch) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await tmux.gitCommands.isEmpty)

        await held.open()
        try await changes.value
        _ = try await starting.value
        #expect(await tmux.gitCommands.contains { $0.arguments.dropFirst().first == "add" })
    }

    @Test func theWorktreeListNamesTheOpenSession() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }
        let path = checkout(branch: branch)
        _ = try await start(store, branch: branch)
        try await waitUntil("the worktree row") { linkedRow(store, path: path) != nil }
        let row = try #require(linkedRow(store, path: path))

        let listed = try await store.listWorktrees(forWorkspaceID: row.agent.workspaceID, on: host.id)

        #expect(listed.source.repoKey == repo)
        #expect(listed.source.repoName == "my app")
        #expect(listed.source.repoRoot == repo)
        #expect(listed.source.sourceCheckoutPath == path)
        let linked = try #require(listed.worktrees.first { $0.path == path })
        #expect(linked.isLinkedWorktree)
        #expect(linked.branch == branch)
        #expect(linked.openWorkspaceID == row.agent.workspaceID)
        let main = try #require(listed.worktrees.first { $0.path == repo })
        #expect(!main.isLinkedWorktree)
    }

    @Test func aReconnectedSessionReadsItsWorktreeFromTheOption() async throws {
        let tmux = ScriptedTmuxHost()
        let path = checkout(branch: branch)
        await tmux.plantRepository(repo)
        _ = try await tmux.runGitCommand(
            GitCommand(
                arguments: ["worktree", "add", "-b", branch, path, "HEAD"], directory: repo, isMutation: true))
        await tmux.setPanes([.make(sessionName: branch, path: "/tmp", worktree: path)])
        let store = await started(tmux)
        defer { store.setHosts([]) }

        try await waitUntil("the option's checkout") {
            store.workspacesByHost[host.id]?.first { $0.label == branch }?.checkoutPath == path
        }
        let row = try #require(store.workspacesByHost[host.id]?.first { $0.label == branch })
        #expect(row.checkoutPath == path)
        #expect(row.checkoutPath != "/tmp")
    }

    // MARK: Remove

    @Test func removalEndsOnlySessionsMarkedWithTheCheckout() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }
        let path = checkout(branch: branch)
        let agent = try await start(store, branch: branch)
        try await waitUntil("the worktree") { linkedRow(store, path: path) != nil }
        _ = try await store.createShellTerminal(
            ShellTerminalCreationRequest(workspaceID: agent.workspaceID, cwd: path), on: host.id)
        try await waitUntil("the second pane") {
            store.terminals.filter { $0.pane.workspaceID == agent.workspaceID }.count >= 2
        }
        try await store.renameWorkspace(agent.workspaceID, label: "renamed", on: host.id)
        try await waitUntil("the renamed session") {
            store.workspacesByHost[host.id]?.first { $0.id == agent.workspaceID }?.label == "renamed"
        }
        _ = try await store.createShellWorkspace(
            NewWorkspaceSpec(directory: "/tmp", label: branch), tabLabel: nil, on: host.id)
        try await waitUntil("the same name without the option") {
            store.workspacesByHost[host.id]?.contains { $0.label == branch && $0.id != agent.workspaceID } == true
        }
        let row = try #require(linkedRow(store, path: path))
        let checkout = try #require(row.repositoryCheckout)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(hostID: host.id, workspaceID: row.agent.workspaceID, checkout: checkout))

        let receipt = try await store.removeWorktree(request, on: host.id)

        try await waitUntil("the marked session to go") {
            store.workspacesByHost[host.id]?.contains { $0.id == agent.workspaceID } != true
        }
        let left = store.workspacesByHost[host.id] ?? []
        #expect(left.contains { $0.label == "main" })
        #expect(left.contains { $0.label == branch })
        #expect(!left.contains { $0.id == agent.workspaceID })
        #expect(store.terminals.contains { $0.pane.workspaceID == agent.workspaceID } == false)
        #expect(receipt.affectedAgentIDs.contains(row.id))
        #expect(store.removedWorktreesByAgent[row.id]?.request.identity.checkoutPath == path)
        #expect(try await tmux.checkouts(for: [path])[path] == nil)
        let ref = try await tmux.runGitCommand(
            GitCommand(
                arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
                directory: repo, isMutation: false))
        #expect(ref.status == 0)
        let removed = await tmux.gitCommands.filter { $0.arguments.dropFirst().first == "remove" }
        #expect(removed.map(\.arguments) == [["worktree", "remove", path]])
        #expect(await commandScripts(tmux).contains { $0.contains("kill-session") } == false)
    }

    @Test func aDirtyCheckoutStaysWhenTheConfirmationDidNotNameIt() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }
        let path = checkout(branch: branch)
        let agent = try await start(store, branch: branch)
        try await waitUntil("the worktree") { linkedRow(store, path: path) != nil }
        let row = try #require(linkedRow(store, path: path))
        let checkout = try #require(row.repositoryCheckout)
        await tmux.setWorktreeDirty(path)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(hostID: host.id, workspaceID: row.agent.workspaceID, checkout: checkout))

        await #expect(throws: WorktreeRemovalError.changedSinceConfirmation) {
            try await store.removeWorktree(request, on: host.id)
        }

        #expect(store.workspacesByHost[host.id]?.contains { $0.id == agent.workspaceID } == true)
        #expect(store.terminals.contains { $0.pane.workspaceID == agent.workspaceID })
        #expect(try await tmux.checkouts(for: [path])[path]?.isLinkedWorktree == true)
        #expect(await tmux.gitCommands.contains { $0.arguments.dropFirst().first == "remove" } == false)
    }

    @Test func aNamedRiskForcesTheRemoval() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }
        let path = checkout(branch: branch)
        let agent = try await start(store, branch: branch)
        try await waitUntil("the worktree") { linkedRow(store, path: path) != nil }
        let row = try #require(linkedRow(store, path: path))
        let checkout = try #require(row.repositoryCheckout)
        await tmux.setWorktreeDirty(path)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(hostID: host.id, workspaceID: row.agent.workspaceID, checkout: checkout),
            toldRisk: WorktreeRemovalRisk(hasChanges: true, hasSubmodules: false))

        _ = try await store.removeWorktree(request, on: host.id)

        try await waitUntil("the session to go") {
            store.workspacesByHost[host.id]?.contains { $0.id == agent.workspaceID } != true
        }
        let removed = try #require(await tmux.gitCommands.last { $0.arguments.dropFirst().first == "remove" })
        #expect(removed.arguments == ["worktree", "remove", "--force", path])
        #expect(removed.directory == repo)
        #expect(try await tmux.checkouts(for: [path])[path] == nil)
    }

    @Test func aSubmoduleForcesTheRemoval() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }
        let path = checkout(branch: branch)
        let agent = try await start(store, branch: branch)
        try await waitUntil("the worktree") { linkedRow(store, path: path) != nil }
        let row = try #require(linkedRow(store, path: path))
        let checkout = try #require(row.repositoryCheckout)
        await tmux.setWorktreeSubmodule(path)
        let heard = try await store.worktreeRemovalRisk(
            WorktreeRemovalRequest(
                identity: WorktreeIdentity(hostID: host.id, workspaceID: row.agent.workspaceID, checkout: checkout)),
            on: host.id)
        #expect(heard == WorktreeRemovalRisk(hasChanges: false, hasSubmodules: true))
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(hostID: host.id, workspaceID: row.agent.workspaceID, checkout: checkout),
            toldRisk: heard)

        _ = try await store.removeWorktree(request, on: host.id)

        let removed = try #require(await tmux.gitCommands.last { $0.arguments.dropFirst().first == "remove" })
        #expect(removed.arguments == ["worktree", "remove", "--force", path])
        #expect(try await tmux.checkouts(for: [path])[path] == nil)
    }

    @Test func changesLeftByTheEndingPanesKeepTheCheckout() async throws {
        let tmux = ScriptedTmuxHost()
        let store = try await connected(tmux)
        defer { store.setHosts([]) }
        let path = checkout(branch: branch)
        let agent = try await start(store, branch: branch)
        try await waitUntil("the worktree") { linkedRow(store, path: path) != nil }
        let row = try #require(linkedRow(store, path: path))
        let checkout = try #require(row.repositoryCheckout)
        let identity = WorktreeIdentity(hostID: host.id, workspaceID: row.agent.workspaceID, checkout: checkout)
        await tmux.markDirtyAfterAPaneEnds(path)

        await #expect(throws: WorktreeRemovalError.changedWhileTerminalsEnded) {
            try await store.removeWorktree(
                WorktreeRemovalRequest(identity: identity), on: host.id)
        }

        try await waitUntil("the panes to end") {
            store.terminals.contains { $0.pane.workspaceID == agent.workspaceID } == false
        }
        #expect(try await tmux.checkouts(for: [path])[path]?.isLinkedWorktree == true)
        #expect(await tmux.gitCommands.contains { $0.arguments.dropFirst().first == "remove" } == false)

        _ = try await store.removeWorktree(
            WorktreeRemovalRequest(
                identity: identity, toldRisk: WorktreeRemovalRisk(hasChanges: true, hasSubmodules: false)),
            on: host.id)
        #expect(try await tmux.checkouts(for: [path])[path] == nil)
        let removed = try #require(await tmux.gitCommands.last { $0.arguments.dropFirst().first == "remove" })
        #expect(removed.arguments == ["worktree", "remove", "--force", path])
    }

    // MARK: The form

    @Test func aTmuxWorktreeNeedsABranchBeforeItCanStart() async throws {
        let form = StartAgentStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "$0", label: "main", checkoutPath: repo)] },
            existingAgentNames: { _ in [] },
            discoverAgentKinds: { _ in [.claude] },
            remoteHome: { _ in "/Users/dev" },
            start: { _, _, _ in throw TransportError.hostFeatureUnavailable(feature: "unused") },
            awaitAgentVisible: { _ in })
        form.selectedWorkspaceID = "$0"
        await form.discoverAgents()

        #expect(form.offersWorktree)
        #expect(form.worktreeNeedsBranch)
        form.startsInNewWorktree = true
        #expect(!form.canSubmit)
        form.worktreeBranch = branch
        #expect(form.canSubmit)
    }
}
