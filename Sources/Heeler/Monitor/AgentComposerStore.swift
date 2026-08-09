import Foundation
import Observation

/// Local draft operations shared by the plain-text Composer now and future
/// Snippet, Skill, and Staged Image path insertion surfaces.
@MainActor
protocol ComposerDraftOperations: AnyObject {
    func replaceDraft(with text: String)
    func insertIntoDraft(_ text: String)
}

/// Owns Monitor's local draft and optimistic delivery echoes. Draft edits do
/// not touch Transport; only an explicit send emits one `agent.prompt` RPC.
@MainActor
@Observable
final class AgentComposerStore: ComposerDraftOperations {
    struct Message: Identifiable, Equatable {
        let id: UUID
        let text: String
        /// Wall-clock time this message was (last) submitted. Used to decide
        /// whether the snapshot already reflects it (capture-anchored timeline).
        fileprivate(set) var sentAt: Date
        fileprivate var agentWasWorkingAtSend: Bool
        fileprivate var statusRevisionAtSend: UInt64
        fileprivate var observedWorkingAfterSend: Bool
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

    /// Capture-anchored split of local echoes: reflected messages already
    /// appear inside the agent snapshot; pending ones still need bubbles.
    struct MessagePartition: Equatable {
        let reflected: [Message]
        let pending: [Message]
    }

    /// Image file staging for the Composer Files control. Staging never
    /// submits; success only inserts the remote path into the local draft.
    enum FileStageState: Equatable {
        case idle
        case staging
        case failed(String)
    }

    private(set) var messages: [Message] = []
    private(set) var draft = ""
    private(set) var fileStageState: FileStageState = .idle

    private let target: String
    private var agentStatus: AgentStatus
    private var statusRevision: UInt64 = 0
    private let now: @Sendable () -> Date
    private let statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>?
    private let preparer: any ImagePreparing
    private let stageImage: ImageStager?
    private let prompt: @Sendable (AgentPromptParams) async throws -> Agent
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var stageTask: Task<Void, Never>?
    @ObservationIgnored private var stageOperationID: UInt64 = 0
    @ObservationIgnored private var preparedImage: PreparedImage?

    init(
        target: String,
        initialStatus: AgentStatus = .idle,
        now: @escaping @Sendable () -> Date = { Date() },
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>? = nil,
        preparer: any ImagePreparing = ImagePreparer(),
        stageImage: ImageStager? = nil,
        prompt: @escaping @Sendable (AgentPromptParams) async throws -> Agent
    ) {
        self.target = target
        agentStatus = initialStatus
        self.now = now
        self.statusUpdates = statusUpdates
        self.preparer = preparer
        self.stageImage = stageImage
        self.prompt = prompt
    }

    deinit {
        statusTask?.cancel()
        stageTask?.cancel()
    }

    var canSend: Bool {
        draft.contains(where: { !$0.isWhitespace })
    }

    var isStagingFile: Bool {
        if case .staging = fileStageState { true } else { false }
    }

    var fileStageFailureMessage: String? {
        if case .failed(let message) = fileStageState { message } else { nil }
    }

    /// Files is available when a Host stager is wired and no stage is running.
    /// Draft edits do not depend on agent status, so this is independent of
    /// control-key enablement.
    var canStageFile: Bool {
        stageImage != nil && !isStagingFile
    }

    func replaceDraft(with text: String) {
        draft = text
    }

    /// Inserts `text` into the local draft without submitting.
    ///
    /// Separator rule: leading whitespace on `text` is stripped so clipboard
    /// paste cannot double-separate against the draft tail. Empty / pure-
    /// whitespace `text` is a no-op. When the draft is non-empty and does not
    /// already end in whitespace, a single space is inserted before the
    /// remainder so paste, snippet, and staged-path insertions do not glue
    /// onto the preceding token. Callers that want a trailing separator
    /// (staged paths) include it in `text` (trailing whitespace is kept).
    func insertIntoDraft(_ text: String) {
        let insertion = text.drop(while: \.isWhitespace)
        guard !insertion.isEmpty else { return }
        if draft.isEmpty || draft.last?.isWhitespace == true {
            draft.append(contentsOf: insertion)
        } else {
            draft.append(" ")
            draft.append(contentsOf: insertion)
        }
    }

    /// Prepares and stages one image over the Host SFTP seam, then inserts
    /// the remote path into the draft (with a trailing space) without
    /// submitting. Failures keep the draft intact and surface recovery copy.
    func stageAndInsertImage(_ selection: any ImageSelection) {
        guard let stageImage, stageTask == nil else { return }
        discardPreparedImage()
        stageOperationID &+= 1
        let operationID = stageOperationID
        fileStageState = .staging
        stageTask = Task { [weak self] in
            await self?.runStageAndInsert(
                selection, stageImage: stageImage, operationID: operationID)
        }
    }

    func dismissFileStageFailure() {
        guard case .failed = fileStageState else { return }
        fileStageState = .idle
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

    func send() async {
        guard canSend else { return }
        let message = Message(
            id: UUID(),
            text: draft,
            sentAt: now(),
            agentWasWorkingAtSend: agentStatus == .working,
            statusRevisionAtSend: statusRevision,
            observedWorkingAfterSend: false,
            state: .sending)
        draft = ""
        messages.append(message)
        await deliver(message.id)
    }

    func retry(_ id: Message.ID) async {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        guard case .failed = messages[index].state else { return }
        messages[index].sentAt = now()
        messages[index].agentWasWorkingAtSend = agentStatus == .working
        messages[index].statusRevisionAtSend = statusRevision
        messages[index].observedWorkingAfterSend = false
        messages[index].state = .sending
        await deliver(id)
    }

    /// Splits local echoes relative to the current snapshot capture time.
    /// A delivered message is **reflected** when `sentAt < capturedAt` (already
    /// visible in agent output); everything else stays **pending**.
    func partitionMessages(capturedAt: Date?) -> MessagePartition {
        var reflected: [Message] = []
        var pending: [Message] = []
        for message in messages {
            if Self.isReflected(message, capturedAt: capturedAt) {
                reflected.append(message)
            } else {
                pending.append(message)
            }
        }
        return MessagePartition(reflected: reflected, pending: pending)
    }

    /// Pure helper for tests and ``partitionMessages(capturedAt:)``.
    static func isReflected(_ message: Message, capturedAt: Date?) -> Bool {
        guard case .delivered = message.state else { return false }
        guard let capturedAt else { return false }
        return message.sentAt < capturedAt
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

    private func deliver(_ id: Message.ID) async {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let text = messages[index].text
        do {
            _ = try await prompt(AgentPromptParams(target: target, text: text))
            guard let acknowledgedIndex = messages.firstIndex(where: { $0.id == id }) else {
                return
            }
            messages[acknowledgedIndex].state = .delivered(
                progressAfterAcknowledgment(for: messages[acknowledgedIndex]))
        } catch {
            guard let failedIndex = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[failedIndex].state = .failed(Self.message(for: error))
        }
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

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected. Check the connection and retry."
        case TransportError.timedOut:
            "The Host did not answer. Check the connection and retry."
        case let error as HerdrAPIError:
            "herdr rejected the message: \(error.message)"
        case let error as TransportError:
            error.connectionGuidance
        default:
            "The message could not be sent. Check the connection and retry."
        }
    }

    private func runStageAndInsert(
        _ selection: any ImageSelection,
        stageImage: @escaping ImageStager,
        operationID: UInt64
    ) async {
        var unclaimedImage: PreparedImage?
        do {
            let image = try await preparer.prepare(selection)
            unclaimedImage = image
            try Task.checkCancellation()
            guard operationID == stageOperationID else {
                try? image.remove()
                // Drop the busy claim so a future cancel/invalidate path
                // cannot leave Files permanently disabled.
                stageTask = nil
                return
            }
            preparedImage = image
            unclaimedImage = nil

            let staged = try await stageImage(
                image,
                ImageStageProgressReporter { _ in })
            try Task.checkCancellation()
            guard operationID == stageOperationID else {
                stageTask = nil
                return
            }

            stageTask = nil
            discardPreparedImage()
            fileStageState = .idle
            // Trailing space matches Attach path insertion so the user can
            // keep typing after the path without gluing tokens together.
            insertIntoDraft(staged.path + " ")
        } catch {
            try? unclaimedImage?.remove()
            finishStage(error: error, operationID: operationID)
        }
    }

    private func finishStage(error: any Error, operationID: UInt64) {
        guard operationID == stageOperationID else {
            stageTask = nil
            return
        }
        stageTask = nil
        if Self.isCancellation(error) {
            discardPreparedImage()
            fileStageState = .idle
            return
        }
        discardPreparedImage()
        fileStageState = .failed(Self.fileStageMessage(for: error))
    }

    private func discardPreparedImage() {
        try? preparedImage?.remove()
        preparedImage = nil
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? ImageStagingError) == .cancelled
    }

    private static func fileStageMessage(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected. Reconnect, then choose the image again."
        case ImageStagingError.sftpUnavailable:
            "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem, then try again."
        case let staging as ImageStagingError where staging.isRetryable:
            "Image upload failed. Choose the image again to retry."
        case is ImageStagingError:
            "Couldn't attach this image. Try a different image."
        case ImagePreparationError.selectionUnavailable:
            "The selected file is no longer available. Choose another image."
        case ImagePreparationError.sourceTooLarge:
            "The selected image is too large to decode safely. Choose a smaller image."
        case ImagePreparationError.invalidImage:
            "The selected item is not a readable image. Choose a different file."
        case ImagePreparationError.unableToProduceBoundedOutput:
            "The image could not be reduced below the 16 MiB upload limit. Choose a smaller image."
        case ImagePreparationError.localStorageFailed:
            "herdr could not prepare the image in protected local storage. Try again."
        default:
            "Couldn't attach this image. Try a different image."
        }
    }
}
