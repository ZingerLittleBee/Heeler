import Foundation
import Observation

typealias AttachLinkOpener = @MainActor @Sendable (URL) async -> Bool

struct AttachLinkOpenFailure: Identifiable, Equatable {
    let link: AttachLink

    var id: String { link.id }
    var message: String {
        "The link to \(link.host) couldn't be opened. You can copy it instead."
    }
}

/// Owns the complete Agent Attach interaction: terminal lifetime, input
/// generation and pause state, image staging, reconnect replacement, close,
/// and deterministic leave ordering. The view only forwards UI events.
@MainActor
@Observable
final class AgentAttachStore {
    private let target: String
    private let runTerminal: TerminalSessionRunner
    private let linkIndex: AttachLinkIndex
    /// Whether this screen is still the Console's current detail. The
    /// router's path is the ground truth SwiftUI's appear/disappear
    /// callbacks lack: they hand out spurious pairs amid navigation churn,
    /// on departing screens as well as staying ones.
    private let isOnStage: () -> Bool

    private(set) var terminal: AttachTerminalStore
    #if DEBUG
    /// Whether UIKit built and attached the current terminal surface. This is
    /// a lifecycle observation only; Ghostty exposes no acknowledgement that
    /// its render loop presented a frame.
    private(set) var terminalSurfaceAttached = false
    #endif
    let input: TerminalInputController
    let image: ImageAttachStore
    let close: ClosePaneStore
    private(set) var attachLinkOpenFailure: AttachLinkOpenFailure?

    private var transportGeneration: UInt64?
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleID: UInt64 = 0
    private var attachLinkOpenTask: Task<Void, Never>?
    private var attachLinkOpenID: UInt64 = 0
    private var hasLeft = false

    init(
        target: String,
        paneTitle: String,
        transportGeneration: UInt64?,
        isOnStage: @escaping () -> Bool,
        runTerminal: @escaping TerminalSessionRunner,
        stageImage: @escaping ImageStager,
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
            target: target, input: input, runTerminal: runTerminal, linkIndex: linkIndex)
        image = ImageAttachStore(stageImage: stageImage, input: input)
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
    /// left keeps the real status — it is on its way off stage and must not
    /// flash a spinner on the way out.
    var terminalStatus: AttachTerminalStore.Status {
        if terminal.status == .stopped, !hasLeft {
            return .connecting
        }
        return terminal.status
    }

    var terminalFeed: TerminalByteFeed {
        terminal.feed
    }

    var attachLinks: [AttachLink] {
        linkIndex.links
    }

    var imageState: ImageAttachState {
        image.state
    }

    var canSelectImage: Bool {
        terminal.status == .live && image.canSelectImage
    }

    var isLocalInputEnabled: Bool {
        !input.isPaused
    }

    var pendingPaste: TerminalInputController.PasteReview? {
        input.pendingPaste
    }

    var pasteErrorMessage: String? {
        input.pasteErrorMessage
    }

    var closeFailureMessage: String? {
        guard case .failed(let message) = close.state else { return nil }
        return message
    }

    /// A size report from a screen that has left must not start anything:
    /// a departed view still lays out during its exit transition.
    func viewDidResize(cols: Int, rows: Int) {
        guard !hasLeft else { return }
        terminal.viewDidResize(cols: cols, rows: rows)
    }

    #if DEBUG
    func terminalSurfaceDidAttach(_ surfaceID: TerminalSurfaceID) {
        guard !hasLeft, surfaceID == terminalID else { return }
        terminalSurfaceAttached = true
    }
    #endif

    func viewportTextDidChange(_ text: String) {
        guard !hasLeft else { return }
        linkIndex.receiveViewportText(text)
    }

    func openAttachLink(_ link: AttachLink, using open: @escaping AttachLinkOpener) {
        guard !hasLeft else { return }
        attachLinkOpenFailure = nil
        invalidateAttachLinkOpen()
        let openID = attachLinkOpenID
        attachLinkOpenTask = Task { @MainActor [weak self] in
            let accepted = await open(link.url)
            guard
                let self,
                !Task.isCancelled,
                !self.hasLeft,
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
        _ = input.confirmPaste()
    }

    func clearPasteError() {
        input.clearPasteError()
    }

    func selectImage(_ selection: any ImageSelection) {
        image.select(selection)
    }

    func cancelImage() {
        image.cancel()
    }

    func retryImage() {
        image.retry()
    }

    func dismissImageResult() {
        image.dismissResult()
    }

    func copyImagePath() {
        image.copyPath()
    }

    func insertImagePath() {
        image.insertPath()
    }

    /// A short foreground bounce keeps the current PTY and asks it to repaint.
    /// Once the app may have suspended, replace the complete terminal pipeline
    /// immediately: PTY Attach, input session ownership, byte feed and surface
    /// identity. The surrounding Attach interaction remains the same owner, so
    /// links, image actions and a reviewed Paste survive the recovery.
    func didBecomeActive(afterPossibleSuspension: Bool = false) {
        image.didBecomeActive()
        guard !hasLeft else { return }
        guard !afterPossibleSuspension else {
            replaceTerminal { [weak self] in self?.hasLeft == false }
            return
        }
        terminal.didBecomeActive()
    }

    func didEnterBackground() {
        image.didEnterBackground()
    }

    /// A new Transport requires a new terminal pipeline. The replacement is
    /// serialized behind any earlier transition and starts only after the
    /// old terminal has finished. Image state deliberately survives: the
    /// stager resolves the live Transport per call, so a retryable or
    /// completed upload stays actionable across the reconnect.
    func transportGenerationDidChange(_ generation: UInt64?) {
        guard let generation, generation != transportGeneration, !hasLeft else { return }
        transportGeneration = generation
        replaceTerminal { [weak self] in
            guard let self else { return false }
            return !self.hasLeft && self.transportGeneration == generation
        }
    }

    /// Tears the terminal pipeline down and builds a fresh one, serialized
    /// behind any earlier transition. `isStillWanted` is re-asked after the
    /// teardown, which is the only await in here and therefore the only place
    /// the reason for the replacement can go stale.
    ///
    /// The new pipeline carries a new `TerminalSurfaceID`, which is what makes
    /// SwiftUI build a new terminal view rather than reuse the one on screen.
    private func replaceTerminal(while isStillWanted: @escaping @MainActor () -> Bool) {
        guard isStillWanted() else { return }
        enqueueLifecycleTransition { [weak self] in
            guard let self, isStillWanted() else { return }
            let previous = self.terminal
            await previous.stop(preservingPendingPaste: true)
            guard isStillWanted() else { return }
            self.terminal = Self.makeTerminal(
                target: self.target,
                input: self.input,
                runTerminal: self.runTerminal,
                linkIndex: self.linkIndex)
            #if DEBUG
            self.terminalSurfaceAttached = false
            #endif
        }
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

    /// The Attach screen came back after `leave()`.
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
        guard hasLeft, isOnStage() else { return }
        hasLeft = false
        enqueueLifecycleTransition { [weak self] in
            guard let self, !self.hasLeft, self.terminal.status == .stopped else { return }
            self.terminal = Self.makeTerminal(
                target: self.target,
                input: self.input,
                runTerminal: self.runTerminal,
                linkIndex: self.linkIndex)
            #if DEBUG
            self.terminalSurfaceAttached = false
            #endif
        }
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
        guard !hasLeft else {
            return lifecycleTask ?? Task {}
        }
        hasLeft = true
        invalidateAttachLinkOpen()
        attachLinkOpenFailure = nil
        linkIndex.clear()
        // Strongly captured on purpose: the owner is `@State` on a view
        // SwiftUI discards right after `onDisappear`, so this task is often
        // the store's last holder. A weak capture silently skips the
        // teardown once the store deallocates — the live session then holds
        // the Host's terminal channel forever and every later attach queues
        // behind it on "Connecting…". The retain is temporary and
        // self-breaking: the task releases the store when the teardown ends.
        return enqueueLifecycleTransition { [self] in
            await image.leaveAttach()
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
        runTerminal: @escaping TerminalSessionRunner,
        linkIndex: AttachLinkIndex
    ) -> AttachTerminalStore {
        AttachTerminalStore(
            target: target,
            input: input,
            observeOutput: { data in linkIndex.receive(data) },
            finishOutput: { linkIndex.finishOutput() },
            runTerminal: runTerminal)
    }
}
