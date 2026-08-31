import Foundation
import Observation

typealias ShellTerminalCreator =
    @Sendable (ShellTerminalCreationRequest) async throws -> ShellTerminalIdentity

extension ConsoleAgent {
    /// A shell must open in a directory tied to the selected Agent. A missing
    /// directory disables Open Terminal instead of letting herdr inherit some
    /// other focused Pane's cwd.
    var shellTerminalCreationRequest: ShellTerminalCreationRequest? {
        if Self.isAbsoluteNonEmptyPath(agent.cwd) {
            return ShellTerminalCreationRequest(
                workspaceID: agent.workspaceID,
                cwd: agent.cwd)
        }
        if isLinkedWorktree,
            let checkoutPath,
            Self.isAbsoluteNonEmptyPath(checkoutPath)
        {
            return ShellTerminalCreationRequest(
                workspaceID: agent.workspaceID,
                cwd: checkoutPath)
        }
        return nil
    }

    private static func isAbsoluteNonEmptyPath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Agent Detail owns this destination identity locally. It deliberately does
/// not widen notification routing, whose path continues to identify Agents.
enum AgentDetailDestination: Hashable, Sendable {
    case agent(ConsoleAgent.ID)
    case shell(ShellTerminalIdentity)
}

struct OpenTerminalFailure: Identifiable, Equatable {
    enum Kind: Equatable {
        case rejected
        case ambiguous
    }

    let kind: Kind
    let message: String

    var id: String { "\(kind)-\(message)" }
}

/// Owns creation and the local Agent-to-shell stage transition. Creation is
/// single-flight. Once it succeeds, the remote identity is retained before
/// Agent Attach is torn down, so every later attach/reconnect targets the same
/// terminal and can never create another tab implicitly.
///
/// The Workspace's shell tab is remembered in the Console (surviving Back and
/// the detail screen itself), so a later Open Terminal reattaches to it
/// instead of accumulating a new tab per visit. The remembered tab is
/// verified before reuse — one closed on the desktop, or lost to a server
/// restart, is forgotten and recreated under the same explicit tap.
@MainActor
@Observable
final class AgentOpenTerminalStore {
    let agentID: ConsoleAgent.ID
    let creationRequest: ShellTerminalCreationRequest?

    private(set) var shell: ShellTerminalStore?
    private(set) var isOpening = false
    private(set) var isReturning = false
    private(set) var isClosingTerminal = false
    private(set) var failure: OpenTerminalFailure?
    private(set) var closeFailureMessage: String?

    @ObservationIgnored private let createTerminal: ShellTerminalCreator
    @ObservationIgnored private let runTerminal: TerminalSessionRunner
    @ObservationIgnored private let leaveAgent: @MainActor () -> Task<Void, Never>
    @ObservationIgnored private let rejoinAgent: @MainActor () -> Void
    @ObservationIgnored private let isDetailOnStage: () -> Bool
    @ObservationIgnored private let recallTerminal: @MainActor () -> ShellTerminalIdentity?
    @ObservationIgnored private let rememberTerminal: @MainActor (ShellTerminalIdentity) -> Void
    @ObservationIgnored private let forgetTerminal: @MainActor () -> Void
    @ObservationIgnored private let verifyTerminal:
        @Sendable (ShellTerminalIdentity) async throws -> Bool
    @ObservationIgnored private let closeRemoteTerminal:
        @Sendable (ShellTerminalIdentity) async throws -> Void
    @ObservationIgnored private var transportGeneration: UInt64?

    init(
        agent: ConsoleAgent,
        transportGeneration: UInt64?,
        isDetailOnStage: @escaping () -> Bool,
        createTerminal: @escaping ShellTerminalCreator,
        runTerminal: @escaping TerminalSessionRunner,
        leaveAgent: @escaping @MainActor () -> Task<Void, Never>,
        rejoinAgent: @escaping @MainActor () -> Void,
        recallTerminal: @escaping @MainActor () -> ShellTerminalIdentity? = { nil },
        rememberTerminal: @escaping @MainActor (ShellTerminalIdentity) -> Void = { _ in },
        forgetTerminal: @escaping @MainActor () -> Void = {},
        verifyTerminal: @escaping @Sendable (ShellTerminalIdentity) async throws -> Bool = {
            _ in true
        },
        closeRemoteTerminal: @escaping @Sendable (ShellTerminalIdentity) async throws -> Void = {
            _ in
        }
    ) {
        agentID = agent.id
        creationRequest = agent.shellTerminalCreationRequest
        self.transportGeneration = transportGeneration
        self.isDetailOnStage = isDetailOnStage
        self.createTerminal = createTerminal
        self.runTerminal = runTerminal
        self.leaveAgent = leaveAgent
        self.rejoinAgent = rejoinAgent
        self.recallTerminal = recallTerminal
        self.rememberTerminal = rememberTerminal
        self.forgetTerminal = forgetTerminal
        self.verifyTerminal = verifyTerminal
        self.closeRemoteTerminal = closeRemoteTerminal
    }

    var destination: AgentDetailDestination {
        if let shell { return .shell(shell.identity) }
        return .agent(agentID)
    }

    var canOpen: Bool {
        creationRequest != nil && shell == nil && !isOpening
    }

    func open() {
        guard canOpen, let creationRequest else { return }
        failure = nil
        isOpening = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isOpening = false
            }
            do {
                let identity = try await self.resolveTerminal(creationRequest)
                // A tab now exists. From here on cancellation must not turn a
                // partial success into another create attempt: remember it and
                // complete the terminal handoff using this exact identity.
                await self.leaveAgent().value
                self.shell = self.makeShell(identity: identity)
            } catch {
                self.failure = Self.presentation(for: error)
            }
        }
    }

    /// The Workspace's remembered tab, when it is still alive; a fresh one
    /// otherwise. Recreation happens only here, under the user's explicit
    /// Open Terminal — never implicitly from a reconnect.
    private func resolveTerminal(
        _ creationRequest: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        if let remembered = recallTerminal() {
            if try await verifyTerminal(remembered) {
                return remembered
            }
            forgetTerminal()
        }
        let identity = try await createTerminal(creationRequest)
        rememberTerminal(identity)
        return identity
    }

    func dismissFailure() {
        failure = nil
    }

    /// Closes the remote tab and returns to the Agent: the reclaim path for a
    /// terminal not worth keeping for desktop handoff. Remote first — if the
    /// Host cannot be reached, the attach is still alive and the user stays
    /// in the shell with an explanation instead of losing it locally while
    /// the tab lives on.
    func closeTerminal() {
        guard let shell, !isReturning, !isClosingTerminal else { return }
        closeFailureMessage = nil
        isClosingTerminal = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isClosingTerminal = false
            }
            do {
                try await self.closeRemoteTerminal(shell.identity)
            } catch is HerdrAPIError {
                // The server no longer knows the pane: closed on the desktop,
                // or lost to a restart. Either way it is gone, which is the
                // outcome the user asked for.
            } catch TransportError.apiRejected {
                // Same definitive answer, surfaced through the other layer.
            } catch {
                self.closeFailureMessage =
                    "The Host couldn't be reached. The tab is still open there."
                return
            }
            self.forgetTerminal()
            await self.returnToAgent()
        }
    }

    func dismissCloseFailure() {
        closeFailureMessage = nil
    }

    /// Back is a local stage transition. It first waits for the shell's PTY
    /// channel and Host terminal lease to finish, then restores Agent Attach.
    func returnToAgent() async {
        guard let shell, !isReturning else { return }
        isReturning = true
        await shell.leave().value
        guard self.shell === shell else {
            isReturning = false
            return
        }
        self.shell = nil
        isReturning = false
        rejoinAgent()
    }

    func transportGenerationDidChange(_ generation: UInt64?) {
        transportGeneration = generation
        shell?.transportGenerationDidChange(generation)
    }

    private func makeShell(identity: ShellTerminalIdentity) -> ShellTerminalStore {
        ShellTerminalStore(
            identity: identity,
            transportGeneration: transportGeneration,
            isOnStage: { [weak self] in
                guard let self else { return false }
                return self.isDetailOnStage() && self.shell?.identity == identity
            },
            runTerminal: runTerminal)
    }

    private static func presentation(for error: any Error) -> OpenTerminalFailure {
        switch error {
        case let api as HerdrAPIError:
            OpenTerminalFailure(
                kind: .rejected,
                message: "herdr couldn't create the terminal: \(api.message)")
        case TransportError.apiRejected(_, let message):
            OpenTerminalFailure(
                kind: .rejected,
                message: "herdr couldn't create the terminal: \(message)")
        default:
            OpenTerminalFailure(
                kind: .ambiguous,
                message:
                    "The request did not finish clearly. A new tab may already exist on the Host. Check the Host before trying again."
            )
        }
    }
}

/// Thin ordinary-shell owner around the shared PTY pipeline. It adds only the
/// lifecycle needed to replace that pipeline across Host generations and to
/// wait for teardown before the local destination changes.
@MainActor
@Observable
final class ShellTerminalStore {
    private enum LifecycleState {
        case active
        case rejoinRequired
        case left
    }

    let identity: ShellTerminalIdentity
    let input = TerminalInputController()
    private(set) var terminal: AttachTerminalStore

    @ObservationIgnored private let runTerminal: TerminalSessionRunner
    @ObservationIgnored private let isOnStage: @MainActor () -> Bool
    @ObservationIgnored private var transportGeneration: UInt64?
    @ObservationIgnored private var lifecycleState = LifecycleState.active
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleID: UInt64 = 0
    @ObservationIgnored private var isReplacing = false
    @ObservationIgnored private var replacementID: UInt64 = 0
    @ObservationIgnored private var activationRecoveryAwaitsTransport = false

    init(
        identity: ShellTerminalIdentity,
        transportGeneration: UInt64?,
        isOnStage: @escaping @MainActor () -> Bool,
        runTerminal: @escaping TerminalSessionRunner
    ) {
        self.identity = identity
        self.transportGeneration = transportGeneration
        self.isOnStage = isOnStage
        self.runTerminal = runTerminal
        terminal = Self.makeTerminal(
            terminalID: identity.terminalID,
            input: input,
            transportGeneration: transportGeneration,
            runTerminal: runTerminal)
    }

    var terminalID: TerminalSurfaceID { terminal.surfaceID }
    var terminalFeed: TerminalByteFeed { terminal.feed }

    var terminalStatus: AttachTerminalStore.Status {
        guard lifecycleState == .active, isOnStage() else { return terminal.status }
        if isReplacing || terminal.status == .stopped { return .connecting }
        return terminal.status
    }

    var pendingPaste: TerminalInputController.PasteReview? { input.pendingPaste }
    var canConfirmPaste: Bool { terminal.status == .live && input.canConfirmPaste }
    var pasteErrorMessage: String? { input.pasteErrorMessage }

    func viewDidResize(cols: Int, rows: Int) {
        guard lifecycleState == .active, isOnStage() else { return }
        terminal.viewDidResize(cols: cols, rows: rows)
    }

    func send(_ data: Data) { terminal.send(data) }

    func scroll(_ sequence: Data, rows: Int) {
        input.scroll(sequence, rows: rows)
    }

    func requestPaste(_ text: String, bracketedPaste: Bool) {
        _ = input.requestPaste(text, bracketedPaste: bracketedPaste)
    }

    func cancelPaste() { input.cancelPaste() }
    func clearPasteError() { input.clearPasteError() }

    func confirmPaste() {
        guard canConfirmPaste else { return }
        _ = input.confirmPaste()
    }

    func retryTerminal() { terminal.retry() }

    func didBecomeActive(afterPossibleSuspension: Bool) {
        guard isOnStage() else { return }
        if lifecycleState == .rejoinRequired {
            rejoin()
            return
        }
        guard lifecycleState == .active else { return }
        if afterPossibleSuspension {
            if isReplacing {
                activationRecoveryAwaitsTransport = true
                return
            }
            if terminal.transportGeneration == transportGeneration,
                terminal.status == .waitingForSize || terminal.status == .connecting
            {
                return
            }
            input.detachSessionForReplacement()
            activationRecoveryAwaitsTransport = true
            replaceTerminal()
        } else {
            terminal.didBecomeActive()
        }
    }

    func transportGenerationDidChange(_ generation: UInt64?) {
        guard let generation, lifecycleState == .active else { return }
        if activationRecoveryAwaitsTransport,
            isReplacing || terminal.status == .waitingForSize || terminal.status == .connecting
        {
            transportGeneration = generation
            activationRecoveryAwaitsTransport = false
            return
        }
        activationRecoveryAwaitsTransport = false
        if terminal.transportGeneration == generation {
            transportGeneration = generation
            return
        }
        guard generation != transportGeneration else { return }
        transportGeneration = generation
        replaceTerminal()
    }

    private func replaceTerminal() {
        guard lifecycleState == .active, isOnStage() else { return }
        replacementID &+= 1
        let replacementID = replacementID
        isReplacing = true
        enqueueLifecycleTransition { [weak self] in
            guard let self else { return }
            guard self.replacementID == replacementID else { return }
            let previous = self.terminal
            await previous.stop(preservingPendingPaste: true)
            guard self.replacementID == replacementID,
                self.lifecycleState == .active,
                self.isOnStage()
            else {
                self.abortReplacementOffStage(replacementID: replacementID)
                return
            }
            self.terminal = Self.makeTerminal(
                terminalID: self.identity.terminalID,
                input: self.input,
                transportGeneration: self.transportGeneration,
                runTerminal: self.runTerminal)
            self.isReplacing = false
        }
    }

    func rejoin() {
        guard lifecycleState != .active, isOnStage() else { return }
        lifecycleState = .active
        replacementID &+= 1
        let replacementID = replacementID
        isReplacing = true
        enqueueLifecycleTransition { [weak self] in
            guard let self else { return }
            guard self.replacementID == replacementID,
                self.lifecycleState == .active,
                self.isOnStage()
            else {
                self.abortReplacementOffStage(replacementID: replacementID)
                return
            }
            if self.terminal.status != .stopped {
                await self.terminal.stop(preservingPendingPaste: true)
            }
            guard self.replacementID == replacementID,
                self.lifecycleState == .active,
                self.isOnStage()
            else {
                self.abortReplacementOffStage(replacementID: replacementID)
                return
            }
            self.terminal = Self.makeTerminal(
                terminalID: self.identity.terminalID,
                input: self.input,
                transportGeneration: self.transportGeneration,
                runTerminal: self.runTerminal)
            self.isReplacing = false
        }
    }

    /// A queued replacement can become invalid after its predecessor has
    /// stopped but before SwiftUI delivers a balancing disappear/appear pair.
    /// Preserve that incomplete outcome so the next on-stage signal rebuilds
    /// the same remembered terminal instead of leaving a stopped pipeline.
    private func abortReplacementOffStage(replacementID: UInt64) {
        guard self.replacementID == replacementID else { return }
        isReplacing = false
        guard lifecycleState == .active, !isOnStage() else { return }
        lifecycleState = .rejoinRequired
    }

    @discardableResult
    func leave() -> Task<Void, Never> {
        guard lifecycleState != .left else {
            return lifecycleTask ?? Task {}
        }
        lifecycleState = .left
        replacementID &+= 1
        isReplacing = false
        activationRecoveryAwaitsTransport = false
        input.cancelPaste()
        // The view may disappear immediately after scheduling this work. A
        // temporary strong capture guarantees the PTY and terminal lease are
        // still explicitly ended before this task releases the owner.
        return enqueueLifecycleTransition { [self] in
            await terminal.stop()
        }
    }

    @discardableResult
    private func enqueueLifecycleTransition(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = lifecycleTask
        lifecycleID &+= 1
        let id = lifecycleID
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycleTask = task
        Task { @MainActor [weak self] in
            await task.value
            guard self?.lifecycleID == id else { return }
            self?.lifecycleTask = nil
        }
        return task
    }

    private static func makeTerminal(
        terminalID: String,
        input: TerminalInputController,
        transportGeneration: UInt64?,
        runTerminal: @escaping TerminalSessionRunner
    ) -> AttachTerminalStore {
        AttachTerminalStore(
            target: .terminal(terminalID),
            takeover: true,
            input: input,
            transportGeneration: transportGeneration,
            runTerminal: runTerminal)
    }
}
