import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent Detail shell terminal")
struct ShellTerminalStoreTests {
    @Test func creationUsesAgentDirectoryBeforeLinkedWorktreeCheckout() {
        let agent = makeAgent(
            cwd: "/agent/launch",
            checkout: makeCheckout(path: "/worktree/checkout", isLinked: true))

        #expect(
            agent.shellTerminalCreationRequest
                == ShellTerminalCreationRequest(
                    workspaceID: "workspace-1",
                    cwd: "/agent/launch"))
    }

    @Test func creationFallsBackToLinkedWorktreeCheckout() {
        let agent = makeAgent(
            cwd: "",
            checkout: makeCheckout(path: "/worktree/checkout", isLinked: true))

        #expect(
            agent.shellTerminalCreationRequest
                == ShellTerminalCreationRequest(
                    workspaceID: "workspace-1",
                    cwd: "/worktree/checkout"))
    }

    @Test func creationIsUnavailableWithoutAnAbsoluteAgentDirectoryOrLinkedCheckout() {
        #expect(makeAgent(cwd: "relative/path").shellTerminalCreationRequest == nil)
        #expect(
            makeAgent(
                cwd: "",
                checkout: makeCheckout(path: "/main/checkout", isLinked: false)
            )
            .shellTerminalCreationRequest == nil)
    }

    @Test func duplicateInflightOpensCreateExactlyOneTab() async throws {
        let transport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        await transport.configureShellTerminalCreation(gate: gate)
        let store = makeOpenStore(agent: makeAgent(), transport: transport)

        store.open()
        store.open()
        store.open()

        try #require(await eventually { await gate.entryCount == 1 })
        #expect(store.isOpening)
        #expect(await transport.shellTerminalCreations.count == 1)
        await gate.open()
        try #require(await eventually { store.shell != nil })
        #expect(await transport.shellTerminalCreations.count == 1)
    }

    @Test func exactCreationRequestIsForwarded() async throws {
        let transport = ScriptedTransport()
        let agent = makeAgent(cwd: "/repo/current task")
        let store = makeOpenStore(agent: agent, transport: transport)

        store.open()

        try #require(await eventually { store.shell != nil })
        #expect(
            await transport.shellTerminalCreations
                == [
                    ShellTerminalCreationRequest(
                        workspaceID: "workspace-1",
                        cwd: "/repo/current task")
                ])
    }

    @Test func shellSurfaceEnablesDirectTerminalInputAndShellAppropriateKeys() async throws {
        let transport = ScriptedTransport()
        let store = ShellTerminalStore(
            identity: ShellTerminalIdentity(
                paneID: "w1:p-shell",
                tabID: "w1:t-shell",
                terminalID: "term-shell"),
            transportGeneration: 1,
            isOnStage: { true },
            runTerminal: terminalRunner(transport))
        let defaults = UserDefaults(suiteName: "shell-terminal-\(UUID())") ?? .standard
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults))
        let controller = UIHostingController(
            rootView: ShellTerminalView(
                store: store,
                terminal: settings,
                activity: AppActivityCoordinator(),
                isReturning: false,
                onBack: {}))
        let window = AgentSurfaceReplacementTests.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }

        controller.view.layoutIfNeeded()
        try #require(
            await eventually {
                controller.view.layoutIfNeeded()
                return await transport.attachRequests.count == 1
            })
        #expect(await transport.emitAttachOutput(Data("shell".utf8)))
        try #require(await eventually { store.terminalStatus == .live })
        let terminal = try #require(
            AgentSurfaceReplacementTests.terminals(in: controller.view).first)

        #expect(terminal.isLocalInputEnabled)
        #expect(terminal.keysContext?.tabs == [.controls, .appearance])
        terminal.sendControlKey(.enter)
        try #require(
            await eventually {
                await transport.attachInputs.contains(.keystrokes(Data([0x0D])))
            })

        await store.leave().value
    }

    @Test func createdIdentityBecomesALocalDestinationWithoutChangingRouterPath() async throws {
        let transport = ScriptedTransport()
        let identity = ShellTerminalIdentity(
            paneID: "w1:p-shell",
            tabID: "w1:t-shell",
            terminalID: "terminal-shell")
        await transport.configureShellTerminalCreation(identity: identity)
        let agent = makeAgent()
        let router = AgentNotificationRouter()
        router.path = [agent.id]
        let store = makeOpenStore(agent: agent, transport: transport)

        store.open()

        try #require(await eventually { store.shell != nil })
        #expect(store.destination == .shell(identity))
        #expect(router.path == [agent.id])
    }

    @Test func agentAttachEndsBeforeShellAttachStarts() async throws {
        let transport = ScriptedTransport()
        let runner = terminalRunner(transport)
        let agentTerminal = AttachTerminalStore(
            target: "w1:p-agent",
            takeover: true,
            runTerminal: runner)
        agentTerminal.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await transport.attachRequests.count == 1 })
        #expect(await transport.emitAttachOutput(Data("agent".utf8)))
        try #require(await eventually { agentTerminal.status == .live })

        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            leaveAgent: {
                Task { await agentTerminal.stop() }
            })
        store.open()
        let shell = try await shell(in: store)
        shell.viewDidResize(cols: 90, rows: 30)

        try #require(await eventually { await transport.attachRequests.count == 2 })
        #expect(
            await transport.attachRequests.map(\.target)
                == [.agentPane("w1:p-agent"), .terminal("term-shell")])
    }

    @Test func attachFailureAndRetryNeverRecreateTheTab() async throws {
        let transport = ScriptedTransport()
        let store = makeOpenStore(agent: makeAgent(), transport: transport)
        store.open()
        let shell = try await shell(in: store)
        shell.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await transport.attachRequests.count == 1 })
        await transport.failAttachStream(.channelFailed(detail: "terminal not found"))
        try #require(
            await eventually {
                if case .ended = shell.terminalStatus { return true }
                return false
            })

        shell.retryTerminal()

        try #require(await eventually { await transport.attachRequests.count == 2 })
        #expect(await transport.shellTerminalCreations.count == 1)
        #expect(
            await transport.attachRequests.map(\.target)
                == [.terminal("term-shell"), .terminal("term-shell")])
    }

    @Test func hostGenerationReplacementReusesRememberedTerminalID() async throws {
        let transport = ScriptedTransport()
        let store = makeOpenStore(agent: makeAgent(), transport: transport)
        store.open()
        let shell = try await shell(in: store)
        shell.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await transport.attachRequests.count == 1 })
        #expect(await transport.emitAttachOutput(Data("shell".utf8)))
        try #require(await eventually { shell.terminalStatus == .live })
        let previousSurfaceID = shell.terminalID

        shell.transportGenerationDidChange(2)

        try #require(await eventually { shell.terminalID != previousSurfaceID })
        shell.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await transport.attachRequests.count == 2 })
        #expect(
            await transport.attachRequests.map(\.target)
                == [.terminal("term-shell"), .terminal("term-shell")])
        #expect(await transport.shellTerminalCreations.count == 1)
    }

    @Test func offStageAbortedReplacementRejoinsOnTheNextActivationSignal() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        var isOnStage = true
        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            isDetailOnStage: { isOnStage })
        await transport.gateNextAttachEnd(on: endGate)
        store.open()
        let shell = try await shell(in: store)
        shell.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await transport.attachRequests.count == 1 })
        #expect(await transport.emitAttachOutput(Data("shell".utf8)))
        try #require(await eventually { shell.terminalStatus == .live })
        let previousSurfaceID = shell.terminalID

        shell.transportGenerationDidChange(2)
        try #require(await eventually { await endGate.entryCount == 1 })
        isOnStage = false
        await endGate.open()
        try #require(await eventually { shell.terminalStatus == .stopped })

        // The stage comes back without a balancing disappear/appear pair.
        // Foreground delivery is the next on-stage lifecycle signal.
        isOnStage = true
        shell.didBecomeActive(afterPossibleSuspension: false)

        try #require(await eventually { shell.terminalID != previousSurfaceID })
        shell.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await transport.attachRequests.count == 2 })
        #expect(
            await transport.attachRequests.map(\.target)
                == [.terminal("term-shell"), .terminal("term-shell")])
        #expect(await transport.shellTerminalCreations.count == 1)
    }

    @Test func backWaitsForShellTeardownBeforeRestoringAgent() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        var agentRejoined = false
        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            rejoinAgent: { agentRejoined = true })
        store.open()
        let shell = try await shell(in: store)
        shell.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await transport.attachRequests.count == 1 })

        let returning = Task { await store.returnToAgent() }
        try #require(await eventually { await endGate.entryCount == 1 })
        #expect(store.destination == .shell(shell.identity))
        #expect(!agentRejoined)

        await endGate.open()
        await returning.value
        #expect(store.destination == .agent(makeAgent().id))
        #expect(agentRejoined)
        #expect(!(await transport.hasLiveAttachSession))
    }

    @Test func ambiguousCreateFailureExplainsThatATabMayExist() async throws {
        let transport = ScriptedTransport()
        await transport.configureShellTerminalCreation(failure: TransportError.timedOut)
        let store = makeOpenStore(agent: makeAgent(), transport: transport)

        store.open()

        try #require(await eventually { store.failure != nil })
        #expect(store.failure?.kind == .ambiguous)
        #expect(store.failure?.message.contains("may already exist") == true)
        #expect(store.shell == nil)
        #expect(await transport.shellTerminalCreations.count == 1)
    }

    @Test func definitiveCreateRejectionDoesNotEnterShell() async throws {
        let transport = ScriptedTransport()
        await transport.configureShellTerminalCreation(
            failure: HerdrAPIError(code: "workspace_not_found", message: "workspace is gone"))
        let store = makeOpenStore(agent: makeAgent(), transport: transport)

        store.open()

        try #require(await eventually { store.failure != nil })
        #expect(store.failure?.kind == .rejected)
        #expect(store.failure?.message.contains("workspace is gone") == true)
        #expect(store.shell == nil)
    }

    private func makeOpenStore(
        agent: ConsoleAgent,
        transport: ScriptedTransport,
        isDetailOnStage: @escaping () -> Bool = { true },
        leaveAgent: @escaping @MainActor () -> Task<Void, Never> = { Task {} },
        rejoinAgent: @escaping @MainActor () -> Void = {}
    ) -> AgentOpenTerminalStore {
        AgentOpenTerminalStore(
            agent: agent,
            transportGeneration: 1,
            isDetailOnStage: isDetailOnStage,
            createTerminal: { request in
                try await transport.createShellTerminal(request)
            },
            runTerminal: terminalRunner(transport),
            leaveAgent: leaveAgent,
            rejoinAgent: rejoinAgent)
    }

    private func terminalRunner(_ transport: ScriptedTransport) -> TerminalSessionRunner {
        { request, handler in
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
    }

    private func shell(in store: AgentOpenTerminalStore) async throws -> ShellTerminalStore {
        try #require(await eventually { store.shell != nil })
        return try #require(store.shell)
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func makeAgent(
        cwd: String = "/repo",
        checkout: RepositoryCheckout? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: Host.ID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            hostName: "Host",
            agent: Agent(
                terminalID: "term-agent",
                kind: "claude",
                title: "Task",
                status: .idle,
                workspaceID: "workspace-1",
                tabID: "w1:t-agent",
                paneID: "w1:p-agent",
                cwd: cwd,
                revision: 1),
            workspaceLabel: "Workspace",
            repositoryCheckout: checkout)
    }

    private func makeCheckout(path: String, isLinked: Bool) -> RepositoryCheckout {
        RepositoryCheckout(
            repoKey: "/repo/.git",
            repoName: "repo",
            repoRoot: "/repo",
            checkoutPath: path,
            isLinkedWorktree: isLinked)
    }
}
