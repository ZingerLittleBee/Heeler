import Foundation
import Synchronization

/// The remote object one interactive PTY Attach resolves.
///
/// Agent Attach addresses herdr's Agent-facing command with a Pane id. An
/// ordinary shell terminal instead addresses `herdr terminal attach` with the
/// terminal id returned by `tab.create`. Keeping the distinction in the
/// request prevents UI code from selecting remote commands itself.
enum TerminalAttachTarget: Sendable, Hashable {
    case agentPane(String)
    case terminal(String)

    var identifier: String {
        switch self {
        case .agentPane(let identifier), .terminal(let identifier):
            identifier
        }
    }
}

/// How a viewer joins a herdr-core Terminal, which has no Take Over: any viewer
/// that is not only observing may type, and the last one to type, resize or
/// take focus sets the Terminal's size.
enum TerminalViewerRole: Sendable, Equatable {
    /// Sets the Terminal's size on arrival.
    case interactive
    /// Back after a dropped line: sets the size only once it is active again.
    case resumed
    /// Watches only: its input and size count for nothing.
    case observe
}

/// What a viewer's own terminal looks like, which a core uses to answer the
/// program's display queries.
struct TerminalDisplayFacts: Sendable, Equatable {
    struct CellPixels: Sendable, Equatable {
        let width: Int
        let height: Int
    }

    /// Default foreground as `#rrggbb`.
    var foreground: String?
    /// Default background as `#rrggbb`.
    var background: String?
    /// Cursor color as `#rrggbb`.
    var cursor: String?
    var cell: CellPixels?
}

/// Whether anyone is looking at a retained terminal. Only a herdr-core attach
/// passes this on: a hidden one reports neither focus nor display facts.
enum TerminalViewerPresence: Sendable, Equatable {
    case viewed(TerminalDisplayFacts?)
    case hidden
    case factsChanged(TerminalDisplayFacts)
}

/// One interactive terminal request: its typed remote target, how it joins
/// (herdr's takeover flag, a core's viewer role and display facts), and the
/// initial geometry.
struct TerminalAttachRequest: Sendable, Equatable {
    let target: TerminalAttachTarget
    let takeover: Bool
    let viewer: TerminalViewerRole
    let displayFacts: TerminalDisplayFacts?
    let cols: Int
    let rows: Int

    init(
        target: TerminalAttachTarget,
        takeover: Bool = false,
        viewer: TerminalViewerRole = .interactive,
        displayFacts: TerminalDisplayFacts? = nil,
        cols: Int,
        rows: Int
    ) {
        self.target = target
        self.takeover = takeover
        self.viewer = viewer
        self.displayFacts = displayFacts
        self.cols = cols
        self.rows = rows
    }

    /// Compatibility spelling for existing Agent Attach callers. New call
    /// sites that can target more than an Agent use the typed initializer.
    init(target: String, takeover: Bool = false, cols: Int, rows: Int) {
        self.init(
            target: .agentPane(target),
            takeover: takeover,
            cols: cols,
            rows: rows)
    }
}

/// The handshake that separates an attach channel's pre-attach noise from
/// the attach session itself.
///
/// OpenSSH still hands every exec request to the remote account shell as
/// `shell -c command`, even when Heeler requests a PTY and an exec together
/// (no interactive login shell, no socat bootstrap). The account shell or SSH
/// session can still emit generic startup or rc chatter before the `printf` of
/// this marker and the subsequent `exec herdr agent attach`. None of that
/// belongs on the terminal: it would paint until the TUI's first frame wiped
/// it, a flash of unrelated output on every attach.
///
/// So the attach exec command prints this marker immediately before it
/// execs attach, and everything up to it is dropped. Printing it as real
/// control bytes is what makes it unambiguous: chatter that contains the
/// literal text `\033` has no ESC byte, so it cannot open the gate. APC is the
/// one string terminals are required to ignore, which keeps a stray copy
/// harmless.
enum AttachBootstrapHandshake {
    static let marker = Data("\u{1B}_heeler-attach\u{1B}\\".utf8)
    /// `marker` as a `printf` format. Octal throughout: the format has to
    /// survive the Host's account shell (fish included) and `/bin/sh` before
    /// printf ever sees it, and octal escapes are the portable spelling.
    static let markerPrintfFormat = "\\033_heeler-attach\\033\\134"
}

/// Holds an attach channel's output back until the bootstrap handshake lands.
///
/// The withheld bytes are buffered rather than dropped: a channel that dies
/// before the handshake has said everything it is ever going to say in that
/// startup diagnostic, so `flush()` hands it back.
struct AttachBootstrapGate {
    /// A ceiling for a channel that never handshakes. The tail is what
    /// carries the failure, and it stays far longer than the marker, so a
    /// marker split across chunks still matches after a trim.
    static let maximumWithheldBytes = 8 * 1024

    private(set) var isOpen = false
    private var withheld = Data()

    /// The bytes the terminal should paint: nothing until the marker arrives,
    /// everything after it once it has.
    mutating func admit(_ bytes: Data) -> Data {
        if isOpen { return bytes }
        withheld.append(bytes)
        guard let marker = withheld.range(of: AttachBootstrapHandshake.marker) else {
            if withheld.count > Self.maximumWithheldBytes {
                withheld = Data(withheld.suffix(Self.maximumWithheldBytes))
            }
            return Data()
        }
        isOpen = true
        let session = Data(withheld[marker.upperBound...])
        withheld = Data()
        return session
    }

    /// The withheld noise, for a channel that ended before it handshook.
    /// Empty once the gate is open — by then the noise is long past.
    mutating func flush() -> Data {
        guard !isOpen else { return Data() }
        defer { withheld = Data() }
        return withheld
    }
}

/// Drops herdr's direct-attach startup probe from attach output (#451).
///
/// herdr 0.9.4's `agent attach` and `terminal attach` set the terminal up
/// before their handshake and, once in the alternate screen, query it: a
/// DECRQM for SGR pixel mouse, then DA1. herdr waits up to 250 ms for the
/// answer. One that arrives later, as it does over a slow link, reaches the
/// Pane as typed input. With the probe gone, the terminal never answers.
///
/// The probe starts 138 bytes after the bootstrap marker in 0.9.4's output,
/// so only the first 4 KiB after the marker are searched, and only the first
/// probe found there is removed. Every byte after it, or after the window,
/// passes unchanged. At most 15 bytes, the start of a probe split across
/// reads, are held back until the next read settles them; `finish()` hands
/// them on when the output ends.
struct HerdrStartupProbeFilter {
    /// The probe shapes herdr writes: direct attach's, and its client
    /// shell's, which adds the kitty keyboard query.
    static let probes = [
        Data("\u{1B}[?1016$p\u{1B}[c".utf8),
        Data("\u{1B}[?1016$p\u{1B}[?u\u{1B}[c".utf8),
    ]

    /// How far after the marker a probe may start and still be herdr's.
    static let scanWindow = 4 * 1024

    private var isScanning: Bool
    /// The bytes after the marker already handed on.
    private var scanned = 0
    /// A trailing partial probe, held until the next read completes or
    /// refutes it.
    private var held = Data()

    /// A disabled filter passes every byte through, for a channel that never
    /// carries the probe.
    init(isEnabled: Bool) {
        isScanning = isEnabled
    }

    /// The bytes the terminal should paint, given the next bytes after the
    /// bootstrap marker.
    mutating func filter(_ bytes: Data) -> Data {
        guard isScanning else { return bytes }
        var data = held
        data.append(bytes)
        held = Data()
        // Offsets into `data` below this still lie inside the window.
        let limit = Self.scanWindow - scanned
        if let probe = Self.earliestProbe(in: data) {
            isScanning = false
            if data.distance(from: data.startIndex, to: probe.lowerBound) < limit {
                data.removeSubrange(probe)
            }
            return data
        }
        let heldStart = data.count - Self.trailingProbePrefixLength(of: data)
        guard heldStart < limit else {
            isScanning = false
            return data
        }
        held = Data(data.dropFirst(heldStart))
        scanned += heldStart
        return Data(data.prefix(heldStart))
    }

    /// The partial probe still held when the output ends: no read is left to
    /// complete it, so it is output like any other.
    mutating func finish() -> Data {
        isScanning = false
        defer { held = Data() }
        return held
    }

    private static func earliestProbe(in data: Data) -> Range<Data.Index>? {
        probes.compactMap { data.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    /// The length of the longest suffix of `data` that is a proper prefix of
    /// a probe.
    private static func trailingProbePrefixLength(of data: Data) -> Int {
        probes.map { probe in
            for length in stride(from: min(probe.count - 1, data.count), to: 0, by: -1)
            where data.suffix(length).elementsEqual(probe.prefix(length)) {
                return length
            }
            return 0
        }.max() ?? 0
    }
}

/// The last thing an attach command said before it exited, as one line a
/// failure message can quote (#431).
///
/// herdr's own error line ("herdr: lost connection to server: ...") reaches
/// the terminal, but the Session Ended card covers it, and the exit status
/// alone does not say which herdr failed or why. This keeps a bounded tail of
/// the output that was outside the alternate screen and extracts one line
/// from it.
///
/// Alternate-screen content is never retained: it is a TUI's screen, which
/// can show anything, secrets included. Output recorded before the first
/// alternate-screen entry, or after the last leave, is ordinary command
/// output. A command that exits while still inside the alternate screen has
/// no line to quote.
///
/// One flag is enough because the only alternate-screen switches in an attach
/// stream are herdr's own: `herdr terminal attach` draws the pane through its
/// cell-diff renderer (`RenderEncoding::TerminalAnsi` in herdr 0.8.2 and
/// later), which never forwards the inner application's mode switches.
struct AttachExitDiagnostic {
    /// The retained tail. herdr's failure is its last line or two.
    static let maximumRetainedBytes = 4 * 1024
    /// The quoted line's ceiling, in characters, including the ellipsis.
    static let maximumLineLength = 120
    /// Longest escape sequence held back while waiting for the rest of a
    /// mode switch split across chunks. Real mode switches are far shorter.
    private static let maximumCarriedBytes = 32

    private var isInAlternateScreen = false
    /// Output outside the alternate screen since the last leave, or since the
    /// start when it was never entered. Bounded to the tail.
    private var retained: [UInt8] = []
    private var didTruncate = false
    /// A trailing escape sequence that may be an incomplete mode switch.
    private var carried: [UInt8] = []

    /// Feeds the next chunk of attach output, in arrival order.
    mutating func record(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var bytes = carried
        carried = []
        bytes.append(contentsOf: chunk)

        var index = 0
        var runStart = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                index += 1
                continue
            }
            switch Self.modeSwitch(in: bytes, at: index) {
            case .incomplete:
                retain(bytes[runStart..<index])
                carried = Array(bytes[index...])
                return
            case .notAModeSwitch:
                index += 1
            case .modeSwitch(let entersAlternateScreen, let end):
                retain(bytes[runStart..<index])
                if let entersAlternateScreen {
                    if entersAlternateScreen != isInAlternateScreen {
                        retained = []
                        didTruncate = false
                    }
                    isInAlternateScreen = entersAlternateScreen
                }
                index = end
                runStart = end
            }
        }
        retain(bytes[runStart...])
    }

    /// The line to quote, or nil when the command left nothing quotable.
    var line: String? {
        guard !isInAlternateScreen else { return nil }
        var bytes = Array(retained.suffix(Self.maximumRetainedBytes))
        bytes.append(contentsOf: carried)
        var text = String(decoding: bytes, as: UTF8.self)
        if didTruncate || retained.count > Self.maximumRetainedBytes,
            let firstBreak = text.firstIndex(where: \.isNewline)
        {
            // The first line was cut mid-way, possibly inside an escape
            // sequence or a UTF-8 scalar; drop it rather than quote debris.
            text = String(text[text.index(after: firstBreak)...])
        }
        return Self.line(fromOutput: text)
    }

    /// Picks the line to quote from command output already decoded as text.
    static func line(fromOutput output: String) -> String? {
        let lines = sanitized(output)
            // `isNewline`, because "\r\n" is one Character equal to neither.
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // An explicit error line beats whatever usage text follows it: clap
        // prints "error: ...", herdr "herdr: ...", a Rust main "Error: ...".
        let chosen =
            lines.last(where: { line in
                let lowered = line.lowercased()
                return lowered.hasPrefix("error:") || lowered.hasPrefix("herdr:")
            })
            ?? lines.last(where: { !isHint($0) })
            ?? lines.last
        guard let chosen else { return nil }
        guard chosen.count > maximumLineLength else { return chosen }
        return String(chosen.prefix(maximumLineLength - 1)) + "…"
    }

    /// Trailing advice that never explains a failure on its own.
    private static func isHint(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.hasPrefix("note:") || lowered.hasPrefix("for more information")
    }

    private mutating func retain(_ bytes: ArraySlice<UInt8>) {
        guard !isInAlternateScreen, !bytes.isEmpty else { return }
        retained.append(contentsOf: bytes)
        // Trim in batches so a long stream is not shifted on every chunk.
        if retained.count > 2 * Self.maximumRetainedBytes {
            retained.removeFirst(retained.count - Self.maximumRetainedBytes)
            didTruncate = true
        }
    }

    private enum ModeSwitchScan {
        case incomplete
        case notAModeSwitch
        /// A DEC private mode set or reset ending before `end`. The flag is
        /// nil when it names no alternate-screen mode.
        case modeSwitch(entersAlternateScreen: Bool?, end: Int)
    }

    /// Recognizes `ESC [ ? Pm h` and `ESC [ ? Pm l` at `start`. Modes 1049,
    /// 1047, and 47 all switch to the alternate screen.
    private static func modeSwitch(in bytes: [UInt8], at start: Int) -> ModeSwitchScan {
        let introducer: [UInt8] = [0x1B, UInt8(ascii: "["), UInt8(ascii: "?")]
        for offset in 1..<introducer.count {
            guard start + offset < bytes.count else {
                return bytes.count - start <= maximumCarriedBytes ? .incomplete : .notAModeSwitch
            }
            guard bytes[start + offset] == introducer[offset] else { return .notAModeSwitch }
        }
        var index = start + introducer.count
        var parameters: [Int] = []
        var current = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                current = min(current * 10 + Int(byte - UInt8(ascii: "0")), 100_000)
            case UInt8(ascii: ";"):
                parameters.append(current)
                current = 0
            case UInt8(ascii: "h"), UInt8(ascii: "l"):
                parameters.append(current)
                let switchesScreen = parameters.contains { [1049, 1047, 47].contains($0) }
                return .modeSwitch(
                    entersAlternateScreen: switchesScreen ? byte == UInt8(ascii: "h") : nil,
                    end: index + 1)
            default:
                return .notAModeSwitch
            }
            index += 1
            if index - start > maximumCarriedBytes { return .notAModeSwitch }
        }
        return .incomplete
    }

    /// Removes escape sequences, control characters, and bidirectional
    /// formatting, keeping line breaks and tabs.
    private static func sanitized(_ text: String) -> String {
        enum State {
            case text
            case escape
            case escapeIntermediate
            case controlSequence
            case controlString
            case controlStringEscape
        }
        var result = String.UnicodeScalarView()
        var state = State.text
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                if value == 0x1B {
                    state = .escape
                } else if value == 0x0A || value == 0x0D || value == 0x09 {
                    result.append(scalar)
                } else if value < 0x20 || (0x7F...0x9F).contains(value)
                    || isBidiFormatting(value)
                {
                    continue
                } else {
                    result.append(scalar)
                }
            case .escape:
                switch value {
                case 0x5B:  // [
                    state = .controlSequence
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F:  // ] P X ^ _
                    state = .controlString
                case 0x20...0x2F:
                    state = .escapeIntermediate
                case 0x1B:
                    state = .escape
                default:
                    state = .text
                }
            case .escapeIntermediate:
                if !(0x20...0x2F).contains(value) { state = .text }
            case .controlSequence:
                if (0x40...0x7E).contains(value) {
                    state = .text
                } else if value == 0x1B {
                    state = .escape
                } else if value == 0x0A || value == 0x0D {
                    // A line break aborts a malformed sequence; keep the break.
                    result.append(scalar)
                    state = .text
                }
            case .controlString:
                if value == 0x07 {
                    state = .text
                } else if value == 0x1B {
                    state = .controlStringEscape
                }
            case .controlStringEscape:
                state = value == 0x5C ? .text : (value == 0x1B ? .controlStringEscape : .controlString)
            }
        }
        return String(result)
    }

    private static func isBidiFormatting(_ value: UInt32) -> Bool {
        value == 0x200E || value == 0x200F || value == 0x061C
            || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
    }
}

/// Input riding down a live Attach session. Keystrokes and resizes are
/// reliable, while touch scrolling is bounded and may be coalesced.
enum TerminalAttachInput: Sendable, Equatable {
    case keystrokes(Data)
    case scroll(Data)
    case resize(cols: Int, rows: Int)
}

/// The live PTY's mixed-reliability input queue.
///
/// Keystrokes and resizes are reliable and ordered. Touch scrolling is an
/// ephemeral viewport intent: keeping every momentum row under backpressure
/// only makes stale scrolling delay later keyboard input. Scroll rows are
/// therefore coalesced, bounded, and discarded as soon as a reliable key
/// arrives. The writer asks for one item only after the previous SSH write
/// completes, so priority is decided at the last useful moment.
final class TerminalAttachInputQueue: Sendable {
    static let maximumPendingScrollRows = 12
    static let maximumScrollRowsPerWrite = 3
    static let scrollPacingInterval = Duration.milliseconds(33)

    private struct PendingScroll: Sendable {
        let sequence: Data
        var rows: Int
    }

    private struct State: ~Copyable {
        var reliable: [TerminalAttachInput] = []
        var pendingScroll: PendingScroll?
        var waiter: CheckedContinuation<TerminalAttachInput?, Never>?
        var isFinished = false
    }

    private enum NextDecision {
        case wait
        case resume(TerminalAttachInput?)
    }

    private let state = Mutex(State())

    func send(_ keystrokes: Data) {
        guard !keystrokes.isEmpty else { return }
        enqueueReliable(.keystrokes(keystrokes), discardingPendingScroll: true)
    }

    func scroll(_ sequence: Data, rows: Int) {
        guard !sequence.isEmpty, rows > 0 else { return }

        var resumed: (CheckedContinuation<TerminalAttachInput?, Never>, TerminalAttachInput)?
        state.withLock { state in
            guard !state.isFinished else { return }

            if let waiter = state.waiter {
                state.waiter = nil
                let deliveredRows = min(rows, Self.maximumScrollRowsPerWrite)
                let remainingRows = min(
                    rows - deliveredRows,
                    Self.maximumPendingScrollRows - deliveredRows)
                if remainingRows > 0 {
                    state.pendingScroll = PendingScroll(
                        sequence: sequence,
                        rows: remainingRows)
                }
                resumed = (waiter, .scroll(Self.repeated(sequence, count: deliveredRows)))
                return
            }

            if var pending = state.pendingScroll, pending.sequence == sequence {
                pending.rows = min(
                    Self.maximumPendingScrollRows,
                    pending.rows + rows)
                state.pendingScroll = pending
            } else {
                // A direction change makes the previous momentum stale.
                state.pendingScroll = PendingScroll(
                    sequence: sequence,
                    rows: min(rows, Self.maximumPendingScrollRows))
            }
        }
        if let resumed {
            resumed.0.resume(returning: resumed.1)
        }
    }

    func resize(cols: Int, rows: Int) {
        enqueueReliable(.resize(cols: cols, rows: rows), discardingPendingScroll: false)
    }

    func next() async -> TerminalAttachInput? {
        await withCheckedContinuation { continuation in
            let decision = state.withLock { state -> NextDecision in
                if !state.reliable.isEmpty {
                    return .resume(state.reliable.removeFirst())
                }
                if let scroll = state.pendingScroll {
                    let deliveredRows = min(scroll.rows, Self.maximumScrollRowsPerWrite)
                    let remainingRows = scroll.rows - deliveredRows
                    state.pendingScroll =
                        remainingRows > 0
                        ? PendingScroll(sequence: scroll.sequence, rows: remainingRows)
                        : nil
                    return .resume(
                        .scroll(Self.repeated(scroll.sequence, count: deliveredRows)))
                }
                if state.isFinished {
                    return .resume(nil)
                }
                precondition(state.waiter == nil, "Attach input has more than one consumer")
                state.waiter = continuation
                return .wait
            }

            if case .resume(let input) = decision {
                continuation.resume(returning: input)
            }
        }
    }

    func finish() {
        var waiter: CheckedContinuation<TerminalAttachInput?, Never>?
        state.withLock { state in
            guard !state.isFinished else { return }
            state.isFinished = true
            // Explicit shutdown still drains reliable input already accepted
            // by the session. Only ephemeral scroll momentum is abandoned.
            state.pendingScroll = nil
            waiter = state.waiter
            state.waiter = nil
        }
        waiter?.resume(returning: nil)
    }

    private func enqueueReliable(
        _ input: TerminalAttachInput,
        discardingPendingScroll: Bool
    ) {
        var waiter: CheckedContinuation<TerminalAttachInput?, Never>?
        state.withLock { state in
            guard !state.isFinished else { return }
            if discardingPendingScroll {
                state.pendingScroll = nil
            }
            if state.reliable.isEmpty, let waiting = state.waiter {
                state.waiter = nil
                waiter = waiting
            } else {
                state.reliable.append(input)
            }
        }
        waiter?.resume(returning: input)
    }

    /// Drains the queue onto a live PTY channel until the queue finishes or
    /// the task is cancelled. Scroll batches are paced so momentum cannot
    /// monopolize the channel ahead of keystrokes.
    func pump(
        write: (Data) async throws -> Void,
        resize: (Int, Int) async throws -> Void
    ) async throws {
        while let item = await next() {
            guard !Task.isCancelled else { return }
            switch item {
            case .keystrokes(let data):
                try await write(data)
            case .scroll(let data):
                try await write(data)
                try await Task.sleep(for: Self.scrollPacingInterval)
            case .resize(let cols, let rows):
                try await resize(cols, rows)
            }
        }
    }

    private static func repeated(_ sequence: Data, count: Int) -> Data {
        var result = Data(capacity: sequence.count * count)
        for _ in 0..<count {
            result.append(sequence)
        }
        return result
    }
}

/// A live interactive Attach session over its Host's dedicated terminal
/// channel: raw PTY bytes out, keystrokes and window changes in. The byte
/// stream feeds the terminal emulator directly without app-level framing.
///
/// Ending is explicit: call `end()`. The channel is closed by the session's
/// own teardown, which nothing else invokes — dropping the session, or
/// cancelling the task reading `output`, leaves the channel open until the
/// SSH connection closes.
final class TerminalAttachSession: Sendable {
    /// Raw PTY output in arrival order. Finishes without error when the
    /// remote attach exits cleanly (the user detached inside the TUI) or
    /// after `end()`; finishes throwing if the channel dies.
    ///
    /// Each access returns its own stream over the shared source. An
    /// unfolding stream keeps one produce storage per stream *instance*,
    /// shared by every iterator, and its own cancellation handler clears
    /// that storage for a reader whose task is already cancelled — before
    /// the source underneath can refuse the read. Through a single shared
    /// instance, such a reader silently terminates the legitimate consumer's
    /// iteration (#164). A per-access stream confines the damage to the
    /// offending reader; who may consume at all is still decided underneath,
    /// where the first reading task claims the output (#153).
    var output: AsyncThrowingStream<Data, any Error> { makeOutput() }
    private let makeOutput: @Sendable () -> AsyncThrowingStream<Data, any Error>
    private let input: TerminalAttachInputQueue
    private let onEndStarted: @Sendable () -> Void
    private let onConsumed: (@Sendable (Int) -> Void)?
    private let onPresence: (@Sendable (TerminalViewerPresence) -> Void)?
    private let ender: @Sendable () async -> Void

    init(
        output makeOutput: @escaping @Sendable () -> AsyncThrowingStream<Data, any Error>,
        input: TerminalAttachInputQueue,
        onEndStarted: @escaping @Sendable () -> Void = {},
        onConsumed: (@Sendable (Int) -> Void)? = nil,
        onPresence: (@Sendable (TerminalViewerPresence) -> Void)? = nil,
        ender: @escaping @Sendable () async -> Void
    ) {
        self.makeOutput = makeOutput
        self.input = input
        self.onEndStarted = onEndStarted
        self.onConsumed = onConsumed
        self.onPresence = onPresence
        self.ender = ender
    }

    /// The view took `count` bytes of `output`. A herdr-core attach returns
    /// their credit now, never on receipt.
    func outputConsumed(_ count: Int) {
        onConsumed?(count)
    }

    /// A herdr-core viewer, which says what it took and whether it is seen.
    var isCoreViewer: Bool { onPresence != nil }

    /// Whether anyone is looking at this terminal. A herdr-core attach alone
    /// passes this on.
    func setPresence(_ presence: TerminalViewerPresence) {
        onPresence?(presence)
    }

    /// Forwards raw keystroke bytes to the remote PTY. Fire-and-forget: a
    /// dead channel drops them, and the death surfaces on `output`.
    func send(_ keystrokes: Data) {
        input.send(keystrokes)
    }

    /// Coalesces touch-scroll rows behind at most one small in-flight batch.
    /// Pending rows are intentionally lossy so typing never waits behind old
    /// momentum after the user's intent has changed.
    func scroll(_ sequence: Data, rows: Int) {
        input.scroll(sequence, rows: rows)
    }

    /// Propagates a terminal geometry change (rotation, split view) to the
    /// remote PTY via SSH window-change; no reattach needed.
    func resize(cols: Int, rows: Int) {
        input.resize(cols: cols, rows: rows)
    }

    /// Closes the terminal channel explicitly and waits for its teardown;
    /// `output` then finishes without error. Idempotent.
    func end() async {
        onEndStarted()
        input.finish()
        await ender()
    }
}
