import Foundation
import Observation
import os

/// Local draft operations shared by the plain-text Composer, Snippet and Skill
/// insertion, file path insertion, and staged image attachments.
@MainActor
protocol ComposerDraftOperations: AnyObject {
    func replaceDraft(with text: String)
    func insertIntoDraft(_ text: String)
    /// Inserts a staged Host path as a word of its own (ADR 0006).
    func insertPathIntoDraft(_ path: String)
    /// True when staged images are held as visual Composer attachments
    /// instead of raw path insertions into `draft`.
    var retainsImageAttachments: Bool { get }
    func imageStagingDidBegin(operationID: UInt64)
    func imageStagingDidBegin(operationID: UInt64, kind: ComposerImageAttachment.MediaKind)
    func imageStagingDidPrepare(
        operationID: UInt64,
        preview: ComposerImageAttachment.Preview,
        progress: AttachmentStageProgress)
    func imageStagingDidProgress(operationID: UInt64, progress: AttachmentStageProgress)
    func imageStagingDidComplete(
        operationID: UInt64,
        path: String,
        preview: ComposerImageAttachment.Preview?)
    func imageStagingDidFail(
        operationID: UInt64,
        failure: ComposerStagingStore.Failure,
        preview: ComposerImageAttachment.Preview?)
    func imageStagingDidCancel(operationID: UInt64)
    func imageStagingDidDismiss(operationID: UInt64)
    func stagingDidSettle()
}

extension ComposerDraftOperations {
    var retainsImageAttachments: Bool { false }
    func imageStagingDidBegin(operationID: UInt64) {}
    func imageStagingDidBegin(operationID: UInt64, kind: ComposerImageAttachment.MediaKind) {
        imageStagingDidBegin(operationID: operationID)
    }
    func imageStagingDidPrepare(
        operationID: UInt64,
        preview: ComposerImageAttachment.Preview,
        progress: AttachmentStageProgress
    ) {}
    func imageStagingDidProgress(operationID: UInt64, progress: AttachmentStageProgress) {}
    func imageStagingDidComplete(
        operationID: UInt64,
        path: String,
        preview: ComposerImageAttachment.Preview?
    ) {}
    func imageStagingDidFail(
        operationID: UInt64,
        failure: ComposerStagingStore.Failure,
        preview: ComposerImageAttachment.Preview?
    ) {}
    func imageStagingDidCancel(operationID: UInt64) {}
    func imageStagingDidDismiss(operationID: UInt64) {}
    func stagingDidSettle() {}
}

/// Owns Agent detail's local draft and delivery state. Draft edits do not
/// touch Transport. Send delivers through one `agent.prompt` RPC, except
/// when Agent Status is Blocked: then the terminal's policy inserts into the
/// live Attach PTY without Enter, and Chat's refuses.
///
/// Both surfaces share the one draft; each message remembers which surface
/// sent it.
@MainActor
@Observable
final class AgentComposerStore: ComposerDraftOperations {
    struct Message: Identifiable, Equatable {
        let id: UUID
        let text: String
        let route: ComposerRoute
        let stagedImagePaths: [String]
        fileprivate let draftText: String
        fileprivate var stagedImages: [ComposerImageAttachment]
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
        /// `agent.prompt` succeeded but the text stayed in the Agent's input
        /// box. Never resent: the user decides in the terminal.
        case undelivered
        /// A herdr-core step got no answer, so the paste or its submit may
        /// still reach the program. Retry refuses it: the user decides what the
        /// terminal shows.
        case outcomeUnknown
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
        /// A checked Send pasted and pressed the submit key after its checks.
        case submittedViaAttach
        case failed
        /// The policy declined the draft, which is back in the Composer.
        case refused(ComposerRefusal)
        /// A checked step got no answer. The message stays as it is.
        case outcomeUnknown
    }

    private(set) var messages: [Message] = []
    private(set) var draft = "" {
        didSet {
            if draft != oldValue { notice = nil }
        }
    }
    /// Staged and uploading images attached above the text input.
    private(set) var imageAttachments: [ComposerImageAttachment] = []
    /// Recovery keeps the draft editable, but never queues it for delivery.
    var isConnectionAvailable = true
    /// tmux offers Stop while the Agent is Blocked as well as Working.
    var offersStopWhileBlocked = false
    /// Why the last Send or Retry was refused. Changing the draft ends it,
    /// as does the next Send that goes; a transient refusal also ends when
    /// Agent Status changes, since the Agent it described has moved on.
    private(set) var notice: ComposerNotice?
    /// UTF-16 caret/selection, matching the Composer text view.
    private(set) var draftSelection = NSRange(location: 0, length: 0)
    /// Stop's wait, per Agent like the draft: the other surface, a rebuilt
    /// one or a reconnect finds an Esc still waiting on the Agent.
    let stop: AgentComposerStopStore
    /// Voice Input for this draft (ADR 0036). Send waits while it records
    /// or transcribes, so the text always has a draft to land in.
    let voice: ComposerVoiceInput
    /// How the recorder's Send delivers the draft once the text lands: the
    /// policy of the surface and window whose Send was tapped, since the
    /// same Composer can be open on another surface or in another window.
    @ObservationIgnored private var voiceSendPolicy: ComposerDeliveryPolicy?
    /// Bumped when On Device's Stop has landed its text; the view puts the
    /// caret in the input.
    private(set) var voiceFocusRequests = 0

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
    /// How this Host's projection delivers instead of `prompt`, when it checks
    /// Send itself (ADR 0035).
    @ObservationIgnored private let checkedSend: (any CheckedComposerSend)?
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// The detail screen's live Attach writer. Weak: Composer outlives any
    /// one Attach pipeline (reconnect replacement), and a dead writer must
    /// fail the Blocked path rather than retain a stale session.
    @ObservationIgnored private weak var attachInput: TerminalInputController?
    /// ADR 0006 picker path. Weak through the bind so staging can keep the
    /// Composer as its draft owner without a retain cycle.
    @ObservationIgnored private weak var staging: ComposerStagingStore?
    /// Queued image selections waiting for `ComposerStagingStore.begin(_:)`.
    @ObservationIgnored private var queuedImageSelections: [UUID: any ImageSelection] = [:]
    /// Queued video file selections represented as pills in `imageAttachments`.
    @ObservationIgnored private var queuedVideoSelections: [UUID: any FileSelection] = [:]
    /// Queued non-video file selections waiting for `ComposerStagingStore.begin(_:)`.
    @ObservationIgnored private var queuedFileSelections: [any FileSelection] = []
    /// Maps active `ComposerStagingStore` operation ids to attachment ids.
    @ObservationIgnored private var activeImageOperations: [UInt64: UUID] = [:]
    /// Identifies the queued attachment currently entering `staging.begin(_:)`.
    @ObservationIgnored private var startingQueuedAttachmentID: UUID?
    /// Set by ``abandonDroppedImagesForTeardown()`` so leave/cancel events
    /// cannot start the next queued upload.
    @ObservationIgnored private var isTearingDownImages = false
    /// Tracks local `PreparedImage` files owned by this store so `deinit`
    /// removes any uncollected temporary copies safely across isolation.
    @ObservationIgnored private let retainedPreviewURLs = OSAllocatedUnfairLock(initialState: Set<URL>())
    /// Tracks temporary inbox directories for queued file selections so `deinit`
    /// removes unstarted drop copies safely across isolation.
    @ObservationIgnored private let retainedInboxURLs = OSAllocatedUnfairLock(initialState: Set<URL>())
    /// The editor holds marked text. Writing the draft then would destroy
    /// it, so Voice Input's text waits until the composition ends.
    @ObservationIgnored private var isEditorComposing = false

    init(
        target: String,
        initialStatus: AgentStatus = .idle,
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>? = nil,
        agentNotReadyRetryDelay: Duration = AgentComposerStore.defaultAgentNotReadyRetryDelay,
        agentNotReadyRetryBudget: Duration = AgentComposerStore.defaultAgentNotReadyRetryBudget,
        stop: AgentComposerStopStore = AgentComposerStopStore(),
        checkedSend: (any CheckedComposerSend)? = nil,
        voice: ComposerVoiceInput = ComposerVoiceInput(),
        prompt: @escaping @Sendable (AgentPromptParams) async throws -> Agent
    ) {
        self.target = target
        agentStatus = initialStatus
        self.statusUpdates = statusUpdates
        self.stop = stop
        self.checkedSend = checkedSend
        self.voice = voice
        self.agentNotReadyRetryDelay = agentNotReadyRetryDelay
        self.agentNotReadyRetryBudget = agentNotReadyRetryBudget
        self.prompt = prompt
        voice.onTranscript = { [weak self] in self?.insertVoiceTextIfReady() }
    }

    /// The shell-readiness wait in `HeelerSSHTransport.startAgentAwaitingShell`
    /// ends once herdr accepts `agent.start`, and since 0.8.0 herdr accepts it
    /// while the agent is still booting (`launch_pending`), so the first
    /// `agent.prompt` can race the launch; the composer waits that out with
    /// the same pace and budget.
    private static let defaultAgentNotReadyRetryDelay: Duration = .milliseconds(500)
    private static let defaultAgentNotReadyRetryBudget: Duration = .seconds(10)

    deinit {
        statusTask?.cancel()
        let urls = retainedPreviewURLs.withLock { urls -> Set<URL> in
            let copy = urls
            urls.removeAll()
            return copy
        }
        let inboxURLs = retainedInboxURLs.withLock { urls -> Set<URL> in
            let copy = urls
            urls.removeAll()
            return copy
        }
        for url in urls.union(inboxURLs) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    var retainsImageAttachments: Bool { true }

    var readyImagePaths: [String] {
        imageAttachments.compactMap(\.phase.readyPath)
    }

    var hasPendingImages: Bool {
        imageAttachments.contains(where: \.phase.isPending)
    }

    var hasPendingDroppedImages: Bool {
        hasPendingImages
    }

    /// The text Send delivers: typed prose plus any ready staged image paths.
    var composedDraft: String {
        Self.composePrompt(draft: draft, imagePaths: readyImagePaths)
    }

    static func composePrompt(draft: String, imagePaths: [String]) -> String {
        guard !imagePaths.isEmpty else { return draft }
        let joinedPaths = imagePaths.joined(separator: " ") + " "
        guard draft.contains(where: { !$0.isWhitespace }) else { return joinedPaths }
        if let last = draft.last, last.isWhitespace {
            return draft + joinedPaths
        }
        return "\(draft) \(joinedPaths)"
    }

    var canSend: Bool {
        isConnectionAvailable && !hasPendingImages && !voice.blocksSend
            && (!readyImagePaths.isEmpty || draft.contains(where: { !$0.isWhitespace }))
    }

    /// VoiceOver hint for the Send button. Pending images/videos and Voice Input
    /// disable Send.
    var sendAccessibilityHint: String {
        if !isConnectionAvailable {
            return String(localized: "Waiting for the Host connection")
        }
        if hasPendingImages {
            let hasPendingImage = imageAttachments.contains { $0.kind == .image && $0.phase.isPending }
            if !hasPendingImage, imageAttachments.contains(where: { $0.kind == .video && $0.phase.isPending }) {
                return String(localized: "Waiting for video…")
            }
            return String(localized: "Waiting for image…")
        }
        return voice.blocksSend
            ? String(localized: "Waiting for Voice Input…")
            : String(localized: "Delivers the complete draft to the Agent")
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

    /// At the caret, with a space before it unless the text there already ends
    /// in whitespace, and one after it, so the path never runs into a word.
    func insertPathIntoDraft(_ path: String) {
        let range = Self.clamped(draftSelection, to: draft)
        insertIntoDraft(Self.pathInsertion(path, after: (draft as NSString).substring(to: range.location)))
    }

    private static func pathInsertion(_ path: String, after text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return "\(path) " }
        return " \(path) "
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

    /// Whether the editor holds marked text, from the input method.
    func setEditorComposing(_ composing: Bool) {
        guard isEditorComposing != composing else { return }
        isEditorComposing = composing
        if !composing { insertVoiceTextIfReady() }
    }

    /// The recorder's Send: stops recording, and once the text lands sends
    /// the draft through `policy`, the Send of the surface it was tapped on.
    func sendVoice(using session: VoiceInputSession, policy: ComposerDeliveryPolicy) {
        voiceSendPolicy = policy
        session.stop(voice, sending: true)
    }

    /// Voice Input's one insertion, at the caret like a Snippet. Send waited
    /// all along, so the draft it lands in is the one the user is editing.
    /// The streaming recorder shows its text after the whole draft, so it
    /// lands there, with the caret after it (ADR 0043). A recording stopped
    /// with Send then sends the draft through the policy its Send was tapped
    /// with; one stopped with Stop while streaming asks for the input's focus,
    /// so typing carries on.
    private func insertVoiceTextIfReady() {
        guard !isEditorComposing, let landed = voice.takeDraftText() else { return }
        let sendPolicy = voiceSendPolicy
        voiceSendPolicy = nil
        if !landed.text.isEmpty {
            if voice.streams {
                draftSelection = NSRange(location: (draft as NSString).length, length: 0)
            }
            insertVoiceText(landed.text)
        }
        if landed.sends, let sendPolicy {
            Task { await send(policy: sendPolicy) }
        } else if voice.streams, !landed.text.isEmpty {
            voiceFocusRequests += 1
        }
    }

    private func insertVoiceText(_ text: String) {
        let range = Self.clamped(draftSelection, to: draft)
        let characters = draft as NSString
        let before = range.location > 0
            ? characters.substring(
                with: characters.rangeOfComposedCharacterSequence(at: range.location - 1)).last
            : nil
        let end = NSMaxRange(range)
        let after = end < characters.length
            ? characters.substring(with: characters.rangeOfComposedCharacterSequence(at: end)).first
            : nil
        insertIntoDraft(VoiceInputSpacing.fitted(text, after: before, before: after))
    }

    /// Binds ``ComposerStagingStore`` so queued picks, pastes, and drops stage
    /// one operation at a time and feed visual attachments above the input.
    /// `AgentComposerSession` binds its staging once.
    func bindStaging(_ staging: ComposerStagingStore) {
        self.staging = staging
        isTearingDownImages = false
        startNextQueuedImageIfNeeded()
    }

    /// Queues one or more image selections (Photos picker, Paste Image, or drop)
    /// as visual attachments above the input, staging them sequentially.
    func enqueueImages(_ selections: [any ImageSelection]) {
        guard !selections.isEmpty else { return }
        for selection in selections {
            enqueueQueuedSelection(selection)
        }
        startNextQueuedImageIfNeeded()
    }

    /// Queues one file selection (e.g., a pasted or dropped video) for staging
    /// through `FilePreparer` / `stageFile`.
    func enqueueFile(_ selection: any FileSelection) {
        enqueueQueuedFile(selection)
        startNextQueuedImageIfNeeded()
    }

    /// Maps a drop onto draft text insertion, queued image attachments, and/or
    /// queued video/file uploads. Empty and unsupported items are skipped
    /// without touching the draft or submitting it.
    func acceptDrop(_ items: [ComposerDropItem]) {
        for item in items {
            switch item {
            case .text(let text):
                guard !text.isEmpty else { continue }
                insertIntoDraft(text)
            case .image(let data, _):
                guard !data.isEmpty else { continue }
                enqueueQueuedSelection(DataImageSelection(data: data))
            case let .file(url, cleanupURL):
                enqueueQueuedFile(URLFileSelection(url: url, cleanupURL: cleanupURL))
            case .oversizedFile:
                enqueueQueuedFile(FailingFileSelection(error: .sourceTooLarge, isVideo: true))
            case .unsupported:
                continue
            }
        }
        startNextQueuedImageIfNeeded()
    }

    func removeImageAttachment(id: UUID) {
        guard let index = imageAttachments.firstIndex(where: { $0.id == id }) else { return }
        switch imageAttachments[index].phase {
        case .queued:
            queuedImageSelections[id] = nil
            if let video = queuedVideoSelections.removeValue(forKey: id) {
                if let cleanupURL = video.cleanupURL {
                    _ = retainedInboxURLs.withLock { $0.remove(cleanupURL) }
                }
                video.discard()
            }
            let removed = imageAttachments.remove(at: index)
            releaseLocalPreviewIfUnreferenced(removed.preview)
        case .preparing, .uploading:
            if let staging {
                staging.perform(.cancel)
            } else {
                activeImageOperations = activeImageOperations.filter { $0.value != id }
                let removed = imageAttachments.remove(at: index)
                releaseLocalPreviewIfUnreferenced(removed.preview)
            }
        case .failed:
            if let staging {
                staging.perform(.dismiss)
            } else {
                activeImageOperations = activeImageOperations.filter { $0.value != id }
                let removed = imageAttachments.remove(at: index)
                releaseLocalPreviewIfUnreferenced(removed.preview)
            }
        case .ready(let path):
            let removed = imageAttachments.remove(at: index)
            notice = nil
            releaseLocalPreviewIfUnreferenced(removed.preview)
            if let staging,
                case .completed(let outcome) = staging.state,
                outcome.path == path
            {
                staging.perform(.dismiss)
            }
        }
    }

    func retryImageAttachment(id: UUID) {
        guard activeImageOperations.values.contains(id),
            let attachment = imageAttachments.first(where: { $0.id == id }),
            case .failed(_, let isRetryable) = attachment.phase,
            isRetryable
        else { return }
        staging?.perform(.retry)
    }

    /// Clears pending/queued image and file uploads before staging teardown
    /// while preserving any image attachments that have already finished staging.
    func abandonDroppedImagesForTeardown() {
        isTearingDownImages = true
        queuedImageSelections.removeAll()
        let abandonedVideos = Array(queuedVideoSelections.values)
        queuedVideoSelections.removeAll()
        let abandonedFiles = queuedFileSelections
        queuedFileSelections.removeAll()
        for file in abandonedVideos + abandonedFiles {
            if let cleanupURL = file.cleanupURL {
                _ = retainedInboxURLs.withLock { $0.remove(cleanupURL) }
            }
            file.discard()
        }
        activeImageOperations.removeAll()
        startingQueuedAttachmentID = nil
        imageAttachments.removeAll { $0.phase.isPending }
    }

    /// Called once the staging's leave has finished: later uploads may start.
    func resumeDroppedImages() {
        isTearingDownImages = false
        startNextQueuedImageIfNeeded()
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
    func send(policy: ComposerDeliveryPolicy = .terminal) async -> SendResult {
        noting(await sendDraft(policy: policy), policy: policy)
    }

    private enum SendAnywayAction {
        case unknownCommand(String)
        case unconfirmedInputBox(admittedCommand: String?)
    }

    /// The refusal Send Anyway can override now: either a command outside
    /// Chat's menu, or an unconfirmed input-box screen check (overlay /
    /// unrecognized box). Any edit ends the notice, so a refused draft is
    /// still the text refused; a refused Retry must still be failed. Either
    /// waits for what Send or Retry would.
    private var sendAnywayAction: SendAnywayAction? {
        guard let notice else { return nil }
        let action: SendAnywayAction
        switch notice.refusal {
        case .unknownCommand(let name):
            action = .unknownCommand(name)
        case .unconfirmedInputBox:
            action = .unconfirmedInputBox(admittedCommand: notice.admittedCommand)
        default:
            return nil
        }
        if let id = notice.retried {
            guard isConnectionAvailable,
                let message = messages.first(where: { $0.id == id }),
                case .failed = message.state
            else { return nil }
        } else if !canSend {
            return nil
        }
        return action
    }

    var canSendAnyway: Bool { sendAnywayAction != nil }

    /// Sends a draft, or retries a failed message, refused for a command
    /// outside the menu or an unconfirmed input-box reading, after the user
    /// chose to. Every other check on `policy` still applies.
    @discardableResult
    func sendAnyway(policy: ComposerDeliveryPolicy) async -> SendResult {
        guard let action = sendAnywayAction, let notice, notice.route == policy.route else { return .ignored }
        let admitting: ComposerDeliveryPolicy
        let admittedCommand: String?
        switch action {
        case .unknownCommand(let name):
            admitting = policy.admitting(unknownCommand: name)
            admittedCommand = name
        case .unconfirmedInputBox(let priorCommand):
            let base = priorCommand.map { policy.admitting(unknownCommand: $0) } ?? policy
            admitting = base.admittingUnconfirmedInputBox()
            admittedCommand = priorCommand
        }
        let result: SendResult
        if let id = notice.retried {
            result = await retry(id, policy: admitting)
        } else {
            result = await send(policy: admitting)
        }
        if let admittedCommand, case .refused(.unconfirmedInputBox) = result {
            self.notice?.admittedCommand = admittedCommand
        }
        return result
    }

    private func sendDraft(policy: ComposerDeliveryPolicy) async -> SendResult {
        guard canSend else { return .ignored }
        let promptText = composedDraft
        if let refusal = policy.validate(promptText) { return .refused(refusal) }
        let message = Message(
            id: UUID(),
            text: promptText,
            route: policy.route,
            stagedImagePaths: readyImagePaths,
            draftText: draft,
            stagedImages: imageAttachments,
            agentWasWorkingAtSend: agentStatus == .working,
            statusRevisionAtSend: statusRevision,
            observedWorkingAfterSend: false,
            tracksAgentProgress: true,
            state: .sending)
        draft = ""
        draftSelection = NSRange(location: 0, length: 0)
        imageAttachments = []
        stop.holdAfterSend()
        messages.append(message)
        if let preflight = policy.preflight, let refusal = await preflight(message.text) {
            returnToDraft(message.id)
            return .refused(refusal)
        }
        return await deliver(message.id, policy: policy)
    }

    /// Sends a failed message again. The policy should be the one for the
    /// message's own route. A refusal leaves the message's failure as it
    /// was and becomes the notice.
    @discardableResult
    func retry(_ id: Message.ID, policy: ComposerDeliveryPolicy = .terminal) async -> SendResult {
        noting(await retryMessage(id, policy: policy), policy: policy, retried: id)
    }

    private func retryMessage(_ id: Message.ID, policy: ComposerDeliveryPolicy) async -> SendResult {
        guard isConnectionAvailable else { return .ignored }
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return .ignored }
        guard case .failed(let reason) = messages[index].state, messages[index].route == policy.route else {
            return .ignored
        }
        if let refusal = policy.validate(messages[index].text) { return .refused(refusal) }
        messages[index].agentWasWorkingAtSend = agentStatus == .working
        messages[index].statusRevisionAtSend = statusRevision
        messages[index].observedWorkingAfterSend = false
        messages[index].tracksAgentProgress = true
        messages[index].state = .sending
        if let preflight = policy.preflight, let refusal = await preflight(messages[index].text) {
            // The message keeps the failure it was retried for; the refusal
            // is the notice, which ends as any notice does. As the message's
            // failure it would outlast a passing hold.
            fail(id, message: reason)
            return .refused(refusal)
        }
        return await deliver(id, policy: policy)
    }

    /// Keeps a refusal as the notice; any other outcome ends the last one.
    /// A refusal shows even when Agent Status changed under the Send: the
    /// draft came back, and the notice is the only word of why. The next
    /// change that ends it still does.
    private func noting(
        _ result: SendResult, policy: ComposerDeliveryPolicy, retried: Message.ID? = nil
    ) -> SendResult {
        if case .refused(let refusal) = result {
            notice = ComposerNotice(
                refusal: refusal, route: policy.route, conversation: policy.conversation?(), retried: retried)
        } else {
            notice = nil
        }
        return result
    }

    /// Chat follows another conversation, or none: a refusal about the
    /// input box described the one it followed, so it ends. Noted after the
    /// change, as when the Send's own check moved Chat, it stays.
    func conversationDidChange(to conversation: Int) {
        guard let notice, let noted = notice.conversation, noted != conversation,
            notice.refusal.clearsOnConversationChange
        else { return }
        self.notice = nil
    }

    /// What `refusal` held the Send for is over, with no Agent Status
    /// change or edit to say so: its notice gives way to `replacement`, for
    /// the same surface and conversation, which ends as any notice does.
    /// Any other notice stays.
    func replaceNotice(_ refusal: ComposerRefusal, with replacement: ComposerRefusal) {
        guard let notice, notice.refusal == refusal else { return }
        self.notice = ComposerNotice(
            refusal: replacement, route: notice.route, conversation: notice.conversation, retried: notice.retried)
    }

    /// Removes a failed or unanswered echo and restores all of its text to the
    /// draft. If the user has already started another draft, both are kept in
    /// order. An unanswered one is the user's call, having seen the terminal.
    func withdrawToDraft(_ id: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        switch messages[index].state {
        case .failed, .outcomeUnknown: returnToDraft(id)
        case .sending, .delivered, .undelivered: break
        }
    }

    /// Removes an echo and puts its text and staged images back in front of
    /// whatever has been added since.
    private func returnToDraft(_ id: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let removed = messages.remove(at: index)
        if !removed.stagedImages.isEmpty {
            imageAttachments.insert(contentsOf: removed.stagedImages, at: 0)
        }
        let text = removed.draftText
        if !text.isEmpty {
            draft = draft.isEmpty ? text : "\(text)\n\(draft)"
            draftSelection = NSRange(location: (draft as NSString).length, length: 0)
        }
    }

    /// The Transcript recorded these, so a step with no answer reached the
    /// program after all, and nothing is left to decide about them.
    func settleUnknownOutcomes(recorded: Set<Message.ID>) {
        for index in messages.indices
        where messages[index].state == .outcomeUnknown && recorded.contains(messages[index].id) {
            messages[index].state = .delivered(.acknowledged)
            releaseStagedImages(ofMessageAt: index)
        }
    }

    func agentStatusDidChange(_ status: AgentStatus) {
        guard agentStatus != status else { return }
        agentStatus = status
        statusRevision &+= 1
        stop.agentStatusChanged(to: status, keepWaitingWhileBlocked: offersStopWhileBlocked)
        if notice?.refusal.endsWhenStatusBecomes(status) == true { notice = nil }
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

    private func deliver(_ id: Message.ID, policy: ComposerDeliveryPolicy) async -> SendResult {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return .ignored }
        let text = messages[index].text
        if let submit = policy.submitChat {
            guard agentStatus != .blocked else { return deliverWhileBlocked(id, text: text, policy: policy) }
            let outgoing = policy.outgoingText(text)
            let outcome = await submit(id, outgoing)
            return finishChecked(id, outgoing: outgoing, policy: policy, outcome: outcome, success: .deliveredViaPrompt)
        }
        if let checkedSend {
            return await deliverChecked(id, text: text, policy: policy, using: checkedSend)
        }
        if agentStatus == .blocked {
            return deliverWhileBlocked(id, text: text, policy: policy)
        }
        let outgoing = policy.outgoingText(text)
        let input = attachInput
        let generation = input?.liveGeneration
        do {
            _ = try await promptWaitingOutLaunch(
                AgentPromptParams(target: target, text: outgoing))
            guard let acknowledgedIndex = messages.firstIndex(where: { $0.id == id }) else {
                return .ignored
            }
            messages[acknowledgedIndex].state = .delivered(
                progressAfterAcknowledgment(for: messages[acknowledgedIndex]))
            releaseStagedImages(ofMessageAt: acknowledgedIndex)
            if let input, let generation {
                input.recordSubmitted(outgoing, generation: generation)
            }
            if let verify = policy.verify {
                Task { [weak self] in
                    guard !(await verify(outgoing)) else { return }
                    self?.markUndelivered(id)
                }
            }
            return .deliveredViaPrompt
        } catch {
            if Self.isAgentBlocked(error) {
                return deliverWhileBlocked(id, text: text, policy: policy)
            }
            return fail(id, message: Self.message(for: error))
        }
    }

    private func deliverChecked(
        _ id: Message.ID, text: String, policy: ComposerDeliveryPolicy, using checkedSend: any CheckedComposerSend
    ) async -> SendResult {
        let outgoing = policy.outgoingText(text)
        guard TerminalTextSafety.containsOnlySafeScalars(outgoing) else {
            return fail(id, message: Self.unsafeTextMessage)
        }
        let outcome = await checkedSend.send(outgoing, route: policy.route, attach: policy.coreAttach)
        return finishChecked(id, outgoing: outgoing, policy: policy, outcome: outcome, success: .submittedViaAttach)
    }

    private func finishChecked(
        _ id: Message.ID, outgoing: String, policy: ComposerDeliveryPolicy, outcome: CheckedSendOutcome, success: SendResult
    ) -> SendResult {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return .ignored }
        switch outcome {
        case .submitted:
            messages[index].state = .delivered(progressAfterAcknowledgment(for: messages[index]))
            releaseStagedImages(ofMessageAt: index)
            if let verify = policy.verify {
                Task { [weak self] in
                    guard !(await verify(outgoing)) else { return }
                    self?.markUndelivered(id)
                }
            }
            return success
        case .refused(let refusal):
            returnToDraft(id)
            return .refused(refusal)
        case .failed(let message):
            return fail(id, message: message)
        case .outcomeUnknown:
            messages[index].tracksAgentProgress = false
            messages[index].state = .outcomeUnknown
            return .outcomeUnknown
        }
    }

    private func deliverWhileBlocked(
        _ id: Message.ID, text: String, policy: ComposerDeliveryPolicy
    ) -> SendResult {
        guard policy.insertsIntoAttachWhenBlocked else {
            returnToDraft(id)
            return .refused(.agentBlocked)
        }
        return deliverThroughAttach(id, text: text)
    }

    private func markUndelivered(_ id: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
            case .delivered = messages[index].state
        else { return }
        messages[index].tracksAgentProgress = false
        messages[index].state = .undelivered
        releaseStagedImages(ofMessageAt: index)
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
        releaseStagedImages(ofMessageAt: deliveredIndex)
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
        String(localized: "The message could not be sent. Check the connection and retry.")
    private static let unsafeTextMessage =
        String(localized: "The message contains unsafe terminal control characters.")

    func imageStagingDidBegin(operationID: UInt64) {
        imageStagingDidBegin(operationID: operationID, kind: .image)
    }

    func imageStagingDidBegin(operationID: UInt64, kind: ComposerImageAttachment.MediaKind) {
        if let queuedID = startingQueuedAttachmentID,
            let index = imageAttachments.firstIndex(where: { $0.id == queuedID })
        {
            startingQueuedAttachmentID = nil
            queuedImageSelections[queuedID] = nil
            queuedVideoSelections[queuedID] = nil
            activeImageOperations[operationID] = queuedID
            imageAttachments[index].phase = .preparing
            return
        }
        startingQueuedAttachmentID = nil
        let id = UUID()
        activeImageOperations[operationID] = id
        imageAttachments.append(ComposerImageAttachment(id: id, kind: kind, preview: nil, phase: .preparing))
    }

    func imageStagingDidPrepare(
        operationID: UInt64,
        preview: ComposerImageAttachment.Preview,
        progress: AttachmentStageProgress
    ) {
        guard let attachmentID = activeImageOperations[operationID],
            let index = imageAttachments.firstIndex(where: { $0.id == attachmentID })
        else { return }
        imageAttachments[index].preview = preview
        imageAttachments[index].phase = .uploading(progress)
    }

    func imageStagingDidProgress(operationID: UInt64, progress: AttachmentStageProgress) {
        guard let attachmentID = activeImageOperations[operationID],
            let index = imageAttachments.firstIndex(where: { $0.id == attachmentID })
        else { return }
        imageAttachments[index].phase = .uploading(progress)
    }

    func imageStagingDidComplete(
        operationID: UInt64,
        path: String,
        preview: ComposerImageAttachment.Preview?
    ) {
        retainLocalPreview(preview)
        if let attachmentID = activeImageOperations.removeValue(forKey: operationID),
            let index = imageAttachments.firstIndex(where: { $0.id == attachmentID })
        {
            if let preview {
                imageAttachments[index].preview = preview
            }
            imageAttachments[index].phase = .ready(path: path)
        } else if !isTearingDownImages {
            imageAttachments.append(
                ComposerImageAttachment(id: UUID(), preview: preview, phase: .ready(path: path)))
        } else {
            releaseLocalPreviewIfUnreferenced(preview)
        }
        notice = nil
    }

    func imageStagingDidFail(
        operationID: UInt64,
        failure: ComposerStagingStore.Failure,
        preview: ComposerImageAttachment.Preview?
    ) {
        guard let attachmentID = activeImageOperations[operationID],
            let index = imageAttachments.firstIndex(where: { $0.id == attachmentID })
        else { return }
        if failure.isRetryable, let preview {
            imageAttachments[index].preview = preview
            imageAttachments[index].phase = .failed(
                message: failure.message,
                isRetryable: true)
            return
        }
        activeImageOperations[operationID] = nil
        let removed = imageAttachments.remove(at: index)
        releaseLocalPreviewIfUnreferenced(removed.preview)
    }

    func imageStagingDidCancel(operationID: UInt64) {
        if let attachmentID = activeImageOperations.removeValue(forKey: operationID),
            let index = imageAttachments.firstIndex(where: { $0.id == attachmentID })
        {
            let removed = imageAttachments.remove(at: index)
            releaseLocalPreviewIfUnreferenced(removed.preview)
        }
    }

    func imageStagingDidDismiss(operationID: UInt64) {
        if let attachmentID = activeImageOperations.removeValue(forKey: operationID),
            let index = imageAttachments.firstIndex(where: { $0.id == attachmentID })
        {
            let removed = imageAttachments.remove(at: index)
            releaseLocalPreviewIfUnreferenced(removed.preview)
        }
    }

    func stagingDidSettle() {
        startNextQueuedImageIfNeeded()
    }

    private func enqueueQueuedSelection(_ selection: any ImageSelection) {
        let id = UUID()
        queuedImageSelections[id] = selection
        imageAttachments.append(ComposerImageAttachment(id: id, preview: nil, phase: .queued))
    }

    private func enqueueQueuedFile(_ selection: any FileSelection) {
        if let cleanupURL = selection.cleanupURL {
            _ = retainedInboxURLs.withLock { $0.insert(cleanupURL) }
        }
        if selection.isVideo {
            let id = UUID()
            queuedVideoSelections[id] = selection
            imageAttachments.append(ComposerImageAttachment(id: id, kind: .video, preview: nil, phase: .queued))
        } else {
            queuedFileSelections.append(selection)
        }
    }

    private func startNextQueuedImageIfNeeded() {
        guard let staging, !isTearingDownImages else { return }
        guard activeImageOperations.isEmpty else { return }
        switch staging.state {
        case .idle, .completed:
            break
        case .failed, .backgroundInterrupted, .preparing, .uploading:
            return
        }
        if let next = imageAttachments.first(where: { $0.phase == .queued }) {
            if let selection = queuedImageSelections[next.id] {
                startingQueuedAttachmentID = next.id
                if staging.begin(.photo(selection), insertPathIntoComposer: false) == nil {
                    startingQueuedAttachmentID = nil
                }
                return
            }
            if let video = queuedVideoSelections[next.id] {
                startingQueuedAttachmentID = next.id
                if let cleanupURL = video.cleanupURL {
                    _ = retainedInboxURLs.withLock { $0.remove(cleanupURL) }
                }
                if staging.begin(.fileSelection(video), insertPathIntoComposer: false) == nil {
                    startingQueuedAttachmentID = nil
                    if let cleanupURL = video.cleanupURL {
                        _ = retainedInboxURLs.withLock { $0.insert(cleanupURL) }
                    }
                }
                return
            }
        }
        if !queuedFileSelections.isEmpty {
            let nextFile = queuedFileSelections.removeFirst()
            if let cleanupURL = nextFile.cleanupURL {
                _ = retainedInboxURLs.withLock { $0.remove(cleanupURL) }
            }
            if staging.begin(.fileSelection(nextFile)) == nil {
                nextFile.discard()
            }
        }
    }

    private func retainLocalPreview(_ preview: ComposerImageAttachment.Preview?) {
        guard let url = preview?.fileURL else { return }
        _ = retainedPreviewURLs.withLock { $0.insert(url) }
    }

    private func releaseStagedImages(ofMessageAt index: Int) {
        let released = messages[index].stagedImages
        guard !released.isEmpty else { return }
        messages[index].stagedImages = []
        for attachment in released {
            releaseLocalPreviewIfUnreferenced(attachment.preview)
        }
    }

    private func releaseLocalPreviewIfUnreferenced(_ preview: ComposerImageAttachment.Preview?) {
        guard let preview else { return }
        let url = preview.fileURL
        let stillReferencedInDraft = imageAttachments.contains { $0.preview?.fileURL == url }
        let stillReferencedInMessages = messages.contains { message in
            message.stagedImages.contains { $0.preview?.fileURL == url }
        }
        guard !stillReferencedInDraft, !stillReferencedInMessages else { return }
        let removedFromTracking = retainedPreviewURLs.withLock { $0.remove(url) != nil }
        if removedFromTracking {
            preview.removeLocalFile()
        }
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
            String(localized: "The Host is not connected. Check the connection and retry.")
        case TransportError.timedOut:
            String(localized: "The Host did not answer. Check the connection and retry.")
        case let error as HerdrAPIError:
            String(localized: "herdr rejected the message: \(error.message)")
        case let error as TransportError:
            error.presentation.message
        default:
            missingAttachMessage
        }
    }
}
