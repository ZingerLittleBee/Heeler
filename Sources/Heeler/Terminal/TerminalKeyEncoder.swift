import Foundation

/// Encodes a key named in herdr-core's grammar (`enter`, `ctrl+s`, `alt+x`,
/// `f5`) to the bytes a terminal sends for it in the program's keyboard mode. A
/// Template's `submit` and `stop` keys are written in this grammar, and writing
/// a key through an Attach is how Composer Send presses one without the core's
/// `terminal.keys` (ADR 0035). Bytes follow Ghostty's encoder, which
/// `TerminalKeyModifiersTests` checks across the grammar. Nil: not a key in the
/// grammar, or one a terminal sends nothing for.
enum TerminalKeyEncoder {
    static func encode(_ spec: String, modes: TerminalModeTracker) -> Data? {
        guard let (key, modifiers) = parse(spec) else { return nil }
        let flags = KittyFlags(rawValue: modes.kittyKeyboardFlags)
        let bytes =
            flags.isEmpty
            ? legacy(key, modifiers, applicationCursor: modes.usesApplicationCursorKeys)
            : kitty(key, modifiers, flags)
        return bytes.isEmpty ? nil : Data(bytes.utf8)
    }

    private struct Modifiers: OptionSet {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let alt = Modifiers(rawValue: 2)
        static let ctrl = Modifiers(rawValue: 4)
        static let superKey = Modifiers(rawValue: 8)

        /// As an escape sequence carries them.
        var parameter: Int { rawValue + 1 }
    }

    private struct KittyFlags: OptionSet {
        let rawValue: UInt8
        static let reportEvents = KittyFlags(rawValue: 2)
        static let reportAlternates = KittyFlags(rawValue: 4)
        static let reportAll = KittyFlags(rawValue: 8)
        static let reportAssociatedText = KittyFlags(rawValue: 16)
    }

    private enum Key {
        /// Types `character`, or `shifted` under Shift.
        case typing(Character, shifted: Character)
        /// Enter, Tab, Backspace and Esc, whose kitty code is their control byte.
        case control(UInt8)
        /// `CSI <code> ~`.
        case tilde(Int)
        /// `CSI <final>`, or `CSI 1 ; <modifiers> <final>`.
        case final(Character)
        /// F1, F2 and F4: `SS3 <final>` alone.
        case functionFinal(Character)
        /// F3: `SS3 R` alone, and otherwise a tilde key.
        case f3
    }

    // MARK: The grammar (`keys.rs`)

    private static func parse(_ spec: String) -> (Key, Modifiers)? {
        var parts = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.popLast(), !name.isEmpty, let key = key(named: name) else { return nil }
        var modifiers: Modifiers = []
        for part in parts {
            switch part {
            case "shift": modifiers.insert(.shift)
            case "ctrl", "control": modifiers.insert(.ctrl)
            case "alt", "meta", "opt": modifiers.insert(.alt)
            case "super", "cmd": modifiers.insert(.superKey)
            default: return nil
            }
        }
        return (key, modifiers)
    }

    private static func key(named name: String) -> Key? {
        if name.count == 1, let character = name.first,
            let shifted = shiftedCharacters[character]
        {
            return .typing(character, shifted: shifted)
        }
        switch name {
        case "backslash": return .typing("\\", shifted: "|")
        case "space": return .typing(" ", shifted: " ")
        case "backspace": return .control(0x7F)
        case "enter", "return": return .control(0x0D)
        case "tab": return .control(0x09)
        case "esc", "escape": return .control(0x1B)
        case "delete", "del": return .tilde(3)
        case "insert": return .tilde(2)
        case "pageup", "pgup": return .tilde(5)
        case "pagedown", "pgdn": return .tilde(6)
        case "home": return .final("H")
        case "end": return .final("F")
        case "up": return .final("A")
        case "down": return .final("B")
        case "right": return .final("C")
        case "left": return .final("D")
        case "f1": return .functionFinal("P")
        case "f2": return .functionFinal("Q")
        case "f3": return .f3
        case "f4": return .functionFinal("S")
        case "f5": return .tilde(15)
        case "f6": return .tilde(17)
        case "f7": return .tilde(18)
        case "f8": return .tilde(19)
        case "f9": return .tilde(20)
        case "f10": return .tilde(21)
        case "f11": return .tilde(23)
        case "f12": return .tilde(24)
        default: return nil
        }
    }

    /// The characters the grammar names, on a US layout.
    private static let shiftedCharacters: [Character: Character] = {
        var table: [Character: Character] = [
            "`": "~", "\\": "|", "[": "{", "]": "}", ",": "<", "=": "+", "-": "_", ".": ">", "'": "\"", ";": ":",
            "/": "?", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(",
            "0": ")",
        ]
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            guard let letter = UnicodeScalar(scalar).map(Character.init) else { continue }
            table[letter] = Character(letter.uppercased())
        }
        return table
    }()

    // MARK: Legacy

    private static let csi = "\u{1B}["

    private static func legacy(_ key: Key, _ modifiers: Modifiers, applicationCursor: Bool) -> String {
        switch key {
        case .typing(let character, let shifted):
            return legacyTyping(character, shifted: shifted, modifiers)
        case .control(let byte):
            return legacyControl(byte, modifiers)
        case .tilde(let code):
            return modifiers.isEmpty ? "\(csi)\(code)~" : "\(csi)\(code);\(modifiers.parameter)~"
        case .final(let final):
            if modifiers.isEmpty { return (applicationCursor ? "\u{1B}O" : csi) + String(final) }
            return "\(csi)1;\(modifiers.parameter)\(final)"
        case .functionFinal(let final):
            return modifiers.isEmpty ? "\u{1B}O\(final)" : "\(csi)1;\(modifiers.parameter)\(final)"
        case .f3:
            return modifiers.isEmpty ? "\u{1B}OR" : "\(csi)13;\(modifiers.parameter)~"
        }
    }

    private static func legacyControl(_ byte: UInt8, _ modifiers: Modifiers) -> String {
        let character = String(UnicodeScalar(byte))
        if byte == 0x7F {
            // Ctrl chooses ^H and Alt adds Escape; Shift does not change
            // Backspace, including when all three modifiers are held.
            let base = modifiers.contains(.ctrl) ? "\u{8}" : character
            return (modifiers.contains(.alt) ? "\u{1B}" : "") + base
        }
        switch modifiers {
        case []: return character
        case .alt: return "\u{1B}\(character)"
        case .shift where byte == 0x09: return "\(csi)Z"
        default: return "\(csi)27;\(modifiers.parameter);\(byte)~"
        }
    }

    private static func legacyTyping(
        _ character: Character, shifted: Character, _ modifiers: Modifiers
    ) -> String {
        let escape = modifiers.contains(.alt) ? "\u{1B}" : ""
        // Super types nothing of its own, so only Alt's prefix leaves a trace.
        guard !modifiers.contains(.superKey) else {
            return escape.isEmpty ? "" : escape + String(character)
        }
        let isShifted = modifiers.contains(.shift)
        guard modifiers.contains(.ctrl) else { return escape + String(isShifted ? shifted : character) }
        if character.isLetter, isShifted {
            return "\(csi)\(codepoint(character));\(modifiers.parameter)u"
        }
        // Shift has already chosen the punctuation; it is not reported again.
        let chosen = isShifted ? shifted : character
        if let alias = controlAlias(chosen) { return escape + String(UnicodeScalar(alias)) }
        if "019".contains(chosen) { return escape + String(chosen) }
        return "\(csi)\(codepoint(chosen));\(modifiers.subtracting(.shift).parameter)u"
    }

    /// What Ctrl makes of a character, for those that have a control byte and
    /// are not kept apart from another key (Ctrl-I from Tab, Ctrl-M from Enter).
    private static func controlAlias(_ character: Character) -> UInt8? {
        switch character {
        case "i", "m": return nil
        case " ", "2": return 0
        case "3": return 27
        case "\\", "4": return 28
        case "]", "5": return 29
        case "^", "~", "6": return 30
        case "_", "/", "7": return 31
        case "?", "8": return 127
        default:
            guard character.isLetter, let value = character.asciiValue else { return nil }
            return value - 96
        }
    }

    private static func codepoint(_ character: Character) -> Int {
        Int(character.unicodeScalars.first?.value ?? 0)
    }

    // MARK: Kitty

    private static func kitty(_ key: Key, _ modifiers: Modifiers, _ flags: KittyFlags) -> String {
        let reportsAll = flags.contains(.reportAll)
        let reportsEvents = flags.contains(.reportEvents)
        switch key {
        case .control(let byte):
            if !reportsAll, modifiers.isEmpty, byte != 0x1B { return String(UnicodeScalar(byte)) }
            let press = "\(csi)\(byte)\(modifierField(modifiers))u"
            // Enter, Tab and Backspace report a release only once every key does.
            guard reportsEvents, reportsAll || byte == 0x1B else { return press }
            return press + "\(csi)\(byte);\(modifiers.parameter):3u"
        case .typing(let character, let shifted):
            let code = codepoint(character)
            let release = reportsEvents ? "\(csi)\(code);\(modifiers.parameter):3u" : ""
            return kittyTypingPress(character, shifted: shifted, modifiers, flags) + release
        case .tilde(let code):
            return kittyTilde(code, modifiers, reportsEvents: reportsEvents)
        case .f3:
            return kittyTilde(13, modifiers, reportsEvents: reportsEvents)
        case .final(let final), .functionFinal(let final):
            if reportsEvents {
                return "\(csi)1;\(modifiers.parameter):1\(final)\(csi)1;\(modifiers.parameter):3\(final)"
            }
            return modifiers.isEmpty ? "\(csi)\(final)" : "\(csi)1;\(modifiers.parameter)\(final)"
        }
    }

    private static func kittyTypingPress(
        _ character: Character, shifted: Character, _ modifiers: Modifiers, _ flags: KittyFlags
    ) -> String {
        let isShifted = modifiers.contains(.shift)
        let typesText = modifiers.subtracting(.shift).isEmpty
        let typed = isShifted ? shifted : character
        if !flags.contains(.reportAll), typesText { return String(typed) }
        var code = String(codepoint(character))
        if flags.contains(.reportAlternates), isShifted, shifted != character,
            !modifiers.contains(.superKey)
        {
            code += ":\(codepoint(shifted))"
        }
        if flags.contains(.reportAssociatedText), typesText {
            let parameter = modifiers.isEmpty ? "" : String(modifiers.parameter)
            return "\(csi)\(code);\(parameter);\(codepoint(typed))u"
        }
        return "\(csi)\(code)\(modifierField(modifiers))u"
    }

    private static func kittyTilde(_ code: Int, _ modifiers: Modifiers, reportsEvents: Bool) -> String {
        let press = "\(csi)\(code)\(modifierField(modifiers))~"
        return reportsEvents ? press + "\(csi)\(code);\(modifiers.parameter):3~" : press
    }

    private static func modifierField(_ modifiers: Modifiers) -> String {
        modifiers.isEmpty ? "" : ";\(modifiers.parameter)"
    }
}
