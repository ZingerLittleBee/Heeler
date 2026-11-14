import Foundation

/// What Heeler asks tmux to type into a Pane (ADR 0045).
enum TmuxInput: Equatable, Sendable {
    /// Printable text, for `send-keys -l`. It never holds a control character.
    case text(String)
    /// A key by tmux's name, for `send-keys`.
    case key(TmuxKey)
    /// A bracketed paste's text, pasted from a buffer so that tmux brackets it
    /// as the Pane's program asked.
    case paste(String)
}

/// A key as tmux names it: `Enter`, `BTab`, `C-a`, `M-Up`, `C-S-A`.
struct TmuxKey: Equatable, Sendable {
    let name: String
    /// The key has no legacy encoding (Shift with Enter, Space or Escape, Ctrl
    /// with Enter, Tab, Backspace or Escape, Ctrl+Shift with Tab or a letter,
    /// Ctrl with a digit or with punctuation other than `@ [ \ ] ^ _ ? /`): tmux
    /// encodes it only while the Pane is in an extended keys mode, and
    /// otherwise types its name into the Pane or sends its nearest legacy key.
    let isExtended: Bool

    /// How tmux encodes keys for a Pane: `VT10x`, `Ext 1` or `Ext 2` from tmux
    /// 3.5 on. Earlier versions have no such format and read it as empty.
    static let paneKeyModeFormat = "#{pane_key_mode}"

    /// Whether Heeler sends this key to a Pane whose `#{pane_key_mode}` reads
    /// `paneKeyMode`. A key with no legacy encoding goes only in an extended
    /// mode, so never before tmux 3.5: tmux would type its name into the Pane,
    /// or send the nearest legacy key, which can submit a prompt.
    func isSent(whilePaneKeyModeReads paneKeyMode: String) -> Bool {
        guard isExtended else { return true }
        let mode = paneKeyMode.trimmingCharacters(in: .whitespacesAndNewlines)
        return mode == "Ext 1" || mode == "Ext 2"
    }
}

/// Reads the bytes the terminal view writes for Direct Input and the tools
/// keyboard back into what tmux should type (ADR 0045). The view encodes a key
/// for its own keyboard mode, so the same key can arrive in legacy form, in
/// xterm's modifyOtherKeys form (`CSI 27;m;c~`) or in the CSI u form of kitty's
/// protocol; each reads as the one tmux name, and tmux encodes it again for the
/// mode the Pane's program asked for. Pure.
///
/// Text runs become `.text`, control bytes and escape sequences become keys,
/// and a bracketed paste becomes `.paste`. What is no key is dropped: the
/// view's answers to queries (tmux answered the program already), focus and
/// mouse reports, key releases, and keys tmux cannot name (Super, Hyper and
/// kitty's keys without a character). `TmuxInputStream` reads the view's
/// writes one after another.
enum TmuxKeyReader {
    /// Reads `bytes` whole: a paste with no end marker runs to their end.
    static func read(_ bytes: Data) -> [TmuxInput] {
        var stream = TmuxInputStream()
        var inputs = stream.read(bytes, moreQueued: false)
        append(stream.end(), to: &inputs)
        return inputs
    }

    /// Keys and text in `bytes` up to the start of a bracketed paste, and
    /// where the paste's text begins, after its start marker.
    static func keys(in bytes: [UInt8]) -> (inputs: [TmuxInput], pasteAt: Int?) {
        var cursor = Cursor(bytes: bytes)
        var inputs: [TmuxInput] = []
        while let read = cursor.next() {
            if let input = read { append([input], to: &inputs) }
        }
        return (inputs, cursor.pasteAt)
    }

    /// Appends `more` to `inputs`, one text run where two meet.
    static func append(_ more: [TmuxInput], to inputs: inout [TmuxInput]) {
        for input in more {
            if case .text(let text) = input, case .text(let run)? = inputs.last {
                inputs[inputs.count - 1] = .text(run + text)
            } else {
                inputs.append(input)
            }
        }
    }

    // MARK: Keys

    private struct Modifiers: OptionSet {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let alt = Modifiers(rawValue: 2)
        static let ctrl = Modifiers(rawValue: 4)

        /// The bits of an xterm modifier parameter (1 + bits) tmux can name,
        /// or nil when Super, Hyper or Meta is among them. Caps and Num Lock
        /// are not modifiers of the key.
        init?(parameter: Int) {
            let bits = max(parameter, 1) - 1
            guard bits & 0b11_1000 == 0 else { return nil }
            rawValue = bits & 0b111
        }

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// tmux's prefixes, in the order tmux writes them.
        var prefix: String {
            (contains(.ctrl) ? "C-" : "") + (contains(.alt) ? "M-" : "") + (contains(.shift) ? "S-" : "")
        }
    }

    private enum Base {
        case enter, tab, backspace, escape
        /// A key whose modifiers never make it extended: cursor, editing and
        /// function keys.
        case named(String)
        case character(Unicode.Scalar, shifted: Unicode.Scalar?)
    }

    /// Ctrl with these types a control character, which a desktop terminal
    /// sends in place of the key: Heeler sends that character's key, as tmux
    /// reads it from a desktop terminal. tmux's own `C-@`, `C-[` and `C-?`
    /// encode as Ctrl with the character in an extended mode on 3.7b, where
    /// the desktop terminal's key reads as C-Space, Escape and Backspace
    /// (`tmux-input-v1.json`).
    private static let controlCharacters: [Unicode.Scalar: UInt8] = [
        "@": 0x00, "[": 0x1B, "\\": 0x1C, "]": 0x1D, "^": 0x1E, "_": 0x1F, "?": 0x7F,
    ]

    /// What Shift types on a US layout, for a CSI u key that did not say.
    private static let shiftedCharacters: [Unicode.Scalar: Unicode.Scalar] = [
        "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(",
        "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">",
        "/": "?",
    ]

    private static func input(_ base: Base, _ modifiers: Modifiers) -> TmuxInput? {
        var modifiers = modifiers
        switch base {
        case .enter:
            return key("Enter", modifiers, extended: !modifiers.isDisjoint(with: [.shift, .ctrl]))
        case .tab:
            let name = modifiers.contains(.shift) ? "BTab" : "Tab"
            modifiers.remove(.shift)
            return key(name, modifiers, extended: modifiers.contains(.ctrl))
        case .backspace:
            // Shift does not change Backspace, as in a legacy terminal.
            modifiers.remove(.shift)
            return key("BSpace", modifiers, extended: modifiers.contains(.ctrl))
        case .escape:
            return key("Escape", modifiers, extended: !modifiers.isDisjoint(with: [.shift, .ctrl]))
        case .named(let name):
            return key(name, modifiers, extended: false)
        case .character(let character, let shifted):
            return input(character, shifted: shifted, modifiers)
        }
    }

    private static func input(_ character: Unicode.Scalar, shifted: Unicode.Scalar?, _ modifiers: Modifiers) -> TmuxInput? {
        var modifiers = modifiers
        if character == " " {
            if modifiers.isEmpty { return .text(" ") }
            return key("Space", modifiers, extended: modifiers.contains(.shift))
        }
        if character.isASCII, character.properties.isAlphabetic {
            let lower = Character(character).lowercased(), upper = Character(character).uppercased()
            if character.properties.isUppercase { modifiers.insert(.shift) }
            let shift = modifiers.contains(.shift)
            if modifiers.isDisjoint(with: [.ctrl, .alt]) { return .text(shift ? upper : lower) }
            if modifiers.contains(.ctrl), shift { return key(upper, modifiers, extended: true) }
            modifiers.remove(.shift)
            return key(shift ? upper : lower, modifiers, extended: false)
        }
        var typed = character
        if modifiers.contains(.shift) {
            // Shift has chosen the character; it is not reported again.
            typed = shifted ?? shiftedCharacters[character] ?? Self.uppercase(character)
            modifiers.remove(.shift)
        }
        guard !isControl(typed) else { return nil }
        if modifiers.isEmpty { return .text(String(typed)) }
        if modifiers.contains(.ctrl), let byte = controlCharacters[typed] {
            return control(byte, modifiers.subtracting(.ctrl))
        }
        // Ctrl+/ reads as tmux's `C-/` in every mode measured.
        let extended = modifiers.contains(.ctrl) && typed != "/"
        return key(String(typed), modifiers, extended: extended)
    }

    private static func key(_ name: String, _ modifiers: Modifiers, extended: Bool) -> TmuxInput {
        .key(TmuxKey(name: modifiers.prefix + name, isExtended: extended))
    }

    private static func uppercase(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let upper = String(scalar).uppercased().unicodeScalars
        return upper.count == 1 ? upper.first ?? scalar : scalar
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// A control byte as the key a legacy terminal sends it for.
    private static func control(_ byte: UInt8, _ modifiers: Modifiers) -> TmuxInput? {
        switch byte {
        case 0x0D: input(.enter, modifiers)
        case 0x09: input(.tab, modifiers)
        case 0x1B: input(.escape, modifiers)
        case 0x7F: input(.backspace, modifiers)
        case 0x00: key("Space", modifiers.union(.ctrl), extended: false)
        case 0x01...0x1A: key(String(UnicodeScalar(byte + 0x60)), modifiers.union(.ctrl), extended: false)
        case 0x1C...0x1F: key(String(UnicodeScalar(byte + 0x40)), modifiers.union(.ctrl), extended: false)
        default: nil
        }
    }

    /// A key a CSI u or modifyOtherKeys sequence names by its code point.
    private static func base(code: Int, shifted: Int?) -> Base? {
        switch code {
        case 13: return .enter
        case 9: return .tab
        case 8, 127: return .backspace
        case 27: return .escape
        default:
            // kitty's keys without a character (keypad, media, modifiers) sit
            // in the Private Use Area.
            guard !(0xE000...0xF8FF).contains(code), let scalar = Unicode.Scalar(UInt32(clamping: code)),
                !isControl(scalar)
            else { return nil }
            return .character(scalar, shifted: shifted.flatMap { Unicode.Scalar(UInt32(clamping: $0)) })
        }
    }

    private static let tildeKeys: [Int: String] = [
        1: "Home", 2: "IC", 3: "DC", 4: "End", 5: "PPage", 6: "NPage", 7: "Home", 8: "End", 11: "F1", 12: "F2",
        13: "F3", 14: "F4", 15: "F5", 17: "F6", 18: "F7", 19: "F8", 20: "F9", 21: "F10", 23: "F11", 24: "F12",
    ]

    /// `CSI 1;m X` and SS3 finals. `R` is left out: it is also a cursor report.
    private static let finalKeys: [UInt8: String] = [
        0x41: "Up", 0x42: "Down", 0x43: "Right", 0x44: "Left", 0x48: "Home", 0x46: "End", 0x50: "F1",
        0x51: "F2", 0x53: "F4",
    ]

    // MARK: Reading bytes

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0
        /// Where a bracketed paste's text begins; reading stops there.
        private(set) var pasteAt: Int?

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        /// The next input; `.some(nil)` for bytes that held none; nil at the
        /// end, or at the start of a paste.
        mutating func next() -> TmuxInput?? {
            guard index < bytes.count, pasteAt == nil else { return nil }
            let byte = bytes[index]
            if byte == 0x1B { return .some(escape()) }
            if byte < 0x20 || byte == 0x7F {
                index += 1
                return .some(TmuxKeyReader.control(byte, []))
            }
            return .some(text())
        }

        /// Printable characters up to the next control byte; invalid UTF-8 and
        /// C1 controls are dropped.
        private mutating func text() -> TmuxInput? {
            var text = String.UnicodeScalarView()
            while index < bytes.count, bytes[index] >= 0x20, bytes[index] != 0x7F {
                let (scalar, length) = Self.scalar(in: bytes, at: index)
                index += length
                if let scalar, !TmuxKeyReader.isControl(scalar) { text.append(scalar) }
            }
            return text.isEmpty ? nil : .text(String(text))
        }

        private mutating func escape() -> TmuxInput? {
            let start = index
            guard start + 1 < bytes.count else {
                index += 1
                return TmuxKeyReader.input(.escape, [])
            }
            switch bytes[start + 1] {
            case UInt8(ascii: "["):
                if let input = csi() { return input }
                index = start + 2
                return TmuxKeyReader.input(.character("[", shifted: nil), .alt)
            case UInt8(ascii: "O") where start + 2 < bytes.count:
                index = start + 3
                if let name = TmuxKeyReader.finalKeys[bytes[start + 2]] ?? (bytes[start + 2] == 0x52 ? "F3" : nil) {
                    return TmuxKeyReader.input(.named(name), [])
                }
                index = start + 2
                return TmuxKeyReader.input(.character("O", shifted: nil), .alt)
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                if let end = stringEnd(from: start + 2, bell: bytes[start + 1] == UInt8(ascii: "]")) {
                    index = end
                    return nil
                }
            case 0x1B where start + 2 < bytes.count && [UInt8(ascii: "["), UInt8(ascii: "O")].contains(bytes[start + 2]):
                index = start + 1
                guard case .key(let key)? = escape() else { return nil }
                return .key(TmuxKey(name: Self.addingAlt(to: key.name), isExtended: key.isExtended))
            default:
                break
            }
            let next = bytes[start + 1]
            if next < 0x20 || next == 0x7F {
                index = start + 2
                return TmuxKeyReader.control(next, .alt)
            }
            let (scalar, length) = Self.scalar(in: bytes, at: start + 1)
            guard let scalar, !TmuxKeyReader.isControl(scalar) else {
                index = start + 1
                return TmuxKeyReader.input(.escape, [])
            }
            index = start + 1 + length
            return TmuxKeyReader.input(.character(scalar, shifted: nil), .alt)
        }

        /// `M-` among a name's prefixes, in tmux's order.
        private static func addingAlt(to name: String) -> String {
            guard !name.hasPrefix("M-"), !name.contains("-M-") else { return name }
            return name.hasPrefix("C-") ? "C-M-" + name.dropFirst(2) : "M-" + name
        }

        /// Where an OSC, DCS, SOS, PM or APC string ends, after its terminator.
        private func stringEnd(from start: Int, bell: Bool) -> Int? {
            var at = start
            while at < bytes.count {
                if bell, bytes[at] == 0x07 { return at + 1 }
                if bytes[at] == 0x1B, at + 1 < bytes.count, bytes[at + 1] == UInt8(ascii: "\\") { return at + 2 }
                at += 1
            }
            return nil
        }

        /// A control sequence at `index`; nil, with `index` unmoved, when it has
        /// no final byte. `.some(nil)` for a sequence that is no key.
        private mutating func csi() -> TmuxInput?? {
            var at = index + 2
            let parametersStart = at
            while at < bytes.count, (0x30...0x3F).contains(bytes[at]) { at += 1 }
            let parameters = Array(bytes[parametersStart..<at])
            let intermediatesStart = at
            while at < bytes.count, (0x20...0x2F).contains(bytes[at]) { at += 1 }
            guard at < bytes.count, (0x40...0x7E).contains(bytes[at]) else { return nil }
            let final = bytes[at]
            index = at + 1
            guard intermediatesStart == at,
                parameters.first.map({ !(0x3C...0x3F).contains($0) }) ?? true
            else { return .some(nil) }
            if final == UInt8(ascii: "M"), parameters.isEmpty {
                // An X10 mouse report: three bytes of button and position.
                index = min(bytes.count, index + 3)
                return .some(nil)
            }
            let fields = Self.fields(parameters)
            func field(_ position: Int, _ part: Int = 0) -> Int? {
                position < fields.count && part < fields[position].count ? fields[position][part] : nil
            }
            // kitty's event type: 3 is a release.
            guard field(1, 1) != 3 else { return .some(nil) }
            guard let modifiers = Modifiers(parameter: field(1) ?? 1) else { return .some(nil) }
            switch final {
            case UInt8(ascii: "~"):
                if field(0) == 200 {
                    pasteAt = index
                    return .some(nil)
                }
                if field(0) == 27, fields.count >= 3 {
                    guard let code = field(2), let base = TmuxKeyReader.base(code: code, shifted: nil) else {
                        return .some(nil)
                    }
                    return .some(TmuxKeyReader.input(base, modifiers))
                }
                guard let name = field(0).flatMap({ TmuxKeyReader.tildeKeys[$0] }) else { return .some(nil) }
                return .some(TmuxKeyReader.input(.named(name), modifiers))
            case UInt8(ascii: "u"):
                guard let code = field(0), let base = TmuxKeyReader.base(code: code, shifted: field(0, 1)) else {
                    return .some(nil)
                }
                if case .character(let character, _) = base, character != " ",
                    modifiers.isSubset(of: .shift), fields.count >= 3
                {
                    let scalars = fields[2].compactMap { $0.flatMap { Unicode.Scalar(UInt32(clamping: $0)) } }
                    let typed = String(String.UnicodeScalarView(scalars))
                    if !typed.isEmpty, !typed.unicodeScalars.contains(where: TmuxKeyReader.isControl) {
                        return .some(.text(typed))
                    }
                }
                return .some(TmuxKeyReader.input(base, modifiers))
            case UInt8(ascii: "Z"):
                return .some(TmuxKeyReader.input(.tab, modifiers.union(.shift)))
            default:
                guard let name = TmuxKeyReader.finalKeys[final] else { return .some(nil) }
                return .some(TmuxKeyReader.input(.named(name), modifiers))
            }
        }

        /// Parameters split at `;`, each split at `:`. An empty one reads as nil.
        private static func fields(_ parameters: [UInt8]) -> [[Int?]] {
            parameters.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false).map { field in
                field.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false).map {
                    Int(String(decoding: $0, as: UTF8.self))
                }
            }
        }

        /// One UTF-8 scalar at `at`, and the bytes it took; nil for a byte that
        /// starts none.
        private static func scalar(in bytes: [UInt8], at: Int) -> (Unicode.Scalar?, Int) {
            let lead = bytes[at]
            let length: Int
            switch lead {
            case 0x00...0x7F: return (Unicode.Scalar(lead), 1)
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default: return (nil, 1)
            }
            guard at + length <= bytes.count else { return (nil, 1) }
            var decoder = UTF8()
            var iterator = bytes[at..<(at + length)].makeIterator()
            guard case .scalarValue(let scalar) = decoder.decode(&iterator) else { return (nil, 1) }
            return (scalar, length)
        }
    }
}

/// The terminal view's input as it arrives, one write at a time (ADR 0045).
///
/// A bracketed paste goes on across writes until its end marker and is pasted
/// as one, so its line feeds never become Enter keys. Past `pasteLimit` bytes
/// what has arrived is pasted, at a character boundary, and the rest goes on
/// as a paste of its own.
///
/// A write that ends inside a paste's start marker waits for the next one:
/// `ESC [ 2`, `ESC [ 20` and `ESC [ 200` are no key. `ESC` and `ESC [` are
/// keys (Escape, Alt+[), and wait only while another write is already
/// queued; they join it only when it goes on with the marker, so a key typed
/// after Escape stays a key of its own. A write that ends inside a character
/// waits for the rest of it.
struct TmuxInputStream {
    /// A 1 MB `set-buffer` pasted exactly on 3.3a and 3.7b (ADR 0045).
    static let defaultPasteLimit = 1 << 20

    private static let pasteStart = Array("\u{1B}[200~".utf8)
    private static let pasteEnd = Array("\u{1B}[201~".utf8)

    let pasteLimit: Int
    /// The end of the last write, kept for the next.
    private var held: [UInt8] = []
    /// The text of a paste still open.
    private var paste: [UInt8]?

    init(pasteLimit: Int = defaultPasteLimit) {
        self.pasteLimit = max(pasteLimit, 1)
    }

    /// What `bytes` completes. `moreQueued` says another write already waits.
    mutating func read(_ bytes: Data, moreQueued: Bool) -> [TmuxInput] {
        var inputs: [TmuxInput] = []
        var data = Array(bytes)
        if !held.isEmpty {
            if Self.continues(held, with: data) {
                data = held + data
            } else {
                TmuxKeyReader.append(TmuxKeyReader.keys(in: held).inputs, to: &inputs)
            }
            held = []
        }
        var at = 0
        while at < data.count {
            if paste != nil {
                at = continuePaste(data, from: at, into: &inputs)
                continue
            }
            var segment = Array(data[at...])
            let read = TmuxKeyReader.keys(in: segment)
            if let pasteAt = read.pasteAt {
                TmuxKeyReader.append(read.inputs, to: &inputs)
                paste = []
                at += pasteAt
                continue
            }
            let kept = Self.unfinished(segment, moreQueued: moreQueued)
            if kept > 0 {
                held = Array(segment.suffix(kept))
                segment.removeLast(kept)
                TmuxKeyReader.append(TmuxKeyReader.keys(in: segment).inputs, to: &inputs)
            } else {
                TmuxKeyReader.append(read.inputs, to: &inputs)
            }
            at = data.count
        }
        return inputs
    }

    /// What is left once no more comes: an open paste runs to here, and kept
    /// bytes read as they are.
    mutating func end() -> [TmuxInput] {
        var inputs: [TmuxInput] = []
        if let body = paste, !body.isEmpty { inputs.append(.paste(String(decoding: body, as: UTF8.self))) }
        paste = nil
        TmuxKeyReader.append(TmuxKeyReader.keys(in: held).inputs, to: &inputs)
        held = []
        return inputs
    }

    /// Adds `bytes[start...]` to the open paste. Returns where reading goes
    /// on: after the end marker, or at the end of `bytes`.
    private mutating func continuePaste(_ bytes: [UInt8], from start: Int, into inputs: inout [TmuxInput]) -> Int {
        var body = paste ?? []
        let previous = body.count
        body.append(contentsOf: bytes[start...])
        // The end marker can begin in what an earlier write brought.
        if let end = Self.index(of: Self.pasteEnd, in: body, from: max(0, previous - (Self.pasteEnd.count - 1))) {
            if end > 0 { inputs.append(.paste(String(decoding: body[..<end], as: UTF8.self))) }
            paste = nil
            return start + end + Self.pasteEnd.count - previous
        }
        // Keep what could begin the end marker.
        while body.count - (Self.pasteEnd.count - 1) > pasteLimit {
            let cut = Self.characterStart(in: body, at: pasteLimit)
            inputs.append(.paste(String(decoding: body[..<cut], as: UTF8.self)))
            body.removeFirst(cut)
        }
        paste = body
        return bytes.count
    }

    /// How many bytes at the end of `bytes` wait for the next write.
    private static func unfinished(_ bytes: [UInt8], moreQueued: Bool) -> Int {
        for length in stride(from: pasteStart.count - 1, through: 1, by: -1) where bytes.count >= length {
            guard bytes.suffix(length).elementsEqual(pasteStart.prefix(length)) else { continue }
            // After another `ESC` it is that key's Alt.
            let start = bytes.count - length
            guard start == 0 || bytes[start - 1] != 0x1B else { break }
            if length >= 3 || moreQueued { return length }
            break
        }
        guard let lead = truncatedCharacter(in: bytes) else { return 0 }
        return bytes.count - lead + (lead > 0 && bytes[lead - 1] == 0x1B ? 1 : 0)
    }

    /// Whether `bytes` go on from `held`: with more of the paste's start
    /// marker, or with the rest of a character.
    private static func continues(_ held: [UInt8], with bytes: [UInt8]) -> Bool {
        if pasteStart.starts(with: held) {
            return pasteStart.starts(with: held + bytes.prefix(pasteStart.count - held.count))
        }
        return bytes.first.map { (0x80...0xBF).contains($0) } ?? false
    }

    /// Where a UTF-8 character that `bytes` end inside begins.
    private static func truncatedCharacter(in bytes: [UInt8]) -> Int? {
        var index = bytes.count - 1
        var continuations = 0
        while index >= 0, continuations < 3, (0x80...0xBF).contains(bytes[index]) {
            index -= 1
            continuations += 1
        }
        guard index >= 0 else { return nil }
        let length: Int
        switch bytes[index] {
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: return nil
        }
        return continuations + 1 < length ? index : nil
    }

    /// `at`, or the start of the character `at` falls inside.
    private static func characterStart(in bytes: [UInt8], at: Int) -> Int {
        var index = at
        while index > 0, at - index < 3, (0x80...0xBF).contains(bytes[index]) { index -= 1 }
        return index > 0 ? index : at
    }

    private static func index(of marker: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= marker.count, start <= bytes.count - marker.count else { return nil }
        return (start...(bytes.count - marker.count)).first { bytes[$0...].starts(with: marker) }
    }
}
