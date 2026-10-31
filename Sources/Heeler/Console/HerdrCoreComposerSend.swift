import Foundation

/// Composer Send on a herdr-core Agent (ADR 0035): the draft goes through the
/// Attach the user is viewing in checked steps, so it is submitted only while the
/// same Agent still holds the terminal, and a step nobody answers is never sent
/// again. One Send at a time per Agent: two pastes must not share one submit.
@MainActor
final class HerdrCoreComposerSend {
    enum Outcome: Equatable, Sendable {
        /// The paste and the submit key both left, in that order.
        case submitted
        /// The paste left and the submit is the user's: the Agent is Blocked.
        case pasted
        /// Nothing more goes out, and the draft comes back with this.
        case refused(ComposerRefusal)
        /// Nothing left Heeler, so sending again is safe.
        case failed(String)
        /// A step got no answer and may still reach the program.
        case outcomeUnknown
    }

    /// One sampling period of the core's foreground with margin.
    static let sampleDelay: Duration = .milliseconds(550)
    /// A note the core types between paste and submit ends with Enter.
    static let submitWindow: Duration = .seconds(2)
    /// Allows for input the core holds: about a second late, with no echo.
    static let stepTimeout: Duration = .seconds(5)
    static let liveAttachTimeout: Duration = .seconds(5)

    /// The shells observed to drop a pending paste on one Ctrl+C. zsh waits on
    /// the owner's check, so it says what any other shell says.
    private static let shellsDroppingPasteOnInterrupt: Set<String> = ["bash", "fish", "dash"]

    private let address: String
    private let projection: @MainActor () -> HerdrCoreConsoleProjection?
    private let clock: BlockedCardClock
    private weak var attach: AgentAttachStore?
    private var lastSend: Task<Outcome, Never>?

    init(
        address: String,
        projection: @escaping @MainActor () -> HerdrCoreConsoleProjection?,
        clock: BlockedCardClock = .live
    ) {
        self.address = address
        self.projection = projection
        self.clock = clock
    }

    /// The Attach the user is viewing.
    func bind(_ attach: AgentAttachStore?) {
        self.attach = attach
    }

    func send(_ text: String) async -> Outcome {
        let previous = lastSend
        let send = Task {
            _ = await previous?.value
            return await deliver(text)
        }
        lastSend = send
        return await send.value
    }

    // MARK: The steps

    private func deliver(_ text: String) async -> Outcome {
        guard let attach, let projection = projection() else { return .failed(Self.notConnected) }
        guard let session = await liveSession(of: attach) else { return .failed(Self.noLiveAttach) }

        let held: Holder
        switch await holder(in: projection) {
        case .success(let holder): held = holder
        case .failure(let refusal): return refusal.outcome
        }

        let modes = attach.terminal.modes
        guard modes.usesBracketedPaste else { return .refused(.programNotAcceptingPaste) }
        let submitKey = held.record.submit ?? "enter"
        guard TerminalKeyEncoder.encode(submitKey, modes: modes) != nil else {
            return .refused(.inputNotReady(Self.unknownSubmitKey))
        }

        // Watching from before the paste: a change while it is on its way counts.
        let (wakes, wake) = AsyncStream.makeStream(of: Wake.self)
        let watch = projection.watchProgram(at: address) { wake.yield(.program($0)) }
        defer {
            projection.endProgramWatch(watch)
            wake.finish()
        }

        let isBlocked = held.agent.status == .blocked
        let pasteStart = clock.now()
        let paste = TerminalBracketedPaste.encode(text, bracketed: true)
        switch await write(paste, on: session, attach, indexedAs: isBlocked ? .composerInsert : nil) {
        case .left: break
        case .notLeft: return .failed(Self.notConnected)
        case .unknown: return .outcomeUnknown
        }
        if isBlocked { return .pasted }
        wake.yield(.pasteLeft)

        switch await sampleAfterPaste(of: held, wakes: wakes, wake: wake, in: projection) {
        case .holds(let record):
            if HerdrCoreAgentRule.agent(in: record)?.status == .blocked { return .pasted }
            guard clock.now() - pasteStart < Self.submitWindow else {
                return .refused(.notSubmitted(Self.windowPassed))
            }
            return await submit(submitKey, text: text, on: session, attach)
        case .changed(let foreground):
            return await giveUp(after: foreground, of: held.record, on: session, attach)
        case .ended:
            return .refused(.notSubmitted(Self.programEnded))
        case .noAnswer:
            return .outcomeUnknown
        }
    }

    /// Waits, bounded, for an Attach that can take input, opening one if none is
    /// on its way.
    private func liveSession(
        of attach: AgentAttachStore
    ) async -> TerminalInputController.SessionGeneration? {
        let input = attach.input
        if let ready = input.readySession { return ready }
        attach.openForSend()
        try? await AsyncDeadline.run(for: Self.liveAttachTimeout, sleep: clock.sleep) {
            await input.untilSessionIsReady()
        }
        return input.readySession
    }

    private struct Holder {
        let record: HerdrCoreTerminalRecord
        let agent: HerdrCoreAgent
        let foreground: HerdrCoreForeground
    }

    private struct NoHolder: Error {
        let outcome: Outcome
    }

    /// What holds the terminal before anything is written. A record with no
    /// sample yet gets one read: nothing has left, so an unanswered one is safe.
    private func holder(in projection: HerdrCoreConsoleProjection) async -> Result<Holder, NoHolder> {
        var record = projection.terminalRecord(at: address)
        if record?.foreground == nil {
            do {
                record = try await read(in: projection)
            } catch where Self.saysProgramEnded(error) {
                return .failure(NoHolder(outcome: .refused(.inputNotReady(Self.agentLeft))))
            } catch {
                return .failure(NoHolder(outcome: .failed(Self.noAnswerBeforePaste)))
            }
        }
        guard let record, let agent = HerdrCoreAgentRule.agent(in: record) else {
            return .failure(NoHolder(outcome: .refused(.inputNotReady(Self.agentLeft))))
        }
        guard let foreground = record.foreground, foreground.pid != nil else {
            return .failure(NoHolder(outcome: .refused(.inputNotReady(Self.notSampledYet))))
        }
        return .success(Holder(record: record, agent: agent, foreground: foreground))
    }

    private enum Write {
        case left
        /// Still on this side, and it never will leave.
        case notLeft
        case unknown
    }

    private func write(
        _ data: Data, on session: TerminalInputController.SessionGeneration, _ attach: AgentAttachStore,
        indexedAs source: AttachUserMessageIndex.OutgoingSource? = nil
    ) async -> Write {
        let input = attach.input
        do {
            try await AsyncDeadline.run(for: Self.stepTimeout, sleep: clock.sleep) {
                try await input.writeAcknowledged(data, generation: session, indexedAs: source)
            }
            return .left
        } catch AsyncDeadlineError.timedOut, TransportError.coreMutationOutcomeUnknown {
            return .unknown
        } catch {
            return .notLeft
        }
    }

    private func read(in projection: HerdrCoreConsoleProjection) async throws -> HerdrCoreTerminalRecord {
        let address = address
        return try await AsyncDeadline.run(for: Self.stepTimeout, sleep: clock.sleep) {
            try await projection.readTerminalRecord(at: address)
        }
    }

    private static func saysProgramEnded(_ error: any Error) -> Bool {
        guard let refusal = error as? HerdrAPIError else { return false }
        return refusal.code == "finished" || refusal.code == "not_found"
    }

    // MARK: The sample after the paste

    private enum Sample {
        /// The same pid runs the same program, as of this record.
        case holds(HerdrCoreTerminalRecord)
        /// Something else holds the terminal, or nothing the core can name.
        case changed(HerdrCoreForeground?)
        case ended
        case noAnswer
    }

    private enum Wake: Sendable {
        case program(HerdrCoreProgramChange)
        case pasteLeft
        case sampleDelayPassed
        case read(Result<HerdrCoreTerminalRecord, any Error>)
    }

    /// Waits for a foreground sample taken after the paste: the next event, or
    /// the sample delay followed by a read. An event that shows the Agent gone
    /// ends the wait at once; one that shows it still there does not hurry the
    /// submit, which keeps the full delay.
    private func sampleAfterPaste(
        of held: Holder, wakes: AsyncStream<Wake>, wake: AsyncStream<Wake>.Continuation,
        in projection: HerdrCoreConsoleProjection
    ) async -> Sample {
        let clock = clock
        let timer = Task {
            try? await clock.sleep(Self.sampleDelay)
            wake.yield(.sampleDelayPassed)
        }
        var reading: Task<Void, Never>?
        defer {
            timer.cancel()
            reading?.cancel()
        }

        var hasPasteLeft = false
        var sawSampleAfterPaste = false
        for await event in wakes {
            switch event {
            case .program(.ended):
                return .ended
            case .program(.sample(let foreground)):
                guard Self.holdsTheSameProgram(foreground, as: held) else { return .changed(foreground) }
                sawSampleAfterPaste = hasPasteLeft
            case .pasteLeft:
                hasPasteLeft = true
            case .sampleDelayPassed:
                if sawSampleAfterPaste {
                    return .holds(projection.terminalRecord(at: address) ?? held.record)
                }
                reading = Task {
                    do {
                        wake.yield(.read(.success(try await read(in: projection))))
                    } catch {
                        wake.yield(.read(.failure(error)))
                    }
                }
            case .read(.success(let record)):
                if record.hasFinished || record.isRestarting { return .ended }
                guard Self.holdsTheSameProgram(record.foreground, as: held) else {
                    return .changed(record.foreground)
                }
                return .holds(record)
            case .read(.failure(let error)):
                return Self.saysProgramEnded(error) ? .ended : .noAnswer
            }
        }
        return .noAnswer
    }

    /// The same pid is not enough: a shell wrapper can outlive its Agent under
    /// the same pid, and only the program behind it tells them apart.
    private static func holdsTheSameProgram(_ sample: HerdrCoreForeground?, as held: Holder) -> Bool {
        guard let sample, sample.pid == held.foreground.pid else { return false }
        var now = held.record
        now.foreground = sample
        return HerdrCoreAgentRule.program(of: now) == HerdrCoreAgentRule.program(of: held.record)
    }

    // MARK: How it ends

    private func submit(
        _ key: String, text: String, on session: TerminalInputController.SessionGeneration,
        _ attach: AgentAttachStore
    ) async -> Outcome {
        guard let bytes = TerminalKeyEncoder.encode(key, modes: attach.terminal.modes) else {
            return .refused(.notSubmitted(Self.submitKeyLost))
        }
        switch await write(bytes, on: session, attach) {
        case .left:
            attach.input.recordSubmitted(text, generation: session)
            return .submitted
        case .notLeft:
            return .refused(.notSubmitted(Self.submitKeyLost))
        case .unknown:
            return .outcomeUnknown
        }
    }

    /// Nothing is submitted. A shell holding the foreground has the text as a
    /// pending paste at best, and one Ctrl+C makes it drop that unrun. Text the
    /// program had read went with it.
    private func giveUp(
        after foreground: HerdrCoreForeground?, of record: HerdrCoreTerminalRecord,
        on session: TerminalInputController.SessionGeneration, _ attach: AgentAttachStore
    ) async -> Outcome {
        guard let foreground else { return .refused(.notSubmitted(Self.mayRemain)) }
        var now = record
        now.foreground = foreground
        guard HerdrCoreAgentRule.program(of: now) == .shell,
            let interrupt = TerminalKeyEncoder.encode("ctrl+c", modes: attach.terminal.modes)
        else { return .refused(.notSubmitted(Self.mayRemain)) }
        switch await write(interrupt, on: session, attach) {
        case .unknown:
            return .outcomeUnknown
        case .notLeft:
            return .refused(.notSubmitted(Self.mayRemain))
        case .left:
            let shell = HerdrCoreAgentRule.shellName(of: foreground)
            return .refused(
                .notSubmitted(
                    Self.shellsDroppingPasteOnInterrupt.contains(shell) ? Self.dropped : Self.mayRemain))
        }
    }

    // MARK: What the Composer says

    private static let notConnected = "The message could not be sent. Check the connection and retry."
    private static let noLiveAttach = "The terminal did not connect in time, so nothing was sent. Retry when it shows."
    private static let noAnswerBeforePaste = "The Host did not answer, so nothing was sent. Check the connection and retry."
    private static let agentLeft = "The Agent no longer holds this terminal, so nothing was sent."
    private static let notSampledYet = "The Agent is still starting, so nothing was sent. Try again in a moment."
    private static let unknownSubmitKey = "This Terminal's Template names a submit key Heeler cannot press, so nothing was sent."
    private static let windowPassed =
        "The Host answered too slowly to submit safely, so the text stayed in the Agent's input unsubmitted. Finish it in the terminal, or clear it there before sending again."
    private static let programEnded = "The Agent ended before the message was submitted, so nothing was submitted."
    private static let submitKeyLost =
        "The connection changed before the message was submitted, so nothing was submitted. The text may still be in the Agent's input."
    private static let mayRemain =
        "The Agent left the terminal before the message was submitted, so nothing was submitted. The text may still be in the terminal."
    private static let dropped =
        "The Agent left the terminal before the message was submitted, so nothing was submitted, and the text is no longer in the terminal."
}
