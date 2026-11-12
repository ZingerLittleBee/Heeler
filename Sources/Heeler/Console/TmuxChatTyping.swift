import Foundation
import Synchronization

/// Chat's own size-less Attach to one tmux Pane (ADR 0043).
///
/// Opens as an unviewed, zero-geometry control client so `TmuxPaneAttach` posts
/// `refresh-client -f ignore-size` and never asks for a client size (`-C`),
/// waits for `TmuxPaneFeed`'s initial paint so `#{bracket_paste_flag}` has
/// settled before any paste runs, drains output, and closes through
/// `TerminalAttachSession.end()` (`TmuxPaneAttach.close()`).
final class TmuxChatAttach: Sendable {
    private actor FirstPaintGate {
        private var isPainted = false
        private var endResult: Result<Void, any Error>?
        private var waiter: CheckedContinuation<Void, any Error>?

        func painted() {
            guard !isPainted, endResult == nil else { return }
            isPainted = true
            let waiter = self.waiter
            self.waiter = nil
            waiter?.resume(returning: ())
        }

        func ended(_ error: (any Error)?) {
            guard !isPainted, endResult == nil else { return }
            let failure =
                error
                ?? TransportError.malformedResponse(
                    String(localized: "tmux: The control client ended before it painted."))
            endResult = .failure(failure)
            let waiter = self.waiter
            self.waiter = nil
            waiter?.resume(throwing: failure)
        }

        func wait() async throws {
            if isPainted { return }
            if let endResult {
                try endResult.get()
                return
            }
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
            }
        }
    }

    let tmuxSend: TmuxAttachSend
    private let session: TerminalAttachSession
    private let drain: Task<Void, Never>
    private let closed = Mutex(false)

    private init(tmuxSend: TmuxAttachSend, session: TerminalAttachSession, drain: Task<Void, Never>) {
        self.tmuxSend = tmuxSend
        self.session = session
        self.drain = drain
    }

    static func open(session: TerminalAttachSession) async throws -> TmuxChatAttach {
        guard let tmuxSend = session.tmuxSend else {
            await session.end()
            throw TransportError.malformedResponse(String(localized: "tmux: The Attach has no send queue."))
        }
        let gate = FirstPaintGate()
        let output = session.output
        let drain = Task {
            do {
                for try await chunk in output {
                    if !chunk.isEmpty {
                        await gate.painted()
                    }
                }
                await gate.ended(nil)
            } catch {
                await gate.ended(error)
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await gate.wait()
            } onCancel: {
                Task { await gate.ended(CancellationError()) }
            }
        } catch {
            await session.end()
            _ = await drain.value
            throw error
        }
        return TmuxChatAttach(tmuxSend: tmuxSend, session: session, drain: drain)
    }

    func close() async {
        let shouldClose = closed.withLock { alreadyClosed -> Bool in
            if alreadyClosed { return false }
            alreadyClosed = true
            return true
        }
        guard shouldClose else { return }
        await session.end()
        _ = await drain.value
    }
}

/// How Chat reads and types into a tmux Pane (ADRs 0035, 0043 and 0044).
///
/// Screen reads run `capture-pane -e -p` on the Host's socket without opening a
/// control client. Typing opens an Attach of Chat's own that asks for no size
/// and closes as soon as the action finishes, checking the foreground process
/// before and after it opens, and re-reading the screen when answering a
/// Blocked Card dialog.
@MainActor
final class TmuxChatTyping: CheckedChatTyping {
    typealias Refusal = HerdrCoreChatTyping.Refusal

    private struct Holder: Equatable {
        let pid: Int
        let kind: String

        init?(_ sample: TmuxPaneForeground.Sample) {
            guard let pid = sample.foregroundPID,
                case .known(let kind) = HerdrCoreAgentRule.program(
                    arguments: sample.pane.foregroundArguments ?? [], name: sample.pane.command)
            else { return nil }
            self.pid = pid
            self.kind = kind
        }
    }

    private let paneID: String
    private weak var projection: TmuxConsoleProjection?
    private let clock: BlockedCardClock
    /// The tmux server instance this Pane belongs to: `%0` means another Pane on
    /// any other server.
    private let corePin: TerminalCorePin
    /// What held the foreground as the last screen read ran.
    private var screenHolder: Holder?
    /// That read saw another process than the read before it, so a dialog it found
    /// may not be the one the user is answering. The next read settles it.
    private var holderChangedAtLastRead = false

    init(paneID: String, projection: TmuxConsoleProjection, clock: BlockedCardClock) {
        self.paneID = paneID
        self.projection = projection
        self.clock = clock
        corePin = TerminalCorePin(joined: projection.inventoryCore)
    }

    var blockedScreen: BlockedScreenIO {
        var screen = BlockedScreenIO.unavailable
        screen.readScreen = { [weak self] in
            guard let self else { throw TransportError.cancelled }
            return try await self.readScreen()
        }
        screen.typeWhileShowing = { [weak self] typing, stillShows in
            guard let self else { throw TransportError.cancelled }
            switch typing {
            case .keys(let keys): try await self.press(keys, heldSinceScreenRead: true, whileShowing: stillShows)
            case .paste(let text): try await self.paste(text, heldSinceScreenRead: true, whileShowing: stillShows)
            }
        }
        screen.recordAnswer = { [weak self] declines in
            guard let self else { return }
            await self.recordAnswer(declines: declines)
        }
        return screen
    }

    // MARK: Reading

    /// Reads `capture-pane -e -p` on the Host's socket alongside the Pane's
    /// foreground process, without opening an Attach.
    func readScreen() async throws -> ANSIScreen {
        guard let projection else { throw TransportError.cancelled }
        guard projection.admits(corePin) else { throw TransportError.tmuxServerGone }
        let paneID = paneID
        let corePin = corePin
        let (foreground, screen) = try await AsyncDeadline.run(for: TmuxComposerSend.stepTimeout, sleep: clock.sleep) {
            async let foregroundRead = projection.readPaneForeground(paneID)
            async let screenRead = projection.capturePaneScreen(paneID, keepingTo: corePin)
            return try await (foregroundRead, screenRead)
        }
        let holder: Holder?
        if case .live(let sample) = foreground, corePin.admits(sample.instance.id) {
            holder = Holder(sample)
        } else {
            holder = nil
        }
        holderChangedAtLastRead = screenHolder != nil && holder != screenHolder
        screenHolder = holder
        return screen
    }

    // MARK: Typing

    func press(
        _ keys: [String], heldSinceScreenRead: Bool = false,
        whileShowing stillShows: (@Sendable (ANSIScreen) -> Bool)? = nil
    ) async throws {
        var steps: [TmuxInput] = []
        for key in keys {
            guard let encoded = Self.inputs(forKeyNamed: key) else {
                throw Refusal(message: Self.unknownKey)
            }
            steps.append(contentsOf: encoded)
        }
        let attach = try await attachToType(heldSinceScreenRead: heldSinceScreenRead, stillShows: stillShows)
        do {
            for step in steps {
                if case .key(let key) = step, key.isExtended {
                    switch await attach.tmuxSend.canSendKey(key, clock.sleep) {
                    case true: break
                    case false: throw Refusal(message: Self.unknownKey)
                    case nil: throw Refusal(message: Self.noAnswer)
                    }
                }
            }
            var anyLeft = false
            for step in steps {
                let outcome: TmuxSendWriteOutcome
                switch step {
                case .text(let text):
                    outcome = await attach.tmuxSend.sendText(text, clock.sleep)
                case .key(let key):
                    outcome = await attach.tmuxSend.sendKey(key.name, clock.sleep)
                case .paste(let text):
                    outcome = await attach.tmuxSend.paste(text, clock.sleep)
                }
                switch outcome {
                case .left:
                    anyLeft = true
                case .notLeft:
                    if anyLeft {
                        throw TransportError.sshUnreachable(detail: Self.noAnswer)
                    }
                    throw Refusal(message: Self.noAnswer)
                case .unknown:
                    throw TransportError.sshUnreachable(detail: Self.noAnswer)
                }
            }
        } catch {
            await attach.close()
            throw error
        }
        await attach.close()
    }

    func paste(
        _ text: String, heldSinceScreenRead: Bool = false,
        whileShowing stillShows: (@Sendable (ANSIScreen) -> Bool)? = nil
    ) async throws {
        let attach = try await attachToType(heldSinceScreenRead: heldSinceScreenRead, stillShows: stillShows)
        do {
            switch await attach.tmuxSend.paste(text, clock.sleep) {
            case .left:
                break
            case .notLeft:
                throw Refusal(message: Self.noAnswer)
            case .unknown:
                throw TransportError.sshUnreachable(detail: Self.noAnswer)
            }
        } catch {
            await attach.close()
            throw error
        }
        await attach.close()
    }

    private func recordAnswer(declines: Bool) async {
        guard let projection, projection.admits(corePin) else { return }
        _ = await projection.recordHeelerAnswer(declines: declines, on: paneID)
    }

    private func attachToType(
        heldSinceScreenRead: Bool, stillShows: (@Sendable (ANSIScreen) -> Bool)?
    ) async throws -> TmuxChatAttach {
        let projection = try liveProjection()
        let holder = try await checkHolder(in: projection, heldSinceScreenRead: heldSinceScreenRead)
        let attach = try await openAttach(in: projection)
        do {
            let holderNow = try await checkHolder(in: projection, heldSinceScreenRead: heldSinceScreenRead)
            guard holderNow == holder else { throw Refusal(message: Self.holderChangedWhileOpening) }
            if let stillShows {
                let paneID = paneID
                let corePin = corePin
                let currentScreen: ANSIScreen
                do {
                    currentScreen = try await AsyncDeadline.run(
                        for: TmuxComposerSend.stepTimeout, sleep: clock.sleep
                    ) {
                        try await projection.capturePaneScreen(paneID, keepingTo: corePin)
                    }
                } catch TransportError.tmuxServerGone {
                    throw Refusal(message: Self.serverGone)
                } catch TransportError.tmuxPaneGone {
                    throw Refusal(message: Self.agentLeft)
                } catch {
                    throw Refusal(message: Self.noAnswer)
                }
                guard stillShows(currentScreen) else {
                    throw Refusal(message: BlockedCardStore.changedMessage)
                }
            }
        } catch {
            await attach.close()
            throw error
        }
        return attach
    }

    private func openAttach(in projection: TmuxConsoleProjection) async throws -> TmuxChatAttach {
        let paneID = paneID
        let corePin = corePin
        do {
            return try await AsyncDeadline.run(for: TmuxComposerSend.liveAttachTimeout, sleep: clock.sleep) {
                try await projection.openChatAttach(at: paneID, keepingTo: corePin)
            }
        } catch TransportError.tmuxServerGone {
            throw Refusal(message: Self.serverGone)
        } catch TransportError.tmuxPaneGone {
            throw Refusal(message: Self.agentLeft)
        } catch {
            if !projection.admits(corePin) {
                throw Refusal(message: Self.serverGone)
            }
            throw Refusal(message: Self.noAnswer)
        }
    }

    private func liveProjection() throws -> TmuxConsoleProjection {
        guard let projection else { throw TransportError.cancelled }
        guard projection.admits(corePin) else { throw Refusal(message: Self.serverGone) }
        return projection
    }

    private func checkHolder(
        in projection: TmuxConsoleProjection, heldSinceScreenRead: Bool
    ) async throws -> Holder {
        let paneID = paneID
        let foreground: TmuxPaneForeground
        do {
            foreground = try await AsyncDeadline.run(for: TmuxComposerSend.stepTimeout, sleep: clock.sleep) {
                try await projection.readPaneForeground(paneID)
            }
        } catch {
            throw Refusal(message: Self.noAnswer)
        }
        switch foreground {
        case .serverNotRunning:
            throw Refusal(message: projection.admits(corePin) ? Self.agentLeft : Self.serverGone)
        case .paneGone(let instance), .dead(let instance):
            throw Refusal(message: corePin.admits(instance.id) ? Self.agentLeft : Self.serverGone)
        case .live(let sample):
            guard corePin.admits(sample.instance.id) else {
                throw Refusal(message: Self.serverGone)
            }
            guard case .known = HerdrCoreAgentRule.program(
                arguments: sample.pane.foregroundArguments ?? [], name: sample.pane.command)
            else {
                throw Refusal(message: Self.agentLeft)
            }
            guard let holder = Holder(sample) else {
                throw Refusal(message: Self.notSampledYet)
            }
            if heldSinceScreenRead, holderChangedAtLastRead || holder != screenHolder {
                throw Refusal(message: Self.holderChanged)
            }
            return holder
        }
    }

    // MARK: Keys

    /// Turns one herdr key name into the `TmuxInput` steps `TmuxPaneAttach` sends.
    /// Encoding under kitty's disambiguate flag preserves modifiers on extended keys
    /// (`shift+enter`, `ctrl+0`) while keeping printable characters as `.text`.
    static func inputs(forKeyNamed name: String) -> [TmuxInput]? {
        var modes = TerminalModeTracker()
        modes.receive(Data("\u{1B}[>1u".utf8))
        guard let bytes = HerdrCoreChatTyping.bytes(forKeyNamed: name, modes: modes) else {
            return nil
        }
        let inputs = TmuxKeyReader.read(bytes)
        return inputs.isEmpty ? nil : inputs
    }

    // MARK: What Chat says

    private static let serverGone = TransportError.tmuxServerGone.presentation.message
    private static let agentLeft = String(localized: "The Agent no longer holds this terminal, so Heeler pressed nothing.")
    private static let holderChanged =
        String(localized: "Another process took over the terminal after Heeler read the screen, so Heeler pressed nothing.")
    private static let holderChangedWhileOpening =
        String(localized: "Another process took over the terminal as Heeler reached it, so Heeler pressed nothing.")
    private static let notSampledYet = String(localized: "The Agent is still starting, so Heeler pressed nothing. Try again in a moment.")
    private static let noAnswer = String(localized: "The Host did not answer, so Heeler pressed nothing. Check the connection and retry.")
    private static let unknownKey = String(localized: "Heeler can't press this key in this terminal, so it pressed nothing.")
}
