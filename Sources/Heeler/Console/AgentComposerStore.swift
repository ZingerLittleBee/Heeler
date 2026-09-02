import Foundation
import Observation

/// Local draft operations shared by the plain-text Composer now and future
/// Snippet, Skill, and Staged Image path insertion surfaces.
@MainActor
protocol ComposerDraftOperations: AnyObject {
    func replaceDraft(with text: String)
    func insertIntoDraft(_ text: String)
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

    private let target: String
    private var agentStatus: AgentStatus
    private var statusRevision: UInt64 = 0
    private let statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>?
    private let prompt: @Sendable (AgentPromptParams) async throws -> Agent
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// The detail screen's live Attach writer. Weak: Composer outlives any
    /// one Attach pipeline (reconnect replacement), and a dead writer must
    /// fail the Blocked path rather than retain a stale session.
    @ObservationIgnored private weak var attachInput: TerminalInputController?

    init(
        target: String,
        initialStatus: AgentStatus = .idle,
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>? = nil,
        prompt: @escaping @Sendable (AgentPromptParams) async throws -> Agent
    ) {
        self.target = target
        agentStatus = initialStatus
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

    /// Completes an inline Skill suggestion: swaps the typed trigger token at
    /// the end of the draft for the full invocation. A draft that no longer
    /// ends with the token — edited under a stale suggestion — is left alone
    /// rather than mangled.
    func replaceTrailingToken(_ token: String, with text: String) {
        guard !token.isEmpty, draft.hasSuffix(token) else { return }
        draft.removeLast(token.count)
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

    /// The already-open Attach PTY writer owned by Agent detail. Blocked
    /// Send uses the same pipe as the tools keyboard.
    func bindAttachInput(_ input: TerminalInputController?) {
        attachInput = input
    }

    @discardableResult
    func send() async -> SendResult {
        guard canSend else { return .ignored }
        let message = Message(
            id: UUID(), text: draft,
            agentWasWorkingAtSend: agentStatus == .working,
            statusRevisionAtSend: statusRevision,
            observedWorkingAfterSend: false,
            tracksAgentProgress: true,
            state: .sending)
        draft = ""
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
        if agentStatus == .blocked {
            return deliverThroughAttach(id, text: text)
        }
        let input = attachInput
        let generation = input?.liveGeneration
        do {
            _ = try await prompt(AgentPromptParams(target: target, text: text))
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

    /// Types the draft into the live Attach PTY without submitting. Matches
    /// tools-keyboard writes: UTF-8 bytes, no bracketed paste, no Enter.
    /// Those bytes already cross `TerminalInputController`'s writer, which
    /// indexes them; do not also `record(submitted:)` here.
    private func deliverThroughAttach(_ id: Message.ID, text: String) -> SendResult {
        guard TerminalTextSafety.containsOnlySafeScalars(text) else {
            return fail(id, message: Self.unsafeTextMessage)
        }
        guard let attachInput, attachInput.send(Data(text.utf8)) else {
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
