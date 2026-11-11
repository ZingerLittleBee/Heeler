import Foundation

/// What one Attach makes of its control client's events (ADR 0043): the
/// bytes for a terminal that shows only its Pane, and the commands that get
/// them. Pure: the Attach sends each command with its tag and hands back
/// every event, the replies to those tags among them.
///
/// tmux prints a command's reply where it ran the command among the Pane's
/// output, so a paint's captures hold all output before its first reply and
/// none after its last. Output in between is in some captures and not in
/// others, and the paint is asked for again. Output from the window's other
/// Panes is dropped.
struct TmuxPaneFeed: Sendable {
    enum Action: Equatable, Sendable {
        case send(TmuxControlCommand, tag: UInt64)
        /// Bytes for the terminal, in order.
        case write(Data)
        /// The Attach is over; nothing comes after.
        case end(End)
    }

    enum End: Equatable, Sendable {
        /// The Pane is gone, or Heeler closed its window once no session of the
        /// user's held it any more.
        case paneGone
        /// Heeler's session no longer holds the Pane: it ended, its client was
        /// moved, or the Pane went to another window.
        case sessionLeft
        /// tmux could not say what the Pane looks like, three times over.
        case paintFailed
    }

    enum BracketedPaste: Equatable, Sendable {
        case enabled
        case disabled
        /// tmux before 3.7 reports no `bracket_paste_flag`, and the Pane's
        /// `%output` on this Attach has not turned DECSET 2004 off.
        case unreportedAndNotTurnedOff
    }

    private enum Purpose: Equatable, Sendable {
        case paint(generation: UInt64, step: TmuxPanePaint.Step)
        case resume
        case check
        case closeWindow
    }

    private struct Paint: Sendable {
        var generation: UInt64
        var steps: [TmuxPanePaint.Step]
        var replies: [TmuxPanePaint.Step: TmuxControlReply] = [:]
        /// Output of the Pane came after the paint's first reply.
        var disturbed = false
    }

    /// Paints asked for before one that tmux disturbed is written anyway.
    static let paintAttempts = 3

    private let pane: String
    private let window: String
    private let session: String
    private var viewRows: Int
    private let wantsHistory: Bool
    private var nextTag: UInt64 = 1
    private var purposes: [UInt64: Purpose] = [:]
    private var generation: UInt64 = 0
    private var paint: Paint?
    private var attempts = 0
    private var painted = false
    private var checking = false
    /// Something changed while a check was out: it may not have seen it.
    private var checkAgain = false
    /// A paint stopped at a failed reply; the check says whether to try again.
    private var paintWaitsOnCheck = false
    private var paintBracketedPaste: Bool?
    private var outputModes = TerminalModeTracker()
    private var ended = false

    /// `includingHistory` when the terminal has no history of the Pane yet.
    init(pane: String, window: String, session: String, viewRows: Int, includingHistory: Bool) {
        self.pane = pane
        self.window = window
        self.session = session
        self.viewRows = viewRows
        wantsHistory = includingHistory
    }

    /// Asks where the Pane's window is linked: a row per session, saying
    /// whether the session is one of Heeler's.
    static func checkCommand(pane: String) -> TmuxControlCommand {
        TmuxControlCommand([
            "list-panes", "-a", "-F", "#{session_id} #{window_id} #{?@heeler-attach,1,0}", "-f",
            "#{==:#{pane_id},\(pane)}",
        ])
    }

    /// The first paint's commands.
    mutating func start() -> [Action] {
        beginPaint()
    }

    var bracketedPaste: BracketedPaste {
        switch outputModes.bracketedPasteSetting ?? paintBracketedPaste {
        case true: .enabled
        case false: .disabled
        case nil: .unreportedAndNotTurnedOff
        }
    }

    mutating func updateViewRows(_ rows: Int) {
        guard rows > 0 else { return }
        viewRows = rows
    }

    /// Paints the Pane again without repeating its history, as when its size
    /// or the view's changed.
    mutating func repaint() -> [Action] {
        guard !ended, painted || paint != nil else { return [] }
        attempts = 0
        return beginPaint()
    }

    mutating func receive(_ event: TmuxControlClient.Event) -> [Action] {
        guard !ended else { return [] }
        switch event {
        case .output(let from, let bytes):
            guard from == pane else { return [] }
            outputModes.receive(bytes)
            guard let paint else { return painted ? [.write(bytes)] : [] }
            if paint.replies[.modes] != nil { self.paint?.disturbed = true }
            return []
        case .replied(let tag, let reply):
            guard let purpose = purposes.removeValue(forKey: tag) else { return [] }
            return replied(purpose, reply)
        case .notification(let notification):
            return notified(notification)
        case .ended:
            return []
        }
    }

    // MARK: Paint

    private mutating func beginPaint() -> [Action] {
        generation += 1
        attempts += 1
        let steps = TmuxPanePaint.steps(includingHistory: wantsHistory && !painted)
        paint = Paint(generation: generation, steps: steps)
        return steps.map { send(TmuxPanePaint.command($0, pane: pane), for: .paint(generation: generation, step: $0)) }
    }

    private mutating func replied(_ purpose: Purpose, _ reply: TmuxControlReply) -> [Action] {
        switch purpose {
        case .paint(let generation, let step):
            guard var paint, paint.generation == generation else { return [] }
            guard reply.succeeded else {
                // The Pane may be gone; whatever the check finds, this paint is.
                self.paint = nil
                paintWaitsOnCheck = true
                return check()
            }
            if step == .modes, let flag = reply.lines.first.flatMap(TmuxPaneModes.init)?.bracketedPaste {
                paintBracketedPaste = flag
                outputModes = TerminalModeTracker()
            }
            paint.replies[step] = reply
            self.paint = paint
            guard paint.replies.count == paint.steps.count else { return [] }
            return finishPaint(paint)
        case .resume:
            return []
        case .check:
            checking = false
            return checked(reply)
        case .closeWindow:
            return end(.paneGone)
        }
    }

    private mutating func finishPaint(_ paint: Paint) -> [Action] {
        self.paint = nil
        guard let modes = paint.replies[.modes]?.lines.first.flatMap(TmuxPaneModes.init) else {
            return attempts < Self.paintAttempts ? beginPaint() : end(.paintFailed)
        }
        if paint.disturbed, attempts < Self.paintAttempts {
            return beginPaint()
        }
        attempts = 0
        painted = true
        let bytes = TmuxPanePaint.bytes(
            modes: modes,
            history: paint.replies[.history]?.lines,
            screen: paint.replies[.screen]?.lines ?? [],
            normalScreen: paint.replies[.normalScreen]?.lines ?? [],
            viewRows: viewRows)
        return [.write(bytes)]
    }

    // MARK: Notifications

    private mutating func notified(_ notification: TmuxControlNotification) -> [Action] {
        switch notification {
        case .paused(let paused) where paused == pane:
            // A paint already asked for captured nothing of what the pause dropped.
            let resume = send(TmuxControlCommand(["refresh-client", "-A", "\(pane):continue"]), for: .resume)
            attempts = 0
            return [resume] + beginPaint()
        case .sessionsChanged:
            return check()
        case .windowClosed(let closed), .unlinkedWindowClosed(let closed), .layoutChanged(let closed):
            return closed == window ? check() : []
        case .sessionChanged(let now) where now != session:
            return end(.sessionLeft)
        default:
            return []
        }
    }

    // MARK: The window's links

    private mutating func check() -> [Action] {
        guard !checking else {
            checkAgain = true
            return []
        }
        checking = true
        checkAgain = false
        return [send(Self.checkCommand(pane: pane), for: .check)]
    }

    private mutating func checked(_ reply: TmuxControlReply) -> [Action] {
        let links = reply.lines.map { String(decoding: $0, as: UTF8.self).split(separator: " ").map(String.init) }
            .filter { $0.count == 3 }
        guard reply.succeeded, !links.isEmpty else { return end(.paneGone) }
        guard links.contains(where: { $0[0] == session && $0[1] == window }) else { return end(.sessionLeft) }
        if links.allSatisfy({ $0[2] == "1" }) {
            return [send(TmuxControlCommand(["kill-window", "-t", window]), for: .closeWindow)]
        }
        var actions: [Action] = []
        if paintWaitsOnCheck {
            paintWaitsOnCheck = false
            actions += attempts < Self.paintAttempts ? beginPaint() : end(.paintFailed)
            if ended { return actions }
        }
        if checkAgain { actions += check() }
        return actions
    }

    // MARK: Plumbing

    private mutating func send(_ command: TmuxControlCommand, for purpose: Purpose) -> Action {
        let tag = nextTag
        nextTag += 1
        purposes[tag] = purpose
        return .send(command, tag: tag)
    }

    private mutating func end(_ end: End) -> [Action] {
        ended = true
        return [.end(end)]
    }
}
