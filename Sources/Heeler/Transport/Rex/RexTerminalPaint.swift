import Foundation

/// What a Rex terminal's view is told to do, in order.
enum RexTerminalInstruction: Sendable, Equatable {
    /// The server's grid for the block is now this, with its cell size and
    /// owner. The first comes before the first paint.
    case grid(RexTerminalGrid)
    /// Reset the terminal and paint these bytes: a full reset (RIS) followed
    /// by the server's VT redraw of screen and scrollback. `exact` is false
    /// for a best-effort paint taken while the program kept writing; a later
    /// paint replaces it once the stream goes quiet.
    case paint(Data, exact: Bool)
    /// The title a program set most recently, or empty if none did. The
    /// redraw does not carry it, so it follows each paint.
    case title(String)
    /// Program output, in order.
    case feed(Data)
    /// The terminal's default colors on the server.
    case theme(RexTerminalTheme)
    /// The program exited. On macOS, Rex 0.1.0-preview.14 reported 0 whatever
    /// the program's real status, because programs run under `login`.
    case exited(code: Int?)
    /// The stream is starting over. What the view shows may be out of date
    /// until the next paint, which replaces it.
    case restarting
    /// Nothing follows.
    case ended(RexTerminalEnd)
}

/// Why a terminal's stream ended for good.
enum RexTerminalEnd: Sendable, Equatable {
    /// The block closed, or no longer exists.
    case blockClosed
    /// This side closed the stream.
    case closedHere
    /// The redraw could not be read, so nothing could be painted.
    case paintFailed
    /// The redraw grew past `redrawByteLimit`: the block's history is too
    /// long to paint, and every later attempt would read it whole again.
    case redrawTooLarge
    /// The server refused a ticket because the control link is not attached
    /// to the block's session.
    case notAttached
    /// No stream could be opened or kept, after the last way it ended.
    case streamUnavailable(RexDataEnding?)
    /// The connection the stream rode is gone: its SSH connection closed or
    /// was replaced, so no channel or ticket can come from it again. Only a
    /// new attach, on the next connection, goes on.
    case connectionLost
}

/// One read a paint asks of the control link, against the block's terminal.
enum RexTerminalRead: Sendable, Equatable {
    /// `modes`: whether autowrap is on decides the redraw's `unwrap`.
    case modes
    /// `format` as `vt`, with every extra the lab used, paged.
    case format(unwrap: Bool)
    /// The next page of a redraw: `offset` counts the UTF-8 bytes read so far.
    case blobRead(id: Int, offset: Int)
    /// `title`, which the redraw does not carry.
    case title
}

/// What a read came back with.
enum RexTerminalAnswer: Sendable, Equatable {
    /// Whether autowrap (DECAWM, `?7`) is on; nil when the answer did not say.
    case modes(wraparound: Bool?)
    /// One page of the redraw as UTF-8, and the result to read the next page
    /// from, or nil when this page ends it.
    case page(Data, next: Int?)
    case title(String)
    /// The read failed, or its answer could not be read.
    case failed
}

/// The first paint of a Rex terminal, and every repaint after it, as a pure
/// state machine (ADR 0051). It reads the stream's items in order, asks for
/// reads and waits as effects, and hears back their outcomes; it never reads
/// a clock. What it emits is the ordered instructions for one terminal view.
///
/// A paint reads `modes`, then asks for the `vt` redraw and the title
/// together. Rex 0.1.0-preview.14 (API revision 12) took the redraw's state
/// somewhere between the request leaving and its answer arriving, so a paint
/// is exact only when no program output and no resize arrived from the
/// request until the whole answer, pages and title included, plus the
/// settle time. The program's bytes after the redraw's first answer are kept
/// and fed after the paint.
///
/// - First paint: begins at the stream's first message, the resize after
///   the snapshot. Output before it is not shown. An attempt that output
///   disturbed is tried again after the stream pauses, up to `attempts`;
///   the last is painted best effort and marked dirty.
/// - Dirty: once the stream has been quiet for `quietRepaint`, one attempt is
///   made; it paints only if exact, which clears the mark. Otherwise the
///   wait starts over, twice as long after each such attempt up to
///   `quietRepaintLimit`, since each one reads the whole redraw again.
/// - Repaints: when the program leaves the alternate screen it was painted
///   on (the redraw carries no primary screen behind it), and when the
///   server's grid changes, a paint runs as the first one does. Output keeps
///   reaching the view meanwhile, and what came after the cut is fed again
///   after the repaint.
/// - Memory: the output kept for after a paint is bounded by
///   `replayByteLimit`. Past it, what was kept is dropped and keeping starts
///   over from there. Such an attempt is never exact; on the last attempt of
///   a first paint it is painted anyway, with that gap until the dirty mark's
///   quiet repaint, and a repaint keeps showing the live output instead.
///   The redraw, which pages the block's whole history, is bounded by
///   `redrawByteLimit`: one that grows past it ends the stream with
///   `.redrawTooLarge` rather than be read whole again on every repaint. So
///   one paint holds at most the redraw, its copy behind the reset, the kept
///   output, and the page being read.
struct RexTerminalPaint: Sendable {
    struct Parameters: Sendable, Equatable {
        /// How long after the whole answer no output may arrive for an exact
        /// paint. The lab passed 59 of 59 handoffs with 30 to 60 ms.
        var settle: Duration = .milliseconds(60)
        /// Between attempts, the stream must pause this long ...
        var retryQuiet: Duration = .milliseconds(50)
        /// ... or this long must pass, before the next attempt.
        var retryWaitLimit: Duration = .milliseconds(200)
        /// A dirty paint is redone once the stream has been quiet this long.
        var quietRepaint: Duration = .milliseconds(250)
        /// The longest quiet asked for: each quiet repaint that output
        /// disturbs doubles the next one's, up to this.
        var quietRepaintLimit: Duration = .seconds(30)
        /// Attempts at a paint before one is shown best effort.
        var attempts = 3
        /// The largest page asked for, as the server measures it (encoded as
        /// JSON). Rex lowers anything larger to this.
        var pageBytes = 983_040
        /// Program output kept for after a paint.
        var replayByteLimit = 4 * 1024 * 1024
        /// The longest redraw painted: room for a long history, while one
        /// paint stays within what a phone can hold beside its other views.
        var redrawByteLimit = 32 * 1024 * 1024
        /// Reads that may fail in a row before a first paint gives up.
        var failedReadLimit = 5
        /// The wait after a failed read before the next try.
        var failedReadDelay: Duration = .seconds(2)

        init() {}
    }

    enum Effect: Sendable, Equatable {
        /// Send this read; hand its answer back with `answered(_:id:)`.
        case read(RexTerminalRead, id: UInt64)
        /// Wait this long, then call `waited(id:)`.
        case wait(Duration, id: UInt64)
        case emit(RexTerminalInstruction)
    }

    /// RIS: the redraw never clears what was there before it.
    static let reset = Data([0x1B, 0x63])

    /// Room left in a control message for the envelope around a page.
    static let pageEnvelopeBytes = 4096

    /// The page size to ask for under a control link's message limit.
    static func pageBytes(asked: Int, messageLimit: Int) -> Int {
        max(1024, min(asked, messageLimit - pageEnvelopeBytes))
    }

    private enum Run: Equatable {
        /// Up to `attempts`; the last paints best effort.
        case full
        /// One attempt that paints only when exact.
        case quiet
    }

    private struct Attempt {
        let run: Run
        let number: Int
        /// The reads in flight.
        var modesID: UInt64?
        var pageID: UInt64?
        var titleID: UInt64?
        var redraw = Data()
        var redrawDone = false
        var title: String?
        var titleDone = false
        /// The redraw was asked for.
        var asked = false
        /// The redraw's first answer came: output from here on is kept.
        var cut = false
        /// Output, a grid change, or a pause in the stream came after the
        /// redraw was asked for.
        var disturbed = false
        /// Kept output passed the bound and was dropped.
        var overflowed = false
        var replay = Data()
        var settling = false

        init(run: Run, number: Int, modesID: UInt64) {
            self.run = run
            self.number = number
            self.modesID = modesID
        }
    }

    private enum Timer {
        case settle
        case retryPause(activity: UInt64, waited: Duration, next: Int)
        case quietWatch(activity: UInt64)
        case readRetry(number: Int)
    }

    let parameters: Parameters

    private var nextID: UInt64 = 0
    private var attempt: Attempt?
    private var timer: (id: UInt64, kind: Timer)?
    /// Counts what makes the stream not quiet: output, grid changes, pauses.
    private var activity: UInt64 = 0
    private var isPaused = false
    private var started = false
    private(set) var isPainted = false
    private(set) var isDirty = false
    private var grid: RexTerminalGrid?
    private var modes = TerminalModeTracker()
    private var paintedOnAlternateScreen = false
    private var repaintPending = false
    /// Quiet repaints that output disturbed since the last exact paint.
    private var quietMisses = 0
    /// Exit notices that came before the first paint.
    private var held: [RexTerminalInstruction] = []
    /// The terminal's default colors as the stream last gave them; nil
    /// while no stream has given any. Each paint applies them after its
    /// reset, since the redraw carries no OSC 10 to 12 colors.
    private var theme: RexTerminalTheme?
    private var failedReads = 0
    private(set) var hasEnded = false
    private(set) var paintCount = 0
    private(set) var exactPaintCount = 0
    /// Output dropped from what was kept for after a paint.
    private(set) var droppedReplayBytes: UInt64 = 0

    init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// Whether a paint is being read: the stream must be read promptly
    /// meanwhile, or the exactness test means nothing.
    var isReading: Bool { attempt != nil }

    // MARK: Inputs

    /// A new stream began, after a new HELLO: nothing of the last one counts.
    /// The view keeps what it shows until this stream's first paint.
    mutating func beginStream() -> [Effect] {
        attempt = nil
        timer = nil
        isPaused = false
        started = false
        isPainted = false
        isDirty = false
        grid = nil
        modes = TerminalModeTracker()
        paintedOnAlternateScreen = false
        repaintPending = false
        quietMisses = 0
        held = []
        // A stream sends a theme only when its colors are not the built-in
        // ones, so colors a last stream gave go back to the view's own
        // unless this one gives them again.
        if theme != nil { theme = .builtIn }
        failedReads = 0
        hasEnded = false
        return []
    }

    /// The stream's items, in order.
    mutating func receive(_ items: [RexStreamScanner.Item]) -> [Effect] {
        guard !hasEnded else { return [] }
        var effects: [Effect] = []
        for item in items {
            switch item {
            case .program(let bytes): effects += output(bytes)
            case .message(let message): effects += received(message)
            }
        }
        return effects
    }

    /// The stream stopped arriving: its connection dropped and is being
    /// resumed. Output may be on its way, so nothing read until
    /// `streamResumed` is exact, and the stream is not quiet meanwhile.
    mutating func streamPaused() -> [Effect] {
        activity &+= 1
        isPaused = true
        attempt?.disturbed = true
        return []
    }

    /// The stream goes on where it stopped.
    mutating func streamResumed() -> [Effect] {
        activity &+= 1
        isPaused = false
        return []
    }

    mutating func answered(_ answer: RexTerminalAnswer, id: UInt64) -> [Effect] {
        guard !hasEnded, var current = attempt else { return [] }
        if id == current.modesID {
            current.modesID = nil
            guard case .modes(let wraparound) = answer else { return readFailed() }
            // The redraw's unwrap rejoins soft-wrapped lines, which goes wrong when autowrap is off.
            let unwrap = wraparound ?? true
            let format = makeID()
            let title = makeID()
            current.pageID = format
            current.titleID = title
            current.asked = true
            if isPaused { current.disturbed = true }
            attempt = current
            return [.read(.format(unwrap: unwrap), id: format), .read(.title, id: title)]
        }
        if id == current.pageID {
            current.pageID = nil
            guard case .page(let bytes, let next) = answer else { return readFailed() }
            current.cut = true
            guard current.redraw.count + bytes.count <= parameters.redrawByteLimit else {
                attempt = nil
                hasEnded = true
                return [.emit(.ended(.redrawTooLarge))]
            }
            current.redraw.append(bytes)
            if let next {
                let page = makeID()
                current.pageID = page
                attempt = current
                return [.read(.blobRead(id: next, offset: current.redraw.count), id: page)]
            }
            current.redrawDone = true
            attempt = current
            return settleWhenRead()
        }
        if id == current.titleID {
            current.titleID = nil
            // The redraw stands without the title.
            if case .title(let title) = answer { current.title = title }
            current.titleDone = true
            attempt = current
            return settleWhenRead()
        }
        return []
    }

    mutating func waited(id: UInt64) -> [Effect] {
        guard !hasEnded, let timer, timer.id == id else { return [] }
        self.timer = nil
        switch timer.kind {
        case .settle:
            return evaluate()
        case .retryPause(let since, let waited, let next):
            // A paused stream says nothing of the program: the wait does not count.
            let total = isPaused ? waited : waited + parameters.retryQuiet
            if !isPaused, since == activity || total >= parameters.retryWaitLimit {
                return startAttempt(.full, number: next)
            }
            return arm(.retryPause(activity: activity, waited: total, next: next), after: parameters.retryQuiet)
        case .quietWatch(let since):
            guard since == activity, !isPaused else { return watchForQuiet() }
            return startAttempt(.quiet, number: 1)
        case .readRetry(let number):
            return startAttempt(.full, number: number)
        }
    }

    // MARK: The stream

    private mutating func output(_ bytes: Data) -> [Effect] {
        activity &+= 1
        if var current = attempt {
            if current.asked { current.disturbed = true }
            if current.cut { keep(bytes, in: &current) }
            attempt = current
        }
        guard isPainted else { return [] }
        modes.receive(bytes)
        var effects: [Effect] = [.emit(.feed(bytes))]
        if paintedOnAlternateScreen, !modes.isAlternateScreen {
            paintedOnAlternateScreen = false
            effects += requestRepaint()
        }
        return effects
    }

    private mutating func keep(_ bytes: Data, in current: inout Attempt) {
        if current.replay.count + bytes.count <= parameters.replayByteLimit {
            current.replay.append(bytes)
            return
        }
        droppedReplayBytes += UInt64(current.replay.count)
        current.overflowed = true
        current.replay = Data()
        if bytes.count <= parameters.replayByteLimit {
            current.replay = bytes
        } else {
            droppedReplayBytes += UInt64(bytes.count)
        }
    }

    private mutating func received(_ message: RexStreamMessage) -> [Effect] {
        var effects: [Effect] = []
        let first = !started
        started = true
        switch message {
        case .resize(let next):
            if next != grid {
                let changed = grid.map { $0.columns != next.columns || $0.rows != next.rows } ?? false
                grid = next
                effects.append(.emit(.grid(next)))
                if changed {
                    activity &+= 1
                    if attempt?.asked == true { attempt?.disturbed = true }
                    if isPainted { effects += requestRepaint() }
                }
            }
        case .theme(let next):
            // The next paint applies it; a painted view gets it at once. A
            // palette entry the server no longer lists goes back to Rex's
            // built-in color, which only a redraw says, so it repaints.
            let dropped = !(theme?.paletteIndices.subtracting(next.paletteIndices).isEmpty ?? true)
            theme = next
            if isPainted {
                effects.append(.emit(.theme(next)))
                if dropped { effects += requestRepaint() }
            }
        case .childExited(let code):
            effects += emitOrHold(.exited(code: code))
        case .unknown:
            break
        }
        if first { effects += startAttempt(.full, number: 1) }
        return effects
    }

    private mutating func emitOrHold(_ instruction: RexTerminalInstruction) -> [Effect] {
        guard isPainted else {
            held.append(instruction)
            return []
        }
        return [.emit(instruction)]
    }

    // MARK: Attempts

    private mutating func startAttempt(_ run: Run, number: Int) -> [Effect] {
        timer = nil
        repaintPending = false
        let id = makeID()
        attempt = Attempt(run: run, number: number, modesID: id)
        return [.read(.modes, id: id)]
    }

    private mutating func settleWhenRead() -> [Effect] {
        guard var current = attempt, current.redrawDone, current.titleDone, !current.settling else { return [] }
        current.settling = true
        attempt = current
        return arm(.settle, after: parameters.settle)
    }

    private mutating func evaluate() -> [Effect] {
        guard let current = attempt else { return [] }
        attempt = nil
        failedReads = 0
        if !current.disturbed, !current.overflowed {
            return paint(current, exact: true)
        }
        switch current.run {
        case .quiet:
            quietMisses += 1
            return repaintPending ? startAttempt(.full, number: 1) : watchForQuiet()
        case .full where current.number < parameters.attempts:
            return arm(.retryPause(activity: activity, waited: .zero, next: current.number + 1), after: parameters.retryQuiet)
        case .full where current.overflowed && isPainted:
            // A gap in the output kept; the live output shown is better than this paint.
            isDirty = true
            return repaintPending ? startAttempt(.full, number: 1) : watchForQuiet()
        case .full:
            return paint(current, exact: false)
        }
    }

    private mutating func paint(_ current: Attempt, exact: Bool) -> [Effect] {
        var bytes = Self.reset
        if let theme { bytes.append(theme.sequences) }
        bytes.append(current.redraw)
        var effects: [Effect] = [.emit(.paint(bytes, exact: exact))]
        if let title = current.title { effects.append(.emit(.title(title))) }
        if !current.replay.isEmpty { effects.append(.emit(.feed(current.replay))) }
        effects += held.map { .emit($0) }
        held = []
        paintCount += 1
        if exact {
            exactPaintCount += 1
            quietMisses = 0
        }
        isPainted = true
        isDirty = !exact
        // The paint starts with RIS, which leaves the tracker as new from
        // whatever it was in, a sequence cut short included.
        modes.receive(bytes)
        paintedOnAlternateScreen = modes.isAlternateScreen
        modes.receive(current.replay)
        if paintedOnAlternateScreen, !modes.isAlternateScreen {
            paintedOnAlternateScreen = false
            repaintPending = true
        }
        if repaintPending { return effects + startAttempt(.full, number: 1) }
        if isDirty { return effects + watchForQuiet() }
        return effects
    }

    private mutating func requestRepaint() -> [Effect] {
        guard attempt == nil, !isRetryPausing else {
            repaintPending = true
            return []
        }
        return startAttempt(.full, number: 1)
    }

    private var isRetryPausing: Bool {
        switch timer?.kind {
        case .retryPause, .readRetry: true
        default: false
        }
    }

    private mutating func readFailed() -> [Effect] {
        guard let current = attempt else { return [] }
        attempt = nil
        failedReads += 1
        guard isPainted else {
            if failedReads >= parameters.failedReadLimit {
                hasEnded = true
                return [.emit(.ended(.paintFailed))]
            }
            return arm(.readRetry(number: current.number), after: parameters.failedReadDelay)
        }
        // What is shown stays; it is suspect until a quiet repaint replaces it.
        isDirty = true
        return watchForQuiet(after: parameters.failedReadDelay)
    }

    private mutating func watchForQuiet(after delay: Duration? = nil) -> [Effect] {
        arm(.quietWatch(activity: activity), after: delay ?? quietWindow)
    }

    /// `quietRepaint`, doubled for each quiet repaint output disturbed.
    private var quietWindow: Duration {
        let limit = max(parameters.quietRepaint, parameters.quietRepaintLimit)
        return min(parameters.quietRepaint * (1 << min(quietMisses, 16)), limit)
    }

    private mutating func arm(_ kind: Timer, after delay: Duration) -> [Effect] {
        let id = makeID()
        timer = (id, kind)
        return [.wait(delay, id: id)]
    }

    private mutating func makeID() -> UInt64 {
        nextID += 1
        return nextID
    }
}

/// The control-link calls behind each `RexTerminalRead`, and how their
/// answers read. Rex block methods take the session and block, and their
/// own arguments under `args`.
enum RexTerminalReads {
    /// Every extra the lab's redraw used. With these and `unwrap`, the
    /// redraw reproduced text, soft wraps, styles and modes in Rex's own
    /// emulator; it carries no title, cursor shape, OSC 10/11 colors, saved
    /// cursor, or primary screen behind the alternate one. The method has no
    /// argument that limits scrollback, so a long history is paged whole.
    static let redrawExtras = [
        "extra_charsets", "extra_cursor", "extra_hyperlink", "extra_keyboard", "extra_kitty_keyboard", "extra_modes",
        "extra_palette", "extra_protection", "extra_pwd", "extra_scrolling_region", "extra_style", "extra_tabstops",
    ]

    static func call(_ read: RexTerminalRead, session: String, block: String, pageBytes: Int)
        -> (method: String, payload: JSONValue)
    {
        var payload: [String: JSONValue] = ["session_id": .string(session), "block_id": .string(block)]
        let name: String
        switch read {
        case .modes:
            name = "modes"
        case .title:
            name = "title"
        case .format(let unwrap):
            name = "format"
            var args: [String: JSONValue] = [
                "format": .string("vt"), "unwrap": .bool(unwrap), "max_bytes": .number(Double(pageBytes)),
            ]
            for extra in redrawExtras { args[extra] = .bool(true) }
            payload["args"] = .object(args)
        case .blobRead(let id, let offset):
            name = "blob_read"
            payload["args"] = .object([
                "id": .number(Double(id)), "offset": .number(Double(offset)), "max_bytes": .number(Double(pageBytes)),
            ])
        }
        return (RexInventoryWire.terminalMethod(name), .object(payload))
    }

    static func answer(to read: RexTerminalRead, _ result: JSONValue) -> RexTerminalAnswer {
        switch read {
        case .modes:
            guard case .array(let modes) = result["modes"] else { return .modes(wraparound: nil) }
            // DECAWM is DEC private mode 7; an ANSI mode 7 is another one.
            let autowrap = modes.first {
                $0["number"] == .number(7) && $0["ansi"] != .bool(true)
            }
            guard case .bool(let set) = autowrap?["set"] else { return .modes(wraparound: nil) }
            return .modes(wraparound: set)
        case .title:
            guard let title = result["title"]?.stringValue else { return .failed }
            return .title(displayTitle(title))
        case .format:
            guard let content = result["content"]?.stringValue else { return .failed }
            let more = result["eof"] != .bool(true)
            return .page(Data(content.utf8), next: more ? result["id"]?.pageID : nil)
        case .blobRead(let id, _):
            guard let data = result["data"]?.stringValue else { return .failed }
            if result["eof"] == .bool(true) { return .page(Data(data.utf8), next: nil) }
            // A page that brings nothing and does not end the result would repeat forever.
            guard !data.isEmpty else { return .failed }
            return .page(Data(data.utf8), next: result["id"]?.pageID ?? id)
        }
    }
}

extension RexTerminalReads {
    /// The longest title kept, in characters.
    static let titleCharacterLimit = 256

    /// A title as a program set it, fit to show: control characters, which
    /// a program may put anywhere, are dropped, and a long title is cut.
    static func displayTitle(_ title: String) -> String {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: title.unicodeScalars.filter { $0.properties.generalCategory != .control })
        return String(String(kept).prefix(titleCharacterLimit))
    }
}

extension JSONValue {
    fileprivate var pageID: Int? {
        guard case .number(let value) = self, value.rounded() == value, value >= 0, value <= 9_007_199_254_740_992 else {
            return nil
        }
        return Int(value)
    }
}
