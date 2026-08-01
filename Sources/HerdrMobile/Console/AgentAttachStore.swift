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

    private(set) var terminal: AttachTerminalStore
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
        runTerminal: @escaping TerminalSessionRunner,
        stageImage: @escaping ImageStager,
        closePane: @escaping () async throws -> Void
    ) {
        let input = TerminalInputController()
        self.target = target
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

    var terminalID: ObjectIdentifier {
        ObjectIdentifier(terminal)
    }

    var terminalStatus: AttachTerminalStore.Status {
        terminal.status
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

    func viewDidResize(cols: Int, rows: Int) {
        terminal.viewDidResize(cols: cols, rows: rows)
    }

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

    func didBecomeActive() {
        image.didBecomeActive()
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
        enqueueLifecycleTransition { [weak self] in
            guard let self, !self.hasLeft, self.transportGeneration == generation else { return }
            let previous = self.terminal
            await previous.stop()
            guard !self.hasLeft, self.transportGeneration == generation else { return }
            self.terminal = Self.makeTerminal(
                target: self.target,
                input: self.input,
                runTerminal: self.runTerminal,
                linkIndex: self.linkIndex)
        }
    }

    func retryTerminal() {
        terminal.retry()
    }

    func confirmClose() async -> Bool {
        await close.confirmClose()
        guard close.state == .closed else { return false }
        await leave()
        return true
    }

    func leave() async {
        guard !hasLeft else {
            await lifecycleTask?.value
            return
        }
        hasLeft = true
        invalidateAttachLinkOpen()
        attachLinkOpenFailure = nil
        linkIndex.clear()
        let transition = enqueueLifecycleTransition { [weak self] in
            guard let self else { return }
            await self.image.leaveAttach()
            await self.terminal.stop()
            self.linkIndex.clear()
        }
        await transition.value
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
