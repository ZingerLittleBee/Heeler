import Foundation
import Observation

/// What Stop's Esc came to. `.sent` means only that the key left Heeler;
/// whether the Agent stopped shows in its status.
enum AgentInterruptOutcome: Equatable, Sendable {
    case sent
    case failed(String)
}

/// The Composer's trailing button. While the Agent is Working and the draft
/// is blank it is Stop, which presses Esc in the Agent's program; with text
/// it stays Send, so a prompt can still queue behind the running turn.
enum AgentComposerPrimaryControl: Equatable {
    case send
    case stop

    init(status: AgentStatus, draft: String, canStop: Bool) {
        let isBlank = !draft.contains(where: { !$0.isWhitespace })
        self = canStop && status == .working && isBlank ? .stop : .send
    }
}

/// When Chat's Composer folds: the actions row goes, and Add and Send sit
/// beside a one-line input until a tap into it. Failure and notice rows
/// stay. Anything that holds or is about to hold the keyboard keeps it
/// open, the tools dock included, so swapping keyboards never resizes it.
/// A card in the input's place has its own layout.
enum AgentComposerCollapse {
    static func isCollapsed(
        isEnabled: Bool,
        isInputFocused: Bool,
        keyboardPresentation: AgentComposerKeyboardPresentation,
        inheritsKeyboard: Bool,
        hasInputReplacement: Bool
    ) -> Bool {
        isEnabled
            && !isInputFocused
            && keyboardPresentation == .hidden
            && !inheritsKeyboard
            && !hasInputReplacement
    }
}

/// The Composer's Stop. Each tap presses Esc once, then waits for Agent
/// Status to leave Working instead of sending another: Esc reaching the
/// program proves nothing about the turn, and one that lands after the turn
/// already ended can open the program's own history (Claude Code's rewind,
/// Codex's backtrack). Past the window, Stop works again: the status can
/// stay Working for good reasons, such as background agents or shells
/// that Esc does not end, so the notice says what is seen, not why.
///
/// A send that empties the draft holds Stop back for a moment, since Stop
/// takes Send's place: the second tap of a double tap would interrupt the
/// turn the prompt was meant to queue behind.
@MainActor
@Observable
final class AgentComposerStopStore {
    enum Phase: Equatable {
        case ready
        /// Esc is on its way, or went and the Agent is still Working.
        case stopping
        /// The window passed with the Agent still Working.
        case unconfirmed
        /// Esc may not have gone: Chat's request failed, or the terminal
        /// had no live writer. There is nothing to wait for, so Stop works
        /// again at once, with the notice saying why.
        case failed(String)
    }

    static let unconfirmedMessage = "Esc went, but the Agent still shows Working."

    private(set) var phase: Phase = .ready
    /// Stop stays Send for a moment after a send emptied the draft.
    private(set) var isHeldAfterSend = false
    @ObservationIgnored private let confirmationWindow: Duration
    @ObservationIgnored private let sendHold: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// Bumped by every tap and every status change, so a wait that was
    /// overtaken cannot overwrite the newer phase.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var holdGeneration = 0

    init(
        confirmationWindow: Duration = .seconds(3),
        sendHold: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.confirmationWindow = confirmationWindow
        self.sendHold = sendHold
        self.sleep = sleep
    }

    var isStopping: Bool { phase == .stopping }

    /// Why the last Stop has not shown its effect.
    var notice: String? {
        switch phase {
        case .ready, .stopping: nil
        case .unconfirmed: Self.unconfirmedMessage
        case .failed(let message): message
        }
    }

    /// Presses Esc through `interrupt` unless an earlier one is still
    /// waiting on the Agent. Returns the wait.
    @discardableResult
    func stop(
        using interrupt: @escaping @MainActor () async -> AgentInterruptOutcome
    ) -> Task<Void, Never>? {
        guard phase != .stopping else { return nil }
        generation += 1
        let generation = generation
        phase = .stopping
        return Task { [weak self] in
            let outcome = await interrupt()
            guard let sleep = self?.begin(after: outcome, generation: generation) else { return }
            try? await sleep()
            guard let self, self.generation == generation else { return }
            phase = .unconfirmed
        }
    }

    /// A send just emptied the draft; returns the hold.
    @discardableResult
    func holdAfterSend() -> Task<Void, Never> {
        holdGeneration += 1
        let holdGeneration = holdGeneration
        isHeldAfterSend = true
        let sleep = sleep
        let hold = sendHold
        return Task { [weak self] in
            try? await sleep(hold)
            guard let self, self.holdGeneration == holdGeneration else { return }
            isHeldAfterSend = false
        }
    }

    /// Any status but Working ends the wait: the Agent stopped, finished,
    /// or turned to a dialog, and Stop no longer shows.
    func agentStatusChanged(to status: AgentStatus) {
        guard status != .working else { return }
        generation += 1
        phase = .ready
    }

    /// Records a failed Esc, or returns the confirmation window's wait.
    private func begin(
        after outcome: AgentInterruptOutcome,
        generation: Int
    ) -> (@Sendable () async throws -> Void)? {
        guard self.generation == generation else { return nil }
        if case .failed(let message) = outcome {
            phase = .failed(message)
            return nil
        }
        let sleep = sleep
        let window = confirmationWindow
        return { try await sleep(window) }
    }
}
