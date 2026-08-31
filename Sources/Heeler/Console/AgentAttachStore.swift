import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

typealias AttachmentStageProgressHandler = @Sendable (AttachmentStageProgress) async -> Void
typealias ImageStager =
    @Sendable (PreparedImage, AttachmentStageProgressReporter) async throws -> StagedImage
typealias FileStager =
    @Sendable (PreparedFile, AttachmentStageProgressReporter) async throws -> StagedFile

struct AttachmentStageProgressReporter: Sendable {
    private let handler: AttachmentStageProgressHandler

    init(_ handler: @escaping AttachmentStageProgressHandler) {
        self.handler = handler
    }

    func report(_ progress: AttachmentStageProgress) async {
        await handler(progress)
    }
}

@MainActor
protocol AttachmentClipboard {
    func copy(_ path: String) throws
}

@MainActor
struct SystemAttachmentClipboard: AttachmentClipboard {
    static let lifetime: TimeInterval = 24 * 60 * 60

    func copy(_ path: String) throws {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: path]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(Self.lifetime),
            ])
    }
}

typealias AttachLinkOpener = @MainActor @Sendable (URL) async -> Bool

struct AttachLinkOpenFailure: Identifiable, Equatable {
    let link: AttachLink

    var id: String { link.id }
    var message: String {
        "The link to \(link.host) couldn't be opened. You can copy it instead."
    }
}

/// Owns the complete Agent Attach interaction: terminal lifetime, Composer
/// staging, reconnect replacement, close, and deterministic leave ordering.
/// The view only forwards UI events.
@MainActor
@Observable
final class AgentAttachStore {
    /// Attach presence and leave cleanup are related, but not interchangeable.
    /// A recovery may become invalid off stage before SwiftUI delivers the
    /// real leave callback. That transition requires a later full terminal
    /// replacement, while `leave()` still owns the interaction cleanup.
    private enum LifecycleState {
        case active
        case rejoinRequired
        case left
    }

    private let target: String
    private let runTerminal: TerminalSessionRunner
    private let linkIndex: AttachLinkIndex
    /// Whether this screen is still the Console's current detail. The
    /// router's path is the ground truth SwiftUI's appear/disappear
    /// callbacks lack: they hand out spurious pairs amid navigation churn,
    /// on departing screens as well as staying ones.
    private let isOnStage: () -> Bool

    private(set) var terminal: AttachTerminalStore
    let input: TerminalInputController
    let staging: ComposerStagingStore
    let close: ClosePaneStore
    private(set) var attachLinkOpenFailure: AttachLinkOpenFailure?

    private var transportGeneration: UInt64?
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleID: UInt64 = 0
    private var attachLinkOpenTask: Task<Void, Never>?
    private var attachLinkOpenID: UInt64 = 0
    private var lifecycleState = LifecycleState.active
    /// Owns recovery presentation for the latest scheduled replacement. Its
    /// predecessor may still be stopping, but an older queued transition cannot
    /// clear the token a newer transition installed. This is presentation
    /// state, not a transport claim: while it exists the screen must show
    /// recovery instead of the predecessor's stale `.live` state and its empty
    /// overlay.
    private var terminalRecoveryOwner: UUID?
    /// A possible-suspension activation observed by the selected screen is also
    /// a claim that this lifecycle is current. SwiftUI can still deliver a
    /// delayed disappear from the foreground mount after that claim, without a
    /// balancing appear. Only that recovery may survive such an on-stage leave;
    /// ordinary replacement and rejoin transitions keep their existing teardown
    /// semantics.
    private var activationRecoveryOwnsOnStageLifecycle = false
    /// Joins the independently scheduled readiness projection and terminal
    /// waiter for the exact foreground-recovery pipeline.
    private var activationRecovery = TerminalRecoveryGenerationLatch()

    init(
        target: String,
        paneTitle: String,
        transportGeneration: UInt64?,
        isOnStage: @escaping () -> Bool,
        runTerminal: @escaping TerminalSessionRunner,
        stageImage: @escaping ImageStager,
        stageFile: @escaping FileStager,
        composer: any ComposerDraftOperations,
        closePane: @escaping () async throws -> Void
    ) {
        let input = TerminalInputController()
        self.target = target
        self.isOnStage = isOnStage
        self.runTerminal = runTerminal
        self.transportGeneration = transportGeneration
        self.input = input
        let linkIndex = AttachLinkIndex()
        self.linkIndex = linkIndex
        terminal = Self.makeTerminal(
            target: target, input: input, transportGeneration: transportGeneration,
            runTerminal: runTerminal, linkIndex: linkIndex)
        staging = ComposerStagingStore(
            stageImage: stageImage,
            stageFile: stageFile,
            composer: composer)
        close = ClosePaneStore(paneTitle: paneTitle, close: closePane)
    }

    var terminalID: TerminalSurfaceID {
        terminal.surfaceID
    }

    /// What the screen should say about the terminal.
    ///
    /// A stopped terminal on a screen that has *not* left is one `rejoin()` is
    /// already replacing, so it reads as connecting: the alternative is a black
    /// surface with no overlay and nothing to say for itself. A screen that has
    /// left or is no longer the router's current detail keeps the real status —
    /// it is on its way off stage and must not flash a spinner on the way out.
    var terminalStatus: AttachTerminalStore.Status {
        guard lifecycleState == .active, isOnStage() else { return terminal.status }
        if terminalRecoveryOwner != nil {
            return .connecting
        }
        if terminal.status == .stopped {
            return .connecting
        }
        return terminal.status
    }

    var terminalFeed: TerminalByteFeed {
        terminal.feed
    }

    #if DEBUG
    func terminalDidBecomeVisible() {
        terminal.restorationTrace.emit(.agentDetailVisible, generation: terminal.transportGeneration)
    }

    func agentSnapshotSwitcherDidBecomeAvailable() {
        terminal.restorationTrace.emit(
            .agentSnapshotSwitcherAvailable,
            generation: terminal.transportGeneration)
    }

    func terminalSurfaceDidAttach() {
        terminal.restorationTrace.emit(.terminalSurfaceAttached, generation: terminal.transportGeneration)
    }
    #endif

    var attachLinks: [AttachLink] {
        linkIndex.links
    }

    var pendingPaste: TerminalInputController.PasteReview? {
        input.pendingPaste
    }

    var canConfirmPaste: Bool {
        terminal.status == .live && input.canConfirmPaste
    }

    var pasteErrorMessage: String? {
        input.pasteErrorMessage
    }

    var closeFailureMessage: String? {
        guard case .failed(let message) = close.state else { return nil }
        return message
    }

    /// A size report from a screen that has left or moved off stage must not
    /// start anything: a departed view still lays out during its exit
    /// transition, before SwiftUI necessarily delivers `onDisappear`.
    func viewDidResize(cols: Int, rows: Int) {
        guard lifecycleState == .active, isOnStage() else { return }
        terminal.viewDidResize(cols: cols, rows: rows)
    }

    func viewportTextDidChange(_ text: String) {
        guard lifecycleState == .active else { return }
        linkIndex.receiveViewportText(text)
    }

    func openAttachLink(_ link: AttachLink, using open: @escaping AttachLinkOpener) {
        guard lifecycleState == .active else { return }
        attachLinkOpenFailure = nil
        invalidateAttachLinkOpen()
        let openID = attachLinkOpenID
        attachLinkOpenTask = Task { @MainActor [weak self] in
            let accepted = await open(link.url)
            guard
                let self,
                !Task.isCancelled,
                self.lifecycleState == .active,
                self.attachLinkOpenID == openID
            else {
                return
            }
            self.attachLinkOpenTask = nil
            guard !accepted else { return }
            self.attachLinkOpenFailure = AttachLinkOpenFailure(link: link)
        }
    }

    func copyFailedAttachLink(using copy: (String) -> Void) {
        guard let failure = attachLinkOpenFailure else { return }
        copy(failure.link.target)
        attachLinkOpenFailure = nil
    }

    func dismissAttachLinkOpenFailure() {
        attachLinkOpenFailure = nil
    }

    func send(_ keystrokes: Data) {
        terminal.send(keystrokes)
    }

    func scroll(_ sequence: Data, rows: Int) {
        input.scroll(sequence, rows: rows)
    }

    func requestPaste(_ text: String, bracketedPaste: Bool) {
        _ = input.requestPaste(text, bracketedPaste: bracketedPaste)
    }

    func insertSnippet(_ text: String, bracketedPaste: Bool) {
        _ = input.insertSnippet(text, bracketedPaste: bracketedPaste)
    }

    func cancelPaste() {
        input.cancelPaste()
    }

    func confirmPaste() {
        guard canConfirmPaste else { return }
        _ = input.confirmPaste()
    }

    func clearPasteError() {
        input.clearPasteError()
    }

    /// A short foreground bounce keeps the current PTY and asks it to repaint.
    /// Once the app may have suspended, replace the complete terminal pipeline
    /// immediately: PTY Attach, input session ownership, byte feed and surface
    /// identity. The surrounding Attach interaction remains the same owner, so
    /// links, staging state and a reviewed Paste survive the recovery.
    func didBecomeActive(afterPossibleSuspension: Bool = false) {
        guard lifecycleState == .active, isOnStage() else { return }
        guard !afterPossibleSuspension else {
            if activationRecovery.isActive {
                activationRecoveryOwnsOnStageLifecycle = true
                return
            }
            if terminalRecoveryOwner != nil {
                activationRecoveryOwnsOnStageLifecycle = true
                activationRecovery.begin(
                    projectedGeneration: transportGeneration)
                return
            }
            input.detachSessionForReplacement()
            activationRecovery.begin(
                projectedGeneration: transportGeneration)
            replaceTerminal(ownsOnStageLifecycle: true) { [weak self] in
                guard let self else { return false }
                return self.lifecycleState == .active && self.isOnStage()
            }
            return
        }
        terminal.didBecomeActive()
    }

    /// A new Transport requires a new terminal pipeline. The replacement is
    /// serialized behind any earlier transition and starts only after the
    /// old terminal has finished. Staging deliberately survives: the
    /// stager resolves the live Transport per call, so a retryable or
    /// completed upload stays actionable across the reconnect.
    func transportGenerationDidChange(_ generation: UInt64?) {
        guard let generation, lifecycleState == .active else { return }
        if let decision = activationRecovery.recordProjection(generation) {
            advanceTransportGeneration(to: generation)
            applyActivationRecovery(decision)
            return
        }
        if terminal.transportGeneration == generation {
            transportGeneration = generation
            return
        }
        guard generation != transportGeneration else { return }
        transportGeneration = generation
        replaceTerminal { [weak self] in
            guard let self else { return false }
            return self.lifecycleState == .active && self.transportGeneration == generation
        }
    }

    private func terminalTransportDidBecomeReady(
        pipelineID: TerminalSurfaceID,
        generation: UInt64
    ) {
        guard
            let decision = activationRecovery.recordAcquisition(
                generation, by: pipelineID)
        else { return }
        applyActivationRecovery(decision)
    }

    private func applyActivationRecovery(
        _ decision: TerminalRecoveryGenerationLatch.Decision
    ) {
        switch decision {
        case .pending:
            return
        case .acknowledge(let generation), .retain(let generation):
            advanceTransportGeneration(to: generation)
        case .replace(let generation):
            advanceTransportGeneration(to: generation)
            replaceTerminal { [weak self] in
                guard let self else { return false }
                return self.lifecycleState == .active
                    && self.transportGeneration == generation
            }
        }
    }

    private func advanceTransportGeneration(to generation: UInt64) {
        guard transportGeneration.map({ generation > $0 }) ?? true else { return }
        transportGeneration = generation
    }

    /// Tears the terminal pipeline down and builds a fresh one, serialized
    /// behind any earlier transition. `isStillWanted` is re-asked when the
    /// queued operation starts and after teardown: the route can change both
    /// while this waits for an earlier transition and while `stop()` awaits.
    ///
    /// The new pipeline carries a new `TerminalSurfaceID`, which is what makes
    /// SwiftUI build a new terminal view rather than reuse the one on screen.
    private func replaceTerminal(
        ownsOnStageLifecycle: Bool = false,
        while isStillWanted: @escaping @MainActor () -> Bool
    ) {
        guard isStillWanted() else { return }
        // Synchronous on purpose. `previous.stop()` can wait on the SSH channel
        // teardown, and the user must see recovery throughout that wait rather
        // than the predecessor's `.live` status and an EmptyView overlay.
        let recoveryOwner = UUID()
        terminalRecoveryOwner = recoveryOwner
        activationRecoveryOwnsOnStageLifecycle =
            activationRecoveryOwnsOnStageLifecycle || ownsOnStageLifecycle
        enqueueLifecycleTransition { [weak self] in
            guard let self else { return }
            guard isStillWanted() else {
                if !self.isOnStage() {
                    self.abortTerminalRecoveryOffStage(ownedBy: recoveryOwner)
                } else {
                    self.finishTerminalRecovery(ownedBy: recoveryOwner)
                }
                return
            }
            let previous = self.terminal
            await previous.stop(preservingPendingPaste: true)
            guard isStillWanted() else {
                if !self.isOnStage() {
                    self.abortTerminalRecoveryOffStage(ownedBy: recoveryOwner)
                } else {
                    self.finishTerminalRecovery(ownedBy: recoveryOwner)
                }
                return
            }
            guard self.terminalRecoveryOwner == recoveryOwner else { return }
            let replacement = Self.makeTerminal(
                target: self.target,
                input: self.input,
                transportGeneration: self.transportGeneration,
                runTerminal: self.runTerminal,
                linkIndex: self.linkIndex,
                transportReady: { [weak self] pipelineID, generation in
                    self?.terminalTransportDidBecomeReady(
                        pipelineID: pipelineID, generation: generation)
                },
                runDidFinish: { [weak self] pipelineID in
                    self?.activationRecovery.clear(boundTo: pipelineID)
                })
            self.terminal = replacement
            self.activationRecovery.bind(to: replacement.surfaceID)
            self.finishTerminalRecovery(ownedBy: recoveryOwner)
        }
    }

    private func finishTerminalRecovery(ownedBy owner: UUID) {
        guard terminalRecoveryOwner == owner else { return }
        terminalRecoveryOwner = nil
        activationRecoveryOwnsOnStageLifecycle = false
    }

    func retryTerminal() {
        terminal.retry()
    }

    func confirmClose() async -> Bool {
        await close.confirmClose()
        guard close.state == .closed else { return false }
        await leave().value
        return true
    }

    /// The Attach screen came back after `leave()` or an off-stage recovery
    /// abort.
    ///
    /// `leave()` rides `onDisappear`, which SwiftUI also fires for removals the
    /// user never made — and the state that comes back is the one that left. A
    /// torn-down store cannot serve it: its terminal is stopped for good, which
    /// draws as a black surface with no overlay, no error and no way back. A
    /// fresh terminal pipeline is exactly what an Agent switch would have
    /// built, so build one.
    ///
    /// Only the screen the Console still has on stage may rejoin. SwiftUI
    /// hands spurious appears to *departing* screens too (an Agent switch, a
    /// notification deep link), and a departed screen's view keeps laying out
    /// through the transition — a resurrected pipeline would attach unseen
    /// and hold the Host's only terminal channel, leaving the screen the user
    /// is actually looking at queued behind it on "Connecting…" forever.
    func rejoin() {
        guard lifecycleState != .active, isOnStage() else { return }
        activationRecovery.clear()
        let requiresFullReplacement = lifecycleState == .rejoinRequired
        lifecycleState = .active
        // A rejoin is the latest terminal transition even when it is queued
        // behind an in-flight recovery and the teardown leave enqueued after
        // it. Take presentation ownership synchronously so the recovery task
        // cannot expose its intermediate pipeline before this one lands.
        let recoveryOwner = UUID()
        terminalRecoveryOwner = recoveryOwner
        enqueueLifecycleTransition { [weak self] in
            guard let self else { return }
            guard self.lifecycleState == .active else {
                self.finishTerminalRecovery(ownedBy: recoveryOwner)
                return
            }
            guard self.isOnStage() else {
                self.abortTerminalRecoveryOffStage(ownedBy: recoveryOwner)
                return
            }
            if requiresFullReplacement, self.terminal.status != .stopped {
                await self.terminal.stop(preservingPendingPaste: true)
                guard self.terminalRecoveryOwner == recoveryOwner else { return }
                guard self.lifecycleState == .active else {
                    self.finishTerminalRecovery(ownedBy: recoveryOwner)
                    return
                }
                guard self.isOnStage() else {
                    self.abortTerminalRecoveryOffStage(ownedBy: recoveryOwner)
                    return
                }
            }
            guard self.terminal.status == .stopped else {
                self.finishTerminalRecovery(ownedBy: recoveryOwner)
                return
            }
            guard self.terminalRecoveryOwner == recoveryOwner else { return }
            let replacement = Self.makeTerminal(
                target: self.target,
                input: self.input,
                transportGeneration: self.transportGeneration,
                runTerminal: self.runTerminal,
                linkIndex: self.linkIndex,
                transportReady: { [weak self] pipelineID, generation in
                    self?.terminalTransportDidBecomeReady(
                        pipelineID: pipelineID, generation: generation)
                },
                runDidFinish: { [weak self] pipelineID in
                    self?.activationRecovery.clear(boundTo: pipelineID)
                })
            self.terminal = replacement
            self.activationRecovery.bind(to: replacement.surfaceID)
            self.finishTerminalRecovery(ownedBy: recoveryOwner)
        }
    }

    /// A terminal transition that became invalid off stage never completed,
    /// whether it aborted before or after stopping its predecessor. Record
    /// that outcome so a later on-stage appearance can try again even if
    /// SwiftUI has not delivered the departing screen's delayed
    /// `onDisappear` yet. Only the transition that still owns recovery may
    /// change this state; a stale operation must not turn a newer on-stage
    /// transition back into a leave.
    private func abortTerminalRecoveryOffStage(ownedBy owner: UUID) {
        guard terminalRecoveryOwner == owner, lifecycleState == .active,
            !isOnStage()
        else { return }
        lifecycleState = .rejoinRequired
        activationRecovery.clear()
        finishTerminalRecovery(ownedBy: owner)
    }

    /// Leaves the screen: records the departure and enqueues the teardown,
    /// then returns the teardown for callers that must wait for it.
    ///
    /// Recording is synchronous on purpose. SwiftUI can hand out a spurious
    /// disappear/appear pair back-to-back in one transaction, and `rejoin()`
    /// can only undo a departure that is already visible when it runs — a
    /// leave deferred behind a Task hop runs *after* the rejoin has already
    /// no-opped, and strands a visible screen on a permanently stopped
    /// terminal: black, no overlay, no way back.
    @discardableResult
    func leave() -> Task<Void, Never> {
        leave(preservingOnStageActivationRecovery: true)
    }

    /// A deliberate local destination handoff is not SwiftUI navigation churn.
    /// It must tear down even while a foreground recovery owns the on-stage
    /// lifecycle, because the shell cannot take the Host terminal lease until
    /// this Attach has explicitly released it.
    @discardableResult
    func leaveForTerminalHandoff() -> Task<Void, Never> {
        leave(preservingOnStageActivationRecovery: false)
    }

    private func leave(
        preservingOnStageActivationRecovery: Bool
    ) -> Task<Void, Never> {
        guard lifecycleState != .left else {
            return lifecycleTask ?? Task {}
        }
        if preservingOnStageActivationRecovery,
            lifecycleState == .active,
            activationRecoveryOwnsOnStageLifecycle,
            terminalRecoveryOwner != nil,
            isOnStage()
        {
            return lifecycleTask ?? Task {}
        }
        lifecycleState = .left
        terminalRecoveryOwner = nil
        activationRecoveryOwnsOnStageLifecycle = false
        activationRecovery.clear()
        invalidateAttachLinkOpen()
        attachLinkOpenFailure = nil
        linkIndex.clear()
        input.cancelPaste()
        // Strongly captured on purpose: the owner is `@State` on a view
        // SwiftUI discards right after `onDisappear`, so this task is often
        // the store's last holder. A weak capture silently skips the
        // teardown once the store deallocates — the live session then holds
        // the Host's terminal channel forever and every later attach queues
        // behind it on "Connecting…". The retain is temporary and
        // self-breaking: the task releases the store when the teardown ends.
        return enqueueLifecycleTransition { [self] in
            await staging.leave()
            await terminal.stop()
            linkIndex.clear()
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

    private func invalidateAttachLinkOpen() {
        attachLinkOpenID &+= 1
        attachLinkOpenTask?.cancel()
        attachLinkOpenTask = nil
    }

    private static func makeTerminal(
        target: String,
        input: TerminalInputController,
        transportGeneration: UInt64?,
        runTerminal: @escaping TerminalSessionRunner,
        linkIndex: AttachLinkIndex,
        transportReady: @escaping @MainActor @Sendable (TerminalSurfaceID, UInt64) -> Void = {
            _, _ in
        },
        runDidFinish: @escaping @MainActor @Sendable (TerminalSurfaceID) -> Void = { _ in }
    ) -> AttachTerminalStore {
        AttachTerminalStore(
            target: target,
            takeover: true,
            input: input,
            transportGeneration: transportGeneration,
            observeOutput: { data in linkIndex.receive(data) },
            finishOutput: { linkIndex.finishOutput() },
            transportReady: transportReady,
            runDidFinish: runDidFinish,
            runTerminal: runTerminal)
    }
}
