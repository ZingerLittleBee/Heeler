import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// New-agent form logic (#12, #97, #230) against scripted discovery and start
/// closures: argument parsing, Host/workspace/Agent selection, param assembly,
/// and outcome mapping — no SSH, no ConsoleStore.
@MainActor
@Suite("Start agent store")
struct StartAgentStoreTests {
    /// Records the starts the store dispatches and scripts their outcome.
    @MainActor
    private final class StartRecorder {
        var params: [AgentLaunchRequest] = []
        var destinations: [StartAgentStore.LaunchDestination] = []
        /// One entry per start, aligned with `params`; nil is a plain
        /// workspace launch, non-nil the fresh-worktree variant (#97).
        var worktrees: [WorktreeSpec?] {
            destinations.map {
                if case .newWorktree(let spec) = $0 { return spec }
                return nil
            }
        }
        var hostIDs: [Host.ID] = []
        var error: (any Error)?
        var agent = Agent(.fixture(paneID: "w1:pnew", status: .working))
        var gate: ScriptedTransportCallGate?

        func record(
            _ params: AgentLaunchRequest,
            _ destination: StartAgentStore.LaunchDestination,
            _ hostID: Host.ID
        ) async throws -> Agent {
            self.params.append(params)
            destinations.append(destination)
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
        awaitAgentVisible: @escaping (ConsoleAgent.ID) async -> Void = { _ in },
        origin: StartAgentStore.LaunchOrigin? = nil,
        recents: RecentWorkspaceStore? = nil,
        recorder: StartRecorder
    ) -> StartAgentStore {
        StartAgentStore(
            hosts: hosts, workspaces: workspaces,
            existingAgentNames: existingAgentNames,
            discoverAgentKinds: agentKinds,
            start: { params, destination, hostID in
                try await recorder.record(params, destination, hostID)
            },
            awaitAgentVisible: awaitAgentVisible,
            origin: origin,
            recents: recents ?? makeRecents())
    }

    /// The `.started` state a default-recorder submit lands in: the recorder's
    /// fixture pane on the submitting Host.
    private func started(on host: Host, paneID: String = "w1:pnew") -> StartAgentStore.State {
        .started(ConsoleAgent.ID(hostID: host.id, paneID: paneID))
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

    @Test func smartPunctuationNormalizesBackToASCII() {
        // The iOS keyboard rewrites "--" to an em dash and quotes to curly
        // variants even with autocorrection disabled. The editor prevents the
        // rewrite, and parsing remains defensive for pasted text.
        #expect(StartAgentStore.normalizeSmartPunctuation("\u{2014}yolo") == "--yolo")
        #expect(StartAgentStore.normalizeSmartPunctuation("\u{2013}v") == "-v")
        #expect(
            StartAgentStore.normalizeSmartPunctuation(
                "--label \u{201C}code review\u{201D} \u{2018}x\u{2019}")
                == #"--label "code review" 'x'"#)
        #expect(StartAgentStore.normalizeSmartPunctuation("--plain 'ascii'") == "--plain 'ascii'")
    }

    @Test func editingArgumentsDefersSmartPunctuationNormalizationUntilParsing() {
        let store = makeStore(hosts: [.fixture()], recorder: StartRecorder())
        store.arguments = "\u{2014}yolo --label \u{201C}code review\u{201D}"

        #expect(store.arguments == "\u{2014}yolo --label \u{201C}code review\u{201D}")
        #expect(store.parsedArguments == .success(["--yolo", "--label", "code review"]))
    }

    @Test func argumentEditorDisablesEverySmartPunctuationTrait() {
        let textView = UITextView()

        AgentArgumentsTextView.configure(textView)

        #expect(textView.autocapitalizationType == .none)
        #expect(textView.autocorrectionType == .no)
        #expect(textView.spellCheckingType == .no)
        #expect(textView.smartDashesType == .no)
        #expect(textView.smartQuotesType == .no)
        #expect(textView.smartInsertDeleteType == .no)
    }

    @Test func argumentEditorAtomicallyRejectsASmartDashReplacement() {
        let recorder = TextBindingRecorder()
        let coordinator = AgentArgumentsTextView.Coordinator(text: recorder.binding)
        let textView = UITextView()
        textView.text = "--"

        let accepted = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 0, length: 2),
            replacementText: "\u{2014}")

        #expect(!accepted)
        #expect(textView.text == "--")
        #expect(recorder.value == "--")
        #expect(textView.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test func argumentParserReportsIncompleteAndUnsafeInput() {
        #expect(StartAgentStore.parseArguments(#""unfinished"#) == .failure(.unclosedDoubleQuote))
        #expect(StartAgentStore.parseArguments("'unfinished") == .failure(.unclosedSingleQuote))
        #expect(StartAgentStore.parseArguments(#"--flag\"#) == .failure(.danglingEscape))
        #expect(StartAgentStore.parseArguments("\"line\nbreak\"") == .failure(.controlCharacter))
    }

    @MainActor
    private final class TextBindingRecorder {
        var value = ""

        var binding: Binding<String> {
            Binding(
                get: { self.value },
                set: { self.value = $0 })
        }
    }

    @Test func supportedAgentCatalogListsKnownKinds() {
        #expect(SupportedAgentKind.allCases.map(\.rawValue) == [
            "pi", "claude", "codex", "gemini", "cursor", "devin", "agy",
            "cline", "omp", "mastracode", "opencode", "copilot", "kimi",
            "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli",
            "maki", "qwen",
        ])
        #expect(SupportedAgentKind.qwen.rawValue == "qwen")
        #expect(SupportedAgentKind.qwen.displayName == "Qwen Code")
        #expect(SupportedAgentKind.qwen.executable == "qwen")
        #expect(SupportedAgentKind.cursor.executable == "cursor-agent")
        #expect(SupportedAgentKind.kiro.executable == "kiro-cli")
        #expect(
            SupportedAgentKind.allCases
                .filter { $0 != .cursor && $0 != .kiro }
                .allSatisfy { $0.executable == $0.rawValue })
    }

    @Test func agentDiscoveryCommandPrintsQwenWhenOnPath() {
        let command = SSHTransportSettings.defaultAgentDiscoveryCommand
        #expect(
            command.contains(
                "command -v qwen >/dev/null 2>&1"
                    + " && printf \"__HEELER_AGENT_KIND__=%s\\n\" \"qwen\""))
    }

    @Test func agentDiscoveryParsesQwenAndDropsUnknownKinds() {
        let output = """
            Welcome to the Host
            gemini
            __HEELER_AGENT_KIND__=qwen
            __HEELER_AGENT_KIND__=notarealagent
            __HEELER_AGENT_KIND__=qwen
            last login: never
            """
        #expect(SSHTransportSettings.discoveredAgentKinds(from: output) == [.qwen])
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

        #expect(store.state == started(on: host))
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

        #expect(store.state == started(on: host))
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

        #expect(store.launchTarget == .existingWorkspace)
        #expect(store.canSubmit == false)
        await store.submit()
        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)
    }

    @Test func newWorkspaceCanSubmitWithZeroReportedWorkspaces() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(hosts: [host], recorder: recorder)
        await store.discoverAgents()

        #expect(store.canSubmit == false)
        store.launchTarget = .newWorkspace
        #expect(store.canSubmit == false)
        store.newWorkspaceDirectory = "   "
        #expect(store.canSubmit == false)
        store.newWorkspaceDirectory = "  /home/you/src/app  "
        #expect(store.canSubmit == true)

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.first?.workspaceID == nil)
        #expect(recorder.params.first?.cwd == nil)
        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/home/you/src/app"))])
    }

    @Test func newWorkspaceTrimsDirectoryAndDropsAnEmptyLabel() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        await store.discoverAgents()
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "\n /tmp/project \t"
        store.newWorkspaceLabel = "   "

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.first?.workspaceID == nil)
        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/tmp/project", label: nil))])
    }

    @Test func newWorkspaceSubmitRemembersTheReturnedWorkspaceAndWaits() async throws {
        let host = Host.fixture()
        let recents = makeRecents()
        let recorder = StartRecorder()
        recorder.agent = Agent(
            .fixture(paneID: "nw1:pnew", status: .working, workspaceID: "nw1"))
        let visibilityGate = ScriptedTransportCallGate()
        final class SeenBox { var ids: [ConsoleAgent.ID] = [] }
        let seen = SeenBox()
        let store = makeStore(
            hosts: [host],
            awaitAgentVisible: { id in
                seen.ids.append(id)
                await visibilityGate.waitUntilOpen()
            },
            recents: recents,
            recorder: recorder)
        await store.discoverAgents()
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "/src/app"
        store.newWorkspaceLabel = "  App  "

        let submit = Task { await store.submit() }
        try await waitUntil("the visibility wait should begin") {
            await visibilityGate.entryCount == 1
        }
        #expect(store.state == .starting)

        await visibilityGate.open()
        await submit.value

        #expect(store.state == started(on: host, paneID: "nw1:pnew"))
        #expect(seen.ids == [ConsoleAgent.ID(hostID: host.id, paneID: "nw1:pnew")])
        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/src/app", label: "App"))])

        let next = makeStore(
            hosts: [host],
            workspaces: { _ in
                [ConsoleWorkspace(id: "w1", label: "Old"),
                    ConsoleWorkspace(id: "nw1", label: "App")]
            },
            recents: recents,
            recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "nw1")
    }

    @Test func newWorkspaceServerRejectionUsesExistingErrorPresentation() async {
        let host = Host.fixture()
        let recents = makeRecents()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "cwd_not_found", message: "no such directory")
        let store = makeStore(hosts: [host], recents: recents, recorder: recorder)
        await store.discoverAgents()
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "/missing"

        await store.submit()

        #expect(store.state == .failed("herdr rejected the command: no such directory"))
        let next = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recents: recents,
            recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "w1")
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

        #expect(store.state == started(on: host))
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
        #expect(first.state == started(on: host))

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
        store.arguments = #"—yolo --continue --label "code review""#
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.hostIDs == [host.id])
        #expect(recorder.params.first?.kind == "claude")
        #expect(recorder.params.first?.name == "reviewer")
        #expect(
            recorder.params.first?.arguments
                == ["--yolo", "--continue", "--label", "code review"])
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(recorder.destinations == [.existingWorkspace])
        #expect(recorder.worktrees == [nil])
    }

    @Test func submitDispatchesAgentStartWithQwenKind() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.qwen] },
            recorder: recorder)
        await store.discoverAgents()
        #expect(store.selectedAgentKind == .qwen)

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.first?.kind == "qwen")
    }

    /// Launching from an agent's own screen: Host, workspace, and directory
    /// come from that agent, so the new tab lands beside it rather than at
    /// the workspace root.
    @Test func originLaunchInheritsTheAgentsHostWorkspaceAndDirectory() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host, .fixture(id: UUID(), name: "other")],
            workspaces: { _ in [ConsoleWorkspace(id: "w9", label: "Other")] },
            origin: StartAgentStore.LaunchOrigin(
                hostID: host.id, workspaceID: "w1", cwd: "/Users/dev/proj/api"),
            recorder: recorder)
        // Two Hosts would otherwise leave the picker unset.
        #expect(store.selectedHostID == host.id)
        #expect(store.selectedWorkspaceID == "w1")
        store.name = "reviewer"
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.hostIDs == [host.id])
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(recorder.params.first?.cwd == "/Users/dev/proj/api")
        #expect(recorder.worktrees == [nil])
    }

    /// A worktree launch lands in a brand-new checkout, which contradicts the
    /// inherited directory. The form drops the option, and a stale toggle
    /// cannot smuggle it back in.
    @Test func originLaunchNeverTakesTheWorktreeVariant() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            origin: StartAgentStore.LaunchOrigin(
                hostID: host.id, workspaceID: "w1", cwd: "/Users/dev/proj"),
            recorder: recorder)
        #expect(!store.offersWorktree)
        store.startsInNewWorktree = true
        store.worktreeBranch = "task/fix"
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.worktrees == [nil])
        #expect(recorder.params.first?.cwd == "/Users/dev/proj")
    }

    /// New Workspace would open a different directory and drop the origin
    /// Workspace. The origin flow hides the choice, and forcing the fields
    /// cannot smuggle it onto the request.
    @Test func originLaunchNeverExposesOrTakesNewWorkspace() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            origin: StartAgentStore.LaunchOrigin(
                hostID: host.id, workspaceID: "w1", cwd: "/Users/dev/proj"),
            recorder: recorder)
        #expect(!store.offersNewWorkspace)
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "/tmp/elsewhere"
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.destinations == [.existingWorkspace])
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(recorder.params.first?.cwd == "/Users/dev/proj")
    }

    /// The origin agent proves its workspace exists, so it outranks both the
    /// remembered pick and the snapshot the Host happens to report.
    @Test func originWorkspaceOutranksTheRememberedAndReportedOnes() async {
        let host = Host.fixture()
        let recents = makeRecents()
        recents.remember("w7", for: host.id)
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in
                [ConsoleWorkspace(id: "w7", label: "Remembered")]
            },
            origin: StartAgentStore.LaunchOrigin(
                hostID: host.id, workspaceID: "w1", cwd: "/Users/dev/proj"),
            recents: recents,
            recorder: recorder)

        #expect(store.selectedWorkspaceID == "w1")
        store.selectedWorkspaceID = "w7"
        #expect(store.selectedWorkspaceID == "w1", "the origin workspace is not user-overridable")
    }

    /// Without an origin the launch carries no directory, leaving herdr to
    /// place the tab at the workspace's own.
    @Test func consoleLaunchCarriesNoDirectory() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        await store.submit()

        #expect(store.offersWorktree)
        #expect(recorder.params.first?.cwd == nil)
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

        #expect(store.state == started(on: host))
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(
            recorder.destinations
                == [.newWorktree(WorktreeSpec(branch: "task/fix-97", base: "origin/main"))])
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

        #expect(store.state == started(on: host))
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

    @Test func switchingToNewWorkspaceDropsAnActiveWorktreeRequest() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        await store.discoverAgents()
        store.startsInNewWorktree = true
        store.worktreeBranch = "task/fix"
        store.worktreeBase = "origin/main"
        #expect(store.offersWorktree)

        store.launchTarget = .newWorkspace

        #expect(!store.offersWorktree)
        #expect(store.startsInNewWorktree == false)
        #expect(store.worktreeBranch.isEmpty)
        #expect(store.worktreeBase.isEmpty)
        store.newWorkspaceDirectory = "/src/app"
        await store.submit()

        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/src/app"))])
        #expect(recorder.worktrees == [nil])
        #expect(recorder.params.first?.workspaceID == nil)
    }

    @Test func switchingHostResetsNewWorkspaceFields() {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(hosts: [hostA, hostB], recorder: StartRecorder())
        store.selectedHostID = hostA.id
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "/src/app"
        store.newWorkspaceLabel = "App"

        store.selectedHostID = hostB.id

        #expect(store.launchTarget == .existingWorkspace)
        #expect(store.newWorkspaceDirectory.isEmpty)
        #expect(store.newWorkspaceLabel.isEmpty)
        #expect(store.offersWorktree)
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

        #expect(store.state == started(on: host))
        #expect(store.canDismiss == true)
    }

    /// The owner navigates to the started Agent, so the store stays in
    /// `.starting` until the Console reports the row — and the `.started`
    /// payload names exactly the pane the visibility wait was given.
    @Test func submitAwaitsTheStartedAgentsVisibilityBeforeFinishing() async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let visibilityGate = ScriptedTransportCallGate()
        final class SeenBox { var ids: [ConsoleAgent.ID] = [] }
        let seen = SeenBox()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            awaitAgentVisible: { id in
                seen.ids.append(id)
                await visibilityGate.waitUntilOpen()
            },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        let submit = Task { await store.submit() }
        try await waitUntil("the visibility wait should begin") {
            await visibilityGate.entryCount == 1
        }
        #expect(store.state == .starting)

        await visibilityGate.open()
        await submit.value

        #expect(store.state == started(on: host))
        #expect(seen.ids == [ConsoleAgent.ID(hostID: host.id, paneID: "w1:pnew")])
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
