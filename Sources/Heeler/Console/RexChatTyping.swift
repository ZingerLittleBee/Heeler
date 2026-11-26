import Foundation

/// The Agent holding a Rex block's foreground, read afresh: its process id and
/// kind. Rex names no start time, so a process that took the same id under the
/// same program reads as the same holder (ADR 0055).
struct RexAgentHolder: Equatable, Sendable {
    let pid: Int
    let kind: String
    /// The foreground as `process` answered, for the status and the shell. Its
    /// directory and the rest do not make another holder.
    let process: RexInventoryWire.Process

    static func == (lhs: RexAgentHolder, rhs: RexAgentHolder) -> Bool {
        lhs.pid == rhs.pid && lhs.kind == rhs.kind
    }

    enum Read: Equatable, Sendable {
        case holds(RexAgentHolder)
        /// The block is open and no known Agent leads its foreground.
        case agentLeft(RexInventoryWire.Process)
        /// The block closed.
        case ended
        /// A known Agent whose process id Rex has yet to name.
        case notSampledYet
    }

    /// Throws what the read throws, but for a block that closed.
    static func read(on requests: RexBlockRequests) async throws -> Read {
        let answer: JSONValue
        do {
            answer = try await requests.read(.process)
        } catch RexControlError.server(let failure) where failure.kind == .notFound {
            return .ended
        }
        let process = RexInventoryWire.process(answer)
        var details = RexTerminalDetails()
        details.noteForeground(process)
        guard let kind = RexAgentRule.agentKind(in: details) else { return .agentLeft(process) }
        guard let pid = process.processID else { return .notSampledYet }
        return .holds(RexAgentHolder(pid: pid, kind: kind, process: process))
    }
}

/// How Chat reads and types into a Rex terminal (ADR 0055): on the Host's
/// control link, one request at a time to the block, in the lane an open
/// terminal view's input to it shares (`RexBlockRequests`). It opens no data
/// link, never asks for a size, and never takes or gives back the block.
///
/// A key or a paste goes only while the Agent that held the foreground at the
/// check before it still does: read afresh before anything is encoded, and
/// again once the block's lane is held, so nothing of an open terminal's input
/// comes between that read and the typing. A Blocked Card's answer goes only
/// while the screen it answers still shows, read in the lane too. A screen
/// Rex's answer does not show with certainty is no screen, and nothing is
/// recorded on the Host.
@MainActor
final class RexChatTyping: CheckedChatTyping {
    typealias Refusal = HerdrCoreChatTyping.Refusal

    private let address: RexPaneAddress
    private weak var projection: RexConsoleProjection?
    /// The server this terminal belongs to.
    private let corePin: TerminalCorePin
    /// What held the foreground as the last screen read began.
    private var screenHolder: RexAgentHolder?
    /// That read saw another process than the read before it, so a dialog it
    /// found may not be the one the user is answering. The next read settles it.
    private var holderChangedAtLastRead = false

    init(address: RexPaneAddress, projection: RexConsoleProjection) {
        self.address = address
        self.projection = projection
        corePin = TerminalCorePin(joined: projection.inventoryCore)
    }

    /// A Blocked Card's way to the Agent: its keys reach only the process whose
    /// screen it answered, over that screen. Nothing is written on the Host for
    /// its answers, so `recordAnswer` stays nil.
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
        return screen
    }

    // MARK: Reading

    /// The screen now, colors kept, with the holder read just before it.
    /// A screen Rex's answer does not show with certainty throws
    /// `TransportError.rexScreenUnreadable`, which names Rex and no version
    /// to check.
    func readScreen() async throws -> ANSIScreen {
        guard let projection else { throw TransportError.cancelled }
        do {
            let requests = try await projection.blockRequests(at: address, keepingTo: corePin)
            let holder: RexAgentHolder?
            if case .holds(let current) = try await RexAgentHolder.read(on: requests) {
                holder = current
            } else {
                holder = nil
            }
            let screen = try await RexChatScreen.read(on: requests).screen
            holderChangedAtLastRead = screenHolder != nil && holder != screenHolder
            screenHolder = holder
            return screen
        } catch is RexScreenProblem {
            throw TransportError.rexScreenUnreadable
        } catch let error as RexControlError {
            throw TransportError(rexControl: error)
        }
    }

    // MARK: Typing

    /// Keys named as for `agent.send_keys`, in one write: OpenCode's two Escs
    /// have to arrive together. They are encoded for the program's modes and
    /// kitty keyboard flags as Rex reports them.
    func press(
        _ keys: [String], heldSinceScreenRead: Bool = false,
        whileShowing stillShows: (@Sendable (ANSIScreen) -> Bool)? = nil
    ) async throws {
        let (requests, holder) = try await checkedRequests(heldSinceScreenRead: heldSinceScreenRead)
        let modes: TerminalModeTracker
        do {
            let flags = try await RexChatScreen.kittyKeyboardFlags(on: requests)
            modes = try RexChatScreen.modes(from: await requests.read(.modes), kittyKeyboardFlags: flags)
        } catch {
            throw Refusal(message: Self.saying(error))
        }
        var bytes = Data()
        for key in keys {
            guard let encoded = HerdrCoreChatTyping.bytes(forKeyNamed: key, modes: modes) else {
                throw Refusal(message: Self.unknownKey)
            }
            bytes.append(encoded)
        }
        guard !bytes.isEmpty, let text = String(validating: bytes, as: UTF8.self) else {
            throw Refusal(message: Self.unknownKey)
        }
        try await send([.text(text)], on: requests, holder: holder, stillShows: stillShows)
    }

    /// Text as one paste, framed by the server as the program's modes say. A
    /// program with bracketed paste off would take each line break as Enter,
    /// so text with one is refused then, as read in the lane.
    func paste(
        _ text: String, heldSinceScreenRead: Bool = false,
        whileShowing stillShows: (@Sendable (ANSIScreen) -> Bool)? = nil
    ) async throws {
        let (requests, holder) = try await checkedRequests(heldSinceScreenRead: heldSinceScreenRead)
        guard requests.fitsOnePaste(text) else { throw Refusal(message: Self.pasteTooLarge) }
        try await send(
            [.paste(text)], on: requests, holder: holder, needsBracketedPaste: text.contains(where: \.isNewline),
            stillShows: stillShows)
    }

    /// The block's requests, with the Agent that holds it now.
    private func checkedRequests(heldSinceScreenRead: Bool) async throws -> (RexBlockRequests, RexAgentHolder) {
        guard let projection else { throw TransportError.cancelled }
        let requests: RexBlockRequests
        do {
            requests = try await projection.blockRequests(at: address, keepingTo: corePin)
        } catch {
            throw Refusal(message: Self.saying(error))
        }
        let holder = try await checkHolder(on: requests, heldSinceScreenRead: heldSinceScreenRead)
        return (requests, holder)
    }

    /// Sends `pieces` in the block's lane once the same Agent still holds the
    /// foreground, with bracketed paste on when `needsBracketedPaste`, and,
    /// for a Blocked Card, its screen still shows.
    private func send(
        _ pieces: [RexTerminalInputPiece], on requests: RexBlockRequests, holder: RexAgentHolder,
        needsBracketedPaste: Bool = false, stillShows: (@Sendable (ANSIScreen) -> Bool)?
    ) async throws {
        let sending = try await requests.send(pieces) { @MainActor in
            let now: RexAgentHolder.Read
            do {
                now = try await RexAgentHolder.read(on: requests)
            } catch {
                throw Refusal(message: Self.saying(error))
            }
            switch now {
            case .holds(let current) where current == holder: break
            case .holds, .agentLeft, .notSampledYet: throw Refusal(message: Self.holderChangedWhileOpening)
            case .ended: throw Refusal(message: Self.agentLeft)
            }
            if needsBracketedPaste {
                let modes: TerminalModeTracker
                do {
                    modes = try RexChatScreen.modes(from: await requests.read(.modes), kittyKeyboardFlags: 0)
                } catch {
                    throw Refusal(message: Self.saying(error))
                }
                guard modes.usesBracketedPaste else { throw Refusal(message: Self.linesWouldSubmit) }
            }
            guard let stillShows else { return }
            let screen: ANSIScreen
            do {
                screen = try await RexChatScreen.read(on: requests).screen
            } catch {
                throw Refusal(message: Self.saying(error))
            }
            guard stillShows(screen) else { throw Refusal(message: BlockedCardStore.changedMessage) }
        }
        switch sending {
        case .sent:
            return
        case .notSent(let failure):
            throw Refusal(message: failure?.kind == .notFound ? Self.agentLeft : Self.noAnswer)
        case .unknown:
            // The bytes may have reached the program: never "pressed nothing".
            throw TransportError.coreMutationOutcomeUnknown
        }
    }

    private func checkHolder(on requests: RexBlockRequests, heldSinceScreenRead: Bool) async throws -> RexAgentHolder {
        let read: RexAgentHolder.Read
        do {
            read = try await RexAgentHolder.read(on: requests)
        } catch {
            throw Refusal(message: Self.saying(error))
        }
        switch read {
        case .holds(let holder):
            if heldSinceScreenRead, holderChangedAtLastRead || holder != screenHolder {
                throw Refusal(message: Self.holderChanged)
            }
            return holder
        case .agentLeft, .ended:
            throw Refusal(message: Self.agentLeft)
        case .notSampledYet:
            throw Refusal(message: Self.notSampledYet)
        }
    }

    /// What a read that failed says: another server than the terminal's, a
    /// block that closed, a screen that shows nothing certain, a modes answer
    /// this build cannot read, or no answer to go on.
    private static func saying(_ error: any Error) -> String {
        switch error {
        case let refusal as Refusal: refusal.message
        case TransportError.rexServerGone: serverGone
        case RexControlError.server(let failure) where failure.kind == .notFound: agentLeft
        case is RexScreenProblem: unreadable
        case TransportError.rexAnswerUnreadable(let detail):
            TransportError.rexAnswerUnreadable(detail).presentation.message
        default: noAnswer
        }
    }

    // MARK: What Chat says

    private static let serverGone = TransportError.rexServerGone.presentation.message
    private static let unreadable = TransportError.rexScreenUnreadable.presentation.message
    private static let agentLeft = String(localized: "The Agent no longer holds this terminal, so Heeler pressed nothing.")
    private static let holderChanged =
        String(localized: "Another process took over the terminal after Heeler read the screen, so Heeler pressed nothing.")
    private static let holderChangedWhileOpening =
        String(localized: "Another process took over the terminal as Heeler reached it, so Heeler pressed nothing.")
    private static let notSampledYet = String(localized: "The Agent is still starting, so Heeler pressed nothing. Try again in a moment.")
    private static let noAnswer = String(localized: "The Host did not answer, so Heeler pressed nothing. Check the connection and retry.")
    private static let unknownKey = String(localized: "Heeler can't press this key in this terminal, so it pressed nothing.")
    private static let pasteTooLarge =
        String(localized: "This paste is too large to send to a Rex terminal in one piece. Paste less at a time.")
    private static let linesWouldSubmit = ComposerRefusal.programNotAcceptingPaste.message
}
