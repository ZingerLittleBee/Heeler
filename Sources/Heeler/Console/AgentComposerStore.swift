import Foundation
import Observation

/// Local draft operations shared by the plain-text Composer now and future
/// Snippet, Skill, and Staged Image path insertion surfaces.
@MainActor
protocol ComposerDraftOperations: AnyObject {
    func replaceDraft(with text: String)
    func insertIntoDraft(_ text: String)
    func abandonDroppedImagesForTeardown()
    func resumeDroppedImagesAfterRejoin()
}

extension ComposerDraftOperations {
    func abandonDroppedImagesForTeardown() {}
    func resumeDroppedImagesAfterRejoin() {}
}

/// Owns Agent detail's local draft and delivery state. Draft edits do not
/// touch Transport. Send delivers through one `agent.prompt` RPC, except
/// when Agent Status is Blocked: then it inserts into the live Attach PTY
/// without Enter.
@MainActor
@Observable
final class AgentComposerStore: ComposerDraftOperations {
    struct Message: Identifiable, Equatable {
        let id: UUID
        let text: String
        fileprivate var agentWasWorkingAtSend: Bool
        fileprivate var statusRevisionAtSend: UInt64
        fileprivate var observedWorkingAfterSend: Bool
        /// Attach-inserted Blocked drafts are acked by the PTY write. They
        /// do not claim Working/Done from later status pushes.
        fileprivate var tracksAgentProgress: Bool
        fileprivate(set) var state: DeliveryState
    }

    enum DeliveryState: Equatable {
        case sending
        case delivered(AgentProgress)
        case failed(String)
    }

    enum AgentProgress: Equatable {
        case acknowledged
        case agentBusy
        case working
        case done
    }

    /// How Send finished. `.deliveredViaAttach` is the view's cue to present
    /// the tools keyboard so the user can Enter or Esc themselves.
    enum SendResult: Equatable {
        case ignored
        case deliveredViaPrompt
        case deliveredViaAttach
        case failed
    }

    private(set) var messages: [Message] = []
    private(set) var draft = ""
    /// UTF-16 caret/selection, matching the Composer text view.
    private(set) var draftSelection = NSRange(location: 0, length: 0)

    private let target: String
    private var agentStatus: AgentStatus
    private var statusRevision: UInt64 = 0
    private let statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>?
    /// Pace and budget for waiting out a fresh Agent's launch on
    /// `agent_not_ready`; the defaults mirror the transport's
    /// shell-readiness wait (`startAgentAwaitingShell`). Tests inject
    /// smaller values so the wait itself stays under test.
    private let agentNotReadyRetryDelay: Duration
    private let agentNotReadyRetryBudget: Duration
    private let prompt: @Sendable (AgentPromptParams) async throws -> Agent
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// The detail screen's live Attach writer. Weak: Composer outlives any
    /// one Attach pipeline (reconnect replacement), and a dead writer must
    /// fail the Blocked path rather than retain a stale session.
    @ObservationIgnored private weak var attachInput: TerminalInputController?
    /// ADR 0006 picker path. Weak through the bind so staging can keep the
    /// Composer as its draft owner without a retain cycle.
    @ObservationIgnored private weak var staging: ComposerStagingStore?
    /// Dropped images waiting for `ComposerStagingStore.begin(_:)`. Each item
    /// owns a unique placeholder already inserted in `draft`.
    @ObservationIgnored private var pendingDroppedImages: [PendingDroppedImage] = []
    /// Set by ``abandonDroppedImagesForTeardown()`` so leave/cancel events
    /// cannot start the next queued upload.
    @ObservationIgnored private var isTearingDownDroppedImages = false

    private struct PendingDroppedImage {
        enum Status: Equatable {
            case queued
            case staging(operationID: UInt64)
            case awaitingOutcome(operationID: UInt64, retryable: Bool)
        }

        let data: Data
        let placeholder: String
        var status: Status

        var blocksQueue: Bool {
            switch status {
            case .queued:
                false
            case .staging, .awaitingOutcome:
                true
            }
        }
    }

    init(
        target: String,
        initialStatus: AgentStatus = .idle,
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>? = nil,
        agentNotReadyRetryDelay: Duration = AgentComposerStore.defaultAgentNotReadyRetryDelay,
        agentNotReadyRetryBudget: Duration = AgentComposerStore.defaultAgentNotReadyRetryBudget,
        prompt: @escaping @Sendable (AgentPromptParams) async throws -> Agent
    ) {
        self.target = target
        agentStatus = initialStatus
        self.statusUpdates = statusUpdates
        self.agentNotReadyRetryDelay = agentNotReadyRetryDelay
        self.agentNotReadyRetryBudget = agentNotReadyRetryBudget
        self.prompt = prompt
    }

    /// The shell-readiness wait in `HeelerSSHTransport.startAgentAwaitingShell`
    /// covers the 0.7.5 `agent_pane_busy` shape only; on 0.8.0+ the launch
    /// race moved downstream to `agent.prompt`, so the composer carries the
    /// same budget here.
    private static let defaultAgentNotReadyRetryDelay: Duration = .milliseconds(500)
    private static let defaultAgentNotReadyRetryBudget: Duration = .seconds(10)

    deinit {
        statusTask?.cancel()
    }

    var canSend: Bool {
        !hasPendingDroppedImages && draft.contains(where: { !$0.isWhitespace })
    }

    var hasPendingDroppedImages: Bool {
        !pendingDroppedImages.isEmpty
    }

    /// VoiceOver hint for the Send button. Pending drops disable Send.
    var sendAccessibilityHint: String {
        hasPendingDroppedImages
            ? "Waiting for image…"
            : "Delivers the complete draft to the Agent"
    }

    var pendingDropPlaceholders: [String] {
        pendingDroppedImages.map(\.placeholder)
    }

    func replaceDraft(with text: String) {
        draft = text
        draftSelection = NSRange(location: (text as NSString).length, length: 0)
    }

    /// Inserts at the current caret, or replaces the current selection. This
    /// is the Snippet / Skill / staged-path insertion path: the draft changes
    /// and nothing is submitted.
    func insertIntoDraft(_ text: String) {
        let range = Self.clamped(draftSelection, to: draft)
        draft = (draft as NSString).replacingCharacters(in: range, with: text)
        draftSelection = NSRange(
            location: range.location + (text as NSString).length,
            length: 0)
    }

    func setDraftSelection(_ range: NSRange) {
        let clamped = Self.clamped(range, to: draft)
        guard draftSelection != clamped else { return }
        draftSelection = clamped
    }

    /// Typing and selection changes from the Composer text view. Unlike
    /// ``replaceDraft(with:)``, this keeps the view's caret.
    func applyEditorDraft(_ text: String, selection: NSRange) {
        let clamped = Self.clamped(selection, to: text)
        guard draft != text || draftSelection != clamped else { return }
        draft = text
        draftSelection = clamped
    }

    /// Forwards dropped images onto ``ComposerStagingStore.begin(_:)``, the
    /// same call the photo picker uses. One operation at a time; extras queue.
    func bindStaging(_ staging: ComposerStagingStore) {
        self.staging = staging
        isTearingDownDroppedImages = false
        staging.onOperationEvent = { [weak self] event in
            self?.handleDroppedImageStagingEvent(event)
        }
        startNextDroppedImageIfNeeded()
    }

    /// Maps a drop onto draft insertion and/or the ADR 0006 staging path.
    /// Empty and unsupported items are skipped without touching the draft or
    /// submitting it. Each image inserts a unique placeholder; later text
    /// stays after it, and the Host path replaces that token.
    func acceptDrop(_ items: [ComposerDropItem]) {
        for item in items {
            switch item {
            case .text(let text):
                guard !text.isEmpty else { continue }
                insertIntoDraft(text)
            case .image(let data, _):
                guard !data.isEmpty else { continue }
                reserveDroppedImage(data)
            case .unsupported:
                continue
            }
        }
        startNextDroppedImageIfNeeded()
    }

    /// Visible token inserted for a queued drop. Private-use scalars plus a
    /// UUID fragment so ordinary user text cannot collide with it.
    static func makeDropPlaceholder(uuid: UUID = UUID()) -> String {
        let hex = String(
            uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        ).lowercased()
        return "\u{E000}img:\(hex)\u{E001}"
    }

    static func containsDropPlaceholder(_ text: String) -> Bool {
        let prefix = "\u{E000}img:"
        let suffix: Character = "\u{E001}"
        var search = text.startIndex
        while let start = text[search...].range(of: prefix) {
            let hexStart = start.upperBound
            guard let hexEnd = text.index(hexStart, offsetBy: 8, limitedBy: text.endIndex),
                hexEnd < text.endIndex,
                text[hexEnd] == suffix,
                text[hexStart..<hexEnd].allSatisfy(\.isHexDigit)
            else {
                search = start.upperBound
                continue
            }
            return true
        }
        return false
    }

    /// Clears queued drops and their tokens before staging teardown. Later
    /// cancel/dismiss events must not start another upload.
    func abandonDroppedImagesForTeardown() {
        isTearingDownDroppedImages = true
        for item in pendingDroppedImages {
            applyTokenReplacement(item.placeholder, firstReplacement: "")
        }
        pendingDroppedImages.removeAll()
    }

    /// Called after a serial leave has finished. Same-store rejoin does not
    /// reconstruct Attach or re-bind staging.
    func resumeDroppedImagesAfterRejoin() {
        isTearingDownDroppedImages = false
        startNextDroppedImageIfNeeded()
    }

    /// Completes an inline Skill suggestion: swaps the typed trigger token at
    /// the end of the draft for the full invocation. A draft that no longer
    /// ends with the token — edited under a stale suggestion — is left alone
    /// rather than mangled.
    func replaceTrailingToken(_ token: String, with text: String) {
        guard !token.isEmpty, draft.hasSuffix(token) else { return }
        draft.removeLast(token.count)
        draft.append(text)
        draftSelection = NSRange(location: (draft as NSString).length, length: 0)
    }

    /// Starts consuming Console's existing per-Agent status fan-out. This
    /// does not open a Transport event stream or perform an RPC.
    func open() {
        guard !hasOpened else { return }
        hasOpened = true
        guard let statusUpdates else { return }
        statusTask = Task { [weak self] in
            for await update in statusUpdates {
                guard !Task.isCancelled, let self else { return }
                if let status = update.status {
                    self.agentStatusDidChange(status)
                }
            }
        }
    }

    /// The already-open Attach PTY writer owned by Agent detail. Blocked
    /// Send uses the same pipe as the tools keyboard.
    func bindAttachInput(_ input: TerminalInputController?) {
        attachInput = input
    }

    @discardableResult
    func send() async -> SendResult {
        guard canSend, !containsPendingPlaceholderInDraft else { return .ignored }
        let message = Message(
            id: UUID(), text: draft,
            agentWasWorkingAtSend: agentStatus == .working,
            statusRevisionAtSend: statusRevision,
            observedWorkingAfterSend: false,
            tracksAgentProgress: true,
            state: .sending)
        draft = ""
        draftSelection = NSRange(location: 0, length: 0)
        messages.append(message)
        return await deliver(message.id)
    }

    @discardableResult
    func retry(_ id: Message.ID) async -> SendResult {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return .ignored }
        guard case .failed = messages[index].state else { return .ignored }
        messages[index].agentWasWorkingAtSend = agentStatus == .working
        messages[index].statusRevisionAtSend = statusRevision
        messages[index].observedWorkingAfterSend = false
        messages[index].tracksAgentProgress = true
        messages[index].state = .sending
        return await deliver(id)
    }

    /// Removes a failed echo and restores all of its text to the draft. If
    /// the user has already started another draft, both are kept in order.
    func withdrawToDraft(_ id: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        guard case .failed = messages[index].state else { return }
        let text = messages.remove(at: index).text
        draft = draft.isEmpty ? text : "\(text)\n\(draft)"
    }

    func agentStatusDidChange(_ status: AgentStatus) {
        guard agentStatus != status else { return }
        agentStatus = status
        statusRevision &+= 1
        for index in messages.indices {
            guard messages[index].tracksAgentProgress else { continue }
            if status == .working,
                messages[index].statusRevisionAtSend != statusRevision
            {
                messages[index].observedWorkingAfterSend = true
            }
            guard case .delivered(let progress) = messages[index].state else { continue }
            switch status {
            case .working
                where progress != .done && messages[index].observedWorkingAfterSend:
                messages[index].state = .delivered(.working)
            case .done
                where messages[index].observedWorkingAfterSend
                    || !messages[index].agentWasWorkingAtSend:
                messages[index].state = .delivered(.done)
            case .idle where messages[index].observedWorkingAfterSend:
                messages[index].state = .delivered(.done)
            default:
                break
            }
        }
    }

    private func deliver(_ id: Message.ID) async -> SendResult {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return .ignored }
        let text = messages[index].text
        if Self.containsDropPlaceholder(text) {
            return .ignored
        }
        if agentStatus == .blocked {
            return deliverThroughAttach(id, text: text)
        }
        let input = attachInput
        let generation = input?.liveGeneration
        do {
            _ = try await promptWaitingOutLaunch(
                AgentPromptParams(target: target, text: text))
            guard let acknowledgedIndex = messages.firstIndex(where: { $0.id == id }) else {
                return .ignored
            }
            messages[acknowledgedIndex].state = .delivered(
                progressAfterAcknowledgment(for: messages[acknowledgedIndex]))
            if let input, let generation {
                input.recordSubmitted(text, generation: generation)
            }
            return .deliveredViaPrompt
        } catch {
            if Self.isAgentBlocked(error) {
                return deliverThroughAttach(id, text: text)
            }
            return fail(id, message: Self.message(for: error))
        }
    }

    /// Delivers one `agent.prompt` request, waiting out a fresh launch's
    /// `agent_not_ready` rejections first. herdr 0.8.0+ answers `agent.start`
    /// while the pane's agent is still booting (`launch_pending`), so the
    /// first prompt of a just-started Agent can beat the agent's registration
    /// on the Host and be refused with "agent wX:pY is not an active named
    /// agent" — the pane id is correct, and re-entering the session later
    /// finds it active because only time was missing. Retrying on that code
    /// alone, at a fixed pace inside a bounded budget (the transport's
    /// shell-readiness wait shape), keeps that bubble off the user's first
    /// send while a genuinely absent Agent (`agent_not_found`) still fails
    /// immediately.
    private func promptWaitingOutLaunch(
        _ params: AgentPromptParams
    ) async throws -> Agent {
        let deadline = ContinuousClock.now + agentNotReadyRetryBudget
        while true {
            do {
                return try await prompt(params)
            } catch let error where Self.isAgentNotReady(error) {
                guard ContinuousClock.now + agentNotReadyRetryDelay < deadline else {
                    throw error
                }
                try await Task.sleep(for: agentNotReadyRetryDelay)
            }
        }
    }

    /// Types the draft into the live Attach PTY without submitting. Matches
    /// tools-keyboard writes: UTF-8 bytes, no bracketed paste, no Enter.
    /// Those bytes already cross `TerminalInputController`'s writer, which
    /// indexes them; do not also `record(submitted:)` here.
    private func deliverThroughAttach(_ id: Message.ID, text: String) -> SendResult {
        guard !Self.containsDropPlaceholder(text) else { return .ignored }
        guard TerminalTextSafety.containsOnlySafeScalars(text) else {
            return fail(id, message: Self.unsafeTextMessage)
        }
        guard let attachInput, attachInput.insertComposerDraft(text) else {
            return fail(id, message: Self.missingAttachMessage)
        }
        guard let deliveredIndex = messages.firstIndex(where: { $0.id == id }) else {
            return .ignored
        }
        messages[deliveredIndex].tracksAgentProgress = false
        messages[deliveredIndex].state = .delivered(.acknowledged)
        return .deliveredViaAttach
    }

    @discardableResult
    private func fail(_ id: Message.ID, message: String) -> SendResult {
        guard let failedIndex = messages.firstIndex(where: { $0.id == id }) else {
            return .ignored
        }
        messages[failedIndex].state = .failed(message)
        return .failed
    }

    private static func isAgentNotReady(_ error: any Error) -> Bool {
        if let apiError = error as? HerdrAPIError {
            return apiError.code == "agent_not_ready"
        }
        if let transportError = error as? TransportError,
            case .apiRejected(let code, _) = transportError
        {
            return code == "agent_not_ready"
        }
        return false
    }

    private static func isAgentBlocked(_ error: any Error) -> Bool {
        if let apiError = error as? HerdrAPIError {
            return apiError.code == "agent_blocked"
        }
        if let transportError = error as? TransportError,
            case .apiRejected(let code, _) = transportError
        {
            return code == "agent_blocked"
        }
        return false
    }

    private func progressAfterAcknowledgment(for message: Message) -> AgentProgress {
        if message.observedWorkingAfterSend {
            switch agentStatus {
            case .working:
                return .working
            case .done, .idle:
                return .done
            default:
                break
            }
        } else if !message.agentWasWorkingAtSend,
            message.statusRevisionAtSend != statusRevision,
            agentStatus == .done
        {
            // The status stream keeps only the newest event. A fast
            // working-to-done pair can therefore arrive as Done alone.
            return .done
        }
        return message.agentWasWorkingAtSend ? .agentBusy : .acknowledged
    }

    private static let missingAttachMessage =
        "The message could not be sent. Check the connection and retry."
    private static let unsafeTextMessage =
        "The message contains unsafe terminal control characters."

    private var containsPendingPlaceholderInDraft: Bool {
        pendingDroppedImages.contains { draft.contains($0.placeholder) }
            || Self.containsDropPlaceholder(draft)
    }

    private func reserveDroppedImage(_ data: Data) {
        let placeholder = Self.makeDropPlaceholder()
        insertIntoDraft(placeholder)
        pendingDroppedImages.append(
            PendingDroppedImage(
                data: data,
                placeholder: placeholder,
                status: .queued))
    }

    private func handleDroppedImageStagingEvent(_ event: ComposerStagingStore.OperationEvent) {
        guard !isTearingDownDroppedImages else { return }
        switch event {
        case .completed(let id, let path):
            fulfillDroppedImage(id: id, path: path)
        case .cancelled(let id), .dismissed(let id):
            abandonDroppedImage(id: id)
        case .failed(let id, let retryable):
            failDroppedImage(id: id, retryable: retryable)
        }
        startNextDroppedImageIfNeeded()
    }

    private func fulfillDroppedImage(id: UInt64, path: String) {
        guard let index = indexOfDroppedImage(id: id) else { return }
        let placeholder = pendingDroppedImages[index].placeholder
        pendingDroppedImages.remove(at: index)
        let insertion = "\(path) "
        if !applyTokenReplacement(placeholder, firstReplacement: insertion) {
            insertIntoDraft(insertion)
        }
    }

    private func abandonDroppedImage(id: UInt64) {
        guard let index = indexOfDroppedImage(id: id) else { return }
        let placeholder = pendingDroppedImages[index].placeholder
        pendingDroppedImages.remove(at: index)
        applyTokenReplacement(placeholder, firstReplacement: "")
    }

    private func failDroppedImage(id: UInt64, retryable: Bool) {
        guard let index = indexOfDroppedImage(id: id) else { return }
        if retryable {
            pendingDroppedImages[index].status = .awaitingOutcome(
                operationID: id,
                retryable: true)
            return
        }
        abandonDroppedImage(id: id)
    }

    private func startNextDroppedImageIfNeeded() {
        guard let staging, !isTearingDownDroppedImages else { return }
        if pendingDroppedImages.contains(where: { $0.blocksQueue }) { return }
        switch staging.state {
        case .idle, .completed:
            break
        case .failed, .backgroundInterrupted, .preparing, .uploading:
            return
        }
        guard let index = pendingDroppedImages.firstIndex(where: { $0.status == .queued })
        else { return }
        guard
            let id = staging.begin(
                .photo(DataImageSelection(data: pendingDroppedImages[index].data)),
                insertPathIntoComposer: false)
        else { return }
        pendingDroppedImages[index].status = .staging(operationID: id)
    }

    private func indexOfDroppedImage(id: UInt64) -> Int? {
        pendingDroppedImages.firstIndex { item in
            switch item.status {
            case .staging(let operationID), .awaitingOutcome(let operationID, _):
                operationID == id
            case .queued:
                false
            }
        }
    }

    /// Replaces the first exact token and deletes any later copies the user
    /// duplicated. Returns false when the token is gone.
    @discardableResult
    private func applyTokenReplacement(_ token: String, firstReplacement: String) -> Bool {
        guard !token.isEmpty else { return false }
        var found = false
        var isFirst = true
        while true {
            let range = (draft as NSString).range(of: token)
            guard range.location != NSNotFound else { break }
            let replacement = isFirst ? firstReplacement : ""
            draft = (draft as NSString).replacingCharacters(in: range, with: replacement)
            draftSelection = Self.selection(
                afterReplacing: range,
                with: (replacement as NSString).length,
                current: draftSelection)
            found = true
            isFirst = false
        }
        return found
    }

    private static func selection(
        afterReplacing range: NSRange,
        with replacementLength: Int,
        current: NSRange
    ) -> NSRange {
        let delta = replacementLength - range.length
        let rangeEnd = range.location + range.length
        if current.location >= rangeEnd {
            return NSRange(location: current.location + delta, length: current.length)
        }
        if current.location + current.length <= range.location {
            return current
        }
        return NSRange(location: range.location + replacementLength, length: 0)
    }

    private static func clamped(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(range.location, 0), length)
        let remaining = length - location
        let clampedLength = min(max(range.length, 0), remaining)
        return NSRange(location: location, length: clampedLength)
    }

    static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected. Check the connection and retry."
        case TransportError.timedOut:
            "The Host did not answer. Check the connection and retry."
        case let error as HerdrAPIError:
            "herdr rejected the message: \(error.message)"
        case let error as TransportError:
            error.presentation.message
        default:
            missingAttachMessage
        }
    }
}
