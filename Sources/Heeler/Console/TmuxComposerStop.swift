import Foundation

/// The tmux name of one herdr key, read back from the bytes the terminal view
/// would send for it (`TerminalKeyEncoder`, then `TmuxKeyReader`).
enum TmuxNamedKey {
    static func name(for herdrKey: String) -> String? {
        guard let bytes = TerminalKeyEncoder.encode(herdrKey, modes: TerminalModeTracker()) else { return nil }
        let inputs = TmuxKeyReader.read(bytes)
        guard inputs.count == 1, case .key(let key) = inputs[0] else { return nil }
        return key.name
    }
}

/// Composer Stop on a tmux Agent (ADRs 0024 and 0045): Chat's keys for the
/// program, through the Attach's control client, after anything already typed.
/// A guard reads `capture-pane` on that same queue and can press nothing. When
/// every key leaves, Heeler writes idle at once.
@MainActor
final class TmuxComposerStop {
    enum Seat {
        case terminal(AgentAttachStore?)
        case chat
    }

    static let notSent = String(localized: "The terminal isn't connected, so Stop wasn't sent.")

    private static let liveAttachTimeout: Duration = .seconds(5)

    private let paneID: String
    private let program: ChatProgram
    private let plan: ChatStopPlan
    private let projection: @MainActor () -> TmuxConsoleProjection?
    private let corePin: TerminalCorePin
    private let clock: BlockedCardClock
    private let seat: Seat

    init(
        paneID: String,
        program: ChatProgram,
        plan: ChatStopPlan,
        projection: @escaping @MainActor () -> TmuxConsoleProjection?,
        corePin: TerminalCorePin,
        clock: BlockedCardClock,
        seat: Seat
    ) {
        self.paneID = paneID
        self.program = program
        self.plan = plan
        self.projection = projection
        self.corePin = corePin
        self.clock = clock
        self.seat = seat
    }

    convenience init(
        paneID: String,
        program: ChatProgram,
        plan: ChatStopPlan,
        projection: @escaping @MainActor () -> TmuxConsoleProjection?,
        corePin: TerminalCorePin,
        clock: BlockedCardClock,
        attach: AgentAttachStore?
    ) {
        self.init(
            paneID: paneID, program: program, plan: plan, projection: projection,
            corePin: corePin, clock: clock, seat: .terminal(attach))
    }

    func perform() async -> AgentInterruptOutcome {
        guard let projection = projection(), projection.admits(corePin) else { return .failed(Self.notSent) }
        switch seat {
        case .terminal(let attach):
            guard let attach else { return .failed(Self.notSent) }
            guard stillTheProgram(in: projection) else { return .failed(Self.notSent) }
            guard let send = await liveSend(of: attach, in: projection) else { return .failed(Self.notSent) }
            guard projection.admits(corePin), stillTheProgram(in: projection) else { return .failed(Self.notSent) }
            return await runStopPlan(on: send, in: projection)

        case .chat:
            guard let heldPID = await foregroundProgramPID(in: projection) else { return .failed(Self.notSent) }
            if let screenGuard = plan.screenGuard {
                let paneID = paneID
                let corePin = corePin
                guard let screen = try? await AsyncDeadline.run(
                    for: TmuxComposerSend.stepTimeout, sleep: clock.sleep,
                    operation: { try await projection.capturePaneScreen(paneID, keepingTo: corePin) })
                else {
                    return .failed(ChatStopPlan.unreadableScreenMessage)
                }
                let context = ChatStopContext(
                    screen: screen,
                    activity: Self.activity(of: projection.agentsByPane[paneID]?.agent.status ?? .unknown))
                if case .refuse(let reason) = screenGuard(context) {
                    return .failed(reason)
                }
            }
            let chatAttach: TmuxChatAttach
            do {
                let paneID = paneID
                let corePin = corePin
                chatAttach = try await AsyncDeadline.run(for: Self.liveAttachTimeout, sleep: clock.sleep) {
                    try await projection.openChatAttach(at: paneID, keepingTo: corePin)
                }
            } catch {
                return .failed(Self.notSent)
            }
            guard projection.admits(corePin), await foregroundProgramPID(in: projection) == heldPID else {
                await chatAttach.close()
                return .failed(Self.notSent)
            }
            let outcome = await runStopPlan(on: chatAttach.tmuxSend, in: projection)
            await chatAttach.close()
            return outcome
        }
    }

    private func runStopPlan(
        on send: TmuxAttachSend, in projection: TmuxConsoleProjection
    ) async -> AgentInterruptOutcome {
        if let screenGuard = plan.screenGuard {
            switch await send.capturePane(clock.sleep) {
            case .text(let text):
                let context = ChatStopContext(
                    screen: ANSIScreenDecoder.decode(text),
                    activity: Self.activity(of: projection.agentsByPane[paneID]?.agent.status ?? .unknown))
                switch screenGuard(context) {
                case .press: break
                case .refuse(let reason): return .failed(reason)
                }
            case .notLeft, .unknown:
                return .failed(ChatStopPlan.unreadableScreenMessage)
            }
        }

        var anyLeft = false
        for key in plan.keys {
            guard let name = TmuxNamedKey.name(for: key) else { return .failed(ChatStopPlan.unreachableMessage) }
            switch await send.sendKey(name, clock.sleep) {
            case .left:
                anyLeft = true
            case .notLeft:
                return .failed(anyLeft ? ChatStopPlan.unreachableMessage : Self.notSent)
            case .unknown:
                return .failed(ChatStopPlan.unreachableMessage)
            }
        }

        guard let projection = self.projection(), projection.admits(corePin) else { return .sent }
        _ = await projection.writeHeelerStatus(
            TmuxStatusReport(state: "idle", app: Self.reportedApp(program)), on: paneID)
        return .sent
    }

    private func foregroundProgramPID(in projection: TmuxConsoleProjection) async -> Int? {
        let paneID = paneID
        guard let foreground = try? await AsyncDeadline.run(
            for: TmuxComposerSend.stepTimeout, sleep: clock.sleep,
            operation: { try await projection.readPaneForeground(paneID) }),
            case .live(let sample) = foreground,
            corePin.admits(sample.instance.id),
            let pid = sample.foregroundPID,
            HerdrCoreAgentRule.program(
                arguments: sample.pane.foregroundArguments ?? [], name: sample.pane.command) == .known(program.rawValue)
        else {
            return nil
        }
        return pid
    }

    private func stillTheProgram(in projection: TmuxConsoleProjection) -> Bool {
        guard let pane = projection.inventoryPane(paneID) else { return false }
        return TmuxAgentRule.agentKind(in: pane) == program.rawValue
    }

    private func liveSend(
        of attach: AgentAttachStore, in projection: TmuxConsoleProjection
    ) async -> TmuxAttachSend? {
        let input = attach.input
        if let ready = input.readySession, let send = input.tmuxSend(for: ready) { return send }
        guard projection.admits(corePin) else { return nil }
        attach.openForSend()
        try? await AsyncDeadline.run(for: Self.liveAttachTimeout, sleep: clock.sleep) {
            await input.untilSessionIsReady()
        }
        guard let ready = input.readySession else { return nil }
        return input.tmuxSend(for: ready)
    }

    private static func activity(of status: AgentStatus) -> ChatAgentActivity {
        if status == .working { return .working }
        if status == .blocked { return .blocked }
        if status == .idle || status == .done { return .idle }
        return .unknown
    }

    /// The `app` word a Program Status uses for this program.
    static func reportedApp(_ program: ChatProgram) -> String {
        HerdrCoreAgentRule.reportedApps.first { $0.value == program.rawValue }?.key ?? program.rawValue
    }
}
