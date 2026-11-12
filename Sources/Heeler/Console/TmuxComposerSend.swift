import Foundation

/// Composer Send on a tmux Agent (ADRs 0035 and 0043): pastes the draft into
/// the viewed Attach's named buffer (`set-buffer`, `paste-buffer -p -r -d`) and
/// presses `Enter` once, all through that Attach's control client, only while
/// the same known Agent process still leads the Pane's foreground before and
/// after the paste, its `@heeler-status` does not read Blocked, and bracketed
/// paste is on (`#{bracket_paste_flag}` from tmux 3.7, or assumed for a known
/// Agent before 3.7 until this Attach saw DECSET 2004 turned off).
///
/// One Send runs at a time per Agent, and a control-client step that gets no
/// answer is never sent again: the next Send waits for the Host to answer a
/// probe and warns once before anything new can paste behind it.
@MainActor
final class TmuxComposerSend: CheckedComposerSend {
    typealias Outcome = CheckedSendOutcome

    nonisolated static let submitWindow: Duration = .seconds(2)
    nonisolated static let stepTimeout: Duration = .seconds(5)
    nonisolated static let liveAttachTimeout: Duration = .seconds(5)

    /// Shells seen dropping a pending paste on one `0x03` (ADR 0035).
    private static let shellsDroppingPasteOnInterrupt: Set<String> = ["bash", "fish", "dash", "zsh"]

    private struct HeldAgent {
        let kind: String
        let pid: Int
    }

    private enum PrePasteRead {
        case held(HeldAgent)
        case outcome(Outcome)
    }

    private let paneID: String
    private let projection: @MainActor () -> TmuxConsoleProjection?
    /// The tmux server instance this Composer's Agent runs on: `%0` means
    /// another Pane on any other server.
    private let corePin: TerminalCorePin
    private let clock: BlockedCardClock
    private var lastSend: Task<Outcome, Never>?
    private var lastSendHasNoAnswer = false

    init(
        paneID: String,
        projection: @escaping @MainActor () -> TmuxConsoleProjection?,
        corePin: TerminalCorePin = TerminalCorePin(),
        clock: BlockedCardClock = .live
    ) {
        self.paneID = paneID
        self.projection = projection
        self.corePin = corePin
        self.clock = clock
    }

    func send(_ text: String, route: ComposerRoute = .terminal, attach: AgentAttachStore?) async -> Outcome {
        let previous = lastSend
        let send = Task {
            _ = await previous?.value
            let outcome = await deliver(text, route: route, attach: attach)
            if outcome == .outcomeUnknown { lastSendHasNoAnswer = true }
            return outcome
        }
        lastSend = send
        return await send.value
    }

    // MARK: Checked steps

    private func deliver(_ text: String, route: ComposerRoute, attach: AgentAttachStore?) async -> Outcome {
        guard let projection = projection() else { return .failed(Self.notConnected) }
        guard projection.admits(corePin) else { return .refused(.inputNotReady(Self.serverGone)) }
        if lastSendHasNoAnswer { return await settleLastSend(in: projection, attach: attach) }

        switch route {
        case .terminal:
            guard let attach else { return .failed(Self.notConnected) }
            if hasEnded(in: projection, attach: attach) { return .refused(.inputNotReady(Self.agentEnded)) }
            guard let (session, tmuxSend) = await liveSend(of: attach) else {
                if !projection.admits(corePin) { return .refused(.inputNotReady(Self.serverGone)) }
                return hasEnded(in: projection, attach: attach)
                    ? .refused(.inputNotReady(Self.agentEnded))
                    : .failed(Self.noLiveAttach)
            }
            guard projection.admits(corePin) else { return .refused(.inputNotReady(Self.serverGone)) }

            let held: HeldAgent
            switch await readHeldAgent(in: projection, route: .terminal) {
            case .held(let agent): held = agent
            case .outcome(let outcome): return outcome
            }

            return await pasteAndSubmit(
                text, held: held, on: tmuxSend, in: projection,
                onSubmitted: { attach.input.recordSubmitted(text, generation: session) })

        case .chat:
            if projection.hasPaneEnded(paneID) { return .refused(.inputNotReady(Self.agentEnded)) }

            let held: HeldAgent
            switch await readHeldAgent(in: projection, route: .chat) {
            case .held(let agent): held = agent
            case .outcome(let outcome): return outcome
            }

            let chatAttach: TmuxChatAttach
            do {
                let paneID = paneID
                let corePin = corePin
                chatAttach = try await AsyncDeadline.run(for: Self.liveAttachTimeout, sleep: clock.sleep) {
                    try await projection.openChatAttach(at: paneID, keepingTo: corePin)
                }
            } catch TransportError.tmuxServerGone {
                return .refused(.inputNotReady(Self.serverGone))
            } catch TransportError.tmuxPaneGone {
                return .refused(.inputNotReady(Self.agentEnded))
            } catch {
                if !projection.admits(corePin) { return .refused(.inputNotReady(Self.serverGone)) }
                return projection.hasPaneEnded(paneID)
                    ? .refused(.inputNotReady(Self.agentEnded))
                    : .failed(Self.notConnected)
            }

            let outcome = await deliverThroughChatAttach(
                text, held: held, chatAttach: chatAttach, in: projection)
            await chatAttach.close()
            return outcome
        }
    }

    private func deliverThroughChatAttach(
        _ text: String,
        held: HeldAgent,
        chatAttach: TmuxChatAttach,
        in projection: TmuxConsoleProjection
    ) async -> Outcome {
        guard projection.admits(corePin) else { return .refused(.inputNotReady(Self.serverGone)) }
        if let changed = await changeWhileAttachOpened(from: held, in: projection) {
            return changed
        }
        return await pasteAndSubmit(
            text, held: held, on: chatAttach.tmuxSend, in: projection, onSubmitted: nil)
    }

    private func pasteAndSubmit(
        _ text: String,
        held: HeldAgent,
        on tmuxSend: TmuxAttachSend,
        in projection: TmuxConsoleProjection,
        onSubmitted: (@MainActor () -> Void)?
    ) async -> Outcome {
        if await tmuxSend.bracketedPaste() == .disabled {
            return .refused(.programNotAcceptingPaste)
        }
        guard projection.admits(corePin) else { return .refused(.inputNotReady(Self.serverGone)) }

        let pasteStart = clock.now()
        switch await tmuxSend.paste(text, clock.sleep) {
        case .left: break
        case .notLeft: return .failed(Self.notConnected)
        case .unknown: return .outcomeUnknown
        }

        let after: TmuxPaneForeground
        do {
            after = try await readForeground(in: projection)
        } catch {
            return .outcomeUnknown
        }
        switch after {
        case .serverNotRunning, .paneGone, .dead:
            return .refused(.notSubmitted(Self.programEnded))
        case .live(let sample):
            guard corePin.admits(sample.instance.id) else {
                return .refused(.notSubmitted(Self.programEnded))
            }
            let afterProgram = HerdrCoreAgentRule.program(
                arguments: sample.pane.foregroundArguments ?? [], name: sample.pane.command)
            if sample.foregroundPID == held.pid, afterProgram == .known(held.kind) {
                if Self.isBlocked(sample.pane, kind: held.kind) {
                    return .refused(.notSubmitted(Self.becameBlocked))
                }
                guard clock.now() - pasteStart < Self.submitWindow else {
                    return .refused(.notSubmitted(Self.windowPassed))
                }
                switch await tmuxSend.sendKey("Enter", clock.sleep) {
                case .left:
                    onSubmitted?()
                    return .submitted
                case .notLeft:
                    return .refused(.notSubmitted(Self.submitKeyLost))
                case .unknown:
                    return .outcomeUnknown
                }
            }
            return await giveUp(after: sample, program: afterProgram, on: tmuxSend)
        }
    }

    /// Drains any stalled control-client command first, then reads the Pane's
    /// foreground. Once both answer, any queued command has left in FIFO order,
    /// so the user hears once that the last message may still be in the Agent's
    /// input before the next Send is allowed through.
    private func settleLastSend(in projection: TmuxConsoleProjection, attach: AgentAttachStore?) async -> Outcome {
        if let session = attach?.input.readySession, let tmuxSend = attach?.input.tmuxSend(for: session) {
            if await tmuxSend.settle(clock.sleep) == .unknown {
                return .failed(Self.noAnswerBeforePaste)
            }
        }
        let sample: TmuxPaneForeground
        do {
            sample = try await readForeground(in: projection)
        } catch {
            return .failed(Self.noAnswerBeforePaste)
        }
        lastSendHasNoAnswer = false
        switch sample {
        case .serverNotRunning:
            return .refused(.inputNotReady(Self.agentEnded))
        case .paneGone(let instance), .dead(let instance):
            return .refused(.inputNotReady(corePin.admits(instance.id) ? Self.agentEnded : Self.serverGone))
        case .live(let live):
            guard corePin.admits(live.instance.id) else {
                return .refused(.inputNotReady(Self.serverGone))
            }
            guard case .known = HerdrCoreAgentRule.program(
                arguments: live.pane.foregroundArguments ?? [], name: live.pane.command)
            else {
                return .refused(.inputNotReady(Self.agentLeft))
            }
            return .refused(.inputNotReady(Self.lastSendMayRemain))
        }
    }

    private func hasEnded(in projection: TmuxConsoleProjection, attach: AgentAttachStore) -> Bool {
        projection.hasPaneEnded(paneID) || attach.terminal.status == .finished
    }

    private func liveSend(
        of attach: AgentAttachStore
    ) async -> (TerminalInputController.SessionGeneration, TmuxAttachSend)? {
        let input = attach.input
        if let ready = input.readySession, let send = input.tmuxSend(for: ready) {
            return (ready, send)
        }
        attach.openForSend()
        try? await AsyncDeadline.run(for: Self.liveAttachTimeout, sleep: clock.sleep) {
            await input.untilSessionIsReady()
        }
        guard let ready = input.readySession, let send = input.tmuxSend(for: ready) else {
            return nil
        }
        return (ready, send)
    }

    private func readHeldAgent(in projection: TmuxConsoleProjection, route: ComposerRoute) async -> PrePasteRead {
        let foreground: TmuxPaneForeground
        do {
            foreground = try await readForeground(in: projection)
        } catch {
            return .outcome(.failed(Self.noAnswerBeforePaste))
        }
        switch foreground {
        case .serverNotRunning:
            return .outcome(.refused(.inputNotReady(projection.admits(corePin) ? Self.agentEnded : Self.serverGone)))
        case .paneGone(let instance), .dead(let instance):
            return .outcome(.refused(.inputNotReady(corePin.admits(instance.id) ? Self.agentEnded : Self.serverGone)))
        case .live(let sample):
            guard corePin.admits(sample.instance.id) else {
                return .outcome(.refused(.inputNotReady(Self.serverGone)))
            }
            guard case .known(let kind) = HerdrCoreAgentRule.program(
                arguments: sample.pane.foregroundArguments ?? [], name: sample.pane.command)
            else {
                return .outcome(.refused(.inputNotReady(Self.agentLeft)))
            }
            guard let pid = sample.foregroundPID else {
                return .outcome(.refused(.inputNotReady(Self.notSampledYet)))
            }
            if Self.isBlocked(sample.pane, kind: kind) {
                return .outcome(
                    route == .chat
                        ? .refused(.agentBlocked)
                        : .refused(.inputNotReady(Self.answerTheQuestionFirst)))
            }
            return .held(HeldAgent(kind: kind, pid: pid))
        }
    }

    private func changeWhileAttachOpened(
        from held: HeldAgent, in projection: TmuxConsoleProjection
    ) async -> Outcome? {
        let foreground: TmuxPaneForeground
        do {
            foreground = try await readForeground(in: projection)
        } catch {
            return .failed(Self.noAnswerBeforePaste)
        }
        switch foreground {
        case .serverNotRunning:
            return .refused(.inputNotReady(projection.admits(corePin) ? Self.agentEnded : Self.serverGone))
        case .paneGone(let instance), .dead(let instance):
            return .refused(.inputNotReady(corePin.admits(instance.id) ? Self.agentEnded : Self.serverGone))
        case .live(let sample):
            guard corePin.admits(sample.instance.id) else {
                return .refused(.inputNotReady(Self.serverGone))
            }
            let program = HerdrCoreAgentRule.program(
                arguments: sample.pane.foregroundArguments ?? [], name: sample.pane.command)
            guard sample.foregroundPID == held.pid, program == .known(held.kind) else {
                return .refused(.inputNotReady(Self.holderChangedWhileOpening))
            }
            if Self.isBlocked(sample.pane, kind: held.kind) {
                return .refused(.agentBlocked)
            }
            return nil
        }
    }

    private func readForeground(in projection: TmuxConsoleProjection) async throws -> TmuxPaneForeground {
        let paneID = paneID
        return try await AsyncDeadline.run(for: Self.stepTimeout, sleep: clock.sleep) {
            try await projection.readPaneForeground(paneID)
        }
    }

    private static func isBlocked(_ pane: TmuxInventory.Pane, kind: String) -> Bool {
        TmuxProgramStatus(option: pane.status).word(forAgent: kind) == "blocked"
    }

    /// Nothing is submitted. When a shell now leads the Pane's foreground, one
    /// raw `0x03` (`send-keys -H -t <pane> 03`) drops a pending paste unrun
    /// even when the exited Agent left extended keyboard flags on the Pane.
    private func giveUp(
        after sample: TmuxPaneForeground.Sample,
        program: HerdrCoreAgentRule.Program,
        on tmuxSend: TmuxAttachSend
    ) async -> Outcome {
        guard sample.foregroundPID != nil, program == .shell else {
            return .refused(.notSubmitted(Self.mayRemain))
        }
        switch await tmuxSend.sendHexByte(0x03, clock.sleep) {
        case .unknown:
            return .outcomeUnknown
        case .notLeft:
            return .refused(.notSubmitted(Self.mayRemain))
        case .left:
            let shell = HerdrCoreAgentRule.shellName(
                arguments: sample.pane.foregroundArguments ?? [], name: sample.pane.command)
            return .refused(
                .notSubmitted(Self.shellsDroppingPasteOnInterrupt.contains(shell) ? Self.dropped : Self.mayRemain))
        }
    }

    // MARK: What the Composer says

    private static let serverGone = TransportError.tmuxServerGone.presentation.message
    private static let notConnected = String(localized: "The message could not be sent. Check the connection and retry.")
    private static let noLiveAttach = String(
        localized: "The terminal did not connect in time, so nothing was sent. Retry when it shows.")
    private static let becameBlocked = String(
        localized:
            "The Agent started asking something before the message was submitted, so nothing was submitted. The text may still be in the Agent's input."
    )
    private static let noAnswerBeforePaste = String(
        localized: "The Host did not answer, so nothing was sent. Check the connection and retry.")
    private static let lastSendMayRemain = String(
        localized:
            "The last message may still be in the Agent's input, so nothing was sent. Check the terminal, then send again."
    )
    private static let agentLeft = String(localized: "The Agent no longer holds this terminal, so nothing was sent.")
    private static let agentEnded = String(localized: "The Agent has ended, so nothing was sent.")
    private static let answerTheQuestionFirst = String(
        localized:
            "The Agent is waiting on its question on screen, so nothing was sent. Answer it with the tools keyboard first, then send again."
    )
    private static let holderChangedWhileOpening =
        String(localized: "Another process took over the terminal as Heeler reached it, so nothing was sent.")
    private static let notSampledYet = String(
        localized: "The Agent is still starting, so nothing was sent. Try again in a moment.")
    private static let windowPassed = String(
        localized:
            "The Host answered too slowly to submit safely, so the text stayed in the Agent's input unsubmitted. Finish it in the terminal, or clear it there before sending again."
    )
    private static let programEnded = String(
        localized: "The Agent ended before the message was submitted, so nothing was submitted.")
    private static let submitKeyLost = String(
        localized:
            "The connection changed before the message was submitted, so nothing was submitted. The text may still be in the Agent's input."
    )
    private static let mayRemain = String(
        localized:
            "The Agent left the terminal before the message was submitted, so nothing was submitted. The text may still be in the terminal."
    )
    private static let dropped = String(
        localized:
            "The Agent left the terminal before the message was submitted, so nothing was submitted, and the text is no longer in the terminal."
    )
}
