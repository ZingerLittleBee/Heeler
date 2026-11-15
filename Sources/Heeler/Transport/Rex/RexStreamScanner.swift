import Foundation

/// A terminal's size as its stream reports it.
struct RexTerminalGrid: Sendable, Equatable {
    var columns: Int
    var rows: Int
    /// Pixel size of one cell; 0 where the server has no figure.
    var cellWidth: Int
    var cellHeight: Int
    /// Who owned the block when this size was set; nil for no one.
    var owner: String?
}

/// The default colors a stream reports for its terminal. A missing color
/// means the server's built-in default.
struct RexTerminalTheme: Sendable, Equatable {
    var foreground: String?
    var background: String?
    var cursor: String?
    /// Entries of the 256-color palette that differ, as `index=RRGGBB`.
    var palette: [String]
    /// `light` or `dark`, or nil to let the background decide.
    var scheme: String?
}

/// One of the stream's own messages.
enum RexStreamMessage: Sendable, Equatable {
    /// The terminal's size, first just after the snapshot and again whenever
    /// it changes.
    case resize(RexTerminalGrid)
    /// The default colors; a later one supersedes an earlier one.
    case theme(RexTerminalTheme)
    /// The program has exited: the stream remains open but carries no more
    /// of its output.
    case childExited(exitCode: Int?)
    /// A message of a type this build does not read, which it skips.
    case unknown(type: String)
}

/// Splits a Rex terminal stream (`rex.data.terminal.v1`) into the program's
/// bytes and the stream's own messages. Pure, and what it yields does not
/// depend on how the stream is cut into chunks, apart from where runs of
/// program bytes are split.
///
/// Each stream opens with the server's snapshot of the terminal, which
/// Heeler skips undecoded: it paints from the server's VT redraw instead. The scanner skips
/// everything before the first control sequence that carries this stream's
/// nonce, `ESC _ rex1;<nonce>;<json> ESC \`, keeping only a tail shorter
/// than that sequence's prefix between chunks. Rex 0.1.0-preview.14 (API
/// revision 12) put that first message, a resize, right at the snapshot's
/// end on every connection the lab watched.
///
/// From there, the stream's own messages are taken out and read, and every
/// other byte is the program's, in order. A sequence with another nonce is
/// a look-alike a program printed, and passes through as program bytes. A
/// chunk that ends partway into what may be one of the stream's own
/// messages is held back until the next chunk says. An own message whose
/// JSON cannot be read is dropped and scanning goes on after it; one that
/// grows past `messageByteLimit` without ending is dropped up to its end.
struct RexStreamScanner: Sendable {
    enum Item: Sendable, Equatable {
        /// Program output, in order.
        case program(Data)
        case message(RexStreamMessage)
    }

    /// Larger than any message Rex sends: a theme with the whole palette
    /// changed is a few KiB.
    static let messageByteLimit = 64 * 1024

    private static let escape: UInt8 = 0x1B
    private static let backslash: UInt8 = 0x5C

    let nonce: UInt64
    private let prefix: [UInt8]
    /// Whether the snapshot is behind; true from the first own message on.
    private(set) var isPastSnapshot = false
    /// Snapshot bytes skipped so far.
    private(set) var skippedSnapshotBytes: UInt64 = 0
    /// Program bytes yielded so far: where in the program's output the
    /// stream has got to.
    private(set) var programByteCount: UInt64 = 0
    /// Own messages dropped because they could not be read or never ended.
    private(set) var droppedMessageCount = 0
    /// Bytes that may begin something the next chunk decides.
    private var held: [UInt8] = []
    /// Inside an own message too long to keep, until its terminator.
    private var discarding = false

    init(nonce: UInt64) {
        self.nonce = nonce
        prefix = [Self.escape] + Array("_rex1;\(nonce);".utf8)
    }

    /// The items `chunk` completes, in stream order.
    mutating func scan(_ chunk: Data) -> [Item] {
        var bytes = held
        bytes.append(contentsOf: chunk)
        held = []
        guard isPastSnapshot else { return skipSnapshot(bytes) }
        return scanLive(bytes, from: 0)
    }

    // MARK: Snapshot

    private mutating func skipSnapshot(_ bytes: [UInt8]) -> [Item] {
        var searchFrom = 0
        while let escape = firstEscape(in: bytes, from: searchFrom) {
            switch match(bytes, at: escape) {
            case .complete:
                skippedSnapshotBytes += UInt64(escape)
                isPastSnapshot = true
                return scanLive(bytes, from: escape)
            case .partial:
                skippedSnapshotBytes += UInt64(escape)
                held = Array(bytes[escape...])
                return []
            case .mismatch:
                searchFrom = escape + 1
            }
        }
        // No prefix starts in here, nor begins at the end.
        skippedSnapshotBytes += UInt64(bytes.count)
        return []
    }

    // MARK: Live

    private mutating func scanLive(_ bytes: [UInt8], from start: Int) -> [Item] {
        var items: [Item] = []
        var programStart = start
        var index = start

        func flushProgram(upTo end: Int) {
            guard end > programStart else { return }
            items.append(.program(Data(bytes[programStart..<end])))
            programByteCount += UInt64(end - programStart)
        }

        while index < bytes.count {
            if discarding {
                guard let terminator = terminator(in: bytes, from: index) else {
                    // A last ESC may be the first half of the terminator.
                    held = bytes.last == Self.escape ? [Self.escape] : []
                    return items
                }
                discarding = false
                index = terminator + 2
                programStart = index
                continue
            }
            guard let escape = firstEscape(in: bytes, from: index) else { break }
            switch match(bytes, at: escape) {
            case .mismatch:
                index = escape + 1
            case .partial:
                flushProgram(upTo: escape)
                held = Array(bytes[escape...])
                return items
            case .complete:
                flushProgram(upTo: escape)
                let body = escape + prefix.count
                guard let terminator = terminator(in: bytes, from: body) else {
                    if bytes.count - escape > Self.messageByteLimit {
                        droppedMessageCount += 1
                        discarding = true
                        held = bytes.last == Self.escape ? [Self.escape] : []
                    } else {
                        held = Array(bytes[escape...])
                    }
                    return items
                }
                if let message = Self.message(Data(bytes[body..<terminator])) {
                    items.append(.message(message))
                } else {
                    droppedMessageCount += 1
                }
                index = terminator + 2
                programStart = index
            }
        }
        flushProgram(upTo: bytes.count)
        return items
    }

    // MARK: Matching

    private enum Match {
        case complete
        /// The bytes end before the prefix does, and agree with it so far.
        case partial
        case mismatch
    }

    private func match(_ bytes: [UInt8], at start: Int) -> Match {
        let available = min(bytes.count - start, prefix.count)
        for offset in 0..<available where bytes[start + offset] != prefix[offset] {
            return .mismatch
        }
        return available == prefix.count ? .complete : .partial
    }

    private func firstEscape(in bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        return bytes[start...].firstIndex(of: Self.escape)
    }

    /// Where the string terminator `ESC \` begins, at or after `start`.
    private func terminator(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while let escape = firstEscape(in: bytes, from: index) {
            guard escape + 1 < bytes.count else { return nil }
            if bytes[escape + 1] == Self.backslash { return escape }
            index = escape + 1
        }
        return nil
    }

    // MARK: Messages

    /// The message a body holds, or nil when it is not a JSON object with a
    /// `type`, or a known type lacks what it needs.
    static func message(_ body: Data) -> RexStreamMessage? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body),
            let type = value["type"]?.stringValue
        else { return nil }
        switch type {
        case "resize":
            guard let columns = value["cols"]?.streamInteger, let rows = value["rows"]?.streamInteger else {
                return nil
            }
            return .resize(
                RexTerminalGrid(
                    columns: columns, rows: rows, cellWidth: value["cell_width_px"]?.streamInteger ?? 0,
                    cellHeight: value["cell_height_px"]?.streamInteger ?? 0, owner: value["owner"]?.stringValue))
        case "theme":
            var palette: [String] = []
            if case .array(let entries) = value["palette"] {
                palette = entries.compactMap(\.stringValue)
            }
            return .theme(
                RexTerminalTheme(
                    foreground: value["foreground"]?.stringValue, background: value["background"]?.stringValue,
                    cursor: value["cursor"]?.stringValue, palette: palette, scheme: value["scheme"]?.stringValue))
        case "child_exited":
            return .childExited(exitCode: value["exit_code"]?.streamInteger)
        default:
            return .unknown(type: type)
        }
    }
}

extension JSONValue {
    /// A whole number that fits an `Int`.
    fileprivate var streamInteger: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) <= 9_007_199_254_740_992 else {
            return nil
        }
        return Int(value)
    }
}
