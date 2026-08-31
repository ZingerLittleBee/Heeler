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
        // No Snippets or Skills on a shell terminal: its Keys dock offers the
        // control pad and Appearance alone.
        #expect(ShellTerminalKeysDock.tabs == [.controls, .appearance])
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

    @Test func foregroundRecoveryDoesNotAbsorbANewerTransportGeneration() async throws {
        let transport = ScriptedTransport()
        let generation = ShellTerminalGenerationSource(1)
        let runner: TerminalSessionRunner = { request, handler in
            let readyGeneration = await generation.value
            await handler.transportDidBecomeReady(readyGeneration)
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
        let store = ShellTerminalStore(
            identity: ShellTerminalIdentity(
                paneID: "w1:p-shell",
                tabID: "w1:t-shell",
                terminalID: "term-shell"),
            transportGeneration: 1,
            isOnStage: { true },
            runTerminal: runner)

        let firstSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: firstSessionGate)
        store.viewDidResize(cols: 80, rows: 24)
        await firstSessionGate.waitForEntry()
        let firstStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("first".utf8)))
        await firstSessionGate.open()
        await firstStatusChanges.next()
        #expect(store.terminalStatus == .live)

        await generation.set(2)
        let predecessorID = store.terminalID
        let recoveryChanges = observeTerminalChanges(of: store)
        store.didBecomeActive(afterPossibleSuspension: true)
        await recoveryChanges.next()
        let recoveryID = store.terminalID
        #expect(recoveryID != predecessorID)
        #expect(store.terminalStatus == .waitingForSize)

        let secondSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: secondSessionGate)
        store.viewDidResize(cols: 100, rows: 30)
        await secondSessionGate.waitForEntry()
        #expect(await transport.attachRequests.count == 2)

        // Coalesce away the projection edge for generation 2. A later edge
        // for generation 3 must replace the still-connecting pipeline 2.
        await generation.set(3)
        let latestRecoveryChanges = observeTerminalChanges(of: store)
        store.transportGenerationDidChange(3)
        await secondSessionGate.open()
        await latestRecoveryChanges.next()
        let latestRecoveryID = store.terminalID
        #expect(latestRecoveryID != recoveryID)
        #expect(await transport.attachRequests.count == 2)

        let thirdSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: thirdSessionGate)
        store.viewDidResize(cols: 100, rows: 30)
        await thirdSessionGate.waitForEntry()
        #expect(await transport.attachRequests.count == 3)
        let latestStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("latest".utf8)))
        await thirdSessionGate.open()
        await latestStatusChanges.next()
        #expect(store.terminalStatus == .live)

        await store.leave().value
        #expect(store.terminalID == latestRecoveryID)
        #expect(await transport.attachRequests.count == 3)
        #expect(await !transport.hasLiveAttachSession)
    }

    @Test func foregroundRecoveryAbsorbsItsAcquiredTransportGeneration() async throws {
        let transport = ScriptedTransport()
        let generation = ShellTerminalGenerationSource(1)
        let runner: TerminalSessionRunner = { request, handler in
            let readyGeneration = await generation.value
            await handler.transportDidBecomeReady(readyGeneration)
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
        let store = ShellTerminalStore(
            identity: ShellTerminalIdentity(
                paneID: "w1:p-shell",
                tabID: "w1:t-shell",
                terminalID: "term-shell"),
            transportGeneration: 1,
            isOnStage: { true },
            runTerminal: runner)

        let firstSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: firstSessionGate)
        store.viewDidResize(cols: 80, rows: 24)
        await firstSessionGate.waitForEntry()
        let firstStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("first".utf8)))
        await firstSessionGate.open()
        await firstStatusChanges.next()
        #expect(store.terminalStatus == .live)

        await generation.set(2)
        let recoveryChanges = observeTerminalChanges(of: store)
        store.didBecomeActive(afterPossibleSuspension: true)
        await recoveryChanges.next()
        let recoveryID = store.terminalID

        let secondSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: secondSessionGate)
        store.viewDidResize(cols: 100, rows: 30)
        await secondSessionGate.waitForEntry()

        // The exact edge belongs to the already-acquired pipeline and does
        // not create a second writer for generation 2.
        store.transportGenerationDidChange(2)
        #expect(store.terminalID == recoveryID)
        #expect(await transport.attachRequests.count == 2)

        let secondStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("second".utf8)))
        await secondSessionGate.open()
        await secondStatusChanges.next()
        #expect(store.terminalStatus == .live)

        await store.leave().value
        #expect(store.terminalID == recoveryID)
        #expect(await transport.attachRequests.count == 2)
        #expect(await !transport.hasLiveAttachSession)
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

    /// Records what crosses the store's memory closures. A MainActor class so
    /// the `@Sendable` verify/close closures can capture it.
    @MainActor
    private final class TerminalMemoryProbe {
        var verified: [ShellTerminalIdentity] = []
        var closed: [ShellTerminalIdentity] = []
    }

    @Test func openReattachesTheRememberedTerminalInsteadOfCreating() async throws {
        let transport = ScriptedTransport()
        let remembered = ShellTerminalIdentity(
            paneID: "w1:p-old", tabID: "w1:t-old", terminalID: "term-old")
        let probe = TerminalMemoryProbe()
        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            recallTerminal: { remembered },
            verifyTerminal: { @MainActor identity in
                probe.verified.append(identity)
                return true
            })

        store.open()

        let shell = try await shell(in: store)
        #expect(shell.identity == remembered)
        #expect(probe.verified == [remembered])
        #expect(await transport.shellTerminalCreations.isEmpty)
    }

    @Test func aDeadRememberedTerminalIsForgottenAndRecreated() async throws {
        let transport = ScriptedTransport()
        let remembered = ShellTerminalIdentity(
            paneID: "w1:p-old", tabID: "w1:t-old", terminalID: "term-old")
        var forgets = 0
        var rememberedIdentities: [ShellTerminalIdentity] = []
        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            recallTerminal: { remembered },
            rememberTerminal: { rememberedIdentities.append($0) },
            forgetTerminal: { forgets += 1 },
            verifyTerminal: { _ in false })

        store.open()

        let shell = try await shell(in: store)
        #expect(shell.identity != remembered)
        #expect(forgets == 1)
        #expect(await transport.shellTerminalCreations.count == 1)
        // The fresh tab replaces the dead one in the Workspace's memory.
        #expect(rememberedIdentities == [shell.identity])
    }

    @Test func aFreshCreationIsRemembered() async throws {
        let transport = ScriptedTransport()
        var rememberedIdentities: [ShellTerminalIdentity] = []
        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            rememberTerminal: { rememberedIdentities.append($0) })

        store.open()

        let shell = try await shell(in: store)
        #expect(rememberedIdentities == [shell.identity])
    }

    /// A verification that cannot reach the Host must not quietly create a
    /// second tab next to a possibly-live remembered one.
    @Test func anUnreachableVerificationFailsOpenWithoutCreating() async throws {
        let transport = ScriptedTransport()
        let remembered = ShellTerminalIdentity(
            paneID: "w1:p-old", tabID: "w1:t-old", terminalID: "term-old")
        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            recallTerminal: { remembered },
            verifyTerminal: { _ in throw TransportError.timedOut })

        store.open()

        try #require(await eventually { store.failure != nil })
        #expect(store.shell == nil)
        #expect(await transport.shellTerminalCreations.isEmpty)
    }

    @Test func closeTerminalClosesTheTabForgetsItAndReturnsToTheAgent() async throws {
        let transport = ScriptedTransport()
        let probe = TerminalMemoryProbe()
        var forgets = 0
        var rejoined = 0
        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            rejoinAgent: { rejoined += 1 },
            forgetTerminal: { forgets += 1 },
            closeRemoteTerminal: { @MainActor identity in
                probe.closed.append(identity)
            })
        store.open()
        let shell = try await shell(in: store)

        store.closeTerminal()

        try #require(await eventually { store.shell == nil })
        #expect(probe.closed == [shell.identity])
        #expect(forgets == 1)
        #expect(rejoined == 1)
        #expect(store.closeFailureMessage == nil)
    }

    /// A tab already closed on the desktop is the outcome the user asked for,
    /// not an error to surface.
    @Test func closeTerminalTreatsAnAlreadyGoneTabAsClosed() async throws {
        let transport = ScriptedTransport()
        var forgets = 0
        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            forgetTerminal: { forgets += 1 },
            closeRemoteTerminal: { _ in
                throw HerdrAPIError(code: "pane_not_found", message: "pane gone")
            })
        store.open()
        _ = try await shell(in: store)

        store.closeTerminal()

        try #require(await eventually { store.shell == nil })
        #expect(forgets == 1)
        #expect(store.closeFailureMessage == nil)
    }

    /// An unreachable Host means the tab is still open there: stay in the
    /// shell, keep the memory, and say so.
    @Test func closeTerminalKeepsTheShellWhenTheHostIsUnreachable() async throws {
        let transport = ScriptedTransport()
        var forgets = 0
        let store = makeOpenStore(
            agent: makeAgent(),
            transport: transport,
            forgetTerminal: { forgets += 1 },
            closeRemoteTerminal: { _ in throw TransportError.timedOut })
        store.open()
        _ = try await shell(in: store)

        store.closeTerminal()

        try #require(await eventually { store.closeFailureMessage != nil })
        #expect(store.shell != nil)
        #expect(forgets == 0)
        #expect(!store.isClosingTerminal)
    }

    private func makeOpenStore(
        agent: ConsoleAgent,
        transport: ScriptedTransport,
        isDetailOnStage: @escaping () -> Bool = { true },
        leaveAgent: @escaping @MainActor () -> Task<Void, Never> = { Task {} },
        rejoinAgent: @escaping @MainActor () -> Void = {},
        recallTerminal: @escaping @MainActor () -> ShellTerminalIdentity? = { nil },
        rememberTerminal: @escaping @MainActor (ShellTerminalIdentity) -> Void = { _ in },
        forgetTerminal: @escaping @MainActor () -> Void = {},
        verifyTerminal: @escaping @Sendable (ShellTerminalIdentity) async throws -> Bool = {
            _ in true
        },
        closeRemoteTerminal: @escaping @Sendable (ShellTerminalIdentity) async throws -> Void = {
            _ in
        }
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
            rejoinAgent: rejoinAgent,
            recallTerminal: recallTerminal,
            rememberTerminal: rememberTerminal,
            forgetTerminal: forgetTerminal,
            verifyTerminal: verifyTerminal,
            closeRemoteTerminal: closeRemoteTerminal)
    }

    private func terminalRunner(_ transport: ScriptedTransport) -> TerminalSessionRunner {
        { request, handler in
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
    }

    private func observeTerminalChanges(
        of store: ShellTerminalStore
    ) -> ShellObservationChangeProbe {
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        withObservationTracking {
            _ = store.terminalID
        } onChange: {
            continuation.yield()
            continuation.finish()
        }
        return ShellObservationChangeProbe(changes)
    }

    private func observeStatusChanges(
        of store: ShellTerminalStore
    ) -> ShellObservationChangeProbe {
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        withObservationTracking {
            _ = store.terminalStatus
        } onChange: {
            continuation.yield()
            continuation.finish()
        }
        return ShellObservationChangeProbe(changes)
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

private actor ShellObservationChangeProbe {
    private let changes: AsyncStream<Void>

    init(_ changes: AsyncStream<Void>) {
        self.changes = changes
    }

    func next() async {
        for await _ in changes { return }
    }
}

private actor ShellTerminalGenerationSource {
    private(set) var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func set(_ value: UInt64) {
        self.value = value
    }
}
