import Foundation
import SwiftUI
import Testing
import UIKit
import os

@testable import Heeler

/// Worktrees on a core Host, through `ConsoleStore` and the form stores over the
/// scripted core transport: what git is asked, in what order against the kills,
/// and what the user is told (ADR 0032). `HerdrCoreTransportE2ETests` runs the
/// same git on a real Host.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreWorktreesTests {
    private nonisolated static let main = "/work/app"
    private nonisolated static let linked = "/home/dev/.herdr/worktrees/app/feature-login"
    private static let space = "s9"
    private static var workspace: String { HerdrCoreOrganization.spaceWorkspaceID(space) }
    private static let labels = ["herdr.space": space, "herdr.tab": "tb9"]

    private static let checkouts = [
        main: HostCheckout(root: main, mainCheckout: main),
        linked: HostCheckout(root: linked, mainCheckout: main, isLinkedWorktree: true),
    ]

    private nonisolated static func shell(
        _ address: String, cwd: String, labels: [String: String] = [:], parent: String? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(true), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ]
        if let parent { fields["parent"] = .string(parent) }
        return .object(fields)
    }

    private static func agent(
        _ address: String, cwd: String, labels: [String: String] = [:]
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(true), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "labels": .object(labels.mapValues(JSONValue.string)),
            "foreground": .object([
                "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
                "cwd": .string(cwd),
            ]),
            "status": .object(["state": .string("working"), "app": .string("claude-code")]),
        ])
    }

    private static func created(sequence: Int, _ record: JSONValue) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string("created"),
                "terminal": record["address"] ?? .null, "data": record,
            ]),
        ]))) ?? Data()
    }

    /// One main-checkout Terminal, and a Worktree Workspace of an Agent, a labeled
    /// shell and a shell that joined the Agent's Tab with no label of its own.
    private static let worktreeInventory = [
        shell("t9", cwd: main),
        agent("t1", cwd: linked, labels: labels),
        shell("t2", cwd: linked, labels: labels),
        shell("t3", cwd: linked, parent: "t1"),
    ]

    @MainActor
    private final class Fixture {
        let transport: ScriptedCoreTransport
        let services: ScriptedCoreServices
        let store: ConsoleStore
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

        init(
            terminals: [JSONValue] = HerdrCoreWorktreesTests.worktreeInventory,
            platform: HostPlatform = .posix
        ) async throws {
            let services = ScriptedCoreServices(
                checkouts: HerdrCoreWorktreesTests.checkouts, home: "/home/dev", platform: platform)
            let transport = ScriptedCoreTransport(
                subscribeResults: [
                    .object(["seq": .number(1), "terminals": .array(terminals), "channel": .number(1)])
                ], services: services)
            await transport.setShell("/usr/bin/zsh")
            await transport.setDiscovery(programs: ["claude"])
            self.services = services
            self.transport = transport
            store = ConsoleStore(
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-worktrees-\(UUID().uuidString)") ?? .standard))
            store.setHosts([host])
            await store.resume()
            try await until("the first snapshot") { !self.store.hostsAwaitingSnapshot.contains(self.host.id) }
        }

        func finish() { store.setHosts([]) }

        func until(
            _ what: String, _ condition: @MainActor () async -> Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            for _ in 0..<500 {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }

        var derived: String { HerdrCoreOrganization.workspaceID(directory: HerdrCoreWorktreesTests.main) }

        func form(workspaceID: String? = nil) async -> StartAgentStore {
            let store = store
            let form = StartAgentStore(
                hosts: [host],
                workspaces: { store.workspaces(for: $0) },
                existingAgentNames: { _ in [] },
                discoverAgentKinds: { try await store.availableAgentKinds(on: $0) },
                discoverTemplates: { try await store.availableTemplates(on: $0) },
                startTemplate: { try await store.startTemplate($0, on: $1) },
                remoteHome: { try await store.remoteHomeDirectory(on: $0) },
                start: { params, destination, hostID in
                    switch destination {
                    case .existingWorkspace: try await store.startAgent(params, on: hostID)
                    case .newWorktree(let worktree):
                        try await store.startAgentInNewWorktree(params, worktree: worktree, on: hostID)
                    case .newWorkspace(let workspace):
                        try await store.startAgentInNewWorkspace(params, workspace: workspace, on: hostID)
                    }
                },
                awaitAgentVisible: { _ in },
                offersConnectedWorktrees: { store.capabilities(for: $0).worktrees })
            form.selectedWorkspaceID = workspaceID ?? derived
            await form.discoverAgents()
            return form
        }

        /// One Claude Code in a new Worktree of `workspaceID`, through the Console.
        func start(branch: String?, from workspaceID: String? = nil) async throws -> Agent {
            try await store.startAgentInNewWorktree(
                AgentLaunchRequest(
                    kind: "claude", name: "claude", arguments: [], workspaceID: workspaceID ?? derived),
                worktree: WorktreeSpec(branch: branch), on: host.id)
        }

        func removal() async throws -> WorktreeRemovalRequest {
            try await until("the Worktree's row") {
                self.store.agents.contains { $0.isLinkedWorktree }
            }
            let row = try #require(store.agents.first { $0.isLinkedWorktree })
            let checkout = try #require(row.repositoryCheckout)
            return WorktreeRemovalRequest(
                identity: WorktreeIdentity(
                    hostID: host.id, workspaceID: row.agent.workspaceID, checkout: checkout))
        }

        /// The request a confirmation hands over once it has named what will be lost.
        func removalAfterHearing() async throws -> WorktreeRemovalRequest {
            let request = try await removal()
            return WorktreeRemovalRequest(
                identity: request.identity,
                toldRisk: try await store.worktreeRemovalRisk(request, on: host.id))
        }

        func git(_ prefix: String...) async -> [GitCommand] {
            await services.gitCommands.filter { $0.arguments.starts(with: prefix) }
        }

        func setChanges() async {
            await services.setGitAnswer(
                .success(GitCommandResult(status: 0, output: "?? new.txt\n", message: nil)),
                for: ["status", "--porcelain"])
        }

        func setSubmodule() async {
            await services.setGitAnswer(
                .success(GitCommandResult(status: 0, output: "-1234 vendor/lib\n", message: nil)),
                for: ["submodule", "status"])
        }
    }

    private func terminalLabels(_ params: JSONValue?) -> [String: String] {
        guard case .object(let labels)? = params?["labels"] else { return [:] }
        return labels.compactMapValues(\.stringValue)
    }

    // MARK: Creating one

    @Test func aWorktreeTargetOpensANewDesktopLabeledWorkspaceAtTheCheckoutAndStartsTheAgentThere() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        try await fixture.until("the source's checkout") {
            await fixture.services.checkoutCalls.count == 1
        }
        let form = await fixture.form()
        #expect(form.offersWorktree == false)
        await fixture.store.checkNewAgentOffers(on: fixture.host.id)
        #expect(form.offersWorktree)
        form.startsInNewWorktree = true
        form.worktreeBranch = "  feature/login "

        await form.submit()

        guard case .started = form.state else {
            Issue.record("The launch ended as \(form.state)")
            return
        }
        #expect(await fixture.git("worktree") == [
            GitCommand(
                arguments: ["worktree", "add", "-b", "feature/login", Self.linked, "HEAD"],
                directory: Self.main, isMutation: true)
        ])
        let run = try #require(await fixture.transport.runs.last)
        #expect(await fixture.transport.runs.count == 1)
        #expect(run["cwd"]?.stringValue == Self.linked)
        let labels = terminalLabels(run)
        let space = try #require(labels["herdr.space"])
        #expect(space.hasPrefix("sp"))
        #expect(labels["herdr.tab"]?.hasPrefix("tb") == true)
        #expect(await fixture.transport.documentWrites.isEmpty)

        // It reads as the Worktree it is at once, named for its checkout's folder.
        let terminal = try #require(fixture.store.terminals.first { $0.pane.cwd == Self.linked })
        #expect(terminal.workspaceID == HerdrCoreOrganization.spaceWorkspaceID(space))
        let workspace = try #require(
            fixture.store.workspaces(for: fixture.host.id).first { $0.id == terminal.workspaceID })
        #expect(workspace.label == "feature-login")
        #expect(workspace.checkoutPath == Self.linked)
        #expect(await fixture.services.checkoutCalls.joined().filter { $0 == Self.linked }.isEmpty)
    }

    /// A Template asked into a Worktree does not stay behind in the source Workspace.
    @Test func aTemplateStartsInTheNewWorktreeLikeAnyOtherAgent() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        await fixture.store.checkNewAgentOffers(on: fixture.host.id)
        await fixture.transport.setTemplates([
            .object([
                "name": .string("reviewer"), "description": .string(""),
                "command": .string("pi --thinking high"),
            ])
        ])
        let form = await fixture.form()
        form.selectedAgent = .template(try #require(form.availableTemplates.first))
        form.startsInNewWorktree = true
        form.worktreeBranch = "feature/login"

        await form.submit()

        #expect(await fixture.git("worktree").map(\.arguments) == [
            ["worktree", "add", "-b", "feature/login", Self.linked, "HEAD"]
        ])
        #expect(await fixture.transport.templateRuns == 1)
        let run = try #require(await fixture.transport.runs.last)
        #expect(run["cwd"]?.stringValue == Self.linked)
        #expect(terminalLabels(run)["herdr.space"]?.hasPrefix("sp") == true)
    }

    /// No checkout for a launch that cannot happen.
    @Test func aTemplateGoneByStartMakesNoWorktree() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        await fixture.store.checkNewAgentOffers(on: fixture.host.id)
        await fixture.transport.setTemplates([
            .object([
                "name": .string("reviewer"), "description": .string(""),
                "command": .string("pi --thinking high"),
            ])
        ])
        let form = await fixture.form()
        form.selectedAgent = .template(try #require(form.availableTemplates.first))
        form.startsInNewWorktree = true
        form.worktreeBranch = "feature/login"
        await fixture.transport.setTemplates([])

        await form.submit()

        #expect(await fixture.git("worktree").isEmpty)
        #expect(await fixture.transport.templateRuns == 0)
    }

    @Test func aBranchThatExistsIsCheckedOutInsteadOfMade() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        try await fixture.until("the row") { !fixture.store.terminals.isEmpty }
        await fixture.services.setGitAnswer(
            .success(GitCommandResult(status: 0, output: "", message: nil)),
            for: HerdrCoreWorktrees.branchExistsArguments(branch: "feature/login"))

        _ = try await fixture.start(branch: "feature/login")

        #expect(await fixture.services.gitCommands.suffix(2) == [
            GitCommand(
                arguments: ["show-ref", "--verify", "--quiet", "refs/heads/feature/login"],
                directory: Self.main, isMutation: false),
            GitCommand(
                arguments: ["worktree", "add", Self.linked, "feature/login"],
                directory: Self.main, isMutation: true),
        ])
    }

    /// Herdr TUI's generated `worktree/<name>` has no place here: no branch, no start.
    @Test func withNoTypedBranchNothingStartsAndNoBranchIsMadeUp() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        await fixture.store.checkNewAgentOffers(on: fixture.host.id)
        let form = await fixture.form()
        form.startsInNewWorktree = true
        #expect(!form.canSubmit)
        form.worktreeBranch = "   "
        #expect(!form.canSubmit)

        await form.submit()
        await #expect(throws: HerdrCoreWorktreeError.invalidBranch("Enter a branch name.")) {
            _ = try await fixture.start(branch: nil)
        }

        #expect(await fixture.git("worktree").isEmpty)
        #expect(await fixture.transport.runs.isEmpty)
        form.worktreeBranch = "typed"
        #expect(form.canSubmit)
    }

    @Test func aBaseTypedForAHerdrTUIHostDoesNotReachACoreOne() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        await fixture.store.checkNewAgentOffers(on: fixture.host.id)
        let form = await fixture.form()
        form.startsInNewWorktree = true
        form.worktreeBranch = "typed"
        form.worktreeBase = "origin/main"

        await form.submit()

        #expect(await fixture.git("worktree").map(\.arguments) == [
            ["worktree", "add", "-b", "typed", "/home/dev/.herdr/worktrees/app/typed", "HEAD"]
        ])
    }

    /// The repository is the main checkout's folder from a linked Worktree too,
    /// and the new branch starts from the HEAD of the checkout it was asked from.
    @Test func aWorktreeOfAWorktreeNamesTheRepositoryAfterTheMainCheckout() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        try await fixture.until("the Worktree's row") {
            fixture.store.agents.contains { $0.isLinkedWorktree }
        }

        _ = try await fixture.start(branch: "next", from: Self.workspace)

        #expect(await fixture.git("worktree") == [
            GitCommand(
                arguments: ["worktree", "add", "-b", "next", "/home/dev/.herdr/worktrees/app/next", "HEAD"],
                directory: Self.linked, isMutation: true)
        ])
        #expect(await fixture.git("show-ref").map(\.directory) == [Self.main])
    }

    @Test func aHostileBranchReachesGitAsOneWordAndNamesAHarmlessFolder() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        try await fixture.until("the row") { !fixture.store.terminals.isEmpty }
        let branch = "a;b'c$(id)`x`"

        _ = try await fixture.start(branch: branch)

        #expect(await fixture.git("worktree").map(\.arguments) == [
            ["worktree", "add", "-b", branch, "/home/dev/.herdr/worktrees/app/a-b-c-id-x", "HEAD"]
        ])
    }

    @Test(arguments: ["-x", "a b", "a..b", ".hidden", "x.lock", "x/"])
    func aBranchGitWouldNotTakeNeverReachesIt(branch: String) async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        try await fixture.until("the row") { !fixture.store.terminals.isEmpty }

        await #expect(throws: HerdrCoreWorktreeError.self) { _ = try await fixture.start(branch: branch) }

        #expect(await fixture.services.gitCommands.isEmpty)
        #expect(await fixture.transport.runs.isEmpty)
    }

    @Test func aBranchWithNoFolderNameStopsBeforeGit() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        try await fixture.until("the row") { !fixture.store.terminals.isEmpty }

        await #expect(throws: HerdrCoreWorktreeError.noFolderName(branch: "功.功")) {
            _ = try await fixture.start(branch: "功.功")
        }

        #expect(await fixture.git("worktree").isEmpty)
    }

    @Test func gitWaitsItsTurnAtTheHostsGate() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        try await fixture.until("the source's checkout") {
            await fixture.services.checkoutCalls.count == 1
        }
        let held = ScriptedTransportCallGate()
        let changes = Task { [gate = fixture.store.gitExecGate(for: fixture.host.id)] in
            try await gate.run { await held.waitUntilOpen() }
        }
        await held.waitForEntry()

        let starting = Task { try await fixture.start(branch: "typed") }
        // Only lets a command that skipped the gate show up; passing never waits on it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fixture.services.gitCommands.isEmpty)
        #expect(await fixture.services.checkoutCalls.count == 1)

        await held.open()
        try await changes.value
        _ = try await starting.value
        #expect(await fixture.git("worktree").count == 1)
    }

    /// While a command runs, anything else asking the gate waits. A command that
    /// went around it would let the probe straight through.
    @Test func everyGitCommandHoldsTheHostsGateWhileItRuns() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let gate = fixture.store.gitExecGate(for: fixture.host.id)
        await fixture.services.observeGit { command in
            let free = Noted()
            _ = Task { try await gate.run { free.note(command.arguments) } }
            try? await Task.sleep(for: .milliseconds(20))
            if free.value != nil {
                Issue.record("\(command.arguments) ran with the gate free")
            }
        }

        _ = try await fixture.start(branch: "typed")
        let request = try await fixture.removalAfterHearing()
        _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)

        #expect(await fixture.git("worktree").count == 2)
    }

    @Test func aWorkspaceOutsideAnyRepositoryGetsNoWorktree() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t8", cwd: "/plain")])
        defer { fixture.finish() }
        try await fixture.until("the row") { !fixture.store.terminals.isEmpty }

        await #expect(throws: HerdrCoreWorktreeError.notInGitRepository) {
            _ = try await fixture.start(
                branch: "typed", from: HerdrCoreOrganization.workspaceID(directory: "/plain"))
        }

        #expect(await fixture.services.gitCommands.isEmpty)
        #expect(await fixture.transport.runs.isEmpty)
    }

    @Test func gitsRefusalIsShownAndNoWorkspaceOpens() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        await fixture.store.checkNewAgentOffers(on: fixture.host.id)
        let path = "/home/dev/.herdr/worktrees/app/typed"
        await fixture.services.setGitAnswer(
            .success(
                GitCommandResult(status: 128, output: "", message: "fatal: '\(path)' already exists")),
            for: ["worktree", "add", "-b", "typed", path, "HEAD"])
        let form = await fixture.form()
        form.startsInNewWorktree = true
        form.worktreeBranch = "typed"

        await form.submit()

        #expect(form.state == .failed("Creating the worktree failed: fatal: '\(path)' already exists"))
        #expect(await fixture.transport.runs.isEmpty)
    }

    /// git may have made it, so nothing opens and nothing is sent again.
    @Test func anAddNobodyConfirmedIsSentOnceAndSaysSo() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        try await fixture.until("the row") { !fixture.store.terminals.isEmpty }
        let path = "/home/dev/.herdr/worktrees/app/typed"
        await fixture.services.setGitAnswer(
            .failure(TransportError.gitTimedOut), for: ["worktree", "add", "-b", "typed", path, "HEAD"])

        await #expect(throws: HerdrCoreWorktreeError.addUnconfirmed(path: path)) {
            _ = try await fixture.start(branch: "typed")
        }

        #expect(await fixture.git("worktree").count == 1)
        #expect(await fixture.transport.runs.isEmpty)
    }

    @Test func anAgentThatDoesNotStartLeavesTheCheckoutAndSaysWhere() async throws {
        let fixture = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)])
        defer { fixture.finish() }
        await fixture.store.checkNewAgentOffers(on: fixture.host.id)
        await fixture.transport.setRunFailure(TransportError.timedOut)
        let form = await fixture.form()
        form.startsInNewWorktree = true
        form.worktreeBranch = "typed"

        await form.submit()

        #expect(
            form.state
                == .failed(
                    "The worktree is ready at /home/dev/.herdr/worktrees/app/typed, but the Agent did not start. The Host did not answer in time."
                ))
        #expect(await fixture.git("worktree").count == 1)
    }

    // MARK: What offers it

    /// macOS and Linux both report POSIX.
    @Test func theOptionShowsOnAPosixCoreHostAndStaysHiddenOnNativeWindows() async throws {
        let posix = try await Fixture(terminals: [Self.shell("t9", cwd: Self.main)], platform: .posix)
        defer { posix.finish() }
        await posix.store.checkNewAgentOffers(on: posix.host.id)
        #expect(await posix.form().offersWorktree)
        #expect(posix.store.capabilities(for: posix.host.id).worktrees)

        let windows = try await Fixture(
            terminals: [Self.shell("t9", cwd: Self.main)], platform: .nativeWindows)
        defer { windows.finish() }
        await windows.store.checkNewAgentOffers(on: windows.host.id)
        #expect(windows.store.hostPlatforms[windows.host.id] == .nativeWindows)
        #expect(await !windows.form().offersWorktree)
        #expect(!windows.store.capabilities(for: windows.host.id).worktrees)
    }

    @Test func aCallerThatWentAroundTheOptionOnNativeWindowsReachesNoGit() async throws {
        let fixture = try await Fixture(
            terminals: [Self.shell("t9", cwd: Self.main)], platform: .nativeWindows)
        defer { fixture.finish() }
        try await fixture.until("the row") { !fixture.store.terminals.isEmpty }

        await #expect(throws: TransportError.self) { _ = try await fixture.start(branch: "typed") }

        #expect(await fixture.services.gitCommands.isEmpty)
        #expect(await fixture.transport.runs.isEmpty)
    }

    // MARK: Removing one

    private final class Noted: Sendable {
        private let noted = OSAllocatedUnfairLock<[String]?>(initialState: nil)
        var value: [String]? { noted.withLock { $0 } }
        func note(_ value: [String]) { noted.withLock { $0 = value } }
    }

    /// The membership decides, so the shell with no label goes too and the
    /// Terminal in the main checkout stays.
    @Test func removalEndsEachTerminalOfTheWorkspaceBeforeGitRemovesTheCheckout() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let seen = Noted()
        await fixture.services.observeGit { [transport = fixture.transport] command in
            if command.arguments.starts(with: ["worktree", "remove"]) {
                seen.note(await transport.kills)
            }
        }

        let request = try await fixture.removalAfterHearing()
        let receipt = try await fixture.store.removeWorktree(request, on: fixture.host.id)

        #expect(seen.value?.sorted() == ["t1", "t2", "t3"])
        #expect(await fixture.transport.kills.sorted() == ["t1", "t2", "t3"])
        #expect(await fixture.transport.mutations == ["terminal.kill", "terminal.kill", "terminal.kill"])
        #expect(await fixture.git("worktree") == [
            GitCommand(
                arguments: ["worktree", "remove", Self.linked], directory: Self.main, isMutation: true)
        ])
        #expect(receipt.affectedAgentIDs == [ConsoleAgent.ID(hostID: fixture.host.id, paneID: "t1")])
        #expect(fixture.store.removedWorktreesByAgent[
            ConsoleAgent.ID(hostID: fixture.host.id, paneID: "t1")] == receipt)
    }

    @Test(arguments: [
        (false, false, false),
        (true, false, true),
        (false, true, true),
        (true, true, true),
    ])
    func removalForcesOnlyForChangesOrSubmodules(
        changes: Bool, submodule: Bool, forced: Bool
    ) async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        if changes { await fixture.setChanges() }
        if submodule { await fixture.setSubmodule() }

        let request = try await fixture.removalAfterHearing()
        _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)

        #expect(await fixture.git("worktree").map(\.arguments) == [
            ["worktree", "remove"] + (forced ? ["--force"] : []) + [Self.linked]
        ])
    }

    /// `git submodule status` fails on a submodule it cannot map, which still counts.
    @Test func aSubmoduleGitCannotMapStillForces() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.services.setGitAnswer(
            .success(GitCommandResult(status: 128, output: "", message: "fatal: no submodule mapping")),
            for: ["submodule", "status"])

        let request = try await fixture.removalAfterHearing()
        _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)

        #expect(await fixture.git("worktree", "remove").first?.arguments.contains("--force") == true)
    }

    @Test func theBranchIsNeverDeleted() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setChanges()

        let request = try await fixture.removalAfterHearing()
        _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)

        let commands = await fixture.services.gitCommands.map(\.arguments)
        #expect(!commands.contains { $0.first == "branch" || $0.contains("-D") || $0.contains("-d") })
        #expect(!commands.contains { $0.contains("feature/login") })
    }

    @Test(arguments: [
        Result<JSONValue, any Error>.failure(TransportError.coreMutationOutcomeUnknown),
        .failure(HerdrAPIError(code: "denied", message: "no")),
        .failure(TransportError.timedOut),
        .success(shell("t2", cwd: linked)),
    ])
    func aKillNotConfirmedStopsBeforeGitAndSaysSo(answer: Result<JSONValue, any Error>) async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.transport.setKillAnswer(answer, for: "t2")

        let request = try await fixture.removalAfterHearing()
        await #expect(throws: WorktreeRemovalError.terminalsNotEnded) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }

        #expect(await fixture.git("worktree").isEmpty)
        // Each still got its one kill.
        #expect(await fixture.transport.kills.sorted() == ["t1", "t2", "t3"])
        #expect(fixture.store.removedWorktreesByAgent.isEmpty)
    }

    @Test func detailShowsAnUnconfirmedKillAndMayTryAgain() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.transport.setKillAnswer(.failure(TransportError.coreMutationOutcomeUnknown), for: "t2")
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        let begun = try #require(detail.beginRemoval())

        await detail.finishRemoval(begun)

        #expect(detail.removalPhase == .failed(WorktreeRemovalError.terminalsNotEnded.message))
        #expect(detail.showsFeedback)
        detail.dismissFeedback()
        #expect(detail.canRemove)
    }

    /// What was killed is gone from the inventory, and the Workspace with it, so
    /// the retry cannot be found by a Workspace any more.
    @Test func aRetryAfterGitRefusedStillRemovesWhenNoTerminalIsLeft() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let refused = ["worktree", "remove", Self.linked]
        await fixture.services.setGitAnswer(
            .success(GitCommandResult(status: 128, output: "", message: "fatal: busy")), for: refused)

        let request = try await fixture.removalAfterHearing()
        await #expect(throws: WorktreeRemovalError.removeRefused("fatal: busy")) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }
        #expect(await fixture.transport.kills.count == 3)

        await fixture.transport.setKillAnswer(.failure(TransportError.timedOut), for: "t1")
        await fixture.services.setGitAnswer(
            .success(GitCommandResult(status: 0, output: "", message: nil)), for: refused)
        for (index, address) in ["t1", "t2", "t3"].enumerated() {
            await fixture.transport.deliver(Self.finished(sequence: 2 + index, terminal: address))
        }
        try await fixture.until("the Workspace to go") {
            !fixture.store.workspaces(for: fixture.host.id).contains { $0.id == Self.workspace }
        }

        let receipt = try await fixture.store.removeWorktree(request, on: fixture.host.id)

        #expect(receipt.affectedAgentIDs == [ConsoleAgent.ID(hostID: fixture.host.id, paneID: "t1")])
        #expect(await fixture.transport.kills.count == 3)
        #expect(await fixture.git("worktree", "remove").count == 2)
    }

    private static func finished(sequence: Int, terminal: String) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string("finished"),
                "terminal": .string(terminal),
                "data": .object([
                    "reason": .string("killed"), "exit_code": .null, "signal": .number(1),
                    "finished_ms": .number(5),
                ]),
            ]),
        ]))) ?? Data()
    }

    @Test func aRemoveNobodyConfirmedIsSentOnceAndSaysWhatToCheck() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.services.setGitAnswer(
            .failure(TransportError.gitTimedOut), for: ["worktree", "remove", Self.linked])

        let request = try await fixture.removalAfterHearing()
        await #expect(throws: WorktreeRemovalError.removeUnconfirmed(path: Self.linked)) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }

        #expect(await fixture.git("worktree").count == 1)
    }

    /// The Terminals are still running and the user has not heard, so nothing ends
    /// and nothing is forced. The next confirmation warns, and then it goes ahead.
    @Test func changesTheUserDidNotHearAboutStopTheRemovalUntilTheyHave() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        #expect(detail.confirmation?.message.contains("uncommitted") == false)
        await fixture.setChanges()
        let first = try #require(detail.beginRemoval())

        await detail.finishRemoval(first)

        #expect(detail.removalPhase == .failed(WorktreeRemovalError.changedSinceConfirmation.message))
        #expect(await fixture.transport.kills.isEmpty)
        #expect(await fixture.git("worktree").isEmpty)

        detail.dismissFeedback()
        detail.prepareConfirmation()
        #expect(detail.confirmation?.message.contains("Its uncommitted changes will be lost.") == true)
        let second = try #require(detail.beginRemoval())
        await detail.finishRemoval(second)

        #expect(await fixture.git("worktree", "remove").map(\.arguments) == [
            ["worktree", "remove", "--force", Self.linked]
        ])
    }

    @Test func theConfirmationNamesSubmodulesAndKeepsTheBranch() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setSubmodule()
        await fixture.services.setGitAnswer(
            .success(
                GitCommandResult(
                    status: 0,
                    output: """
                        worktree \(Self.main)
                        branch refs/heads/main

                        worktree \(Self.linked)
                        branch refs/heads/feature/login

                        """, message: nil)),
            for: HerdrCoreWorktrees.listArguments)
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)

        await detail.loadBranchIfNeeded()
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()

        #expect(detail.branch == .named("feature/login"))
        let message = try #require(detail.confirmation?.message)
        #expect(message.contains("The local branch feature/login is kept."))
        #expect(message.contains("Its submodules go with it"))
        #expect(!message.contains("uncommitted"))
    }

    /// A confirmation can only warn of what has been read, so a tap that comes
    /// first does nothing, as Enter does in the desktop app's mod.
    @Test func removeWaitsForTheReadOfWhatItWouldLose() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setChanges()
        let request = try await fixture.removal()
        let held = ScriptedTransportCallGate()
        let store = fixture.store
        let hostID = fixture.host.id
        let detail = makeDetail(fixture, request: request) {
            await held.waitUntilOpen()
            return try await store.worktreeRemovalRisk($0, on: hostID)
        }
        let reading = Task { await detail.loadRemovalRiskIfNeeded() }
        await held.waitForEntry()

        #expect(!detail.canRemove)
        detail.prepareConfirmation()
        #expect(detail.confirmation == nil)

        await held.open()
        await reading.value

        #expect(detail.canRemove)
        detail.prepareConfirmation()
        #expect(detail.confirmation?.message.contains("Its uncommitted changes will be lost.") == true)
        let begun = try #require(detail.beginRemoval())
        await detail.finishRemoval(begun)
        #expect(await fixture.git("worktree", "remove").map(\.arguments) == [
            ["worktree", "remove", "--force", Self.linked]
        ])
    }

    /// What an earlier sheet read was never promised to this one, so a read that
    /// fails here leaves a confirmation that warned of nothing, and that covers
    /// nothing.
    @Test(arguments: [TransportError.timedOut, .cancelled])
    func aLaterSheetWhoseReadFailedForcesNothing(failure: TransportError) async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setChanges()
        let request = try await fixture.removal()
        let earlier = makeDetail(fixture, request: request)
        await earlier.loadRemovalRiskIfNeeded()
        earlier.prepareConfirmation()
        #expect(earlier.confirmation?.message.contains("uncommitted") == true)
        earlier.cancelConfirmation()

        let later = makeDetail(fixture, request: request) { _ in throw failure }
        await later.loadRemovalRiskIfNeeded()
        #expect(later.canRemove)
        later.prepareConfirmation()
        #expect(later.confirmation?.message.contains("uncommitted") == false)
        let begun = try #require(later.beginRemoval())
        await later.finishRemoval(begun)

        #expect(later.removalPhase == .failed(WorktreeRemovalError.changedSinceConfirmation.message))
        #expect(await fixture.transport.kills.isEmpty)
        #expect(await fixture.git("worktree").isEmpty)
    }

    /// Reading says nothing of what any confirmation showed.
    @Test func aReadNoConfirmationShowedCoversNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setChanges()
        let request = try await fixture.removal()
        _ = try await fixture.store.worktreeRemovalRisk(request, on: fixture.host.id)

        await #expect(throws: WorktreeRemovalError.changedSinceConfirmation) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }

        #expect(await fixture.transport.kills.isEmpty)
        #expect(await fixture.git("worktree").isEmpty)
    }

    /// The sheet's task ended with the read unanswered, so its next one asks again.
    @Test func aReadLeftBehindWithItsSheetIsMadeAgain() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setChanges()
        let request = try await fixture.removal()
        let held = ScriptedTransportCallGate()
        let store = fixture.store
        let hostID = fixture.host.id
        let detail = makeDetail(fixture, request: request) {
            await held.waitUntilOpen()
            return try await store.worktreeRemovalRisk($0, on: hostID)
        }
        let leftBehind = Task { await detail.loadRemovalRiskIfNeeded() }
        await held.waitForEntry()
        leftBehind.cancel()
        await held.open()
        await leftBehind.value

        #expect(!detail.canRemove)

        await detail.loadRemovalRiskIfNeeded()

        #expect(detail.canRemove)
        detail.prepareConfirmation()
        #expect(detail.confirmation?.message.contains("Its uncommitted changes will be lost.") == true)
    }

    private func makeDetail(
        _ fixture: Fixture, request: WorktreeRemovalRequest,
        readRisk: ((WorktreeRemovalRequest) async throws -> WorktreeRemovalRisk?)? = nil,
        otherWorkspaces: (() -> [String])? = nil
    ) -> WorktreeDetailStore {
        let store = fixture.store
        let hostID = fixture.host.id
        return WorktreeDetailStore(
            request: request, workspaceLabel: "feature-login",
            checkout: RepositoryCheckout(
                repoKey: Self.main, repoName: "app", repoRoot: Self.main, checkoutPath: Self.linked,
                isLinkedWorktree: true),
            sessionName: "default",
            list: { try await store.listWorktrees(forWorkspaceID: $0, on: hostID) },
            remove: { try await store.removeWorktree($0, on: hostID) },
            hasWorkingAgent: { false },
            readRemovalRisk: readRisk ?? { try await store.worktreeRemovalRisk($0, on: hostID) },
            otherWorkspaces: otherWorkspaces)
    }

    /// git has the last word on what the path is, however the row reads.
    @Test(arguments: [
        HostCheckout(root: linked, mainCheckout: main),
        HostCheckout(root: linked, mainCheckout: "/work/other", isLinkedWorktree: true),
        HostCheckout(root: "/elsewhere", mainCheckout: main, isLinkedWorktree: true),
    ])
    func aPathThatIsNoLongerThatWorktreeEndsNothing(now: HostCheckout) async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let request = try await fixture.removalAfterHearing()
        await fixture.services.setCheckouts([Self.linked: now])

        await #expect(throws: WorktreeRemovalError.staleIdentity) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }

        #expect(await fixture.transport.kills.isEmpty)
        #expect(await fixture.git("worktree").isEmpty)
    }

    @Test func aDetailsRemovalEndsNothingOnceAnotherCoreServesTheAddress() async throws {
        let fixture = try await Fixture(terminals: [Self.agent("t1", cwd: Self.main)])
        defer { fixture.finish() }
        try await fixture.until("the row's checkout") {
            fixture.store.agents.first?.repositoryCheckout != nil
        }
        let row = try #require(fixture.store.agents.first)
        let checkout = try #require(row.repositoryCheckout)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: fixture.host.id, workspaceID: row.agent.workspaceID, checkout: checkout))
        let pin = fixture.store.composerSession(for: row).corePin

        await fixture.transport.setCoreID("c2")
        await fixture.transport.endLink()
        try await fixture.until("the new core's snapshot") {
            fixture.store.hostCores[fixture.host.id] == "c2"
        }

        await #expect(throws: TransportError.herdrCoreTerminalGone) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id, keepingTo: pin)
        }
        #expect(await fixture.transport.kills.isEmpty)
        #expect(
            WorktreeRemovalRefusal(TransportError.herdrCoreTerminalGone, request: request, sessionName: "").message
                == "This Terminal belongs to a core that is gone: Nothing was sent. Open it again from the list.")
    }

    @Test func aMainCheckoutIsNeverRemoved() async throws {
        let fixture = try await Fixture(terminals: [Self.agent("t1", cwd: Self.main)])
        defer { fixture.finish() }
        try await fixture.until("the row's checkout") {
            fixture.store.agents.first?.repositoryCheckout != nil
        }
        let row = try #require(fixture.store.agents.first)
        #expect(!row.isLinkedWorktree)
        let checkout = try #require(row.repositoryCheckout)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: fixture.host.id, workspaceID: row.agent.workspaceID, checkout: checkout))

        await #expect(throws: WorktreeRemovalError.staleIdentity) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }

        #expect(await fixture.transport.kills.isEmpty)
    }

    @Test func withNoInventoryNothingEnds() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let request = try await fixture.removalAfterHearing()
        await fixture.store.suspend()
        try await fixture.until("the inventory to go") {
            fixture.store.hostsAwaitingSnapshot.contains(fixture.host.id)
        }

        await #expect(throws: TransportError.self) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }

        #expect(await fixture.transport.kills.isEmpty)
        #expect(await fixture.git("worktree").isEmpty)
    }

    @Test func aSecondRemovalOfTheSameWorktreeWaitsForNothingAndChangesNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let request = try await fixture.removalAfterHearing()
        let held = ScriptedTransportCallGate()
        let changes = Task { [gate = fixture.store.gitExecGate(for: fixture.host.id)] in
            try await gate.run { await held.waitUntilOpen() }
        }
        await held.waitForEntry()
        let hostID = fixture.host.id
        let first = Task { [store = fixture.store] in try await store.removeWorktree(request, on: hostID) }
        try await Task.sleep(for: .milliseconds(20))

        await #expect(throws: WorktreeRemovalError.alreadyInProgress) {
            _ = try await fixture.store.removeWorktree(
                WorktreeRemovalRequest(identity: request.identity), on: hostID)
        }

        await held.open()
        try await changes.value
        _ = try await first.value
        #expect(await fixture.git("worktree", "remove").count == 1)
    }

    /// A Terminal that joined while the kills were on their way would otherwise
    /// keep running in the deleted folder.
    @Test func aTerminalThatJoinsDuringTheKillsEndsToo() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let request = try await fixture.removalAfterHearing()
        let store = fixture.store
        await fixture.transport.observeKill { [transport = fixture.transport] address in
            guard address == "t1" else { return }
            await transport.deliver(
                Self.created(
                    sequence: 2, Self.shell("t4", cwd: Self.linked, labels: Self.labels)))
            for _ in 0..<500 {
                if await MainActor.run(body: { store.terminals.contains { $0.paneID == "t4" } }) { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)

        #expect(await fixture.transport.kills.contains("t4"))
        #expect(await fixture.git("worktree", "remove").count == 1)
    }

    /// Not knowing what would be lost is no reason to lose it.
    @Test func aRefusalOfTheStatusReadEndsNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let request = try await fixture.removal()
        await fixture.services.setGitAnswer(
            .success(GitCommandResult(status: 128, output: "", message: "fatal: broken")),
            for: ["status", "--porcelain"])

        await #expect(throws: WorktreeRemovalError.riskUnread("fatal: broken")) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }

        #expect(await fixture.transport.kills.isEmpty)
    }

    /// The Terminals are all still running, whatever the alert says of them.
    @Test func aStatusReadThatFailsSaysNoTerminalEnded() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        await fixture.services.setGitAnswer(
            .success(GitCommandResult(status: 128, output: "", message: "fatal: broken")),
            for: ["status", "--porcelain"])
        let begun = try #require(detail.beginRemoval())

        await detail.finishRemoval(begun)

        guard case .failed(let message) = detail.removalPhase else {
            Issue.record("The removal ended as \(detail.removalPhase)")
            return
        }
        #expect(!message.contains("have ended"))
        #expect(message.contains("ended no Terminal"))
        #expect(message.contains("fatal: broken"))
        #expect(await fixture.transport.kills.isEmpty)
    }

    // MARK: Other Workspaces on the checkout

    /// A removal ends one Workspace (ADR 0032), so the others on the checkout are
    /// named rather than ended on the user's behalf.
    @Test func theConfirmationNamesAnotherWorkspaceOnTheCheckoutAndLeavesItRunning() async throws {
        let fixture = try await Fixture(terminals: Self.worktreeInventory + [Self.shell("t7", cwd: Self.linked)])
        defer { fixture.finish() }
        let request = try await fixture.removal()
        try await fixture.until("the other Workspace") {
            fixture.store.workspaces(for: fixture.host.id).filter {
                $0.checkoutPath == Self.linked
            }.count == 2
        }
        let store = fixture.store
        let detail = makeDetail(
            fixture, request: request,
            otherWorkspaces: { store.workspaceLabels(sharingCheckoutOf: request.identity) })
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()

        let message = try #require(detail.confirmation?.message)
        #expect(message.contains("also uses this checkout"), "\(message)")
        #expect(message.contains("keep running"))
        #expect(store.workspaceLabels(sharingCheckoutOf: request.identity).count == 1)

        let begun = try #require(detail.beginRemoval())
        await detail.finishRemoval(begun)
        #expect(await !fixture.transport.kills.contains("t7"))
        #expect(await fixture.git("worktree", "remove").count == 1)
    }

    @Test func aWorkspaceAloneOnItsCheckoutNamesNoOther() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        let request = try await fixture.removal()
        let store = fixture.store
        let detail = makeDetail(
            fixture, request: request,
            otherWorkspaces: { store.workspaceLabels(sharingCheckoutOf: request.identity) })
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()

        let message = try #require(detail.confirmation?.message)
        #expect(!message.contains("also use"))
        #expect(!message.contains("keep running"))
    }

    // MARK: With the sheet gone

    private func reporter(_ fixture: Fixture) -> ((String) -> Void)? {
        fixture.store.outcomeReporter(on: fixture.host.id, title: "Couldn't Remove Worktree")
    }

    /// The link drops, which takes Agent detail and its sheet away, and the kill
    /// then comes back unanswered. What stopped still has to be said.
    @Test func aRemovalThatStopsAfterItsSheetLeftTellsTheConsole() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.transport.setKillAnswer(.failure(TransportError.coreMutationOutcomeUnknown), for: "t2")
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        let begun = try #require(detail.beginRemoval())
        detail.didLeaveScreen(reportingTo: reporter(fixture))

        await detail.finishRemoval(begun)

        let notice = try #require(fixture.store.outcomeNotices.first)
        #expect(fixture.store.outcomeNotices.count == 1)
        #expect(notice.title == "Couldn't Remove Worktree")
        #expect(notice.message == WorktreeRemovalError.terminalsNotEnded.message)
        #expect(!detail.showsFeedback)

        fixture.store.dismissOutcomeNotice(notice)
        #expect(fixture.store.outcomeNotices.isEmpty)
    }

    /// git's answer lost with the link: the checkout may or may not be there.
    @Test func aRemoveNobodyConfirmedAfterItsSheetLeftSaysWhatToCheck() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.services.setGitAnswer(
            .failure(TransportError.gitTimedOut), for: ["worktree", "remove", Self.linked])
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        let begun = try #require(detail.beginRemoval())
        detail.didLeaveScreen(reportingTo: reporter(fixture))

        await detail.finishRemoval(begun)

        #expect(
            fixture.store.outcomeNotices.map(\.message)
                == [WorktreeRemovalError.removeUnconfirmed(path: Self.linked).message])
    }

    /// The alert was still up when the sheet went, so nobody has read it.
    @Test func aFailureStillOnTheSheetWhenItLeavesTellsTheConsoleOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.transport.setKillAnswer(.failure(TransportError.coreMutationOutcomeUnknown), for: "t2")
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        await detail.finishRemoval(try #require(detail.beginRemoval()))
        #expect(detail.showsFeedback)
        #expect(fixture.store.outcomeNotices.isEmpty)

        detail.didLeaveScreen(reportingTo: reporter(fixture))
        detail.didLeaveScreen(reportingTo: reporter(fixture))

        #expect(fixture.store.outcomeNotices.count == 1)
        #expect(!detail.showsFeedback)
    }

    @Test func aFailureTheUserDismissedTellsTheConsoleNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.transport.setKillAnswer(.failure(TransportError.coreMutationOutcomeUnknown), for: "t2")
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        await detail.finishRemoval(try #require(detail.beginRemoval()))
        detail.dismissFeedback()

        detail.didLeaveScreen(reportingTo: reporter(fixture))

        #expect(fixture.store.outcomeNotices.isEmpty)
    }

    /// A sheet that came back says it itself, and a removal that worked needs no word.
    @Test func aSheetBackOnScreenAndARemovalThatWorkedTellTheConsoleNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.transport.setKillAnswer(.failure(TransportError.coreMutationOutcomeUnknown), for: "t2")
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        let begun = try #require(detail.beginRemoval())
        detail.didLeaveScreen(reportingTo: reporter(fixture))
        detail.didReturnToScreen()

        await detail.finishRemoval(begun)

        #expect(fixture.store.outcomeNotices.isEmpty)
        #expect(detail.showsFeedback)

        let clean = try await Fixture()
        defer { clean.finish() }
        let worked = makeDetail(clean, request: try await clean.removal())
        await worked.loadRemovalRiskIfNeeded()
        worked.prepareConfirmation()
        let removing = try #require(worked.beginRemoval())
        worked.didLeaveScreen(reportingTo: reporter(clean))

        await worked.finishRemoval(removing)

        #expect(clean.store.outcomeNotices.isEmpty)
    }

    /// Herdr TUI settles its own unconfirmed removals on the next snapshot.
    @Test func aHerdrTUIHostHasNoReporter() throws {
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "no link") },
                    keepalive: nil)
            })
        defer { store.setHosts([]) }
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrTUI)
        store.setHosts([host])

        #expect(store.outcomeReporter(on: host.id, title: "x") == nil)
    }

    /// What decides the behaviour above: the view tells the store when its
    /// presenter goes away with the sheet up, as a dropped link does.
    private struct SheetOverDetail: View {
        let presence: SheetPresence
        let detail: WorktreeDetailStore
        let report: ((String) -> Void)?

        var body: some View {
            if presence.isDetailShown {
                Color.clear.sheet(isPresented: .constant(true)) {
                    WorktreeDetailView(store: detail, reportAfterLeaving: report) { _ in }
                }
            } else {
                Color.clear
            }
        }
    }

    @Test func aSheetTakenAwayWithItsPresenterTellsTheConsole() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.transport.setKillAnswer(.failure(TransportError.coreMutationOutcomeUnknown), for: "t2")
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        let presence = SheetPresence()
        let controller = UIHostingController(
            rootView: SheetOverDetail(presence: presence, detail: detail, report: reporter(fixture)))

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            try await fixture.until("the sheet") { controller.presentedViewController != nil }
            let begun = try #require(detail.beginRemoval())
            presence.isDetailShown = false
            try await fixture.until("the sheet to go") { controller.presentedViewController == nil }
            await detail.finishRemoval(begun)
            try await fixture.until("the notice") { !fixture.store.outcomeNotices.isEmpty }
        }

        #expect(
            fixture.store.outcomeNotices.map(\.message) == [WorktreeRemovalError.terminalsNotEnded.message])
    }

    // MARK: What the Terminals leave behind

    private func setDirtyOnKill(_ fixture: Fixture) async {
        await fixture.transport.observeKill { [services = fixture.services] _ in
            await services.setGitAnswer(
                .success(GitCommandResult(status: 0, output: "?? new.txt\n", message: nil)),
                for: ["status", "--porcelain"])
        }
    }

    /// The confirmation warned of submodules only, so `--force` may not take what
    /// an Agent wrote on its way out.
    @Test func changesLeftByTheEndingTerminalsStopAForcedRemoval() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setSubmodule()
        await setDirtyOnKill(fixture)
        let request = try await fixture.removalAfterHearing()
        #expect(request.toldRisk == WorktreeRemovalRisk(hasChanges: false, hasSubmodules: true))

        await #expect(throws: WorktreeRemovalError.changedWhileTerminalsEnded) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }

        #expect(await fixture.transport.kills.sorted() == ["t1", "t2", "t3"])
        #expect(await fixture.git("worktree").isEmpty)
        #expect(fixture.store.removedWorktreesByAgent.isEmpty)
    }

    /// The Terminals did end, and the next confirmation warns of what is there now.
    @Test func changesLeftByTheEndingTerminalsAreWarnedOfByTheNextConfirmation() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setSubmodule()
        let request = try await fixture.removal()
        let detail = makeDetail(fixture, request: request)
        await detail.loadRemovalRiskIfNeeded()
        detail.prepareConfirmation()
        #expect(detail.confirmation?.message.contains("uncommitted") == false)
        await setDirtyOnKill(fixture)
        let first = try #require(detail.beginRemoval())

        await detail.finishRemoval(first)

        guard case .failed(let message) = detail.removalPhase else {
            Issue.record("The removal ended as \(detail.removalPhase)")
            return
        }
        #expect(message.contains("Terminals have ended"))
        #expect(message.contains("was not removed"))
        #expect(detail.refusalOffersChanges == false)
        #expect(await fixture.git("worktree").isEmpty)

        detail.dismissFeedback()
        detail.prepareConfirmation()
        #expect(detail.confirmation?.message.contains("Its uncommitted changes will be lost.") == true)
        let second = try #require(detail.beginRemoval())
        await detail.finishRemoval(second)

        #expect(await fixture.git("worktree", "remove").map(\.arguments) == [
            ["worktree", "remove", "--force", Self.linked]
        ])
    }

    /// What was there when the user heard has gone by the end, so nothing forces.
    @Test func changesGoneByTheTimeTheTerminalsEndForceNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setChanges()
        let request = try await fixture.removalAfterHearing()
        await fixture.transport.observeKill { [services = fixture.services] _ in
            await services.setGitAnswer(
                .success(GitCommandResult(status: 0, output: "", message: nil)),
                for: ["status", "--porcelain"])
        }

        _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)

        #expect(await fixture.git("worktree", "remove").map(\.arguments) == [
            ["worktree", "remove", Self.linked]
        ])
    }

    /// A read that fails once the Terminals have ended leaves nothing to force on.
    @Test(arguments: [
        Result<GitCommandResult, any Error>.success(
            GitCommandResult(status: 128, output: "", message: "fatal: broken")),
        .failure(TransportError.gitTimedOut),
    ])
    func aReadThatFailsOnceTheTerminalsEndedRemovesNothing(
        answer: Result<GitCommandResult, any Error>
    ) async throws {
        let fixture = try await Fixture()
        defer { fixture.finish() }
        await fixture.setSubmodule()
        let request = try await fixture.removalAfterHearing()
        await fixture.transport.observeKill { [services = fixture.services] _ in
            await services.setGitAnswer(answer, for: ["status", "--porcelain"])
        }

        let thrown = await #expect(throws: WorktreeRemovalError.self) {
            _ = try await fixture.store.removeWorktree(request, on: fixture.host.id)
        }

        #expect(thrown?.message.contains("Terminals have ended") == true)
        #expect(await fixture.git("worktree").isEmpty)
    }
}

/// Whether Agent detail is still there to present the Worktree sheet.
@MainActor @Observable
private final class SheetPresence {
    var isDetailShown = true
}

/// What a Herdr TUI Host's confirmation keeps saying, with no risk to warn of.
@Suite struct WorktreeRemovalRiskTests {
    @Test func coveredOnlyByWhatTheUserHeard() {
        let clean = WorktreeRemovalRisk(hasChanges: false, hasSubmodules: false)
        let changes = WorktreeRemovalRisk(hasChanges: true, hasSubmodules: false)
        let submodules = WorktreeRemovalRisk(hasChanges: false, hasSubmodules: true)
        #expect(clean.isCovered(by: nil))
        #expect(!changes.isCovered(by: nil))
        #expect(!changes.isCovered(by: clean))
        #expect(!changes.isCovered(by: submodules))
        #expect(changes.isCovered(by: changes))
        #expect(!clean.requiresForce)
        #expect(changes.requiresForce)
        #expect(submodules.requiresForce)
    }

    @Test func withNoRiskTheConfirmationWarnsOfNothing() {
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: UUID(), workspaceID: "w",
                checkout: RepositoryCheckout(
                    repoKey: "k", repoName: "n", repoRoot: "/r", checkoutPath: "/c",
                    isLinkedWorktree: true)))
        let message = WorktreeRemovalConfirmation.make(
            request: request, workspaceLabel: "w", branch: .detached, hasWorkingAgent: false
        ).message
        #expect(!message.contains("uncommitted"))
        #expect(!message.contains("submodule"))
    }
}
