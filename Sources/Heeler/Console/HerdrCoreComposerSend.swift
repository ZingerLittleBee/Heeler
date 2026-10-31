import Foundation

/// Where a herdr-core Send types: the Attach the user is viewing, or for Chat a
/// viewer of its own (ADR 0035).
@MainActor
protocol HerdrCoreTypingSeat: AnyObject, Sendable {
    /// The program's modes, as this seat's output has left them.
    var modes: TerminalModeTracker { get }
    /// Returns once the bytes have left. `coreMutationOutcomeUnknown` says they may
    /// have; anything else says they never did.
    func write(_ data: Data, indexedAs source: AttachUserMessageIndex.OutgoingSource?) async throws
    func recordSubmitted(_ text: String)
    /// `data` left and now waits, unsubmitted, for the user to finish it.
    func notePendingInsert(_ data: Data)
    func leave()
}

/// The Agent holding a core Terminal before anything is typed into it.
struct HerdrCoreAgentHolder {
    enum Problem: Error {
        case agentLeft
        case notSampledYet
        case noAnswer
    }

    let record: HerdrCoreTerminalRecord
    let agent: HerdrCoreAgent
    let foreground: HerdrCoreForeground

    /// A record with no sample yet gets one read: nothing has left, so an
    /// unanswered one is safe.
    @MainActor
    static func current(
        at address: String, in projection: HerdrCoreConsoleProjection, clock: BlockedCardClock
    ) async -> Result<HerdrCoreAgentHolder, Problem> {
        var record = projection.terminalRecord(at: address)
        if record?.foreground == nil {
            do {
                record = try await AsyncDeadline.run(for: HerdrCoreComposerSend.stepTimeout, sleep: clock.sleep) {
                    try await projection.readTerminalRecord(at: address)
                }
            } catch where HerdrCoreComposerSend.saysProgramEnded(error) {
                return .failure(.agentLeft)
            } catch {
                return .failure(.noAnswer)
            }
        }
        guard let record, let agent = HerdrCoreAgentRule.agent(in: record) else { return .failure(.agentLeft) }
        guard let foreground = record.foreground, foreground.pid != nil else { return .failure(.notSampledYet) }
        return .success(HerdrCoreAgentHolder(record: record, agent: agent, foreground: foreground))
    }
}

/// The Attach the user is viewing, as a Send types into it.
@MainActor
private final class ViewedAttachSeat: HerdrCoreTypingSeat {
    private let attach: AgentAttachStore
    private let session: TerminalInputController.SessionGeneration

    init(_ attach: AgentAttachStore, session: TerminalInputController.SessionGeneration) {
        self.attach = attach
        self.session = session
    }

    var modes: TerminalModeTracker { attach.terminal.modes }

    func write(_ data: Data, indexedAs source: AttachUserMessageIndex.OutgoingSource?) async throws {
        try await attach.input.writeAcknowledged(data, generation: session, indexedAs: source)
    }

    func recordSubmitted(_ text: String) {
        attach.input.recordSubmitted(text, generation: session)
    }

    func notePendingInsert(_ data: Data) {
        attach.input.notePendingInsert(data, generation: session)
    }

    func leave() {}
}

/// Composer Send on a herdr-core Agent (ADR 0035): the draft goes through the
/// Attach the user is viewing, or from Chat a viewer of its own, in checked steps,
/// so it is submitted only while the same Agent still holds the terminal, and a
/// step nobody answers is never sent again. One Send at a time per Agent: two
/// pastes must not share one submit.
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
    private var lastSend: Task<Outcome, Never>?
    /// A Send ended with bytes nobody answered for. They stay queued however long
    /// that takes, so another paste would line up behind them under one submit.
    private var lastSendHasNoAnswer = false

    init(
        address: String,
        projection: @escaping @MainActor () -> HerdrCoreConsoleProjection?,
        clock: BlockedCardClock = .live
    ) {
        self.address = address
        self.projection = projection
        self.clock = clock
    }

    /// `attach` is the one the user is viewing, in the window sending. Chat has none.
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

    // MARK: The steps

    private func deliver(_ text: String, route: ComposerRoute, attach: AgentAttachStore?) async -> Outcome {
        guard let projection = projection() else { return .failed(Self.notConnected) }
        if lastSendHasNoAnswer { return await settleLastSend(in: projection) }

        var viewed: ViewedAttachSeat?
        if route == .terminal {
            guard let attach else { return .failed(Self.notConnected) }
            guard let session = await liveSession(of: attach) else { return .failed(Self.noLiveAttach) }
            viewed = ViewedAttachSeat(attach, session: session)
        }

        let held: HerdrCoreAgentHolder
        switch await HerdrCoreAgentHolder.current(at: address, in: projection, clock: clock) {
        case .success(let holder): held = holder
        case .failure(let problem): return Self.outcome(of: problem)
        }
        let isBlocked = held.agent.status == .blocked

        let seat: any HerdrCoreTypingSeat
        if let viewed {
            seat = viewed
        } else {
            // Chat answers a dialog with its card, and never types into one.
            guard !isBlocked else { return .refused(.agentBlocked) }
            do {
                seat = try await projection.chatTyping(at: address).openViewer()
            } catch where Self.saysProgramEnded(error) {
                return .refused(.inputNotReady(Self.agentLeft))
            } catch {
                return .failed(Self.noChatViewer)
            }
        }
        defer { seat.leave() }

        if viewed == nil, let change = await changeWhileViewerOpened(from: held, in: projection) {
            return change
        }

        let modes = seat.modes
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

        let pasteStart = clock.now()
        let paste = TerminalBracketedPaste.encode(text, bracketed: true)
        switch await write(paste, on: seat, indexedAs: isBlocked ? .composerInsert : nil) {
        case .left: break
        case .notLeft: return .failed(Self.notConnected)
        case .unknown: return .outcomeUnknown
        }
        if isBlocked { return .pasted }

        switch await sampleAfterPaste(of: held, wakes: wakes, wake: wake, in: projection) {
        case .holds(let record):
            if HerdrCoreAgentRule.agent(in: record)?.status == .blocked {
                guard route == .terminal else { return .refused(.notSubmitted(Self.becameBlocked)) }
                seat.notePendingInsert(paste)
                return .pasted
            }
            guard clock.now() - pasteStart < Self.submitWindow else {
                return .refused(.notSubmitted(Self.windowPassed))
            }
            return await submit(submitKey, text: text, on: seat)
        case .changed(let foreground):
            return await giveUp(after: foreground, of: held.record, on: seat)
        case .ended:
            return .refused(.notSubmitted(Self.programEnded))
        case .noAnswer:
            return .outcomeUnknown
        }
    }

    /// Nothing goes while the Host stays silent. Its answer says what was queued has
    /// left, since the writer keeps order, and so that it may be in the Agent's input,
    /// where the next submit would take it along. Only the user can see that, so they
    /// hear it once and the next Send is theirs.
    private func settleLastSend(in projection: HerdrCoreConsoleProjection) async -> Outcome {
        do {
            _ = try await read(in: projection)
        } catch where Self.saysProgramEnded(error) {
            lastSendHasNoAnswer = false
            return .refused(.inputNotReady(Self.agentLeft))
        } catch {
            return .failed(Self.noAnswerBeforePaste)
        }
        lastSendHasNoAnswer = false
        return .refused(.inputNotReady(Self.lastSendMayRemain))
    }

    private static func outcome(of problem: HerdrCoreAgentHolder.Problem) -> Outcome {
        switch problem {
        case .agentLeft: .refused(.inputNotReady(agentLeft))
        case .notSampledYet: .refused(.inputNotReady(notSampledYet))
        case .noAnswer: .failed(noAnswerBeforePaste)
        }
    }

    /// Opening Chat's viewer can take seconds, and a paste goes only while the same
    /// process holds the foreground and has no dialog up. Why not, or nil to go on.
    private func changeWhileViewerOpened(
        from held: HerdrCoreAgentHolder, in projection: HerdrCoreConsoleProjection
    ) async -> Outcome? {
        switch await HerdrCoreAgentHolder.current(at: address, in: projection, clock: clock) {
        case .failure(let problem):
            return Self.outcome(of: problem)
        case .success(let now):
            guard Self.holdsTheSameProgram(now.foreground, as: held) else {
                return .refused(.inputNotReady(Self.holderChangedWhileOpening))
            }
            return now.agent.status == .blocked ? .refused(.agentBlocked) : nil
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

    private enum Write {
        case left
        /// Still on this side, and it never will leave.
        case notLeft
        case unknown
    }

    private func write(
        _ data: Data, on seat: any HerdrCoreTypingSeat,
        indexedAs source: AttachUserMessageIndex.OutgoingSource? = nil
    ) async -> Write {
        do {
            try await AsyncDeadline.run(for: Self.stepTimeout, sleep: clock.sleep) {
                try await seat.write(data, indexedAs: source)
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

    static func saysProgramEnded(_ error: any Error) -> Bool {
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
        case sampleDelayPassed
        case read(Result<HerdrCoreTerminalRecord, any Error>)
    }

    /// Waits for a foreground sample taken after the paste: the sample delay
    /// followed by a read, which the core answers at least that long after the
    /// paste reached it. An event that shows the Agent gone ends the wait at once.
    /// One that shows it still there says nothing about after the paste: the core
    /// may have sampled it before the paste arrived, and it sends no other until
    /// the foreground changes.
    private func sampleAfterPaste(
        of held: HerdrCoreAgentHolder, wakes: AsyncStream<Wake>, wake: AsyncStream<Wake>.Continuation,
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

        for await event in wakes {
            switch event {
            case .program(.ended):
                return .ended
            case .program(.sample(let foreground)):
                guard Self.holdsTheSameProgram(foreground, as: held) else { return .changed(foreground) }
            case .sampleDelayPassed:
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
    private static func holdsTheSameProgram(_ sample: HerdrCoreForeground?, as held: HerdrCoreAgentHolder) -> Bool {
        guard let sample, sample.pid == held.foreground.pid else { return false }
        var now = held.record
        now.foreground = sample
        return HerdrCoreAgentRule.program(of: now) == HerdrCoreAgentRule.program(of: held.record)
    }

    // MARK: How it ends

    private func submit(_ key: String, text: String, on seat: any HerdrCoreTypingSeat) async -> Outcome {
        guard let bytes = TerminalKeyEncoder.encode(key, modes: seat.modes) else {
            return .refused(.notSubmitted(Self.submitKeyLost))
        }
        switch await write(bytes, on: seat) {
        case .left:
            seat.recordSubmitted(text)
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
        after foreground: HerdrCoreForeground?, of record: HerdrCoreTerminalRecord, on seat: any HerdrCoreTypingSeat
    ) async -> Outcome {
        guard let foreground else { return .refused(.notSubmitted(Self.mayRemain)) }
        var now = record
        now.foreground = foreground
        guard HerdrCoreAgentRule.program(of: now) == .shell else {
            return .refused(.notSubmitted(Self.mayRemain))
        }
        // The byte itself, not the key in the program's mode: an Agent that died
        // leaves its keyboard flags behind, and a shell reads no `CSI 99;5u`.
        switch await write(Data([0x03]), on: seat) {
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
    private static let noChatViewer = "Heeler couldn't reach the Agent's terminal in time, so nothing was sent. Retry."
    private static let becameBlocked =
        "The Agent started asking something before the message was submitted, so nothing was submitted. The text may still be in the Agent's input."
    private static let noAnswerBeforePaste = "The Host did not answer, so nothing was sent. Check the connection and retry."
    private static let lastSendMayRemain =
        "The last message may still be in the Agent's input, so nothing was sent. Check the terminal, then send again."
    private static let agentLeft = "The Agent no longer holds this terminal, so nothing was sent."
    private static let holderChangedWhileOpening =
        "Another process took over the terminal as Heeler reached it, so nothing was sent."
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
