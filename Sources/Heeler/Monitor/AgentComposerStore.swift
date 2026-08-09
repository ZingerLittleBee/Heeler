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

    private(set) var messages: [Message] = []
    private(set) var draft = ""

    private let target: String
    private var agentStatus: AgentStatus
    private var statusRevision: UInt64 = 0
    private let now: @Sendable () -> Date
    private let statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>?
    private let prompt: @Sendable (AgentPromptParams) async throws -> Agent
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init(
        target: String,
        initialStatus: AgentStatus = .idle,
        now: @escaping @Sendable () -> Date = { Date() },
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>? = nil,
        prompt: @escaping @Sendable (AgentPromptParams) async throws -> Agent
    ) {
        self.target = target
        agentStatus = initialStatus
        self.now = now
        self.statusUpdates = statusUpdates
        self.prompt = prompt
    }

    deinit {
        statusTask?.cancel()
    }

    var canSend: Bool {
        draft.contains(where: { !$0.isWhitespace })
    }

    func replaceDraft(with text: String) {
        draft = text
    }

    func insertIntoDraft(_ text: String) {
        draft.append(text)
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
}
