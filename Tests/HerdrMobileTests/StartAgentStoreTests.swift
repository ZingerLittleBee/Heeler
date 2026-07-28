import Foundation
import Testing

@testable import HerdrMobile

/// New-agent form logic (#12) against scripted discovery and start closures:
/// argument parsing, Host/workspace/Agent selection, param assembly, and outcome
/// mapping — no SSH, no ConsoleStore.
@MainActor
@Suite("Start agent store")
struct StartAgentStoreTests {
    /// Records the starts the store dispatches and scripts their outcome.
    @MainActor
    private final class StartRecorder {
        var params: [AgentLaunchRequest] = []
        /// One entry per start, aligned with `params`; nil is a plain
        /// workspace launch, non-nil the fresh-worktree variant (#97).
        var worktrees: [WorktreeSpec?] = []
        var hostIDs: [Host.ID] = []
        var error: (any Error)?
        var agent = Agent(.fixture(paneID: "w1:pnew", status: .working))
        var gate: ScriptedTransportCallGate?

        func record(
            _ params: AgentLaunchRequest, _ worktree: WorktreeSpec?, _ hostID: Host.ID
        ) async throws -> Agent {
            self.params.append(params)
            worktrees.append(worktree)
            hostIDs.append(hostID)
            await gate?.waitUntilOpen()
            if let error { throw error }
            return agent
        }
    }

    /// A throwaway defaults domain per test, so the remembered-workspace
    /// persistence is real but isolated.
    private func makeRecents() -> RecentWorkspaceStore {
        let name = "recent-workspace-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return RecentWorkspaceStore(defaults: defaults)
    }

    private func makeStore(
        hosts: [Host],
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace] = { _ in [] },
        existingAgentNames: @escaping (Host.ID) -> Set<String> = { _ in [] },
        agentKinds: @escaping (Host.ID) async throws -> [SupportedAgentKind] = { _ in
            [.claude]
        },
        recents: RecentWorkspaceStore? = nil,
        recorder: StartRecorder
    ) -> StartAgentStore {
        StartAgentStore(
            hosts: hosts, workspaces: workspaces,
            existingAgentNames: existingAgentNames,
            discoverAgentKinds: agentKinds,
            start: { params, worktree, hostID in
                try await recorder.record(params, worktree, hostID)
            },
            recents: recents ?? makeRecents())
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    @Test func argumentParserSupportsQuotesEscapesAndEmptyArguments() throws {
        #expect(
            StartAgentStore.parseArguments(
                #" --model "gpt 5" 'literal value' escaped\ value "" prefix" suffix" "#)
                == .success([
                    "--model", "gpt 5", "literal value", "escaped value", "", "prefix suffix",
                ]))
        #expect(try StartAgentStore.parseArguments("   \n ").get() == [])
    }

    @Test func argumentParserReportsIncompleteAndUnsafeInput() {
        #expect(StartAgentStore.parseArguments(#""unfinished"#) == .failure(.unclosedDoubleQuote))
        #expect(StartAgentStore.parseArguments("'unfinished") == .failure(.unclosedSingleQuote))
        #expect(StartAgentStore.parseArguments(#"--flag\"#) == .failure(.danglingEscape))
        #expect(StartAgentStore.parseArguments("\"line\nbreak\"") == .failure(.controlCharacter))
    }

    @Test func supportedAgentCatalogMatchesProtocol17() {
        #expect(SupportedAgentKind.allCases.map(\.rawValue) == [
            "pi", "claude", "codex", "gemini", "cursor", "devin", "agy",
            "cline", "omp", "mastracode", "opencode", "copilot", "kimi",
            "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli",
            "maki",
        ])
        #expect(SupportedAgentKind.cursor.executable == "cursor-agent")
        #expect(SupportedAgentKind.kiro.executable == "kiro-cli")
        #expect(
            SupportedAgentKind.allCases
                .filter { $0 != .cursor && $0 != .kiro }
                .allSatisfy { $0.executable == $0.rawValue })
    }

    @Test func preSelectsTheOnlyHost() {
        let host = Host.fixture()
        let single = makeStore(hosts: [host], recorder: StartRecorder())
        #expect(single.selectedHostID == host.id)

        let many = makeStore(
            hosts: [host, .fixture(address: "b.example")], recorder: StartRecorder())
        #expect(many.selectedHostID == nil)
    }

    @Test func discoveryPublishesHostKindsAndSelectsTheFirst() async {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            agentKinds: { requestedHost in
                #expect(requestedHost == host.id)
                return [.codex, .claude]
            },
            recorder: StartRecorder())

        await store.discoverAgents()

        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.availableAgentKinds == [.codex, .claude])
        #expect(store.selectedAgentKind == .codex)
    }

    @Test func discoverySurfacesFailureAndSupportsAnEmptyResult() async {
        let host = Host.fixture()
        let failing = makeStore(
            hosts: [host],
            agentKinds: { _ in throw TransportError.timedOut },
            recorder: StartRecorder())

        await failing.discoverAgents()
        #expect(failing.agentDiscoveryState == .failed("Agent detection timed out."))
        #expect(failing.availableAgentKinds.isEmpty)

        let empty = makeStore(
            hosts: [host], agentKinds: { _ in [] }, recorder: StartRecorder())
        await empty.discoverAgents()
        #expect(empty.agentDiscoveryState == .loaded)
        #expect(empty.availableAgentKinds.isEmpty)
        #expect(empty.selectedAgentKind == nil)
    }

    @Test func staleDiscoveryCannotOverwriteANewHostSelection() async throws {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let gate = ScriptedTransportCallGate()
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { hostID in
                if hostID == hostA.id {
                    await gate.waitUntilOpen()
                    return [.claude]
                }
                return [.codex]
            },
            recorder: StartRecorder())

        store.selectedHostID = hostA.id
        let stale = Task { await store.discoverAgents() }
        try await waitUntil("the first Host discovery should reach the gate") {
            await gate.entryCount == 1
        }

        store.selectedHostID = hostB.id
        await store.discoverAgents()
        #expect(store.availableAgentKinds == [.codex])
        #expect(store.selectedAgentKind == .codex)

        await gate.open()
        await stale.value
        #expect(store.availableAgentKinds == [.codex])
        #expect(store.selectedAgentKind == .codex)
    }

    @Test func canSubmitRequiresAHostWorkspaceAndDetectedAgent() async {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: {
                $0 == hostA.id ? [ConsoleWorkspace(id: "w1", label: "Proj")] : []
            },
            recorder: StartRecorder())

        #expect(store.canSubmit == false)
        store.selectedHostID = hostA.id
        #expect(store.canSubmit == false)  // Agent discovery has not completed
        await store.discoverAgents()
        #expect(store.canSubmit == true)  // the name is optional
        store.name = "Reviewer"
        #expect(store.canSubmit == false)  // uppercase violates herdr's rule
        store.name = "reviewer"
        #expect(store.canSubmit == true)
        store.arguments = #""unfinished"#
        #expect(store.canSubmit == false)
    }

    @Test func agentNameValidationMirrorsHerdrsRule() {
        #expect(StartAgentStore.agentNameValidationError("a1") == nil)
        #expect(StartAgentStore.agentNameValidationError("code-reviewer_2") == nil)
        #expect(StartAgentStore.agentNameValidationError(String(repeating: "a", count: 32)) == nil)

        #expect(StartAgentStore.agentNameValidationError("Reviewer") != nil)
        #expect(StartAgentStore.agentNameValidationError("1agent") != nil)
        #expect(StartAgentStore.agentNameValidationError("-agent") != nil)
        #expect(StartAgentStore.agentNameValidationError("my agent") != nil)
        #expect(StartAgentStore.agentNameValidationError("agenté") != nil)
        #expect(
            StartAgentStore.agentNameValidationError(String(repeating: "a", count: 33)) != nil)
    }

    @Test func anEmptyNameFallsBackToTheKindSkippingTakenNames() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in ["claude", "claude-2"] },
            recorder: recorder)
        await store.discoverAgents()
        #expect(store.defaultAgentName == "claude-3")

        await store.submit()

        #expect(store.state == .started)
        #expect(recorder.params.map(\.name) == ["claude-3"])
    }

    @Test func aFreshKindNeedsNoSuffix() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in ["reviewer"] },
            recorder: recorder)
        await store.discoverAgents()
        store.name = "   "

        await store.submit()

        #expect(store.state == .started)
        #expect(recorder.params.map(\.name) == ["claude"])
    }

    @Test func anInvalidNameBlocksSubmission() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        await store.discoverAgents()
        store.name = "My Agent"

        #expect(store.nameErrorMessage != nil)
        #expect(store.canSubmit == false)
        await store.submit()
        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)
    }

    @Test func cannotSubmitUntilTheHostReportsAWorkspace() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(hosts: [host], recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        #expect(store.canSubmit == false)
        await store.submit()
        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)
    }

    @Test func switchingHostClearsStaleWorkspaceAndAgentPicks() async {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: {
                $0 == hostA.id
                    ? [ConsoleWorkspace(id: "w1", label: "Proj"),
                        ConsoleWorkspace(id: "w2", label: "Other")]
                    : []
            },
            recorder: StartRecorder())

        store.selectedHostID = hostA.id
        await store.discoverAgents()
        store.selectedWorkspaceID = "w2"
        #expect(store.selectedAgentKind == .claude)
        #expect(store.workspaces.map(\.id) == ["w1", "w2"])

        store.selectedHostID = hostB.id
        #expect(store.selectedWorkspaceID == nil)
        #expect(store.selectedAgentKind == nil)
        #expect(store.agentDiscoveryState == .idle)
        #expect(store.workspaces.isEmpty)
    }

    @Test func defaultsToTheHostsFirstWorkspaceWithNothingRemembered() {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in
                [ConsoleWorkspace(id: "w1", label: "Proj"),
                    ConsoleWorkspace(id: "w2", label: "Other")]
            },
            recorder: StartRecorder())

        #expect(store.selectedWorkspaceID == "w1")
    }

    @Test func fallsBackWhenTheExplicitWorkspaceDisappearsBeforeSubmit() async {
        let host = Host.fixture()
        final class Snapshot {
            var workspaces = [
                ConsoleWorkspace(id: "w1", label: "Proj"),
                ConsoleWorkspace(id: "w2", label: "Other"),
            ]
        }
        let snapshot = Snapshot()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host], workspaces: { _ in snapshot.workspaces }, recorder: recorder)
        store.selectedWorkspaceID = "w2"

        snapshot.workspaces = [ConsoleWorkspace(id: "w1", label: "Proj")]
        store.name = "reviewer"
        await store.discoverAgents()
        await store.submit()

        #expect(store.state == .started)
        #expect(store.selectedWorkspaceID == "w1")
        #expect(recorder.params.map(\.workspaceID) == ["w1"])
    }

    /// The snapshot often lands after the sheet opens; the default has to
    /// follow it rather than latch on the empty list.
    @Test func defaultFollowsAWorkspaceListThatArrivesLate() {
        let host = Host.fixture()
        final class Snapshot { var workspaces: [ConsoleWorkspace] = [] }
        let snapshot = Snapshot()
        let store = makeStore(
            hosts: [host], workspaces: { _ in snapshot.workspaces }, recorder: StartRecorder())

        #expect(store.selectedWorkspaceID == nil)
        snapshot.workspaces = [ConsoleWorkspace(id: "w1", label: "Proj")]
        #expect(store.selectedWorkspaceID == "w1")
    }

    @Test func defaultsToTheWorkspaceLastStartedInOnThatHost() async {
        let host = Host.fixture()
        let other = Host.fixture(address: "b.example")
        let recents = makeRecents()
        let workspaces: (Host.ID) -> [ConsoleWorkspace] = { _ in
            [ConsoleWorkspace(id: "w1", label: "Proj"), ConsoleWorkspace(id: "w2", label: "Other")]
        }

        let first = makeStore(
            hosts: [host], workspaces: workspaces, recents: recents, recorder: StartRecorder())
        first.selectedWorkspaceID = "w2"
        first.name = "reviewer"
        await first.discoverAgents()
        await first.submit()
        #expect(first.state == .started)

        let next = makeStore(
            hosts: [host], workspaces: workspaces, recents: recents, recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "w2")

        // Remembered per Host: another Host falls back to its own first.
        let elsewhere = makeStore(
            hosts: [other], workspaces: workspaces, recents: recents, recorder: StartRecorder())
        #expect(elsewhere.selectedWorkspaceID == "w1")
    }

    @Test func ignoresARememberedWorkspaceTheHostNoLongerReports() async {
        let host = Host.fixture()
        let recents = makeRecents()
        let gone = makeStore(
            hosts: [host], workspaces: { _ in [ConsoleWorkspace(id: "w9", label: "Gone")] },
            recents: recents, recorder: StartRecorder())
        gone.name = "reviewer"
        await gone.discoverAgents()
        await gone.submit()

        let next = makeStore(
            hosts: [host], workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recents: recents, recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "w1")
    }

    @Test func aFailedStartIsNotRemembered() async {
        let host = Host.fixture()
        let recents = makeRecents()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "400", message: "no such workspace")
        let workspaces: (Host.ID) -> [ConsoleWorkspace] = { _ in
            [ConsoleWorkspace(id: "w1", label: "Proj"), ConsoleWorkspace(id: "w2", label: "Other")]
        }
        let store = makeStore(
            hosts: [host], workspaces: workspaces, recents: recents, recorder: recorder)
        store.selectedWorkspaceID = "w2"
        store.name = "reviewer"
        await store.discoverAgents()
        await store.submit()

        let next = makeStore(
            hosts: [host], workspaces: workspaces, recents: recents, recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "w1")
    }

    @Test func submitForwardsTheAssembledParamsAndSucceeds() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.selectedWorkspaceID = "w1"
        store.name = "reviewer"
        store.arguments = #"--continue --label "code review""#
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == .started)
        #expect(recorder.hostIDs == [host.id])
        #expect(recorder.params.first?.kind == "claude")
        #expect(recorder.params.first?.name == "reviewer")
        #expect(recorder.params.first?.arguments == ["--continue", "--label", "code review"])
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(recorder.worktrees == [nil])
    }

    @Test func worktreeSubmitForwardsTheTrimmedSpec() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        store.startsInNewWorktree = true
        store.worktreeBranch = "  task/fix-97  "
        store.worktreeBase = " origin/main "
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == .started)
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(recorder.worktrees == [WorktreeSpec(branch: "task/fix-97", base: "origin/main")])
    }

    @Test func worktreeSubmitWithEmptyFieldsUsesHerdrsDefaults() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        store.startsInNewWorktree = true
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == .started)
        #expect(recorder.worktrees == [WorktreeSpec(branch: nil, base: nil)])
    }

    @Test func anInvalidWorktreeBranchBlocksSubmission() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()
        #expect(store.canSubmit == true)

        store.startsInNewWorktree = true
        store.worktreeBranch = "has space"
        #expect(store.worktreeBranchErrorMessage != nil)
        #expect(store.canSubmit == false)
        await store.submit()
        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)

        // The same text is fine while the toggle is off: it never reaches git.
        store.startsInNewWorktree = false
        #expect(store.worktreeBranchErrorMessage == nil)
        #expect(store.canSubmit == true)
    }

    @Test func switchingHostResetsTheWorktreeFields() {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(hosts: [hostA, hostB], recorder: StartRecorder())
        store.selectedHostID = hostA.id
        store.startsInNewWorktree = true
        store.worktreeBranch = "task/fix-97"
        store.worktreeBase = "origin/main"

        store.selectedHostID = hostB.id

        #expect(store.startsInNewWorktree == false)
        #expect(store.worktreeBranch.isEmpty)
        #expect(store.worktreeBase.isEmpty)
    }

    @Test func worktreeFailuresGetFirstClassCopy() async {
        let host = Host.fixture()
        let workspaces: (Host.ID) -> [ConsoleWorkspace] = { _ in
            [ConsoleWorkspace(id: "w1", label: "Proj")]
        }

        // The dedicated code for a non-git workspace cwd.
        let notGit = StartRecorder()
        notGit.error = HerdrAPIError(
            code: "not_git_worktree",
            message: "Herdr worktree actions require a workspace inside a Git work tree")
        let first = makeStore(hosts: [host], workspaces: workspaces, recorder: notGit)
        first.name = "reviewer"
        first.startsInNewWorktree = true
        await first.discoverAgents()
        await first.submit()
        #expect(
            first.state
                == .failed(
                    "This workspace is not inside a Git repository, so no worktree can be created from it."
                ))

        // Everything else collapses into raw git stderr; pass it through.
        let gitFailure = StartRecorder()
        gitFailure.error = HerdrAPIError(
            code: "worktree_create_failed",
            message: "fatal: 'task/fix-97' is already used by worktree at '/w'")
        let second = makeStore(hosts: [host], workspaces: workspaces, recorder: gitFailure)
        second.name = "reviewer"
        second.startsInNewWorktree = true
        await second.discoverAgents()
        await second.submit()
        #expect(
            second.state
                == .failed(
                    "Creating the worktree failed: fatal: 'task/fix-97' is already used by worktree at '/w'"
                ))
    }

    @Test func startInFlightPreventsDismissalAndDuplicateSubmit() async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let gate = ScriptedTransportCallGate()
        recorder.gate = gate
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        let first = Task { await store.submit() }
        try await waitUntil("the first start should reach the gate") {
            await gate.entryCount == 1
        }
        #expect(store.state == .starting)
        #expect(store.canDismiss == false)

        let second = Task { await store.submit() }
        await second.value
        #expect(await gate.entryCount == 1)
        #expect(recorder.params.count == 1)

        await gate.open()
        await first.value

        #expect(store.state == .started)
        #expect(store.canDismiss == true)
    }

    @Test func submitSurfacesAServerRejection() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "400", message: "no such workspace")
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == .failed("herdr rejected the command: no such workspace"))
    }

    @Test func submitIsANoOpWithoutAHostOrDetectedAgent() async {
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [.fixture(address: "a.example"), .fixture(address: "b.example")],
            recorder: recorder)
        await store.submit()

        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)
    }
}
