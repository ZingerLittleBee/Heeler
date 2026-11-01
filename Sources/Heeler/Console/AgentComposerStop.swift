import Foundation
import Observation

/// What a Stop tap came to. `.sent` means only that the keys left Heeler;
/// whether the Agent stopped shows in its status.
enum AgentInterruptOutcome: Equatable, Sendable {
    case sent
    /// Nothing was pressed, or the keys may not have arrived: a guard refused,
    /// the screen could not be read, the request failed, or the terminal had
    /// no live writer. Why.
    case failed(String)
}

/// How one surface's Stop waits after a press.
struct AgentStopWait: Equatable, Sendable {
    /// How long Stop waits for Agent Status to leave Working, ignoring taps.
    var window: Duration
    /// What Stop says when the window passed with the Agent still Working.
    var unconfirmedNotice: String
    /// The least time from the end of one Stop attempt to the next press,
    /// kept across status changes. A tap sooner, or while an attempt is still
    /// on its way, presses nothing. Zero keeps Esc's behaviour.
    var minimumGap: Duration = .zero

    /// One Esc's wait: the terminal's Stop, and Chat's in Claude Code, Codex,
    /// Pi and Oh My Pi.
    static let escape = AgentStopWait(
        window: .seconds(3), unconfirmedNotice: "Esc went, but the Agent still shows Working.")
}

/// One surface's Stop: what a tap does, the wait after it, and its hint.
struct AgentComposerInterrupt {
    static let escapeHint = "Presses Esc to interrupt the Agent"
    var wait: AgentStopWait
    var accessibilityHint: String
    var perform: @MainActor () async -> AgentInterruptOutcome

    static func escape(
        _ perform: @escaping @MainActor () async -> AgentInterruptOutcome
    ) -> AgentComposerInterrupt {
        AgentComposerInterrupt(wait: .escape, accessibilityHint: escapeHint, perform: perform)
    }

    /// The terminal Composer's Stop for an Agent of `kind`: one Esc, or nil
    /// to keep Send in Grok Build, where Esc only shows a toast. Its turns
    /// stop with Ctrl+C, which Chat's Stop presses after reading the screen.
    static func terminal(
        forAgentKind kind: String, _ perform: @escaping @MainActor () async -> AgentInterruptOutcome
    ) -> AgentComposerInterrupt? {
        SupportedAgentKind(rawValue: kind) == .grok ? nil : .escape(perform)
    }
}

/// The Composer's trailing button. While the Agent is Working and the draft
/// is blank it is Stop, which presses Esc in the Agent's program; with text
/// it stays Send, so a prompt can still reach the running turn. Claude Code
/// and Codex queue it behind the turn; Pi steers the turn with it, and Chat
/// holds it for Oh My Pi, whose steer can background a running command.
/// Esc in Pi or Oh My Pi puts a steer the turn has not taken yet, Chat's or
/// one typed in the terminal, back into the input box, where Chat's next
/// send waits on it.
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
        hasInputReplacement: Bool,
        keyboardIsLeaving: Bool = false
    ) -> Bool {
        isEnabled
            && !keyboardIsLeaving
            && !isInputFocused
            && keyboardPresentation == .hidden
            && !inheritsKeyboard
            && !hasInputReplacement
    }
}

/// The Composer's Stop. Each tap presses the surface's keys once, then
/// waits for Agent Status to leave Working instead of pressing again: keys
/// reaching the program prove nothing about the turn, and an Esc that lands
/// after the turn already ended can open the program's own history (Claude
/// Code's rewind, Codex's backtrack). Past the window, Stop works again: the
/// status can stay Working for good reasons, such as background agents or
/// shells that the keys do not end, so the notice says what is seen, not
/// why. A wait with a minimum gap also ignores taps too soon after the last
/// attempt ended, or while one is still on its way, whatever the status did.
///
/// A send that empties the draft holds Stop back for a moment, since Stop
/// takes Send's place: the second tap of a double tap would interrupt the
/// turn the prompt was meant to queue behind.
@MainActor
@Observable
final class AgentComposerStopStore {
    enum Phase: Equatable {
        case ready
        /// The keys are on their way, or went and the Agent is still Working.
        case stopping
        /// The window passed with the Agent still Working.
        case unconfirmed
        /// Nothing was pressed, or the keys may not have gone; see
        /// `AgentInterruptOutcome.failed`. There is nothing to wait for, so
        /// Stop works again at once, with the notice saying why.
        case failed(String)
    }

    private(set) var phase: Phase = .ready
    /// Stop stays Send for a moment after a send emptied the draft.
    private(set) var isHeldAfterSend = false
    @ObservationIgnored private let sendHold: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant
    /// Bumped by every tap and every status change, so a wait that was
    /// overtaken cannot overwrite the newer phase.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var holdGeneration = 0
    /// What the running stop says once its window passes.
    @ObservationIgnored private var unconfirmedNotice = AgentStopWait.escape.unconfirmedNotice
    /// Attempts whose keys are still on their way, and when the last one
    /// ended. Status changes leave both alone; only a minimum gap reads them.
    @ObservationIgnored private var attemptsOnTheirWay = 0
    @ObservationIgnored private var lastAttemptEnded: ContinuousClock.Instant?

    init(
        sendHold: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.sendHold = sendHold
        self.sleep = sleep
        self.now = now
    }

    var isStopping: Bool { phase == .stopping }

    /// Why the last Stop has not shown its effect. `.unconfirmed` says the
    /// running stop's `wait.unconfirmedNotice`.
    var notice: String? {
        switch phase {
        case .ready, .stopping: nil
        case .unconfirmed: unconfirmedNotice
        case .failed(let message): message
        }
    }

    /// Presses the keys through `interrupt`, then waits as `wait` says,
    /// unless an earlier press is still waiting on the Agent. With a minimum
    /// gap, a tap while an attempt is on its way, or sooner than the gap
    /// after the last one ended, presses nothing either. Returns the wait.
    @discardableResult
    func stop(
        waiting wait: AgentStopWait = .escape,
        using interrupt: @escaping @MainActor () async -> AgentInterruptOutcome
    ) -> Task<Void, Never>? {
        guard phase != .stopping else { return nil }
        if wait.minimumGap > .zero {
            guard attemptsOnTheirWay == 0 else { return nil }
            if let lastAttemptEnded, lastAttemptEnded.duration(to: now()) < wait.minimumGap {
                return nil
            }
        }
        unconfirmedNotice = wait.unconfirmedNotice
        generation += 1
        let generation = generation
        phase = .stopping
        attemptsOnTheirWay += 1
        let window = wait.window
        return Task { [weak self] in
            let outcome = await interrupt()
            guard let sleep = self?.begin(after: outcome, generation: generation, window: window)
            else { return }
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

    /// Ends the attempt, whatever came of it and even when a status change
    /// overtook it. Then records a failed press, or returns the window's wait.
    private func begin(
        after outcome: AgentInterruptOutcome,
        generation: Int,
        window: Duration
    ) -> (@Sendable () async throws -> Void)? {
        attemptsOnTheirWay -= 1
        lastAttemptEnded = now()
        guard self.generation == generation else { return nil }
        if case .failed(let message) = outcome {
            phase = .failed(message)
            return nil
        }
        let sleep = sleep
        return { try await sleep(window) }
    }
}
