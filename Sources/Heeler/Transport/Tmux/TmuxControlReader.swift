import Foundation

/// One command's reply on a tmux control-mode client: the lines between its
/// `%begin` and its `%end` or `%error` (ADR 0045).
struct TmuxControlReply: Equatable, Sendable {
    /// tmux's number for the command. It counts every command the server ran,
    /// so it says nothing about which of this client's commands it was.
    var number: UInt64
    /// The command was one this client wrote. The commands the client was
    /// started with, one block each, and commands from elsewhere say false.
    var fromClient: Bool
    /// `%end` rather than `%error`.
    var succeeded: Bool
    /// What the command printed, a line each without its newline, with the
    /// bytes tmux wrote: `capture-pane -e` lines keep their escape sequences.
    var lines: [Data]
}

/// The notifications an Attach acts on. Every other one is `.other`.
enum TmuxControlNotification: Equatable, Sendable {
    /// `pause-after` paused the pane: tmux drops its output until it continues.
    case paused(pane: String)
    case continued(pane: String)
    case sessionsChanged
    /// A window left the client's session: closed, or unlinked from it.
    case windowClosed(window: String)
    /// A window outside the client's session closed or left its last session.
    case unlinkedWindowClosed(window: String)
    case layoutChanged(window: String)
    case clientSessionChanged
    case clientDetached
    case sessionWindowChanged
    /// The client was moved to another session, as tmux does when the one it
    /// was attached to ends and `detach-on-destroy` is off.
    case sessionChanged(session: String)
    /// Any other notification, by its name with the `%`.
    case other(name: String)
}

/// Reads what a tmux control-mode client prints (ADR 0045), in whatever pieces
/// the channel delivers it. Between a `%begin` and the `%end` or `%error` with
/// the same time and number every line belongs to the block, so a captured
/// pane that shows `%end` lines cannot end one early. Outside a block, a line
/// is pane output or a notification; anything else (a shell's message, an
/// empty line) is dropped.
struct TmuxControlReader: Sendable {
    enum Event: Equatable, Sendable {
        case reply(TmuxControlReply)
        /// Bytes the pane wrote, its octal escapes decoded. `%output` and the
        /// `%extended-output` that `pause-after` turns it into read the same.
        case output(pane: String, bytes: Data)
        case notification(TmuxControlNotification)
        /// The client is ending. tmux gives a reason for some endings.
        case exit(reason: String?)
    }

    /// A line or a block grew past the reader's limit: either this is not a
    /// control client's stream, or it is more than Heeler holds in memory.
    struct Overflow: Error, Equatable {}

    private struct Block: Sendable {
        /// What follows `%begin` on its line; the closing line repeats it.
        var guardFields: Data
        var number: UInt64
        var fromClient: Bool
        var lines: [Data] = []
        var size = 0
    }

    private let lineLimit: Int
    private let blockLimit: Int
    private var pending = Data()
    /// How much of `pending` is known to hold no newline.
    private var searched = 0
    private var block: Block?

    init(lineLimit: Int = 16 << 20, blockLimit: Int = 64 << 20) {
        self.lineLimit = lineLimit
        self.blockLimit = blockLimit
    }

    mutating func read(_ bytes: Data) throws -> [Event] {
        pending.append(bytes)
        var events: [Event] = []
        var lineStart = pending.startIndex
        var searchFrom = pending.index(lineStart, offsetBy: searched)
        while let newline = pending[searchFrom...].firstIndex(of: 0x0A) {
            let line = Data(pending[lineStart..<newline])
            guard line.count <= lineLimit else { throw Overflow() }
            if let event = try take(line) { events.append(event) }
            lineStart = pending.index(after: newline)
            searchFrom = lineStart
        }
        pending.removeSubrange(pending.startIndex..<lineStart)
        searched = pending.count
        guard pending.count <= lineLimit else { throw Overflow() }
        return events
    }

    private mutating func take(_ line: Data) throws -> Event? {
        if var open = block {
            if let succeeded = Self.closes(open, line) {
                block = nil
                return .reply(
                    TmuxControlReply(
                        number: open.number, fromClient: open.fromClient, succeeded: succeeded, lines: open.lines))
            }
            open.size += line.count + 1
            guard open.size <= blockLimit else { throw Overflow() }
            open.lines.append(line)
            block = open
            return nil
        }
        guard line.first == UInt8(ascii: "%") else { return nil }
        let (nameBytes, arguments) = Self.firstWord(of: line)
        let name = String(decoding: nameBytes, as: UTF8.self)
        switch name {
        case "%begin":
            guard let opened = Self.begins(arguments) else { return .notification(.other(name: name)) }
            block = opened
            return nil
        case "%output":
            guard let arguments else { return .notification(.other(name: name)) }
            let (pane, data) = Self.firstWord(of: arguments)
            return .output(pane: String(decoding: pane, as: UTF8.self), bytes: Self.unescaped(data ?? Data()))
        case "%extended-output":
            guard let arguments else { return .notification(.other(name: name)) }
            let (pane, rest) = Self.firstWord(of: arguments)
            return .output(
                pane: String(decoding: pane, as: UTF8.self),
                bytes: Self.unescaped(Self.extendedOutputValue(rest ?? Data())))
        case "%exit":
            guard let arguments, !arguments.isEmpty else { return .exit(reason: nil) }
            return .exit(reason: String(decoding: arguments, as: UTF8.self))
        case "%sessions-changed":
            return .notification(.sessionsChanged)
        case "%client-session-changed":
            return .notification(.clientSessionChanged)
        case "%client-detached":
            return .notification(.clientDetached)
        case "%session-window-changed":
            return .notification(.sessionWindowChanged)
        default:
            return .notification(Self.notification(name, about: arguments))
        }
    }

    /// The notifications that name one pane or window first.
    private static func notification(_ name: String, about arguments: Data?) -> TmuxControlNotification {
        guard let arguments else { return .other(name: name) }
        let subject = String(decoding: firstWord(of: arguments).word, as: UTF8.self)
        switch name {
        case "%pause": return .paused(pane: subject)
        case "%continue": return .continued(pane: subject)
        case "%window-close": return .windowClosed(window: subject)
        case "%unlinked-window-close": return .unlinkedWindowClosed(window: subject)
        case "%layout-change": return .layoutChanged(window: subject)
        case "%session-changed": return .sessionChanged(session: subject)
        default: return .other(name: name)
        }
    }

    /// `<time> <number> <flags>` after `%begin`. Flags' lowest bit marks a
    /// command this client wrote.
    private static func begins(_ arguments: Data?) -> Block? {
        guard let arguments else { return nil }
        let fields = arguments.split(separator: 0x20, omittingEmptySubsequences: false)
        guard fields.count == 3,
            let number = UInt64(String(decoding: fields[1], as: UTF8.self)),
            let flags = Int(String(decoding: fields[2], as: UTF8.self))
        else { return nil }
        var guardFields = Data(" ".utf8)
        guardFields.append(arguments)
        return Block(guardFields: guardFields, number: number, fromClient: flags & 1 != 0)
    }

    /// Whether `line` closes `block`, and how.
    private static func closes(_ block: Block, _ line: Data) -> Bool? {
        for (prefix, succeeded) in [(endPrefix, true), (errorPrefix, false)]
        where line.count == prefix.count + block.guardFields.count && line.starts(with: prefix)
            && line.dropFirst(prefix.count) == block.guardFields
        {
            return succeeded
        }
        return nil
    }

    private static let endPrefix = Data("%end".utf8)
    private static let errorPrefix = Data("%error".utf8)

    /// The bytes up to the first space, and what follows it (nil without a space).
    private static func firstWord(of data: Data) -> (word: Data, rest: Data?) {
        guard let space = data.firstIndex(of: 0x20) else { return (data, nil) }
        return (data[data.startIndex..<space], data[data.index(after: space)...])
    }

    /// `%extended-output`'s value follows its age and any later fields, after
    /// the first ` : `. The value itself can hold ` : `.
    private static func extendedOutputValue(_ fields: Data) -> Data {
        if let separator = fields.range(of: Data(" : ".utf8)) {
            return fields[separator.upperBound...]
        }
        return Data()
    }

    /// tmux writes bytes below 0x20 and the backslash as `\ooo`; every other
    /// byte, UTF-8 included, as it is. A backslash without three octal digits
    /// after it is kept, since only tmux's own escapes are decoded.
    static func unescaped(_ data: Data) -> Data {
        guard data.contains(0x5C) else { return Data(data) }
        let bytes = [UInt8](data)
        var decoded = Data(capacity: bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C, index + 3 < bytes.count,
                let value = octalByte(bytes[index + 1], bytes[index + 2], bytes[index + 3])
            {
                decoded.append(value)
                index += 4
            } else {
                decoded.append(byte)
                index += 1
            }
        }
        return decoded
    }

    private static func octalByte(_ high: UInt8, _ middle: UInt8, _ low: UInt8) -> UInt8? {
        let zero = UInt8(ascii: "0")
        guard (zero...zero + 3).contains(high), (zero...zero + 7).contains(middle), (zero...zero + 7).contains(low)
        else { return nil }
        return (high - zero) << 6 | (middle - zero) << 3 | (low - zero)
    }
}
