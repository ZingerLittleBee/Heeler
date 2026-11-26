import Foundation

/// Composer Send on a Rex Agent (ADR 0055), from the terminal or from Chat:
/// the draft goes as one paste and one Enter on the Host's control link, each
/// in the block's lane, which an open terminal view's input shares, in tmux's
/// order of checks. It pastes only while a known Agent leads the foreground,
/// its status does not read Blocked and bracketed paste is on, with the same
/// process and bracketed paste read again once the lane is held; and it
/// submits only while that process still holds the terminal, read again in
/// the lane before Enter, within the submit window. A shell that took over
/// gets one `0x03`.
///
/// One Send runs at a time per Agent, and a request that got no answer is
/// never sent again: the next Send waits for the server to answer a read and
/// warns once that the last message may still be in the Agent's input.
@MainActor
final class RexComposerSend: CheckedComposerSend {
    typealias Outcome = CheckedSendOutcome

    nonisolated static let submitWindow: Duration = .seconds(2)

    /// Shells seen dropping a pending paste on one `0x03` (ADR 0035).
    private static let shellsDroppingPasteOnInterrupt: Set<String> = ["bash", "fish", "dash", "zsh"]

    /// Why a step in the lane went no further. `tookOver` is the process that
    /// leads the foreground now in place of the Agent the paste went to.
    private struct Halt: Error {
        let outcome: Outcome
        var tookOver: RexInventoryWire.Process?
    }

    private let address: RexPaneAddress
    private let projection: @MainActor () -> RexConsoleProjection?
    /// The server this Composer's Agent runs on.
    private let corePin: TerminalCorePin
    private let clock: BlockedCardClock
    private var lastSend: Task<Outcome, Never>?
    private var lastSendHasNoAnswer = false

    init(
        address: RexPaneAddress,
        projection: @escaping @MainActor () -> RexConsoleProjection?,
        corePin: TerminalCorePin = TerminalCorePin(),
        clock: BlockedCardClock = .live
    ) {
        self.address = address
        self.projection = projection
        self.corePin = corePin
        self.clock = clock
    }

    /// `attach` is the terminal the user is viewing, which only records what
    /// was submitted: the draft itself goes on the control link either way.
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
        let requests: RexBlockRequests
        do {
            requests = try await projection.blockRequests(at: address, keepingTo: corePin)
        } catch TransportError.rexServerGone {
            return .refused(.inputNotReady(Self.serverGone))
        } catch {
            return .failed(Self.notConnected)
        }
        if lastSendHasNoAnswer { return await settleLastSend(on: requests) }

        // Run the three read-only pre-lane checks concurrently (saving 2 RTTs)
        // while still evaluating their results in the exact original order.
        async let heldResult = readHeldAgent(on: requests, in: projection, route: route)
        async let flagsResult: Result<UInt8, any Error> = {
            do { return .success(try await RexChatScreen.kittyKeyboardFlags(on: requests)) }
            catch { return .failure(error) }
        }()
        async let modesRawResult: Result<JSONValue, any Error> = {
            do { return .success(try await requests.read(.modes)) }
            catch { return .failure(error) }
        }()

        let held: RexAgentHolder
        switch await heldResult {
        case .success(let holder): held = holder
        case .failure(let halt):
            _ = await (flagsResult, modesRawResult)
            return halt.outcome
        }

        let modes: TerminalModeTracker
        do {
            let flags = try await flagsResult.get()
            let rawModes = try await modesRawResult.get()
            modes = try RexChatScreen.modes(from: rawModes, kittyKeyboardFlags: flags)
        } catch {
            return Self.beforePaste(error)
        }
        guard modes.usesBracketedPaste else { return .refused(.programNotAcceptingPaste) }
        guard requests.fitsOnePaste(text) else { return .refused(.inputNotReady(Self.pasteTooLarge)) }
        guard let enter = HerdrCoreChatTyping.bytes(forKeyNamed: "enter", modes: modes),
            let submit = String(validating: enter, as: UTF8.self)
        else { return .refused(.inputNotReady(Self.notConnected)) }

        let pasteStart = clock.now()
        switch await sendInLane([.paste(text)], on: requests, check: { @MainActor in
            try await self.stillHeld(held, on: requests, in: projection)
        }) {
        case .success(.sent): break
        case .success(.notSent(let failure)):
            return failure?.kind == .notFound ? .refused(.inputNotReady(Self.agentEnded)) : .failed(Self.notConnected)
        case .success(.unknown): return .outcomeUnknown
        case .failure(let halt): return halt.outcome
        }

        let submitted = await sendInLane([.text(submit)], on: requests, check: { @MainActor in
            try await self.stillHoldsAfterPaste(held, on: requests, in: projection, pasteStart: pasteStart)
        })
        switch submitted {
        case .success(.sent):
            if route == .terminal, let attach, let session = attach.input.readySession {
                attach.input.recordSubmitted(text, generation: session)
            }
            return .submitted
        case .success(.notSent): return .refused(.notSubmitted(Self.submitKeyLost))
        case .success(.unknown): return .outcomeUnknown
        case .failure(let halt):
            if let process = halt.tookOver { return await giveUp(after: process, on: requests) }
            return halt.outcome
        }
    }

    /// `pieces` in the block's lane after `check`, which says why not by
    /// throwing a `Halt`.
    private func sendInLane(
        _ pieces: [RexTerminalInputPiece], on requests: RexBlockRequests,
        check: @escaping @MainActor @Sendable () async throws -> Void
    ) async -> Result<RexBlockRequests.Sending, Halt> {
        do {
            return .success(try await requests.send(pieces, confirming: check))
        } catch let halt as Halt {
            return .failure(halt)
        } catch {
            return .failure(Halt(outcome: .failed(Self.notConnected)))
        }
    }

    /// The Agent to paste for, read afresh: a known Agent leading the
    /// foreground, with no question up.
    private func readHeldAgent(
        on requests: RexBlockRequests, in projection: RexConsoleProjection, route: ComposerRoute
    ) async -> Result<RexAgentHolder, Halt> {
        let read: RexAgentHolder.Read
        do {
            read = try await RexAgentHolder.read(on: requests)
        } catch {
            return .failure(Halt(outcome: Self.beforePaste(error)))
        }
        switch read {
        case .ended: return .failure(Halt(outcome: .refused(.inputNotReady(Self.agentEnded))))
        case .agentLeft: return .failure(Halt(outcome: .refused(.inputNotReady(Self.agentLeft))))
        case .notSampledYet: return .failure(Halt(outcome: .refused(.inputNotReady(Self.notSampledYet))))
        case .holds(let holder):
            if projection.agentStatus(at: address, heldBy: holder) == .blocked {
                return .failure(
                    Halt(
                        outcome: route == .chat
                            ? .refused(.agentBlocked) : .refused(.inputNotReady(Self.answerTheQuestionFirst))))
            }
            return .success(holder)
        }
    }

    /// In the lane before the paste: the same process, with no question up and
    /// bracketed paste still on, since the program can turn it off at any time.
    private func stillHeld(
        _ held: RexAgentHolder, on requests: RexBlockRequests, in projection: RexConsoleProjection
    ) async throws {
        async let readResult: Result<RexAgentHolder.Read, any Error> = {
            do { return .success(try await RexAgentHolder.read(on: requests)) }
            catch { return .failure(error) }
        }()
        async let modesRawResult: Result<JSONValue, any Error> = {
            do { return .success(try await requests.read(.modes)) }
            catch { return .failure(error) }
        }()

        let read: RexAgentHolder.Read
        do {
            read = try await readResult.get()
        } catch {
            _ = await modesRawResult
            throw Halt(outcome: Self.beforePaste(error))
        }
        switch read {
        case .holds(let now) where now == held:
            if projection.agentStatus(at: address, heldBy: now) == .blocked {
                _ = await modesRawResult
                throw Halt(outcome: .refused(.agentBlocked))
            }
        case .ended:
            _ = await modesRawResult
            throw Halt(outcome: .refused(.inputNotReady(Self.agentEnded)))
        case .holds, .agentLeft, .notSampledYet:
            _ = await modesRawResult
            throw Halt(outcome: .refused(.inputNotReady(Self.holderChangedWhileOpening)))
        }
        let modes: TerminalModeTracker
        do {
            modes = try RexChatScreen.modes(from: try await modesRawResult.get(), kittyKeyboardFlags: 0)
        } catch {
            throw Halt(outcome: Self.beforePaste(error))
        }
        guard modes.usesBracketedPaste else { throw Halt(outcome: .refused(.programNotAcceptingPaste)) }
    }

    /// In the lane before Enter: the process the paste went to still holds the
    /// terminal with no question up, within the submit window. A shell that
    /// took over gets one `0x03` instead, which drops the paste unrun.
    private func stillHoldsAfterPaste(
        _ held: RexAgentHolder, on requests: RexBlockRequests, in projection: RexConsoleProjection,
        pasteStart: ContinuousClock.Instant
    ) async throws {
        let read: RexAgentHolder.Read
        do {
            read = try await RexAgentHolder.read(on: requests)
        } catch {
            throw Halt(outcome: .outcomeUnknown)
        }
        switch read {
        case .holds(let now) where now == held:
            if projection.agentStatus(at: address, heldBy: now) == .blocked {
                throw Halt(outcome: .refused(.notSubmitted(Self.becameBlocked)))
            }
            guard clock.now() - pasteStart < Self.submitWindow else {
                throw Halt(outcome: .refused(.notSubmitted(Self.windowPassed)))
            }
        case .ended:
            throw Halt(outcome: .refused(.notSubmitted(Self.programEnded)))
        case .notSampledYet:
            throw Halt(outcome: .refused(.notSubmitted(Self.mayRemain)))
        case .holds(let now):
            throw Halt(outcome: .refused(.notSubmitted(Self.mayRemain)), tookOver: now.process)
        case .agentLeft(let process):
            throw Halt(outcome: .refused(.notSubmitted(Self.mayRemain)), tookOver: process)
        }
    }

    /// Nothing is submitted. When a shell now leads the foreground, one raw
    /// `0x03` drops a pending paste unrun, even where the exited Agent left
    /// its keyboard flags behind. It goes only while that shell still leads,
    /// read again in the lane: the Agent back, or another process, gets none.
    private func giveUp(after process: RexInventoryWire.Process, on requests: RexBlockRequests) async -> Outcome {
        let name = process.program ?? ""
        let arguments = [process.argv0 ?? name]
        guard let shellID = process.processID, HerdrCoreAgentRule.program(arguments: arguments, name: name) == .shell
        else {
            return .refused(.notSubmitted(Self.mayRemain))
        }
        let interrupt = try? await requests.send([.text("\u{03}")]) { @MainActor in
            guard case .agentLeft(let now) = try await RexAgentHolder.read(on: requests), now.processID == shellID else {
                throw Halt(outcome: .refused(.notSubmitted(Self.mayRemain)))
            }
        }
        switch interrupt {
        case .sent?:
            let shell = HerdrCoreAgentRule.shellName(arguments: arguments, name: name)
            return .refused(
                .notSubmitted(Self.shellsDroppingPasteOnInterrupt.contains(shell) ? Self.dropped : Self.mayRemain))
        case .unknown?:
            return .outcomeUnknown
        case .notSent?, nil:
            return .refused(.notSubmitted(Self.mayRemain))
        }
    }

    /// Nothing goes while the last Send's request has no answer. A read the
    /// server answers says the link carries requests again, and the user hears
    /// once that the last message may be in the Agent's input.
    private func settleLastSend(on requests: RexBlockRequests) async -> Outcome {
        let read: RexAgentHolder.Read
        do {
            read = try await RexAgentHolder.read(on: requests)
        } catch {
            return .failed(Self.noAnswerBeforePaste)
        }
        lastSendHasNoAnswer = false
        switch read {
        case .ended: return .refused(.inputNotReady(Self.agentEnded))
        case .agentLeft: return .refused(.inputNotReady(Self.agentLeft))
        case .holds, .notSampledYet: return .refused(.inputNotReady(Self.lastSendMayRemain))
        }
    }

    /// A read that failed before anything left. A kitty flags read that shows
    /// nothing certain is Chat's unreadable screen, and a modes answer this
    /// build cannot read is Rex's answer, neither a silent Host.
    private static func beforePaste(_ error: any Error) -> Outcome {
        switch error {
        case TransportError.rexServerGone: .refused(.inputNotReady(serverGone))
        case RexControlError.server(let failure) where failure.kind == .notFound:
            .refused(.inputNotReady(agentEnded))
        case is RexScreenProblem: .refused(.inputNotReady(screenUnreadable))
        case TransportError.rexAnswerUnreadable(let detail):
            .refused(.inputNotReady(TransportError.rexAnswerUnreadable(detail).presentation.message))
        default: .failed(noAnswerBeforePaste)
        }
    }

    // MARK: What the Composer says

    private static let serverGone = TransportError.rexServerGone.presentation.message
    private static let screenUnreadable = TransportError.rexScreenUnreadable.presentation.message
    private static let notConnected = String(localized: "The message could not be sent. Check the connection and retry.")
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
    private static let pasteTooLarge =
        String(localized: "This paste is too large to send to a Rex terminal in one piece. Paste less at a time.")
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
