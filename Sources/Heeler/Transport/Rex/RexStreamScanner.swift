import Foundation

/// A terminal's size as its stream reports it.
struct RexTerminalGrid: Sendable, Equatable {
    var columns: Int
    var rows: Int
    /// A cell's size in pixels, or 0 when the server does not know it.
    var cellWidth: Int
    var cellHeight: Int
    /// The client that owned the block when the size was set, or nil.
    var owner: String?
}

/// A terminal's default colors as its stream reports them. A color left out
/// is the server's built-in one.
struct RexTerminalTheme: Sendable, Equatable {
    var foreground: String?
    var background: String?
    var cursor: String?
    /// Changes to the 256-color palette, each `index=RRGGBB`.
    var palette: [String]
    /// `light` or `dark`; nil when the terminal decides from the background.
    var scheme: String?
}

/// One of the stream's own messages.
enum RexStreamMessage: Sendable, Equatable {
    /// The terminal's size: one right after the snapshot, then one per change.
    case resize(RexTerminalGrid)
    /// The terminal's default colors, each replacing the last.
    case theme(RexTerminalTheme)
    /// The program exited. No program output follows; the stream stays open.
    case childExited(exitCode: Int?)
    /// A message of a type this build does not read, which it skips.
    case unknown(type: String)
}

/// Splits a Rex terminal stream (`rex.data.terminal.v1`) into the program's
/// bytes and the stream's own messages. Pure, and what it yields does not
/// depend on how the stream is cut into chunks, apart from where runs of
/// program bytes are split.
///
/// A stream starts with a snapshot of the terminal, which Heeler never
/// decodes: it paints from the server's VT redraw instead. The scanner skips
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
